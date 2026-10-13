package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.{getMTProtoClient, MessagesSaveDraft, ChatPeerFullExtras, UserResponse}
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, getChatBgDisplayPath, PresentationSnapshot, currentPresentation, trOr}
import ohos_app_cangjie_entry.utils.{isWhitelistedUrl, isSingleEmoji, safeAnimateTo, mimeTypeForExtension, formatScheduledCallStarts, parsePhoneNumber, formatPhoneNumber, formatFullDate, localDayIndexOf, hexStringFromColor, chatOpenPerfMark}
import ohos_app_cangjie_entry.interop.*
import kit.CoreFileKit.*
import kit.AbilityKit.{Want, Flags, AbilityResult}
import ohos.business_exception.BusinessException
import ohos.callback_invoke.*
import ohos.resource.__GenerateResource__

import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom, getDeepLinkRouter}

/** 最近一次系统 IME 高度（vp），进程级记忆：换聊天页仍可秒用（0 = 从未测到）。 */
var g_lastImeHeightVp: Float64 = 0.0

// 系统返回键：ChatRoomPage.ets onBackPressed 同步派发 chatRoomPage.backPressed。
// iOS 的媒体查看器（GalleryController）是盖在 ChatController 之上的模态层，关闭只 dismiss 自身
// （GalleryController.swift:1474 dismiss(forceAway:) → presentingViewController.dismiss），
// 会话页留在导航栈里。这里全屏查看器是本页内的覆盖层，返回键若不先交给本页，NavDestination 会把
// 整个会话页出栈。可见的会话页（handleAppear 登记、cleanup 按代注销）消费后同步回调
// chatRoom.backHandled，ArkTS 不再出栈。
let CHAT_ROOM_BACK_EVENT: String = "chatRoomPage.backPressed"
let CHAT_ROOM_BACK_HANDLED: String = "chatRoom.backHandled"
var g_chatRoomBackSubscribed: Bool = false
var g_chatRoomBackHandler: Option<() -> Bool> = None
var g_chatRoomBackGeneration: Int64 = 0

func registerChatRoomBackHandler(handler: () -> Bool): Int64 {
    if (!g_chatRoomBackSubscribed) {
        g_chatRoomBackSubscribed = true
        subscribe(CHAT_ROOM_BACK_EVENT, { _p: String =>
            match (g_chatRoomBackHandler) {
                case Some(h) => if (h()) { callArk(CHAT_ROOM_BACK_HANDLED, "{}") }
                case None => ()
            }
        })
    }
    g_chatRoomBackGeneration += 1
    g_chatRoomBackHandler = Some(handler)
    return g_chatRoomBackGeneration
}

func unregisterChatRoomBackHandler(generation: Int64): Unit {
    if (generation != 0 && generation == g_chatRoomBackGeneration) {
        g_chatRoomBackHandler = None
    }
}

/** 消息输入框的 id：底部面板的地球键靠它把焦点交回文字输入。 */
let CHAT_INPUT_FIELD_ID: String = "chatroom_message_input"
/** WP-D: 不可见焦点哨兵 —— RichEditorController 没有 stopEditing，收 IME 靠把焦点移到它上面。 */
let CHAT_FOCUS_SINK_ID: String = "chatroom_composer_focus_sink"
/**
 * WP-E: 输入框内容镜像节点的 id。RichEditor 在 uitest dumpLayout 里没有 text 属性，
 * 6.1 仓颉 ArkUI 绑定也没有 accessibilityText / accessibilityDescription 修饰符，
 * 自动化读不到已输入内容 —— 用一个 1×1 全透明 Text（同焦点哨兵做法）把 inputText
 * 挂进布局树，text 属性随每次输入变化同步刷新；不占布局、不可见。
 */
let CHAT_INPUT_MIRROR_ID: String = "chatroom_message_input_mirror"
// WP-D (S2-18/19/24) composer span markers: fontColor is the only per-span attribute the
// RichEditor reports back for spoiler / link / monospace / code-block, so each kind owns a colour.
let COMPOSER_SPOILER_COLOR: UInt32 = 0xFF8A8A8E
let COMPOSER_LINK_COLOR: UInt32 = 0xFF2481CC
let COMPOSER_CODE_COLOR: UInt32 = 0xFF5E5CE6
let COMPOSER_PRE_COLOR: UInt32 = 0xFF6E6E73
let COMPOSER_FONT_SIZE: Int64 = 16
let COMPOSER_DEFAULT_FONT_FAMILY: String = "HarmonyOS Sans"
let COMPOSER_MONO_FONT_FAMILY: String = "monospace"

/** 6 位大写 RGB（不含 alpha），供与 RichEditor 回报的 fontColor 字符串比对。 */
func composerHex6(color: UInt32): String {
    let digits = "0123456789ABCDEF".toRuneArray()
    var v = color & 0xFFFFFF
    var out = ""
    for (_i in 0..6) {
        out = digits[Int64(v & 0xF)].toString() + out
        v = v >> 4
    }
    return out
}

/** RichEditor 回报的颜色串（"#FFRRGGBB" 等）→ 6 位大写 RGB；取不到 6 位十六进制时返回空串。 */
func composerColorKey(value: String): String {
    var hex = ""
    for (r in value.toAsciiUpper().toRuneArray()) {
        let c = UInt32(r)
        let isDigit = c >= 0x30 && c <= 0x39
        let isHex = c >= 0x41 && c <= 0x46
        if (isDigit || isHex) { hex = hex + r.toString() }
    }
    let runes = hex.toRuneArray()
    if (runes.size < 6) { return "" }
    var out = ""
    for (i in (runes.size - 6)..runes.size) { out = out + runes[i].toString() }
    return out
}

/** 6 位 RGB → 不透明 ARGB；解析失败返回 fallback。 */
func composerParseColor(key: String, fallback: UInt32): UInt32 {
    let runes = key.toRuneArray()
    if (runes.size != 6) { return fallback }
    var v: UInt32 = 0
    for (r in runes) {
        let c = UInt32(r)
        var d: UInt32 = 0
        if (c >= 0x30 && c <= 0x39) { d = c - 0x30 }
        else if (c >= 0x41 && c <= 0x46) { d = c - 0x41 + 10 }
        else if (c >= 0x61 && c <= 0x66) { d = c - 0x61 + 10 }
        else { return fallback }
        v = (v << 4) | d
    }
    return v | 0xFF000000
}

/** RichEditor 回报的 fontWeight 既可能是枚举序号（Bold=9 / Bolder=11 / W600..W900=5..8）也可能是数值字重。 */
func composerWeightIsBold(weight: Int32): Bool {
    if (weight >= 600) { return true }
    if (weight == 9 || weight == 11) { return true }
    return weight >= 5 && weight <= 8
}

/** 一段 RichEditor 文本 span 的样式快照（供 Format 菜单切换与发送时抽取实体）。 */
class ComposerSpanStyle {
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strike: Bool = false
    var mono: Bool = false
    var colorKey: String = ""
    init() {}

    static func fromResult(ts: RichEditorTextStyleResult): ComposerSpanStyle {
        let st = ComposerSpanStyle()
        st.bold = composerWeightIsBold(ts.fontWeight)
        st.italic = match (ts.fontStyle) {
            case FontStyle.Italic => true
            case _ => false
        }
        match (ts.decoration.decorationType) {
            case Some(TextDecorationType.Underline) => st.underline = true
            case Some(TextDecorationType.LineThrough) => st.strike = true
            case _ => ()
        }
        st.mono = ts.fontFamily.toAsciiLower().contains("mono")
        st.colorKey = composerColorKey(ts.fontColor)
        return st
    }

    func isSpoiler(): Bool { return this.colorKey == composerHex6(COMPOSER_SPOILER_COLOR) }
    func isLink(): Bool { return this.colorKey == composerHex6(COMPOSER_LINK_COLOR) }
    func isCode(): Bool { return this.colorKey == composerHex6(COMPOSER_CODE_COLOR) }
    func isPre(): Bool { return this.colorKey == composerHex6(COMPOSER_PRE_COLOR) }

    func has(kind: String): Bool {
        match (kind) {
            case "bold" => return this.bold
            case "italic" => return this.italic
            case "underline" => return this.underline
            case "strike" => return this.strike
            case "spoiler" => return this.isSpoiler()
            case "code" => return this.isCode()
            case "pre" => return this.isPre()
            case "textUrl" => return this.isLink()
            case _ => return false
        }
    }

    func toRichStyle(baseColor: UInt32): RichEditorTextStyle {
        let color = if (this.colorKey.isEmpty()) { baseColor } else { composerParseColor(this.colorKey, baseColor) }
        let decorationType = if (this.underline) { TextDecorationType.Underline }
            else if (this.strike) { TextDecorationType.LineThrough }
            else { TextDecorationType.None }
        return RichEditorTextStyle(
            fontColor: color,
            fontSize: COMPOSER_FONT_SIZE,
            fontStyle: if (this.italic) { FontStyle.Italic } else { FontStyle.Normal },
            fontWeight: if (this.bold) { FontWeight.Bold } else { FontWeight.Normal },
            fontFamily: if (this.mono) { COMPOSER_MONO_FONT_FAMILY } else { COMPOSER_DEFAULT_FONT_FAMILY },
            decoration: TextDecorationOptions(decorationType: decorationType, color: color)
        )
    }
}
/** 实体键盘模式下的输入框（customKeyboard 绑定在它身上）。 */
let CHAT_INPUT_ENTITY_ID: String = "chatroom_message_input_entity"
/**
 * customKeyboard 迁移开关（方案：workflow_output/architecture/customkeyboard-migration.md）。
 * 包装层把 customKeyboard(None) 折算成**空 builder**（绑空键盘而非解绑，
 * text_field.cj:550 value ?? { => }），单字段无法在系统/实体键盘间干净切换 ——
 * 采用双字段方案：文本态字段（系统 IME）与实体态字段（绑 customKeyboard）
 * 条件互斥挂载，焦点即模式，光标常亮对齐 iOS inputView 语义。
 * false = 回退旧路径（面板作为页面布局条件渲染）。
 */
let USE_CUSTOM_KEYBOARD_CONTAINER: Bool = false

/** Page root Stack id; the message context overlay measures its own frame from it. */
let CHAT_ROOM_ROOT_ID: String = "chat_room_root"

/** Authority of shareable sandbox file URIs (AppScope/app.json5 bundleName). */
private let CHATROOM_FILE_URI_BUNDLE: String = "com.hmcangjie.telegram"

private var _chatSearchRequestedOnReturn: Bool = false
private var _chatSearchHandler: Option<() -> Unit> = None

// 改备注 / 改群名后广播给正在展示该 peer 的聊天页（对应 iOS Postbox peer 更新驱动标题刷新）。
private var _chatTitleRefreshHandler: Option<(Int64, String, String) -> Unit> = None

public func notifyPeerDisplayNameChanged(peerId: Int64, peerType: String, name: String): Unit {
    match (_chatTitleRefreshHandler) {
        case Some(handler) => handler(peerId, peerType, name)
        case None => ()
    }
}

/** Telegram MessageEntity 的 offset/length 使用 UTF-16 code units。 */
private func telegramUtf16Length(value: String): Int32 {
    var count: Int32 = 0
    for (rune in value.toRuneArray()) {
        count = count + if (UInt32(rune) > 0xffff) { 2 } else { 1 }
    }
    return count
}

public func requestChatSearchOnReturn(): Unit {
    _chatSearchRequestedOnReturn = true
    match (_chatSearchHandler) {
        case Some(handler) =>
            handler()
            _chatSearchRequestedOnReturn = false
        case None => ()
    }
}

private func registerChatSearchHandler(handler: () -> Unit): Unit {
    _chatSearchHandler = Some(handler)
}

private func consumeChatSearchOnReturn(): Bool {
    let requested = _chatSearchRequestedOnReturn
    _chatSearchRequestedOnReturn = false
    return requested
}

public class ChatEmojiEffectOverlayItem {
    public var token: Int64 = 0
    public var documentId: Int64 = 0
    public var x: Float64 = 0.0
    public var y: Float64 = 0.0
    public init() {}
}

/**
 * 聊天详情页面（Phase H 完整版 — 全媒体收发）
 * 
 * 对应 TelegramHarmony ChatPage.ets (1,202 行)
 * 对应 Telegram-iOS ChatController (聊天室主控制器)
 * 
 * 功能:
 * - 消息列表与实时轮询同步
 * - 回复/编辑预览条
 * - 长按消息操作（回复/编辑/删除/转发）
 * - Reactions 快速反应栏
 * - 📎 附件面板（Camera/Photo/Video/File/Location/Contact/Poll/Voice）
 * - 📷 PhotoPicker 图片选择网格
 * - 🖼 ImageViewer 全屏图片查看
 * - 🎬 VideoPlayer 全屏视频播放
 * - 🎤 VoiceRecorder 语音录制
 * - 🎵 语音消息播放
 * - 📄 文件下载与打开
 * - 发送照片/文件/语音（通过 MTProto）
 */
@HybridComponentEntry
@Component
public class ChatRoomPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @StorageLink["translationSettings"] var translationSettings: TranslationSettingsSnapshot = currentTranslationSettings()
    // diag-suite_settings_appearance-TC-0401-round5.md F-P3（round 3 F-3c 重述）：本屏此前对
    // @StorageLink/currentPresentation/themeVersion 命中全 0，整屏色板与字号在深色态下不随主题
    // 变——与设置根屏（AppearanceSettingsPage.cj:46）/聊天列表已接的同一份快照通道现在补齐。
    // 直接嵌套读取 this.presentation.<字段> 用于本文件自己 build() 内联绘制的元素是安全的
    // （build() 整体随 @StorageLink 变化重新执行，不是把值传给子组件），D-125 只在下面
    // MessageBubble(...) 调用点这一处才需要镜像 + 探针（见 refreshBubbleColorMirrors()）。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // F-P3 · MessageBubble(:1961) 的四个主题入参镜像（D-125：不得直接传 this.presentation.xxx
    // 给子组件构造点，必须先落到本文件自己的裸 @State 字段，由 refreshBubbleColorMirrors() 每次
    // build() 刷新）。MessageBubble 组件侧这四个字段保持 @State（F-2b 的结论：@Prop 在本 SDK
    // 无默认值，而四个调用点里有两个在所有 allowlist 之外），已挂载实例不会被回灌，因此镜像
    // 本身只在构造时生效——真正让主题切换落地的是下面 msgBubbleMountToggle 的重挂载守卫。
    @State var msgBubbleOutColorMirror: UInt32 = 0xFFD9FDD3
    @State var msgBubbleInColorMirror: UInt32 = 0xFFFFFFFF
    @State var msgBubbleOutTextColorMirror: UInt32 = 0xFF111111
    @State var msgBubbleInTextColorMirror: UInt32 = 0xFF000000
    // TC-0407 round4 (diag-suite_settings_appearance-TC-0407.md F-1): themed bubble outline
    // stroke colour mirror, same shape as the four mirrors above. Default MUST stay
    // 0x00000000 — it is the sentinel drawBubbleCanvas() checks via hasStroke before touching
    // ctx.strokeStyle, so the first frame (before the snapshot lands) never paints an outline
    // the source theme doesn't have.
    @State var msgBubbleStrokeColorMirror: UInt32 = 0x00000000
    // D-160 重挂载守卫的专用触发字段（不复用其它布尔状态，避免与别的渲染逻辑耦合）。
    // 由 refreshBubbleColorMirrors() 在四个镜像真的变化时翻转一次。
    @State var msgBubbleMountToggle: Bool = false

    // F-1（diag-suite_settings_appearance-TC-0411-round2.md RC-W3）：
    // WallpaperBackgroundComponent(:1878 调用点) 的全部构造参数都是无任何响应式装饰器的裸
    // public var（既非 @Prop 也非 @State），按 D-125/D-156 双重约束：调用点必须传本文件自己的
    // 裸 @State 镜像字段（不能是 this.chatWallpaperInfo.xxx 嵌套访问，D-125），且因为字段本身无
    // 回灌通道，镜像也只在组件构造那一刻生效（D-156）——本页壁纸组件在 chatWallpaperInfo 整体
    // 重新赋值（ensureLoaded()/reloadChatWallpaper()）时随父组件一起重新构造，不需要额外挂载
    // 守卫。逐字段镜像由 refreshBubbleColorMirrors() 每次 build() 刷新，形状抄同一函数已有的
    // msgBubble* 镜像。
    @State var wpTypeMirror: WallpaperType = WallpaperType.SolidColor
    @State var wpSolidColorMirror: UInt32 = 0xFFE8E6DF
    @State var wpGradientColorsMirror: Array<UInt32> = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]
    @State var wpGradientColorStartMirror: UInt32 = 0xFF8CA0D8
    @State var wpGradientColorEndMirror: UInt32 = 0xFF4A5F9E
    @State var wpGradientAngleMirror: Float64 = 180.0
    @State var wpPhaseMirror: Int32 = 0
    @State var wpImageUriMirror: String = ""
    @State var wpImageDisplayModeMirror: WallpaperImageDisplayMode = WallpaperImageDisplayMode.Cover
    @State var wpImageBlurEnabledMirror: Bool = false
    @State var wpImageBlurStrengthMirror: Int32 = 50
    @State var wpDimmingIntensityMirror: Float64 = 0.0
    @State var wpPatternColorMirror: UInt32 = 0xFF000000
    @State var wpPatternIntensityMirror: Float64 = 0.5
    @State var wpIsDarkModeMirror: Bool = false
    // F-3（diag-suite_settings_appearance-TC-0411-round3.md RC-3）：图案层的最后一跳——
    // getCurrentWallpaper() 已经把 patternFile/patternOverlayEnabled 解算好（服务层主题默认档
    // :790-791），但调用点此前没接。声明形态逐字同型于紧邻的 wpPatternColorMirror/
    // wpIsDarkModeMirror。
    @State var wpPatternFileMirror: String = ""
    // WallpaperBackgroundComponent copies all constructor arguments once. Reassigning
    // chatWallpaperInfo while a cached chat route becomes visible therefore does not update the
    // mounted child. Flip a dedicated branch whenever the resolved wallpaper is reloaded so the
    // component is reconstructed with the new theme-specific values.
    // S6-05：同 msgBubbleMountToggle 机制 —— per-chat 壁纸换成另一张图案时 wpPatternOverlayMirror
    // 分支不变（默认主题壁纸与云端图案壁纸都是 overlay=true），只有翻转本开关才会强制重建。
    @State var wpMountToggle: Bool = false
    // Auto-night can switch while the conversation itself is visible. The presentation snapshot
    // is the same reactive source used by the rest of this page; remember the effective mode so
    // the build probe below reloads the wallpaper exactly when that mode changes.
    @State var wpPresentationDarkMirror: Bool = currentPresentation().isDark
    @State var wpPatternOverlayMirror: Bool = false

    // 首帧即有标题：导航参数在 push 之前已写入（setSelectedChat），不必等 onAppear → ensureLoaded
    // 的下一帧。ensureLoaded 仍按同一规则回填（Saved Messages 等由 VM 改写）。
    @State var chatName: String = if (getSelectedChatName().size > 0) { getSelectedChatName() } else { "Chat" }
    @State var chatAvatarUrl: String = ""
    @State var peerIsVerified: Bool = false
    // 打开会话时从缓存 chat 读到的 left / broadcast 标志（origin/main）；E5 的 VM 镜像
    // channelJoinRequiredMirror / channelIsBroadcastMirror 在 startSubtitleAndPinnedSync 内持续回写，
    // 底栏判定两者取并集。
    @State var channelIsLeft: Bool = false
    @State var channelIsBroadcast: Bool = false
    @State var channelJoinBusy: Bool = false
    @State var channelMuteBusy: Bool = false
    @State var viewModel: ChatRoomViewModel = ChatRoomViewModel()
    @State var inputText: String = ""
    @State var interactiveBotStartPayload: String = ""
    // E5：未加入频道 / 超级群的 Join 输入面板（iOS ChatChannelSubscriberInputPanelNode）。
    // VM 的普通字段由 startSubtitleAndPinnedSync 回写到这些页面 @State（嵌套字段不可靠触发重绘）。
    @State var channelJoinRequiredMirror: Bool = false
    @State var channelJoinRequestNeededMirror: Bool = false
    @State var channelIsBroadcastMirror: Bool = false
    private var customEmojiDraftEntities: ArrayList<CustomEmojiDraftEntity> =
        ArrayList<CustomEmojiDraftEntity>()
    @State var displayMessages: ArrayList<MessageEntry> = ArrayList<MessageEntry>()
    // 消息 List 的懒加载数据源（见 MessageEntrySource.cj）；与 displayMessages 同步替换。
    private let messageSource: MessageEntrySource = MessageEntrySource()
    let listScroller = Scroller()
    private var _syncActive: Bool = false
    private var _syncGeneration: Int64 = 0
    
    // ==================== UI 状态 ====================
    
    // Extracted message context overlay.
    @State var messageContextVisible: Bool = false
    @State var messageContextDismissing: Bool = false
    @State var messageContextMessage: Message = Message()
    @State var messageContextSourceY: Float64 = 0.0
    @State var messageContextTargetY: Float64 = 0.0
    @State var messageContextSourceHeight: Float64 = 1.0
    @State var messageContextScreenHeight: Float64 = 800.0
    @State var messageContextScreenWidth: Float64 = 390.0
    /**
     * S2-37：贴纸面板长按预览改由页根 Stack 呈现（iOS PeekController 由 ChatController
     * 全屏 present，覆盖键盘页签条与输入栏）。请求包由面板构造，只有显隐走 @State；
     * 内容在翻转前写入，build 读到的即是本次请求。
     */
    private var stickerPreviewRequest: StickerPreviewRequest = StickerPreviewRequest()
    @State var stickerPreviewVisible: Bool = false
    @State var messageContextVisibleTop: Float64 = 0.0
    @State var messageContextVisibleBottom: Float64 = 800.0
    @State var messageContextIsSent: Bool = false
    @State var messageContextHasText: Bool = false
    @State var messageContextHasMedia: Bool = false
    @State var messageContextCanTranslate: Bool = false
    @State var messageContextPeerType: String = "user"
    @State var messageContextReadStats: Bool = false
    // iOS secondaryRightNavigationButtonForChatInterfaceState: Saved Messages
    // shows a "…" button when saved topics exist (hasSavedChats).
    @State var savedHasChats: Bool = false
    @State var showSavedModeMenu: Bool = false
    @State var messageContextSaveTone: Bool = false
    // S3-10: iOS Gallery_SaveImage / Gallery_SaveVideo (ChatInterfaceStateContextMenus.swift:1497)
    @State var messageContextSaveTitle: String = "Save Image"
    // S9-03 / S3-25: iOS CISCM:2055-2060 Cancel Sending / Remove (Saved Messages) / Delete
    @State var messageContextDeleteTitle: String = "Delete"
    var messageContextSenderNames: HashMap<Int64, String> = HashMap<Int64, String>()
    @State var messageContextIsPinned: Bool = false
    @State var messageContextHiddenStableId: Int64 = 0
    private var _messageContextGeneration: Int64 = 0
    @State var emojiEffectItems: Array<ChatEmojiEffectOverlayItem> = Array<ChatEmojiEffectOverlayItem>()
    private var _emojiEffectToken: Int64 = 0
    private var _previousEmojiEffectIndex: Int64 = -1

    // Phase P6-4: 回复消息跳转高亮
    @State var highlightedMessageId: Int64 = 0
    
    // 附件面板
    @State var showAttachmentPanel: Bool = false
    @State var isSendingMedia: Bool = false
    // P2-356: 剪贴板媒体粘贴预览发送面板
    @State var showPastePreview: Bool = false
    private var uploadMediaLabel: String = "Uploading..."
    
    // Phase H1.5: PhotoPicker
    @State var showPhotoPicker: Bool = false
    
    // Phase H2: ImageViewer（全屏图片查看器）
    @State var showImageViewer: Bool = false
    @State var imageViewerImages: ArrayList<ImageItem> = ArrayList<ImageItem>()
    @State var imageViewerIndex: Int64 = 0
    
    // Phase H3: VideoPlayer（全屏视频播放器）
    @State var showVideoPlayer: Bool = false
    @State var videoPlayerData: VideoData = VideoData()
    @State var isDownloadingVideo: Bool = false
    
    // Phase H4: VoiceRecorder（语音录制）
    @State var showVoiceRecorder: Bool = false
    
    // Phase H5.2: FileBrowser（文件选择器）
    @State var showFileBrowser: Bool = false
    // Phase P6-1: 视频选择模式标记（复用 FileBrowser）
    private var _videoSelectMode: Bool = false
    // Phase P6-11: 视频消息（圆形）选择模式
    private var _videoNoteMode: Bool = false
    
    // Phase I1: 消息搜索
    @State var showMessageSearch: Bool = false
    // S4-12: iOS ChatController.updateItemNodesSearchTextHighlightStates — the search query plus
    // the result message ids; bubbles of those messages paint the matched text. Plain members:
    // they only feed MessageEntry.searchHighlight (part of the render key) via rebuildDisplayMessages.
    private var _searchHighlightQuery: String = ""
    private var _searchHighlightIds: HashMap<Int64, Bool> = HashMap<Int64, Bool>()

    // Phase I2: Emoji 选择器
    /** 设置里的 Suggest Stickers by Emoji，进页面时读一次。 */
    @State var suggestStickersByEmoji: Bool = true
    /**
     * EntityKeyboardHost.tab 的镜像字段。
     * 调用点**必须**传本组件自己的裸 @State 字段：传函数返回值（如 currentEntityTab()）
     * 或嵌套字段访问时，子组件不会随依赖变化重新 build —— 这条在
     * auth/PhoneInputPage.cj:81 已有真机实测记录，我又踩了一次：页签点了不换面板。
     */
    /** 定时发送贴纸的时间选择器（iOS ChatScheduleTimeScreen 的等价物）。 */
    @State var showSchedulePicker: Bool = false
    // 语音消息：iOS ChatTextInputMediaRecordingButton —— 按住麦克风即录、松手即发、
    // 左滑取消、上滑锁定；点按切换 语音/圆形视频 模式（图标麦克风 ↔ 摄像机）。
    @State var voiceRecording: Bool = false
    @State var voiceLocked: Bool = false
    @State var voiceDuration: Int32 = 0
    @State var voiceWave: ArrayList<Int32> = ArrayList<Int32>()
    @State var mediaModeVideo: Bool = false
    @State var voicePlaybackEpoch: Int64 = 0
    private var _voiceActive: Bool = false
    private var _voiceFilePath: String = ""
    private var voiceTouchStartX: Float64 = 0.0
    private var voiceTouchStartY: Float64 = 0.0
    // 下载与播放共享一次用户意图。快速点另一条语音时，旧下载可以完成缓存，
    // 但不能在稍后反过来抢占当前播放器。
    private var _voicePlaybackRequestGeneration: Int64 = 0
    private var _pendingVoiceDownloadMessageId: Int64 = -1
    // 最近一条语音的资源预热去重。消息列表初次建立时 documentLocalPath 可能尚未
    // 从磁盘缓存回填，不能等第一次点击才做这一步。
    private var _voiceWarmMessageId: Int64 = -1
    // S032/S221：发送键长按 → ChatSendMessageContextScreen（iOS ChatSendMessageActionSheetController）
    @State var sendPressGeneration: Int64 = 0
    @State var sendPressActive: Bool = false
    @State var suppressNextSendClick: Bool = false
    @State var scheduleTargetSticker: StickerItem = StickerItem()
    @State var scheduleTargetGif: GifItem = GifItem()
    @State var scheduleInitialUnix: Int64 = 0
    @State var entityTab: String = "emoji"
    @State var showEmojiPicker: Bool = false
    /** 从实体键盘切回系统键盘时，让文本态字段挂载后自取焦点（🌐 键）。 */
    private var wantSystemKeyboardFocus: Bool = false
    /** iOS ChatInterfaceState：编辑态文本在 editMessage.inputState，composeInputState 保持编辑前的草稿。 */
    private var composeTextBeforeEdit: String = ""
    /** WP-D: 输入框迁到 RichEditor（选区回调 + 逐 span 样式）。blur 走 blurComposer()（焦点哨兵）。 */
    private let chatRichController: RichEditorController = RichEditorController()
    /** iOS 编辑菜单 Format 子菜单：选区存在时在输入栏下方显示；系统 剪切/复制/粘贴/全选 菜单不动。 */
    @State var composerFormatBarVisible: Bool = false
    @State var composerFormatSubmenuOpen: Bool = false
    @State var showComposerLinkSheet: Bool = false
    @State var composerLinkText: String = ""
    @State var composerLinkUrlInput: String = ""
    @State var composerLinkError: Bool = false
    private var composerLinkEditing: Bool = false
    /** 最近一次 onSelect 的选区（RichEditor 自己的偏移单位）。 */
    private var composerSelStart: Int32 = 0
    private var composerSelEnd: Int32 = 0
    /** 编辑器为空时 IME 首次落字继承系统默认样式（深色态近黑）；置 true 让 onImeInputComplete 补基础样式。 */
    private var composerNeedsBaseStyle: Bool = true
    /** 程序化改写编辑器内容期间抑制 onDidChange 回灌。 */
    private var composerSyncSuppressed: Bool = false
    /** Link / Quote 无法从 span 样式反查：按文本记录（text → url / quoted text）。 */
    private var composerLinkUrls: HashMap<String, String> = HashMap<String, String>()
    private var composerQuotes: ArrayList<String> = ArrayList<String>()

    // P2-371: 贴纸键盘面板
    @State var showStickerKeyboard: Bool = false

    // P2-373: GIF 面板
    @State var showGifPanel: Bool = false
    @State var stickerKeyboardOffset: Float64 = 0.0
    @State var emojiKeyboardOffset: Float64 = 0.0
    @State var gifKeyboardOffset: Float64 = 0.0
    @State var gifKeyboardTab: Int32 = 0

    // Phase I3: 位置选择器
    @State var showLocationPicker: Bool = false
    
    // Phase I7: 输入指示器（旧字段保留兼容，不再直接写入）
    @State var typingIndicator: String = ""

    // P2-121: 副标题（presence / typing / 群人数）— 同步自 ViewModel
    @State var subtitleText: String = ""
    // P2-121: 当前 typing 文案（由 ChatTitleActivityService 推送，优先级高于 subtitleText）
    @State var chatTypingText: String = ""

    // P2-122: 多条置顶的总条数（用于显示 "Pinned #N of M"）
    @State var pinnedCount: Int64 = 0
    // iOS GroupCallNavigationAccessoryPanel：群里有进行中的 Video Chat 时顶部 50pt 的 Join 条
    @State var activeGroupCallId: Int64 = 0
    @State var activeGroupCallHash: Int64 = 0
    @State var activeGroupCallCount: Int32 = 0
    @State var activeGroupCallJoined: Bool = false
    // 预约中的 Video Chat（groupCall.schedule_date）：条变成 "Scheduled Video Chat / Starts today at …" + 倒计时胶囊
    @State var activeGroupCallSchedule: Int64 = 0
    @State var activeGroupCallCountdown: String = ""
    private var groupCallCountdownRunning: Bool = false
    private var groupCallPanelAlive: Bool = false
    
    // Phase I4: 投票创建
    @State var showPollCreator: Bool = false
    @State var pollQuestion: String = ""
    @State var pollOption1: String = ""
    @State var pollOption2: String = ""
    @State var pollOption3: String = ""

    // Fix1: 发送联系人 — 联系人选择器
    @State var showContactPicker: Bool = false
    @State var contactPickerList: ArrayList<ContactDisplayData> = ArrayList<ContactDisplayData>()
    @State var contactPickerLoading: Bool = false
    
    // Context-menu action feedback.
    @State var reportDoneToast: Bool = false
    @State var linkCopiedToast: Bool = false
    // imgmenu 批次：媒体保存/复制操作结果吐司（"Saving…"/"Saved to Gallery"/"Photo copied" 等；
    // 空串 = 不显示。showAssetsCreationDialog 结果回调非 UI 线程，写入须 launch{} 包裹。）
    @State var mediaActionToast: String = ""
    // 吐司自动清除计时版本号（防旧计时器清掉新吐司）
    private var mediaToastVersion: Int32 = 0
    
    // Phase P0-1: 转发消息对话选择器
    @State var showForwardPicker: Bool = false
    // S2-70: Schedule Message sheet (iOS ChatScheduleTimeController) and the
    // Scheduled Messages screen (iOS ChatController subject .scheduledMessages).
    @State var showScheduleSheet: Bool = false
    @State var scheduleSheetInitialSec: Int64 = 0
    @State var showScheduledMessages: Bool = false
    @State var scheduledMessages: ArrayList<Message> = ArrayList<Message>()
    @State var scheduledMessagesLoading: Bool = false
    // iOS ChatPresentationInterfaceState.hasScheduledMessages → clock accessory in the input field.
    @State var hasScheduledMessagesMirror: Bool = false
    // S2-72 / S2-74: bot commands of this peer (bot userFull.bot_info or group chatFull.bot_info)
    // and the bot Menu button kind (0 none / 1 commands / 2 web app).
    @State var botCommandsCount: Int64 = 0
    @State var botMenuButtonKind: Int32 = 0
    @State var botMenuButtonText: String = ""
    @State var botMenuButtonUrl: String = ""
    // S5-04: comment / reply thread screen (iOS ChatController subject .replyThread)
    @State var showMessageThread: Bool = false
    @State var threadMessages: ArrayList<Message> = ArrayList<Message>()
    @State var threadRoot: Message = Message()
    @State var threadHasRoot: Bool = false
    @State var threadTitle: String = ""
    @State var threadLoading: Bool = false
    @State var messageContextRepliesTitle: String = ""
    @State var forwardMsgId: Int64 = 0
    @State var forwardDialogs: ArrayList<Chat> = ArrayList<Chat>()
    @State var forwardSearchText: String = ""

    // P2-114: 多选模式（批量删除/批量转发）
    @State var isMultiSelectMode: Bool = false
    @State var selectedMessageIds: HashMap<Int64, Bool> = HashMap<Int64, Bool>()

    // P2-115: 转发选项 — 隐藏发送者/隐藏 caption
    // iOS PendingMessageManager.swift: drop_author (bit11) / drop_media_captions (bit12)
    @State var forwardDropAuthor: Bool = false
    @State var forwardDropCaptions: Bool = false

    // P2-115: 批量转发 — 存放所有要转发的消息 ID
    @State var forwardMsgIds: ArrayList<Int64> = ArrayList<Int64>()
    
    // P2-395: 聊天页壁纸（per-chat 优先，回落全局）
    // 取代旧版 chatBgImagePath 单一图片路径，支持渐变/纯色/图案/自定义图片全部壁纸类型
    // 构造时就按 per-chat → 全局 解析（Preferences 读，与 ensureLoaded 同一解析器）：首帧直接挂
    // 正确壁纸。此前先以默认纯色挂一次（hilog "aboutToAppear type=0"），ensureLoaded 再整体赋值
    // 重建一次，首屏多付一整层壁纸组件的构建与绘制。
    @State var chatWallpaperInfo: WallpaperInfo = getWallpaperBackgroundService().getCurrentWallpaperForChat(getSelectedChatId())
    // P2-116: Reactor 列表覆盖层
    @State var showReactorList: Bool = false
    @State var reactorListMsgId: Int64 = 0

    // P2-118: 已读参与者覆盖层（群消息 — "Seen by N"）
    @State var showReadParticipants: Bool = false
    @State var readParticipantsMsgId: Int64 = 0

    // P2-112: 双向分页 UI 状态
    // 向上加载历史时显示顶部 loading indicator
    @State var isLoadingOlderUI: Bool = false
    // 批 3：原先是 startMessageSync 内的局部变量，改推送驱动后需提升为页面状态。
    private var _initialScrollDone: Bool = false
    // 外语检测轮次（scheduleForeignLanguageDetection）：旧一轮的后台结果不得覆盖新一轮。
    private var _foreignDetectGeneration: Int64 = 0
    // [ChatOpenPerf] 一次性标记：首次 build() 探针、消息 List 首次布局。
    private var _perfFirstBuildMarked: Bool = false
    private var _perfFirstLayoutMarked: Bool = false
    // _initialScrollDone 在安排延迟滚动时即置位，不能代表 List 已真正到达最新端。
    // 首次滚动落地前 onReachStart 会被初始索引 0 自动触发，必须用本标志拦截。
    private var _initialScrollSettled: Bool = false
    private var _lastRenderedId: Int64 = -1
    // 上一次渲染时**最后一条**消息的 stableId —— 尾部新增的唯一判据，见 rebuildDisplayMessages
    private var _lastRenderedStableId: Int64 = -1
    // 最后一个**可见**列表项的索引，由 List.onScrollIndex 维护。-1 = 尚未滚动过。
    // 用来判断「用户此刻是否在底部」—— 决定新消息该自动滚过去，还是只提示。
    private var _lastVisibleIndex: Int64 = -1
    // 第一条可见项，用于上划 HoleReload 后恢复分页边界。
    // iOS PreparedChatHistoryViewTransition 对 HoleReload 设置 stationaryItemRange，
    // 旧可见消息不会因头部插入而跳到新批次最老处；ArkUI List 需显式恢复该锚点。
    private var _firstVisibleIndex: Int64 = -1
    // 列表视口高度（vp），由 List.onAreaChange 维护；S9-30 跳转落点校验用它判断目标是否完整可见。
    private var _listViewportHeightVp: Float64 = 0.0
    // S8-08：秘密聊天会话（selectedId = secretChatId）的对端 userId；0 = 非秘密聊天。
    private var secretPeerUserId: Int64 = 0
    // S8-08：iOS TelegramSecretChat.embeddedState == .handshake —— 对端接受前输入栏只显示等待文案。
    @State var secretHandshakePending: Bool = false
    // 「钉在最新端」：对齐 iOS ChatHistoryListNode 的倒置 ListView（rotated，
    // ChatHistoryListNode.swift:946-948）—— 其滚动原点就是底部 inset
    // （ChatControllerNode.swift:2454/2497 listInsets.top = containerInsets.bottom +
    // inputPanelsHeight + 8 + 11），尾部气泡长高、键盘/面板压缩视口时底边原地不动，
    // 最新消息始终完整停在输入面板上方。ArkUI List 保持的是「距顶偏移」，视口变矮或
    // 末尾气泡在滚动后才长高（链接预览/图片/贴纸尺寸落地）会把最新一条推到输入栏下方。
    // 因此程序滚到最新端后置位；只要仍钉住，列表视口或任一气泡尺寸变化就重新贴底。
    // 用户手指把列表拖离底部即解除（iOS isScrollAtBottomPosition 由 offset <= 0 判定，
    // ChatHistoryListNode.swift:1104-1119）。
    private var _pinnedToLatest: Bool = false
    // 同一帧内多处尺寸变化合并成一次贴底。
    private var _repinScheduled: Bool = false
    // HoleReload 的待恢复锚点。stableId 负责跨头插定位同一条消息，visualY 负责保留
    // 该消息在视口中的精确像素位置（包括只露出一部分的情况）。恢复必须在
    // displayMessages 快照替换的同一轮 UI 更新中执行，不能等待网络状态轮询结束。
    private var _olderAnchorStableId: Int64 = -1
    private var _olderAnchorVisualY: Float64 = 0.0
    private var _olderAnchorPending: Bool = false
    // 快速手势时扩大预取跑道；iOS 有 44 条 history window，本端还需覆盖一次 MTProto RTT。
    private var _historyScrollFast: Bool = false
    // iOS shouldDisplayDownButton：离开最新端即显示，与是否收到新消息无关。
    @State var showScrollToLatestButton: Bool = false
    // 用户不在底部期间累计的新消息数；>0 时显示「N 条新消息」浮层。
    @State var pendingNewCount: Int64 = 0
    // 「是否有新消息」的判据。不能用「最后一条 id 变了」——发送成功时本地计数器 id
    // 上一次实际渲染出的内容指纹，用于跳过「推送到了但渲染产物完全相同」的重建。
    private var _lastRenderKey: String = ""

    // ==================== P2-120: @mention/#hashtag//command 补全面板 ====================

    /** 联想查询 ViewModel（@mention / #hashtag / /command 三类补全） */
    @State var contextQueryVM: ChatContextQueryViewModel = ChatContextQueryViewModel()

    // ==================== P2-120: 内联格式菜单 ====================

    /** 是否显示格式工具条（Bold / Italic / Strikethrough / Code / Spoiler 按钮行） */
    @State var showFormatBar: Bool = false

    // ==================== 非联系人栏 / 输入区附件（iOS ChatReportPeerTitlePanelNode / ChatInterfaceInputContexts） ====================
    // 顶部 peer 操作栏按钮键："block" / "addContact" / "unarchive" / "shareContact" / "reportSpam" / "reportUserSpam"
    @State var peerBarButtons: ArrayList<String> = ArrayList<String>()
    // 非空时 addContact 按钮文案为 "Add %@ to Contacts"（iOS RPT:87-88：无 block 按钮且对方号码可见）
    @State var peerBarAddContactName: String = ""
    @State var peerSettingsFlags: Int32 = 0
    // 当前会话自动删除计时（秒）；iOS presentationInterfaceState.autoremoveTimeout
    @State var autoremoveTimeoutSec: Int32 = 0
    @State var peerIsBotMirror: Bool = false
    // iOS NewContactScreen（聊天栏 Add to Contacts 打开）
    @State var showNewContactSheet: Bool = false
    @State var newContactFirstName: String = ""
    @State var newContactLastName: String = ""
    @State var newContactPhone: String = ""
    @State var newContactSharePhone: Bool = true
    @State var newContactBusy: Bool = false
    @State var showBlockPeerSheet: Bool = false
    // 频道订阅者底栏 Mute / Unmute（iOS ChatChannelSubscriberInputPanelNode）；channelMuteBusy 见上方声明。
    @State var channelMutedMirror: Bool = false
    // Bot 回复键盘（iOS ChatButtonKeyboardInputNode）：true = 键盘区显示按钮键盘
    @State var botKeyboardShown: Bool = false
    @State var botKeyboardMessageId: Int64 = 0
    @State var botKeyboardRows: ArrayList<ArrayList<String>> = ArrayList<ArrayList<String>>()
    @State var botKeyboardSingleUse: Bool = false
    @State var botKeyboardResize: Bool = false
    private var _lastTtlServiceMsgId: Int64 = 0
    @State var botKeyboardDismissedMsgId: Int64 = 0

    // P2-120: pendingFormatEntities 已移除 — parseMarkdown 在 ViewModel.sendMessage 内
    // 直接解析 markdown 标记并通过 sendMessageWithEntities 传给服务端，无需在 View 层积累实体。

    // ==================== P2-120: slowmode / restricted / unblock UI 状态 ====================

    /**
     * 慢速模式倒计时显示文案（空字符串 = 不显示）。
     * 由本地 Timer 每秒更新，根据 viewModel.slowmodeNextSendTimestamp 计算。
     */
    @State var slowmodeCountdownText: String = ""

    // P2-397/P2-400: 内联翻译状态存储（per-message）
    // bubbleTranslateTexts[msgId] = 译文；bubbleTranslateShow[msgId] = 是否显示翻译区
    // bubbleTranslateLoading[msgId] = 是否正在翻译；bubbleTranslateError[msgId] = 是否失败
    // bubbleShowOriginal[msgId] = 是否显示原文（Show Original 切换）
    @State var bubbleTranslateTexts: HashMap<Int64, String> = HashMap<Int64, String>()
    @State var bubbleTranslateShow: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    @State var bubbleTranslateLoading: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    @State var bubbleTranslateError: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    @State var bubbleShowOriginal: HashMap<Int64, Bool> = HashMap<Int64, Bool>()

    // ==================== P2-398: 整聊天翻译条（chat-level translation bar） ====================
    // iOS 对应 ChatTranslationState；顶部翻译条显示 "Translate to <lang>" / "Show Original"
    // chatTransEnabled=true  → 自动翻译模式开启，翻译条显示 "Showing Original / Show Translation"
    // chatTransEnabled=false → 翻译条显示 "Translate to <lang>"（仅当检测到外语时显示）
    // chatTransDetectedForeignLang=true → 检测到外语，显示翻译条
    @State var chatTransEnabled: Bool = false
    @State var chatTransDetectedForeignLang: Bool = false
    @State var chatTransIsTranslating: Bool = false

    @State var loaded: Bool = false
    // 混合迁移：cleanup() 幂等 guard，防止 onDisAppear 被多次触发时重复执行清理逻辑
    @State var cleanedUp: Bool = false
    // 仅页面真实可见期间有效；selectedChat 是导航参数，不能代表可见性。
    private var _visibleConversationGeneration: Int64 = 0
    private var _backHandlerGeneration: Int64 = 0
    private var _userStatusSubscriptionToken: Int64 = -1
    private var _emojiInteractionSubscriptionToken: Int64 = -1
    // S8-08：秘密聊天握手状态订阅（TelegramCore_SecretChatsService.addStateSubscriber）
    private var _secretStateSubscriptionToken: Int64 = -1

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadStickerSuggestionSetting()
        let selectedId = getSelectedChatId()
        let selectedName = getSelectedChatName()
        let selectedPeerType = getSelectedChatPeerType()
        this.interactiveBotStartPayload = consumeSelectedChatBotStartPayload()
        this._visibleConversationGeneration = showConversation(selectedPeerType, selectedId)
        // Selecting a conversation is an interactive read action in iOS Postbox.
        // Commit both the local projection and the server read boundary here.
        // Relying only on List.onVisibleAreaChange leaves a race when a reused
        // row never emits a fresh visibility callback; the next dialogs refresh
        // then restores the old unread count.
        // 提交本身会触发两次投影发布（ChatListPage 在 UI 线程重建行）+ 快照落盘，推迟到本页
        // 首屏内容之后执行（打开即视为已读，不依赖页面届时仍可见）。
        this.scheduleOpenReadCommit(selectedPeerType, selectedId)
        let savedInterfaceState = getChatInterfaceStateService().loadDraftState(selectedId)
        this.chatName = if (selectedName.size > 0) { selectedName } else { "Chat" }
        _chatTitleRefreshHandler = Some({ pid: Int64, pt: String, name: String =>
            if (pid == this.viewModel.chatId && pt == this.viewModel.peerType && name.size > 0
                && !this.viewModel.isSavedMessagesChat()) {
                this.chatName = name
                this.viewModel.chatName = name
            }
        })
        // S8-08：秘密聊天以 secretChatId 为会话键，头像 / 状态文案取对端用户；
        // 握手状态来自 SecretChatsService 会话（REQUESTED = iOS .handshake，READY = .active）。
        // W4 S8-08：setSelectedChat 经 normalizeDialogPeerType 把 "secret" 归一成 PeerKey.SECRET_CHAT
        // ("secretChat")，此前只比 "secret" 永远不进分支 → 对端 id / 握手态全没设，页面开出来就是
        // 普通输入框、空白聊天区（VM.isSecretChatPeer 两种都认，所以只有标题锁还在）。
        if (selectedPeerType == "secret" || selectedPeerType == "secretChat") {
            this.secretPeerUserId = consumeSelectedSecretPeerUserId()
            let secretSvc = getTelegramCore_SecretChatsService()
            this.secretHandshakePending = match (secretSvc.getSession(Int32(selectedId))) {
                case Some(session) => session.status != SecretChatStatus.READY
                case None => true
            }
            // iOS ChatControllerImpl 订阅 peerView：updateEncryption（对端接受）到达后 embeddedState
            // 变 .active，SecretChatHandshakeStatusInputPanelNode 换回普通输入面板。
            if (this._secretStateSubscriptionToken < 0) {
                let secretChatId = selectedId
                this._secretStateSubscriptionToken = secretSvc.addStateSubscriber({ chatId: Int32, status: String =>
                    if (Int64(chatId) != secretChatId) { return }
                    launch { this.secretHandshakePending = status != SecretChatStatus.READY }
                })
            }
        }
        let photoService = getUserPhotoService()
        let avatarIds = ArrayList<Int64>()
        if (selectedPeerType == "chat" || selectedPeerType == "channel") {
            avatarIds.add(selectedId)
            this.chatAvatarUrl = photoService.getChatPhotoPath(selectedId)
            photoService.requestFullPhotosForChats(avatarIds)
            match (getRealChatListService().getCachedChat(selectedPeerType, selectedId)) {
                case Some(chat) =>
                    this.peerIsVerified = chat.isVerified
                    this.channelIsLeft = selectedPeerType == "channel" && chat.isLeft
                    this.channelIsBroadcast = selectedPeerType == "channel" && chat.isBroadcast
                    if (chat.participantsCount > 0) {
                        this.subtitleText = if (chat.isChannel && !chat.isMegagroup) {
                            "${chat.participantsCount} subscribers"
                        } else {
                            "${chat.participantsCount} members"
                        }
                    }
                    if (this.channelIsBroadcast && !this.channelIsLeft) {
                        let peerId = selectedId
                        spawn {
                            let muted = getRealChatListService().getPeerMuteState("channel", peerId)
                            launch {
                                if (getSelectedChatId() == peerId && getSelectedChatPeerType() == "channel") {
                                    this.channelMutedMirror = muted
                                }
                            }
                        }
                    }
                case None => ()
            }
        } else {
            // S8-08：秘密聊天头像 / 认证标取对端用户（avatarPeerId），其余取会话 id 本身。
            let avatarUserId = this.avatarPeerId()
            avatarIds.add(avatarUserId)
            this.chatAvatarUrl = photoService.getUserPhotoPath(avatarUserId)
            photoService.requestFullPhotosForUsers(avatarIds)
            match (photoService.getCachedUser(avatarUserId)) {
                case Some(user) => this.peerIsVerified = user.isVerified
                case None => ()
            }
        }
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Opening: id=${selectedId}, name=${this.chatName}, peer=${selectedPeerType}")
        if (selectedPeerType == "user" && selectedId != 0 && selectedId == getCurrentUserId()) {
            spawn {
                let hasChats = savedMessagesHasPeersOtherThanSaved(fetchSavedDialogs())
                launch { this.savedHasChats = hasChats }
            }
        }
        
        // P2-395: 加载 per-chat 壁纸（per-chat 优先，回落全局）
        // F-1（diag-suite_settings_appearance-TC-0411-round2.md RC-W3）：此前这里在
        // wallpaperType == SolidColor 且存在默认底图时把类型直接改写成 CustomImage + 默认图
        // URI——把"用户选了纯色"当成"用户选了默认图"，是绘制层同一缺口在数据侧的镜像
        // （绘制层那半见 :1878 WallpaperBackgroundComponent 调用点）。壁纸类型必须原样送到
        // 绘制层，改写已删除；getChatBgDisplayPath() 的默认底图现在只在 rootWallpaperUri()
        // 内、真正的 CustomImage 分支里作为兜底使用。
        let loadedWallpaper = getWallpaperBackgroundService().getCurrentWallpaperForChat(selectedId)
        // 字段构造时已用同一解析器取过（首帧即正确壁纸）；渲染等价时不再整体赋值，避免首屏
        // 多一轮壁纸层重建。相位差异走 @Prop 通道（同 reloadChatWallpaper）。
        if (!this.chatWallpaperInfo.sameRenderingAs(loadedWallpaper)) {
            this.chatWallpaperInfo = loadedWallpaper
        } else if (this.chatWallpaperInfo.phase != loadedWallpaper.phase) {
            this.chatWallpaperInfo.phase = loadedWallpaper.phase
            this.wpPhaseMirror = loadedWallpaper.phase
        }
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] chatWallpaper: peerId=${selectedId} type=${loadedWallpaper.wallpaperType.ordinal()} cloudId=${loadedWallpaper.cloudWallpaperId} patternFile=${loadedWallpaper.patternFile} imageUri=${loadedWallpaper.imageUri}")
        this.registerChatWallpaperListener()
        
        this._syncActive = true
        this.viewModel.scrollerRef = Some(this.listScroller)
        this.viewModel.initChatRoomWithPeer(selectedId, this.chatName, selectedPeerType)
        // VM 按 iOS 规则可能改写标题（Saved Messages），同帧回填页面标题。
        this.chatName = this.viewModel.chatName
        // iOS ChatController.viewDidLoad 一进入就 fetchAndUpdateCachedPeerData（非联系人栏 /
        // 自动删除计时器）。放在 peer 绑定之后立即发起，不排在后面的订阅与同步启动之后——
        // 那些步骤任何一个提前结束本函数，都会让顶部栏永远不出现。
        this.refreshComposeExtras()

        // P2-120: 注入 ChatContextQueryViewModel 上下文（peerId / peerType）
        // accessHash 从 RealMessageService 缓存读（initChatRoomWithPeer → loadMessages 已填充）
        this.contextQueryVM.peerId = selectedId
        this.contextQueryVM.peerType = selectedPeerType
        // accessHash 在 loadMessages 完成后才缓存，先置 0，后面轮询时自然可用
        this.contextQueryVM.peerAccessHash = 0

        // P2-117: 恢复草稿到输入框（含 reply 状态），优先从 ChatInterfaceStateService 读
        let cisState = savedInterfaceState
        let localDraft = cisState.draftText
        if (localDraft.size > 0) {
            this.setComposerText(localDraft)
            this.viewModel.inputText = localDraft
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] P2-117 Restored draft from CIS: '${localDraft}'")
            // 恢复 reply 状态
            if (cisState.replyToMsgId > 0) {
                this.viewModel.setReplyTo(cisState.replyToMsgId, cisState.replyToText, cisState.replyToSenderName)
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] P2-117 Restored reply state: msgId=${cisState.replyToMsgId}")
            }
        } else {
            // 兼容旧路径：从全局草稿变量读（Phase Q9）
            let legacyDraft = getSelectedChatDraft()
            if (legacyDraft.size > 0) {
                this.setComposerText(legacyDraft)
                this.viewModel.inputText = legacyDraft
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] P2-117 Restored draft (legacy): '${legacyDraft}'")
            }
        }
        
        // Phase P5-12: 注册语音播放进度回调（驱动波形 UI 刷新）
        getVoicePlayerManager().setOnProgressUpdate({ =>
            launch { this.refreshMessageListForVoice() }
        })
        // iOS：一条语音播完自动接着播下一条语音（SharedMediaPlayer playlist 行为）
        getVoicePlayerManager().setOnFinished({ msgId: Int64 =>
            launch { this.playNextVoiceAfter(msgId) }
        })

        // P2-121: 注册 typing / presence 推送
        let typingActivitySvc = getChatTitleActivityService()
        typingActivitySvc.setPeer(selectedPeerType, selectedId)
        typingActivitySvc.registerWithUpdatesManager()
        this.registerEmojiInteractionUpdates()
        typingActivitySvc.setActivityHandler({ state: ActivityState =>
            let text = state.displayText
            launch {
                this.chatTypingText = text
                this.viewModel.setTypingText(text)
            }
        })

        // P2-121: 注册 userStatus 推送（私聊 online/offline 实时更新副标题）
        this.registerUserStatusUpdates()

        this.startMessageSync()
        // P2-122: 同步多置顶计数（在 startMessageSync 后，VM 状态加载中）
        this.startSubtitleAndPinnedSync()
        this.startGroupCallPanelSync()
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] opened peer=${selectedPeerType}:${selectedId} setup done")
        chatOpenPerfMark("ensureLoadedDone")
        // 全局搜索结果点按 / View in Chat：打开后定位并高亮目标消息
        // （iOS ChatListSearchContainerNode.openMessage → navigateToChatController(subject: .message)）。
        // 首屏历史落地后再跳；不在窗口内时 jumpToReplyMessage 以目标为锚点补拉一窗。
        let focusMessageId = consumeSelectedChatFocusMessageId()
        if (focusMessageId > 0) {
            let _ = spawn {
                sleep(Duration.millisecond * 600)
                launch { this.jumpToReplyMessage(focusMessageId) }
            }
        }

        // P2-398: 恢复 per-peer 整聊天翻译状态（Preferences 持久化）
        let savedTransState = loadChatTranslationState(selectedId)
        if (savedTransState.isEnabled) {
            this.chatTransEnabled = true
            this.chatTransDetectedForeignLang = true
        }
    }

    /** iOS ChatChannelSubscriberInputPanelNode 按钮文案（Channel.JoinChannel / Group.JoinGroup / Group.ApplyToJoin）。 */
    func channelJoinButtonTitle(): String {
        if (this.channelIsBroadcastMirror) { return trOr("Channel.JoinChannel", "Join") }
        if (this.channelJoinRequestNeededMirror) { return trOr("Group.ApplyToJoin", "Apply to Join Group") }
        return trOr("Group.JoinGroup", "Join Group")
    }

    /**
     * E5：点 Join → channels.joinChannel（对位 iOS ChatChannelSubscriberInputPanelNode.buttonPressed
     * → peerChannelMemberCategoriesContextsManager.join）。成功后输入区恢复为该频道的正常面板，
     * 并刷新会话列表使频道立即出现在 Chats 中。
     */
    private func joinCurrentChannel(): Unit {
        if (this.channelJoinBusy) { return }
        this.channelJoinBusy = true
        let channelId = this.viewModel.chatId
        let _ = spawn {
            let msgSvc = getRealMessageService()
            let ok = msgSvc.joinChannel(channelId, msgSvc.getAccessHashForChannel(channelId))
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] joinChannel channelId=${channelId} ok=${ok}")
            if (ok) {
                match (getRealChatListService().getCachedChat(channelId)) {
                    case Some(cached) =>
                        cached.isLeft = false
                        getRealChatListService().cacheChatResponse(cached)
                    case None => ()
                }
                this.viewModel.channelJoinRequired = false
            }
            launch {
                this.channelJoinBusy = false
                if (ok) {
                    this.channelJoinRequiredMirror = false
                    this.channelIsLeft = false
                    match (getChatListVM()) {
                        case Some(vm) => vm.refreshWithPullDown()
                        case None => ()
                    }
                } else {
                    this.showMediaToast("Could not join", autoClear: true)
                }
            }
        }
    }

    /** iOS ChatTextInputPanelNode.startButton → sendBotStart(botStartPayload). */
    private func sendInteractiveBotStart(): Unit {
        let payload = this.interactiveBotStartPayload
        if (payload.size == 0) { return }
        let peerId = this.viewModel.chatId
        let peerType = this.viewModel.peerType
        let accessHash = getRealMessageService().getAccessHashForUser(peerId)
        let _ = spawn {
            let success = getRealMessageService().startBot(peerId, accessHash, peerType, peerId, startParam: payload)
            launch {
                if (success) {
                    this.interactiveBotStartPayload = ""
                    this.viewModel.loadMessages()
                }
            }
        }
    }

    /** 首次构建前的生命周期点，仅作耗时标记（页面初始化仍在 onAppear → ensureLoaded）。 */
    protected override func aboutToAppear(): Unit {
        chatOpenPerfMark("pageAboutToAppear")
    }

    /**
     * 打开会话的已读提交：本地投影 applyIncomingRead + ChatListVM.markAsRead（含服务端
     * readHistory）。两者各发布一次投影（ChatListPage 在 UI 线程重建行）并落盘快照，故延后到
     * 首屏内容之后在 UI 线程执行。不检查页面是否仍可见：打开过就算已读（iOS 同）。
     */
    private func scheduleOpenReadCommit(peerType: String, peerId: Int64): Unit {
        let _ = spawn {
            sleep(Duration.millisecond * 400)
            launch {
                chatOpenPerfMark("readCommit")
                getChatListProjection().applyIncomingRead(peerType, peerId, 0)
                match (getChatListVM()) {
                    case Some(vm) => vm.markAsRead(peerId, peerType)
                    case None => ()
                }
            }
        }
    }

    private func handleAppear(): Unit {
        chatOpenPerfMark("onAppear")
        this.registerImeHeightWatcher()
        registerChatSearchHandler({ => this.showMessageSearch = true })
        this._backHandlerGeneration = registerChatRoomBackHandler({ => this.handleSystemBack() })
        // Move reaction metadata/download/TGS rasterization ahead of the long
        // press so the context bar's first visible artwork is already Lottie.
        preloadQuickReactionLottie()
        // iOS keeps the animatedEmojiAnimations sticker-set metadata warm in
        // AccountContext. Move that round-trip ahead of the first emoji tap.
        let _ = spawn { preloadAnimatedEmojiEffectsMetadata() }
        if (this.loaded && this.cleanedUp) {
            this.resumeAfterDisappear()
        } else {
            this.ensureLoaded()
        }
        // Navigation keeps chat destinations alive. Re-resolve the effective wallpaper every
        // time the route is shown so a theme selected in Appearance is reflected immediately.
        this.reloadChatWallpaper()
        this.setChatSystemBars()
        if (consumeChatSearchOnReturn()) {
            this.showMessageSearch = true
        }
    }

    /**
     * 恢复同一个页面实例。onDisAppear 不等价于销毁：push 资料页、应用切后台都会触发。
     * 对齐 iOS viewDidAppear，重新打开活跃订阅，但保留列表和滚动位置。
     */
    private func resumeAfterDisappear(): Unit {
        this.cleanedUp = false
        // S6-05：资料页 more → Change Wallpaper 只改本会话的 per-chat 槽，回到本页重读一次，
        // 并重新接上变更监听（中途打开过别的会话时监听已被改写）
        this.registerChatWallpaperListener()
        this.reloadChatWallpaper()
        if (getSelectedChatId() == this.viewModel.chatId && getSelectedChatPeerType() == this.viewModel.peerType) {
            // 仍是本会话：资料页可能改过名，采用全局最新名称
            let latestName = getSelectedChatName()
            if (latestName.size > 0 && latestName != this.chatName && !this.viewModel.isSavedMessagesChat()) {
                this.chatName = latestName
                this.viewModel.chatName = latestName
            }
        } else {
            // 中途打开过其它会话（如成员私聊）时，全局选中会话已被改写，回到本页要指回自己
            setSelectedChat(this.viewModel.chatId, this.viewModel.chatName, this.viewModel.peerType)
        }
        this._visibleConversationGeneration = showConversation(this.viewModel.peerType, this.viewModel.chatId)
        this._syncActive = true
        var visibleAnchorId: Int64 = 0
        if (this._firstVisibleIndex >= 0 && this._firstVisibleIndex < this.displayMessages.size) {
            visibleAnchorId = this.displayMessages[this._firstVisibleIndex].message.id
        }
        this.viewModel.resumeActiveRoom(visibleAnchorId)
        getVoicePlayerManager().setOnProgressUpdate({ =>
            launch { this.refreshMessageListForVoice() }
        })

        let typingActivitySvc = getChatTitleActivityService()
        typingActivitySvc.setPeer(this.viewModel.peerType, this.viewModel.chatId)
        typingActivitySvc.registerWithUpdatesManager()
        this.registerEmojiInteractionUpdates()
        typingActivitySvc.setActivityHandler({ state: ActivityState =>
            let text = state.displayText
            launch {
                this.chatTypingText = text
                this.viewModel.setTypingText(text)
            }
        })
        this.registerUserStatusUpdates()
        this.startMessageSync()
        // 资料页可能改了自动删除计时 / 加了联系人：回到本页重取 peer 附加信息
        this.refreshComposeExtras()
        Hilog.info(0, "CjTelegram",
            "[ChatRoomPage] resumed after temporary disappear, anchor=${visibleAnchorId}")
    }

    // ==================== 非联系人栏 / 自动删除计时器 / Bot 回复键盘 / 频道订阅者底栏 ====================

    private func lookupChatMuted(peerId: Int64): Bool {
        match (getChatListVM()) {
            case Some(vm) =>
                for (c in vm.chatList) {
                    if (c.id == peerId) { return c.isMuted }
                }
                for (c in vm.archiveChatList) {
                    if (c.id == peerId) { return c.isMuted }
                }
            case None => ()
        }
        return false
    }

    private func lookupCachedUser(userId: Int64): Option<UserResponse> {
        match (getUserPhotoService().getCachedUser(userId)) {
            case Some(u) => return Some(u)
            case None => return getRealChatListService().getCachedUser(userId)
        }
    }

    /**
     * iOS fetchAndUpdateCachedPeerData → CachedUserData.peerStatusSettings / autoremoveTimeout：
     * 私聊一次 users.getFullUser（settings + bot_info + ttl_period），群 / 频道走
     * messages.getPeerSettings + chatFull.ttl_period。
     */
    private func refreshComposeExtras(): Unit {
        let pt = this.viewModel.peerType
        let pid = this.viewModel.chatId
        Hilog.info(0, "CjTelegram", "[PeerBar] refresh peer=${pt}:${pid}")
        if (pid == 0) { return }
        this.channelMutedMirror = this.lookupChatMuted(pid)
        if (pt == "user" && pid == getCurrentUserId()) { return }
        // S2-12: updatePeerSettings push → recompute the bar from server flags (iOS
        // CachedUserData.peerStatusSettings observer).
        setPeerSettingsListener(Some({ upPt: String, upPid: Int64, upFlags: Int32 =>
            if (upPid == this.viewModel.chatId && upPt == this.viewModel.peerType) {
                launch { this.applyPeerSettings(upFlags, freshUser: None) }
            }
        }))
        let _ = spawn {
            var flags: Int32 = 0
            var ttl: Int32 = 0
            var isBot = false
            var fetched = false
            var hasScheduled = false
            var freshUser: Option<UserResponse> = None
            var botCommands = ArrayList<(String, String)>()
            var menuKind: Int32 = 0
            var menuText = ""
            var menuUrl = ""
            if (pt == "user") {
                // 冷启动刚进会话时 access hash / 连接可能还没就绪：失败时稍后重试两次
                var attempt = 0
                while (!fetched && attempt < 3) {
                    if (attempt > 0) { sleep(Duration.millisecond * 1500) }
                    attempt += 1
                    try {
                        let r = getChatComposeExtrasService().fetchUserExtras(pid)
                        if (r.parsed) {
                            fetched = true
                            flags = r.settingsFlags
                            ttl = r.ttlPeriod
                            isBot = r.hasBotInfo
                            hasScheduled = r.hasScheduled
                            freshUser = r.user
                            botCommands = r.botCommands
                            menuKind = r.menuButtonKind
                            menuText = r.menuButtonText
                            menuUrl = r.menuButtonUrl
                            // S6-05：iOS fetchAndUpdateCachedPeerData → CachedUserData.wallpaper：
                            // 服务端的该会话专属壁纸校准本地 per-chat 槽（变更时经监听重读壁纸层）
                            getWallpaperBackgroundService().syncServerChatWallpaper(
                                pid, r.hasWallpaper, r.wallpaperId, r.wallpaperSlug, r.wallpaperColors, r.wallpaperIntensity)
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[PeerBar] fetch peer=${pt}:${pid} attempt=${attempt} exception: ${e}")
                    }
                }
            } else {
                match (getChatComposeExtrasService().fetchPeerSettingsFlags(pt, pid)) {
                    case Some(f) =>
                        fetched = true
                        flags = f
                    case None => ()
                }
                let full = getRealMessageService().getFullChatInfo(pt, pid)
                ttl = full.ttlPeriod
                // S2-72: chatFull / channelFull bot_info → "/" commands accessory in groups.
                botCommands = full.botCommands
                fetched = true
            }
            let fUser = freshUser
            let fCommands = botCommands
            let fMenuKind = menuKind
            let fMenuText = menuText
            let fMenuUrl = menuUrl
            let fFlags = flags
            let fTtl = ttl
            let fBot = isBot
            let fFetched = fetched
            let fHasScheduled = hasScheduled
            Hilog.info(0, "CjTelegram", "[PeerBar] fetched peer=${pt}:${pid} ok=${fetched} flags=${flags} scheduled=${hasScheduled} cmds=${fCommands.size} menu=${fMenuKind}")
            launch {
                if (pid == this.viewModel.chatId && fFetched) {
                    this.autoremoveTimeoutSec = fTtl
                    if (pt == "user") {
                        this.peerIsBotMirror = fBot
                        if (fHasScheduled) { this.hasScheduledMessagesMirror = true }
                    }
                    this.contextQueryVM.botCommands = fCommands
                    this.botCommandsCount = Int64(fCommands.size)
                    this.botMenuButtonKind = fMenuKind
                    this.botMenuButtonText = fMenuText
                    this.botMenuButtonUrl = fMenuUrl
                    this.applyPeerSettings(fFlags, freshUser: fUser)
                }
            }
        }
    }

    /**
     * iOS ChatReportPeerTitlePanelNode.peerButtons（RPT:66-137）+ 显示条件
     * ChatInterfaceTitlePanelNodes.swift:155-173。TL peerSettings 位 → iOS PeerStatusSettings
     * （TelegramCore/Settings/PeerContactSettings.swift:11-32）：
     *   flags.0 report_spam → canReport · flags.1 add_contact → canAddContact ·
     *   flags.2 block_contact → canBlock · flags.3 share_contact → canShareContact ·
     *   flags.4 need_contacts_exception → addExceptionWhenAddingContact ·
     *   flags.7 autoarchived → autoArchived · flags.8 invite_members → suggestAddMembers。
     * S2-12：Share My Phone Number 栏只由 flags.3 决定（且无其它按钮时）；flags.4（=16）在 iOS
     * 上不产生任何顶栏按钮，只让 New Contact 表单显示 Share My Phone Number 开关
     * （ChatController.addPeerContact shareViaException，本页 newContactSheet 同款判定）。
     */
    private func applyPeerSettings(flags: Int32, freshUser!: Option<UserResponse> = None): Unit {
        this.peerSettingsFlags = flags
        let canReport = (flags & 1) != 0
        let canAddFlag = (flags & 2) != 0
        let canBlock = (flags & 4) != 0
        let canShare = (flags & 8) != 0
        let needContactsException = (flags & 16) != 0
        let autoArchived = (flags & 128) != 0
        let blocked = this.viewModel.hasBlockedPeer
        let buttons = ArrayList<String>()
        var addName = ""
        var contactSource = "none"
        if (this.viewModel.peerType == "user") {
            var contactCanAdd = true
            var phone = ""
            var compact = ""
            // S2-12: prefer the user object the server just returned (users.userFull.users,
            // iOS fetchAndUpdateCachedPeerData) over the possibly stale local cache.
            let userForDecision: Option<UserResponse> = match (freshUser) {
                case Some(u) => Some(u)
                case None => this.lookupCachedUser(this.viewModel.chatId)
            }
            match (userForDecision) {
                case Some(u) =>
                    contactCanAdd = !u.isContact && !u.isSelf
                    phone = u.phone
                    compact = if (u.firstName.size > 0) { u.firstName } else { u.lastName }
                    var src = "cache"
                    match (freshUser) {
                        case Some(_) => src = "server"
                        case None => ()
                    }
                    contactSource = "${src} isContact=${u.isContact} isSelf=${u.isSelf}"
                case None => ()
            }
            if (autoArchived) {
                if ((canBlock || canReport) && !blocked) { buttons.add("block") }
                buttons.add("unarchive")
            } else if (contactCanAdd && canAddFlag) {
                if ((canBlock || canReport) && !blocked) { buttons.add("block") }
                if (buttons.isEmpty() && phone.size > 0 && compact.size > 0) { addName = compact }
                buttons.add("addContact")
            } else if ((canBlock || canReport) && !blocked) {
                buttons.add("block")
            }
            if (buttons.isEmpty() && canShare) { buttons.add("shareContact") }
        } else if (autoArchived) {
            buttons.add("reportUserSpam")
            buttons.add("unarchive")
        } else if (canReport || canBlock) {
            buttons.add("reportSpam")
        }
        this.peerBarAddContactName = addName
        this.peerBarButtons = buttons
        var buttonList = ""
        for (b in buttons) { buttonList = buttonList + b + " " }
        Hilog.info(0, "CjTelegram",
            "[PeerBar] decide peer=${this.viewModel.peerType}:${this.viewModel.chatId} flags=${flags} add_contact=${canAddFlag} block=${canBlock} report=${canReport} share_contact=${canShare} need_contacts_exception=${needContactsException} autoarchived=${autoArchived} blocked=${blocked} contact=${contactSource} buttons=[${buttonList}]")
    }

    private func peerBarButtonTitle(key: String): String {
        if (key == "block") { return "Block User" }
        if (key == "addContact") {
            return if (this.peerBarAddContactName.size > 0) {
                "Add ${this.peerBarAddContactName} to Contacts"
            } else {
                "Add to Contacts"
            }
        }
        if (key == "unarchive") { return "Unarchive" }
        if (key == "shareContact") { return "Share My Phone Number" }
        if (key == "reportSpam") { return "Report Spam and Leave" }
        if (key == "reportUserSpam") { return "Report Spam" }
        return key
    }

    /** iOS RPT.buttonPressed：block / report* → reportPeer，unarchive，addContact → presentPeerContact。 */
    private func onPeerBarButton(key: String): Unit {
        if (key == "addContact") {
            this.openNewContactSheet()
        } else if (key == "block") {
            this.blurComposer()
            this.showBlockPeerSheet = true
        } else if (key == "unarchive") {
            this.unarchiveCurrentPeer()
        } else if (key == "shareContact") {
            this.shareMyPhoneWithPeer()
        } else {
            this.confirmReportPeerSpam()
        }
    }

    /** iOS dismissReportPeer → messages.hidePeerSettingsBar。 */
    private func dismissPeerBar(): Unit {
        let pt = this.viewModel.peerType
        let pid = this.viewModel.chatId
        this.peerBarButtons = ArrayList<String>()
        let _ = spawn { let _ = getChatComposeExtrasService().hidePeerSettingsBar(pt, pid) }
    }

    @Builder
    func peerActionBar() {
        Column {
        Row {
            ForEach(this.peerBarButtons.toArray(), itemGenerator: { key: String, _idx: Int64 =>
                Text(this.peerBarButtonTitle(key))
                    .fontSize(this.scaledFontSize(16))
                    .fontColor(if (key == "block" || key == "reportSpam" || key == "reportUserSpam") {
                        0xFFFF3B30
                    } else {
                        0xFF007AFF
                    })
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .textAlign(TextAlign.Center)
                    .layoutWeight(1)
                    .height(40)
                    .onClick({ _evt => this.onPeerBarButton(key) })
            })
            Image(@r(app.media.chatroom_ic_close))
                .width(14)
                .height(14)
                .fillColor(0x8E8E93)
                .margin(left: 6, right: 12)
                .onClick({ _evt => this.dismissPeerBar() })
        }
        .width(100.percent)
        .height(40)
        .padding(left: 12)
        .alignItems(VerticalAlign.Center)
        Divider().color(0x33000000).strokeWidth(0.5)
        }
        .width(100.percent)
        .backgroundColor(this.presentation.cardColor)
    }

    /** iOS ChatController.addPeerContact → makeNewContactScreen(peer:)（ChatController.swift:9663）。 */
    private func openNewContactSheet(): Unit {
        var first = ""
        var last = ""
        var phone = ""
        match (this.lookupCachedUser(this.viewModel.chatId)) {
            case Some(u) =>
                first = u.firstName
                last = u.lastName
                phone = u.phone
            case None => first = this.chatName
        }
        this.newContactFirstName = first
        this.newContactLastName = last
        this.newContactPhone = phone
        this.newContactSharePhone = true
        this.newContactBusy = false
        this.blurComposer()
        this.showNewContactSheet = true
    }

    private func saveNewContact(): Unit {
        if (this.newContactBusy) { return }
        let first = this.newContactFirstName.trimAscii()
        if (first.isEmpty()) { return }
        let last = this.newContactLastName.trimAscii()
        let phone = this.newContactPhone
        let uid = this.viewModel.chatId
        // need_contacts_exception(flags.4) 时 iOS 显示 "Share My Phone Number" 开关
        let share = this.newContactSharePhone && (this.peerSettingsFlags & 16) != 0
        this.newContactBusy = true
        let _ = spawn {
            let ok = getChatComposeExtrasService().addPeerContact(uid, first, last, phone, share)
            launch {
                this.newContactBusy = false
                if (ok) {
                    this.showNewContactSheet = false
                    this.peerBarButtons = ArrayList<String>()
                    match (this.lookupCachedUser(uid)) {
                        case Some(u) => u.isContact = true
                        case None => ()
                    }
                    // iOS AddContact.StatusSuccess
                    showToast("${first} is now in your contacts list.")
                    this.refreshComposeExtras()
                } else {
                    showToast("Could not add contact")
                }
            }
        }
    }

    @Builder
    func newContactSheet() {
        Stack(alignContent: Alignment.Bottom) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x66000000)
                .onClick({ _evt => this.showNewContactSheet = false })
            Column {
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .onClick({ _evt => this.showNewContactSheet = false })
                    Blank()
                    Text("New Contact")
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.presentation.textColor)
                    Blank()
                    Text(trSource("Done"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(if (this.newContactFirstName.trimAscii().isEmpty() || this.newContactBusy) { 0xFFAEAEB2 } else { 0xFF007AFF })
                        .onClick({ _evt => this.saveNewContact() })
                }
                .width(100.percent)
                .height(52)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)

                Column {
                    TextInput(text: this.newContactFirstName, placeholder: "First Name")
                        .height(44)
                        .backgroundColor(Color.Transparent)
                        .fontColor(this.presentation.textColor)
                        .onChange({ v: String => this.newContactFirstName = v })
                    Divider().color(0x1F000000).strokeWidth(0.5).margin(left: 16)
                    TextInput(text: this.newContactLastName, placeholder: "Last Name")
                        .height(44)
                        .backgroundColor(Color.Transparent)
                        .fontColor(this.presentation.textColor)
                        .onChange({ v: String => this.newContactLastName = v })
                }
                .width(100.percent)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(10)

                Row {
                    Text("mobile")
                        .fontSize(15)
                        .fontColor(this.presentation.textColor)
                    Blank()
                    Text(if (this.newContactPhone.isEmpty()) { "Hidden" } else { "+" + this.newContactPhone })
                        .fontSize(15)
                        .fontColor(0xFF8E8E93)
                }
                .width(100.percent)
                .height(44)
                .padding(left: 16, right: 16)
                .margin(top: 16)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(10)
                .alignItems(VerticalAlign.Center)

                if ((this.peerSettingsFlags & 16) != 0) {
                    Row {
                        Text("Share My Phone Number")
                            .fontSize(15)
                            .fontColor(this.presentation.textColor)
                            .layoutWeight(1)
                        Toggle(ToggleType.Switch, isOn: this.newContactSharePhone)
                            .onChange({ isOn: Bool => this.newContactSharePhone = isOn })
                    }
                    .width(100.percent)
                    .height(44)
                    .padding(left: 16, right: 16)
                    .margin(top: 16)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .alignItems(VerticalAlign.Center)
                    Text("You can make your phone visible to ${this.newContactFirstName}.")
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 6)
                }
            }
            .width(100.percent)
            .padding(left: 16, right: 16, bottom: 34)
            .backgroundColor(this.presentation.backgroundColor)
            .borderRadius(topLeft: 12, topRight: 12)
            .onClick({ _evt => })
        }
        .width(100.percent)
        .height(100.percent)
    }

    /** iOS ChatControllerReport.swift:165-213（TelegramUser 分支）：确认后 block，默认同时举报并删除会话。 */
    @State var blockReportSpamChecked: Bool = true
    @State var blockDeleteChatChecked: Bool = true

    private func blockCurrentPeer(): Unit {
        let uid = this.viewModel.chatId
        let pt = this.viewModel.peerType
        let hash = getRealMessageService().getAccessHashForUser(uid)
        let report = this.blockReportSpamChecked
        let deleteChat = this.blockDeleteChatChecked
        this.showBlockPeerSheet = false
        this.peerBarButtons = ArrayList<String>()
        let _ = spawn {
            let ok = getContactsService().blockUser(uid, hash)
            if (report) { let _ = getChatComposeExtrasService().reportSpam(pt, uid) }
            launch {
                if (ok) { this.viewModel.hasBlockedPeer = true }
                if (deleteChat) {
                    match (getChatListVM()) {
                        case Some(vm) => vm.deleteChat(uid)
                        case None => ()
                    }
                    routerPop()
                }
            }
        }
    }

    @Builder
    func blockCheckRow(title: String, checked: Bool, onTap: () -> Unit) {
        Row {
            Text(if (checked) { "✓" } else { "" })
                .fontSize(17)
                .fontColor(0xFF007AFF)
                .width(28)
            Text(title)
                .fontSize(17)
                .fontColor(this.presentation.textColor)
                .layoutWeight(1)
        }
        .width(100.percent)
        .height(52)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt => onTap() })
    }

    @Builder
    func blockPeerSheet() {
        Stack(alignContent: Alignment.Bottom) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x66000000)
                .onClick({ _evt => this.showBlockPeerSheet = false })
            Column {
                Column {
                    Text("Do you want to block ${this.peerCompactTitle()} from messaging and calling you on Telegram?")
                        .fontSize(13)
                        .fontColor(0xFF8E8E93)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 14, bottom: 14)
                    Divider().color(0x1F000000).strokeWidth(0.5)
                    this.blockCheckRow("Report Spam", this.blockReportSpamChecked, { =>
                        this.blockReportSpamChecked = !this.blockReportSpamChecked
                    })
                    Divider().color(0x1F000000).strokeWidth(0.5)
                    this.blockCheckRow("Delete this Chat", this.blockDeleteChatChecked, { =>
                        this.blockDeleteChatChecked = !this.blockDeleteChatChecked
                    })
                    Divider().color(0x1F000000).strokeWidth(0.5)
                    Text("Block ${this.peerCompactTitle()}")
                        .fontSize(20)
                        .fontColor(0xFFFF3B30)
                        .textAlign(TextAlign.Center)
                        .width(100.percent)
                        .height(57)
                        .onClick({ _evt => this.blockCurrentPeer() })
                }
                .width(100.percent)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(14)
                Text(trSource("Cancel"))
                    .fontSize(20)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFF007AFF)
                    .textAlign(TextAlign.Center)
                    .width(100.percent)
                    .height(57)
                    .margin(top: 8)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(14)
                    .onClick({ _evt => this.showBlockPeerSheet = false })
            }
            .width(100.percent)
            .padding(left: 8, right: 8, bottom: 34)
            .onClick({ _evt => })
        }
        .width(100.percent)
        .height(100.percent)
    }

    private func peerCompactTitle(): String {
        match (this.lookupCachedUser(this.viewModel.chatId)) {
            case Some(u) =>
                if (u.firstName.size > 0) { return u.firstName }
                if (u.lastName.size > 0) { return u.lastName }
            case None => ()
        }
        return this.chatName
    }

    /** iOS unarchivePeer → unarchiveAutomaticallyArchivedPeer（PeerContactSettings.swift:61）+ UnarchiveDone 提示。 */
    private func unarchiveCurrentPeer(): Unit {
        let pt = this.viewModel.peerType
        let pid = this.viewModel.chatId
        var handledByList = false
        match (getChatListVM()) {
            case Some(vm) =>
                for (c in vm.archiveChatList) {
                    if (c.id == pid) { handledByList = true }
                }
                if (handledByList) { vm.unarchiveChat(pid) }
            case None => ()
        }
        if (!handledByList) {
            let _ = spawn { let _ = getRealChatListService().unarchiveChat(pt, pid) }
        }
        // 本地同步去掉 canBlock / canReport / autoArchived（与 iOS 更新 cachedData 一致）
        let clearMask: Int32 = 1 | 4 | 128
        this.applyPeerSettings(this.peerSettingsFlags & (Int32(-1) ^ clearMask))
        showToast("The chat was moved to your main list.")
    }

    /** iOS shareAccountContact → contacts.acceptContact。 */
    /**
     * S2-12: iOS ChatController.swift:9625-9660 shareAccountContact — confirm
     * (Conversation.ShareMyPhoneNumberConfirmation with my formatted number and the
     * peer's compact title, buttons Cancel / Share My Phone Number), then
     * contacts.acceptContact and an OverlayStatus
     * "Conversation.ShareMyPhoneNumber.StatusSuccess"; the bar disappears on success.
     */
    private func shareMyPhoneWithPeer(): Unit {
        let uid = this.viewModel.chatId
        var myPhone = ""
        match (getAuthStorage().getUserData()) {
            case Some(userData) => myPhone = userData.phone
            case None => ()
        }
        var phoneText = if (myPhone.startsWith("+")) { myPhone } else { "+${myPhone}" }
        let parsedNumber = parsePhoneNumber(phoneText)
        if (parsedNumber.countryCode.size > 0 && parsedNumber.nationalNumber.size > 0) {
            phoneText = formatPhoneNumber(parsedNumber.countryCode, parsedNumber.nationalNumber)
        }
        var peerTitle = this.chatName
        match (this.lookupCachedUser(uid)) {
            case Some(u) =>
                if (u.firstName.size > 0) { peerTitle = u.firstName } else if (u.lastName.size > 0) { peerTitle = u.lastName }
            case None => ()
        }
        let capturedTitle = peerTitle
        let question = trOr("Conversation.ShareMyPhoneNumberConfirmation",
            "Are you sure you want to share your phone number %1$@ with %2$@?")
            .replace("%1$@", phoneText).replace("%2$@", peerTitle)
        Hilog.info(0, "CjTelegram", "[PeerBar] share phone confirm peer=${uid} title=${peerTitle}")
        showAlert(
            title: "",
            message: question,
            confirmText: trOr("Conversation.ShareMyPhoneNumber", "Share My Phone Number"),
            onConfirm: { =>
                let hash = getRealMessageService().getAccessHashForUser(uid)
                let _ = spawn {
                    let ok = getContactsService().acceptAndShareContact(uid, hash)
                    Hilog.info(0, "CjTelegram", "[PeerBar] acceptContact peer=${uid} ok=${ok}")
                    launch {
                        if (ok) {
                            this.peerBarButtons = ArrayList<String>()
                            showToast(trOr("Conversation.ShareMyPhoneNumber.StatusSuccess", "%@ can now see your phone number.")
                                .replace("%@", capturedTitle))
                        } else {
                            showToast(trOr("Login.UnknownError", "An error occurred, please try again later."))
                        }
                    }
                }
            },
            cancelText: trOr("Common.Cancel", "Cancel")
        )
    }

    /** iOS ChatControllerReport.swift:214-247（群 / 频道分支）：确认后举报并退出、删除会话。 */
    private func confirmReportPeerSpam(): Unit {
        let pt = this.viewModel.peerType
        let pid = this.viewModel.chatId
        let info = if (pt == "user") {
            "Are you sure you want to report spam from this user?"
        } else if (pt == "channel" && this.channelIsBroadcastMirror) {
            "Are you sure you want to report spam from this channel?"
        } else {
            "Are you sure you want to report spam from this group?"
        }
        let title = if (pt == "user") { "Report Spam" } else { "Report Spam and Leave" }
        let cancelBtn = AlertDialogButtonOptions(value: "Cancel", action: { => () })
        let reportBtn = AlertDialogButtonOptions(
            value: title,
            fontColor: 0xFFFF3B30,
            action: { =>
                let _ = spawn {
                    let _ = getChatComposeExtrasService().reportSpam(pt, pid)
                    launch {
                        match (getChatListVM()) {
                            case Some(vm) => vm.deleteChat(pid)
                            case None => ()
                        }
                        routerPop()
                    }
                }
            }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: "",
            message: info,
            autoCancel: true,
            primaryButton: cancelBtn,
            secondaryButton: reportBtn
        ))
    }

    /** iOS ChatInterfaceInputContexts.swift:193：计时器已设、非收藏夹、输入为空。 */
    private func showAutoremoveAccessory(): Bool {
        return this.autoremoveTimeoutSec > 0 && this.inputText.isEmpty() && this.viewModel.editingMsgId == 0 &&
            !this.viewModel.isSavedMessagesChat()
    }

    /** iOS ChatInterfaceInputContexts.swift:276：存在可见的 Bot 回复键盘且输入为空。 */
    private func showBotKeyboardAccessory(): Bool {
        return this.botKeyboardMessageId != 0 && this.inputText.isEmpty() && this.viewModel.editingMsgId == 0 &&
            this.botKeyboardMessageId != this.botKeyboardDismissedMsgId
    }

    /** 输入框右内边距：附件图标占位（emoji 44 基础上追加计时器 / Bot 键盘）。 */
    private func inputAccessoryExtraWidth(): Float64 {
        var w = 0.0
        if (this.showScheduledAccessory()) { w += 30.0 }
        if (this.showBotCommandsAccessory()) { w += 28.0 }
        if (this.showAutoremoveAccessory()) { w += 38.0 }
        if (this.showBotKeyboardAccessory()) { w += 34.0 }
        return w
    }

    /**
     * iOS keyboardButtonsMessage：最近一条带回复键盘 / 隐藏键盘标记的对方消息决定当前 Bot 键盘；
     * 新键盘到来且输入为空时自动切到按钮键盘（inputMode .inputButtons）。
     */
    private func syncBotKeyboard(messages: ArrayList<Message>): Unit {
        // 自动删除计时器随最新的 messageActionSetMessagesTTL 服务消息即时更新
        // （iOS CachedUserData.autoremoveTimeout 由该动作同步刷新）。
        var t = messages.size - 1
        while (t >= 0) {
            let m = messages[t]
            if (m.serviceTtlPeriod >= 0) {
                if (m.id != this._lastTtlServiceMsgId) {
                    this._lastTtlServiceMsgId = m.id
                    this.autoremoveTimeoutSec = m.serviceTtlPeriod
                }
                break
            }
            t -= 1
        }
        var kbMsgId: Int64 = 0
        var rows = ArrayList<ArrayList<String>>()
        var singleUse = false
        var resize = false
        var i = messages.size - 1
        while (i >= 0) {
            let m = messages[i]
            if (!m.isSent && (m.replyMarkupKind == 1 || m.replyMarkupKind == 2)) {
                if (m.replyMarkupKind == 1 && !m.replyKeyboardRows.isEmpty()) {
                    kbMsgId = m.id
                    rows = m.replyKeyboardRows
                    singleUse = m.replyKeyboardSingleUse
                    resize = m.replyKeyboardResize
                }
                break
            }
            i -= 1
        }
        if (kbMsgId == this.botKeyboardMessageId) { return }
        this.botKeyboardMessageId = kbMsgId
        this.botKeyboardRows = rows
        this.botKeyboardSingleUse = singleUse
        this.botKeyboardResize = resize
        if (kbMsgId == 0) {
            this.botKeyboardShown = false
            return
        }
        if (this.inputText.isEmpty() && kbMsgId != this.botKeyboardDismissedMsgId && !this.entityKeyboardVisible() &&
            !this.showAttachmentPanel) {
            this.showBotKeyboard()
        }
    }

    private func showBotKeyboard(): Unit {
        this.closeEntityKeyboard()
        this.closeAttachmentPanel()
        this.blurComposer()
        this.botKeyboardShown = true
    }

    /** 键盘图标：切回文本输入并弹出系统键盘（iOS .botInput(.keyboard)）。 */
    private func hideBotKeyboardToText(): Unit {
        this.botKeyboardShown = false
        let _ = spawn {
            sleep(Duration.millisecond * 80)
            launch { FocusControl.requestFocus(CHAT_INPUT_FIELD_ID) }
        }
    }

    /** iOS ChatButtonKeyboardInputNode 按下普通按钮 → 以按钮文字发送；single_use 键盘随即收起。 */
    private func onBotKeyboardButton(text: String): Unit {
        if (text.isEmpty()) { return }
        if (this.botKeyboardSingleUse) {
            this.botKeyboardDismissedMsgId = this.botKeyboardMessageId
            this.botKeyboardShown = false
        }
        this.viewModel.sendMessage(text)
        this.scrollToBottom()
        this.advanceChatGradientPhase()
    }

    @Builder
    func botReplyKeyboardPanel() {
        Scroll {
            Column(space: 6) {
                ForEach(this.botKeyboardRows.toArray(), itemGenerator: { row: ArrayList<String>, _ri: Int64 =>
                    Row(space: 6) {
                        ForEach(row.toArray(), itemGenerator: { title: String, _bi: Int64 =>
                            Text(title)
                                .fontSize(16)
                                .fontColor(this.presentation.textColor)
                                .textAlign(TextAlign.Center)
                                .maxLines(2)
                                .textOverflow(TextOverflow.Ellipsis)
                                .layoutWeight(1)
                                .height(43)
                                .padding(left: 4, right: 4)
                                .borderRadius(8)
                                .backgroundColor(this.presentation.cardColor)
                                .shadow(radius: 1.0, color: Color(0x40000000), offsetY: 1.0)
                                .onClick({ _evt => this.onBotKeyboardButton(title) })
                        })
                    }
                    .width(100.percent)
                })
            }
            .width(100.percent)
            .padding(left: 6, right: 6, top: 6, bottom: 6)
        }
        .width(100.percent)
        .constraintSize(minHeight: if (this.botKeyboardResize) { 0.0 } else { 216.0 }, maxHeight: 300.0)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .backgroundColor(0xFFD1D3D9)
    }

    private func applyChatListMute(peerId: Int64, muted: Bool): Unit {
        match (getChatListVM()) {
            case Some(vm) =>
                for (c in vm.chatList) {
                    if (c.id == peerId) { c.isMuted = muted }
                }
                for (c in vm.archiveChatList) {
                    if (c.id == peerId) { c.isMuted = muted }
                }
                vm.publishCurrentChatList("channelPanelMute")
            case None => ()
        }
    }

    /**
     * iOS ChatInterfaceStateInputPanels：广播频道未加入 → Join；已加入但不能发帖
     * （非创建者且无 post_messages 管理权限，chatAdminRights flags.1）→ 订阅者 Mute / Unmute 面板。
     */
    private func isBroadcastSubscriber(): Bool {
        if (this.viewModel.peerType != "channel"
            || !(this.channelIsBroadcastMirror || this.channelIsBroadcast)
            || this.channelJoinRequiredMirror || this.channelIsLeft) {
            return false
        }
        match (getRealChatListService().getCachedChat("channel", this.viewModel.chatId)) {
            case Some(c) => return !c.isCreator && (c.adminRightsFlags & 2) == 0
            case None => return false
        }
    }

    /** iOS ChatChannelSubscriberInputPanelNode → togglePeerMuted（永久静音 / 取消静音）。 */
    private func toggleChannelMute(): Unit {
        if (this.channelMuteBusy) { return }
        let pid = this.viewModel.chatId
        let newMuted = !this.channelMutedMirror
        this.channelMuteBusy = true
        let _ = spawn {
            let ok = getRealChatListService().toggleMuteDialog("channel", pid, newMuted)
            launch {
                this.channelMuteBusy = false
                if (ok) {
                    this.channelMutedMirror = newMuted
                    this.applyChatListMute(pid, newMuted)
                } else {
                    this.showMediaToast("Unable to update notifications", autoClear: true)
                }
            }
        }
    }

    /**
     * iOS ChatController.navigationButtonAction(.openChatInfo(expandAvatar:))：导航栏头像按钮
     * 传 expandAvatar: true（资料页 avatarInitiallyExpanded，头像直接以展开大图显示，S2-02）；
     * 点标题传 false（普通头部，点头像再展开，S6-01）。
     */
    private func openCurrentPeerInfo(expandAvatar!: Bool = false): Unit {
        // 资料页按全局选中会话加载；中途打开过别的会话时先指回本页的 peer
        setSelectedChat(this.viewModel.chatId, this.chatName, this.viewModel.peerType)
        if (this.viewModel.isSavedMessagesChat()) {
            // iOS opens the Saved Messages peer info (not My Profile); it
            // carries the "Chats" pane when saved topics exist.
            routerPush("SavedMessagesPage", "profile")
            return
        }
        if (getSelectedChatPeerType() == "user") {
            routerPush("UserProfilePage", if (expandAvatar) { USER_PROFILE_EXPAND_AVATAR_PARAM } else { "" })
        } else {
            routerPush("PeerInfoPage", "")
        }
    }

    // 混合迁移：aboutToDisappear 有实清理逻辑 + onBackPressed 的 markAsRead/恢复聊天列表逻辑 → 合并进 cleanup()，经根容器 .onDisAppear 触发
    private func cleanup(): Unit {
        if (this.cleanedUp) { return }
        this.cleanedUp = true
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] aboutToDisappear - cleanup")
        this.groupCallPanelAlive = false
        setActiveGroupCallListener(None)
        this.unregisterImeHeightWatcher()
        // 页面离场同样兜底收割键盘流（closeEntityKeyboard 同一条注释）。
        getKeyboardDocPlayback().stopAll()
        getKeyboardFrameClock().stopKeyboardStreams(9223372036854775807)
        hideConversation(this._visibleConversationGeneration)
        this._visibleConversationGeneration = 0
        unregisterChatRoomBackHandler(this._backHandlerGeneration)
        this._backHandlerGeneration = 0
        this._syncActive = false
        this._syncGeneration += 1
        // 批 3：注销消息推送订阅（闭包持有 this，不注销会让已销毁的页面继续被回调）
        this.viewModel.clearMessagesChangedHandler()
        this.viewModel.suspendMediaPipeline()
        this.viewModel.stopPolling()
        // Phase P5-12: 清除语音进度回调
        getVoicePlayerManager().clearOnProgressUpdate()
        this._voicePlaybackRequestGeneration += 1
        this._pendingVoiceDownloadMessageId = -1
        // P2-121: 清除 typing 回调
        getChatTitleActivityService().clearActivityHandler()
        let updatesManager = getUpdatesManager()
        if (this._userStatusSubscriptionToken >= 0) {
            updatesManager.removeUserStatusSubscriber(this._userStatusSubscriptionToken)
            this._userStatusSubscriptionToken = -1
        }
        if (this._emojiInteractionSubscriptionToken >= 0) {
            updatesManager.removeEmojiInteractionSubscriber(this._emojiInteractionSubscriptionToken)
            this._emojiInteractionSubscriptionToken = -1
        }
        if (this._secretStateSubscriptionToken >= 0) {
            getTelegramCore_SecretChatsService().removeStateSubscriber(this._secretStateSubscriptionToken)
            this._secretStateSubscriptionToken = -1
        }
        // P5-9: Save or clear draft
        this.saveDraft()

        // 离开会话只提交已读边界。Chats 由账号级 Projection 持续更新，
        // 不再暂停/恢复同步，也不再为返回页面全量 getDialogs。
            let cleanupGeneration = this._syncGeneration
            let chatIdCopy = this.viewModel.chatId
            let peerTypeCopy = this.viewModel.peerType
            let msgList = this.viewModel.messageList
            spawn {
                var waitCount = 0
                while (this.viewModel.isPollingBusy() && waitCount < 50) {
                    sleep(Duration.millisecond * 100)
                    waitCount += 1
                }
                if (waitCount > 0) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Waited ${waitCount * 100}ms for polling to finish")
                }
                sleep(Duration.millisecond * 500)
                
                // 标记已读
                if (!msgList.isEmpty()) {
                    let maxId = Int32(msgList[msgList.size - 1].id)
                    try {
                        let svc = getRealMessageService()
                        svc.markAsRead(peerTypeCopy, chatIdCopy, maxId)
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] markAsRead failed: ${e}")
                    }
                }
                if (this.cleanedUp && cleanupGeneration == this._syncGeneration) {
                    match (getChatListVM()) {
                        case Some(vm) => launch { vm.clearUnreadCount(chatIdCopy) }
                        case None => ()
                    }
                }
            }
    }

    /**
     * P2-395: 重新加载当前聊天的壁纸（per-chat 优先，回落全局）
     * 用于 WallpaperPickerPage 返回后刷新背景
     */
    private func reloadChatWallpaper(): Unit {
        let chatId = this.viewModel.chatId
        let next = getWallpaperBackgroundService().getCurrentWallpaperForChat(chatId)
        // 合并回归修复：重读结果与当前壁纸渲染等价时不翻转重挂载守卫。本函数会被 per-chat 变更
        // 监听、页面重新可见、暗色切换探针等多条路径反复调用，相同壁纸每次都销毁重建壁纸层
        // （整轮 80×80 fillRect 重绘）会把主线程占满（appfreeze）。
        let changed = !this.chatWallpaperInfo.sameRenderingAs(next)
        if (changed) {
            this.chatWallpaperInfo = next
            // S6-05：镜像在 build() 的探针里刷新；翻转守卫让壁纸层整体重建，新镜像才会进入组件构造。
            this.wpMountToggle = !this.wpMountToggle
        } else if (this.chatWallpaperInfo.phase != next.phase) {
            // 相位走组件自己的 @Prop 通道，不需要重挂载。
            this.chatWallpaperInfo.phase = next.phase
            this.wpPhaseMirror = next.phase
        }
        if (next.wallpaperType == WallpaperType.MultiColorGradient &&
            next.patternOverlayEnabled &&
            next.patternFile.size == 0) {
            // The built-in Telegram pattern is a cloud document. The synchronous wallpaper
            // resolver returns the correct dark/day gradient immediately and starts one
            // de-duplicated fetch; repaint this still-visible chat when that document lands.
            getWallpaperBackgroundService().resolveDefaultPatternFile({ path: String =>
                if (path.size > 0) {
                    launch {
                        if (!this.cleanedUp && this.viewModel.chatId == chatId) {
                            let resolved = getWallpaperBackgroundService().getCurrentWallpaperForChat(chatId)
                            if (!this.chatWallpaperInfo.sameRenderingAs(resolved)) {
                                this.chatWallpaperInfo = resolved
                                this.wpMountToggle = !this.wpMountToggle
                            }
                        }
                    }
                }
            })
        }
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] reloadChatWallpaper: peerId=${chatId} changed=${changed} type=${this.chatWallpaperInfo.wallpaperType.ordinal()} cloudId=${this.chatWallpaperInfo.cloudWallpaperId} patternFile=${this.chatWallpaperInfo.patternFile} imageUri=${this.chatWallpaperInfo.imageUri}")
    }

    /** S6-05：当前会话的 per-chat 壁纸被改写（壁纸库 Apply / userFull.wallpaper 同步）时重读。 */
    private func registerChatWallpaperListener(): Unit {
        setPerChatWallpaperListener(Some({ changedPeerId: Int64 =>
            if (changedPeerId == this.viewModel.chatId) {
                launch { this.reloadChatWallpaper() }
            }
        }))
    }

    /**
     * Harmony exposes the status/navigation regions as system surfaces. Fill them from the
     * effective wallpaper host colour and switch icon contrast with the presentation, so those
     * surfaces cannot fall back to an unrelated white strip during a chat theme transition.
     */
    private func setChatSystemBars(): Unit {
        let dark = this.presentation.isDark
        let barColor = this.chatSystemBarColor()
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let _ = spawn {
                    try {
                        getLastWindow(ctx).setWindowSystemBarProperties(
                            SystemBarProperties(
                                statusBarColor: barColor,
                                isStatusBarLightIcon: dark,
                                statusBarContentColor: if (dark) { "#FFFFFFFF" } else { "#FF000000" },
                                navigationBarColor: barColor,
                                isNavigationBarLightIcon: dark,
                                navigationBarContentColor: if (dark) { "#FFFFFFFF" } else { "#FF000000" },
                                enableStatusBarAnimation: true
                            )
                        )
                    } catch (e: Exception) {
                        Hilog.warn(0, "CjTelegram", "[ChatRoomPage] system bar update failed: ${e}")
                    }
                }
            case None => ()
        }
    }

    private func chatSystemBarColor(): String {
        if (this.chatWallpaperInfo.patternIntensity < 0.0) {
            // WallpaperBackgroundNode's negative-intensity path has an opaque black host.
            return "#FF000000"
        }
        match (this.chatWallpaperInfo.wallpaperType) {
            case WallpaperType.SolidColor =>
                return "#" + hexStringFromColor(this.chatWallpaperInfo.solidColor, true)
            case WallpaperType.TwoColorGradient =>
                return "#" + hexStringFromColor(this.chatWallpaperInfo.gradientColorStart, true)
            case WallpaperType.MultiColorGradient =>
                if (this.chatWallpaperInfo.gradientColors.size > 0) {
                    return "#" + hexStringFromColor(this.chatWallpaperInfo.gradientColors[0], true)
                }
            case WallpaperType.PatternWallpaper =>
                if (this.chatWallpaperInfo.gradientColors.size > 0) {
                    return "#" + hexStringFromColor(this.chatWallpaperInfo.gradientColors[0], true)
                }
            case WallpaperType.CustomImage => ()
        }
        // A system bar is a separate Harmony window, so an arbitrary photo cannot be sampled by
        // the ArkUI page. Use the same dark/light host colour Telegram uses around unavailable
        // image content rather than exposing the platform's unrelated white window default.
        return if (this.presentation.isDark) { "#FF000000" } else { "#FFE8E6DF" }
    }

    /**
     * P2-117: 保存草稿到本地 Preferences + 服务端（messages.saveDraft RPC）
     * 含 reply_to 状态持久化，委托给 ViewModel.saveDraftWithReply()。
     * 仅在 inputText 非空时发送到服务端（避免清除已有草稿时误用此路径）。
     */
    private func saveDraft(): Unit {
        // iOS 离开会话时同步的草稿是 composeInputState（输入框当前文字）；编辑态文本在
        // editMessage 里，不作草稿。此前读的是 VM 的 inputText —— 它只在恢复草稿 / 进入编辑
        // 时被赋值，于是编辑中返回会把被编辑消息的原文存成草稿，且之后永远清不掉。
        let draftText = if (this.viewModel.editingMsgId > 0) { this.composeTextBeforeEdit } else { this.inputText }
        if (draftText.size > 0) {
            this.viewModel.saveDraftWithReply(draftText)
        } else {
            // 如果输入为空，清除服务端草稿（静默，不影响 UX）
            this.viewModel.clearDraftAfterSend()
        }
    }

    /**
     * P2-399/P2-400: 获取当前选中的翻译目标语言显示名（用于气泡译文标签）
     */
    private func getTranslateLangName(): String {
        let code = getSelectedTranslateLang()
        let langs = getSupportedLanguages()
        for (lang in langs) {
            if (lang.code == code) { return lang.name }
        }
        return code
    }

    private func isPremiumAccount(): Bool {
        match (getAuthStorage().getUserData()) {
            case Some(user) => return user.isPremium
            case None => return false
        }
    }

    /**
     * P2-398: 启用整聊天自动翻译模式
     * 1. 保存状态到 Preferences
     * 2. 调用 togglePeerTranslations（hide=false → 告知服务端启用翻译）
     * 3. 批量翻译当前所有可见消息（逐条 messages.translateText）
     * @State temp-var 写法：每次更新集合先 var temp = map 再赋回
     */
    private func enableChatTranslation(): Unit {
        let chatId = this.viewModel.chatId
        let peerType = this.viewModel.peerType
        let toLang = getSelectedTranslateLang()
        let msgSvc = getRealMessageService()
        let accessHash = if (peerType == "user") {
            msgSvc.getAccessHashForUser(chatId)
        } else if (peerType == "channel") {
            msgSvc.getAccessHashForChannel(chatId)
        } else {
            Int64(0)
        }

        // 持久化状态
        let state = ChatTranslationState()
        state.toLang = toLang
        state.isEnabled = true
        saveChatTranslationState(chatId, state)

        // 通知服务端启用（hide=false）
        togglePeerTranslations(chatId, accessHash, peerType, false)

        // 标记翻译中
        launch {
            this.chatTransIsTranslating = true
        }

        // 收集当前所有消息 ID
        let currentMsgs = this.viewModel.messageList
        let msgIds = ArrayList<Int64>()
        var k: Int64 = 0
        while (k < currentMsgs.size) {
            let m = currentMsgs[k]
            if (m.content.size > 0 && !m.isSent) {
                msgIds.add(m.id)
            }
            k = k + 1
        }

        let capturedChatId = chatId
        let capturedHash = accessHash
        let capturedType = peerType
        let capturedLang = toLang

        translateAllMessages(
            msgIds,
            capturedChatId,
            capturedHash,
            capturedType,
            capturedLang,
            { mid: Int64, text: String =>
                let capturedMid = mid
                let capturedText = text
                launch {
                    var showMap = this.bubbleTranslateShow
                    showMap[capturedMid] = true
                    this.bubbleTranslateShow = showMap
                    var txtMap = this.bubbleTranslateTexts
                    txtMap[capturedMid] = capturedText
                    this.bubbleTranslateTexts = txtMap
                    var loadMap = this.bubbleTranslateLoading
                    loadMap[capturedMid] = false
                    this.bubbleTranslateLoading = loadMap
                }
            }
        )

        // 等批量翻译完成后清除 translating 标记
        spawn {
            var w: Int64 = 0
            let waitMax: Int64 = 120
            while (w < waitMax) {
                sleep(Duration.millisecond * 500)
                w = w + 1
            }
            launch { this.chatTransIsTranslating = false }
        }
    }

    /**
     * P2-398: 禁用整聊天自动翻译模式（Show Original）
     * 1. 清除 Preferences 状态
     * 2. 调用 togglePeerTranslations（hide=true → 告知服务端禁用翻译）
     * 3. 隐藏所有气泡翻译区（重置 bubbleTranslateShow）
     */
    private func disableChatTranslation(): Unit {
        let chatId = this.viewModel.chatId
        let peerType = this.viewModel.peerType
        let msgSvc = getRealMessageService()
        let accessHash = if (peerType == "user") {
            msgSvc.getAccessHashForUser(chatId)
        } else if (peerType == "channel") {
            msgSvc.getAccessHashForChannel(chatId)
        } else {
            Int64(0)
        }

        // 持久化关闭状态
        let state = ChatTranslationState()
        state.isEnabled = false
        saveChatTranslationState(chatId, state)

        // 通知服务端禁用（hide=true）
        togglePeerTranslations(chatId, accessHash, peerType, true)

        // 清空所有气泡翻译（整体赋值触发 @State 重建）
        launch {
            this.bubbleTranslateShow = HashMap<Int64, Bool>()
            this.bubbleTranslateTexts = HashMap<Int64, String>()
            this.bubbleTranslateLoading = HashMap<Int64, Bool>()
            this.bubbleTranslateError = HashMap<Int64, Bool>()
            this.chatTransIsTranslating = false
        }
    }

    /**
     * P2-398: 检测消息列表中是否有外语消息（heuristic：首条来自对方的消息非空即视为外语）
     * iOS 使用 NLLanguageRecognizer，Cangjie 简化：收到对方消息即显示翻译条（Policy A fidelity-gap）
     */
    private func detectForeignLanguage(): Bool {
        let msgs = this.viewModel.messageList
        let service = getTranslateService()
        var i: Int64 = 0
        while (i < msgs.size) {
            let m = msgs[i]
            if (!m.isSent && service.canTranslateChatText(m.content)) {
                return true
            }
            i = i + 1
        }
        return false
    }

    /**
     * P2-397/P2-400: 通过 messages.translateText MTProto 翻译指定消息
     * 结果写入 bubbleTranslate* HashMap，由 MessageBubble 通过 prop 读取展示
     * accessHash 从 RealMessageService 缓存读取（loadMessages 时已填充）
     * @State temp-var 写法保证集合突变触发 UI 重建（S-003）
     */
    private func translateBubbleMessage(msgId: Int64, toLang: String): Unit {
        let chatId = this.viewModel.chatId
        let peerType = this.viewModel.peerType
        let msgSvc = getRealMessageService()
        let accessHash = if (peerType == "user") {
            msgSvc.getAccessHashForUser(chatId)
        } else if (peerType == "channel") {
            msgSvc.getAccessHashForChannel(chatId)
        } else {
            Int64(0)
        }
        let mid = msgId
        let lang = toLang

        // Mark loading + show translate area
        var showMap = this.bubbleTranslateShow
        showMap[mid] = true
        this.bubbleTranslateShow = showMap
        var loadMap = this.bubbleTranslateLoading
        loadMap[mid] = true
        this.bubbleTranslateLoading = loadMap
        var errMap = this.bubbleTranslateError
        errMap[mid] = false
        this.bubbleTranslateError = errMap

        spawn {
            let svc = getTranslateService()
            let result = svc.translateMessage(
                chatId,
                accessHash,
                peerType,
                Int32(mid),
                lang
            )
            let ok = result.success
            let txt = result.translatedText
            launch {
                var txtMap = this.bubbleTranslateTexts
                txtMap[mid] = txt
                this.bubbleTranslateTexts = txtMap
                var lMap = this.bubbleTranslateLoading
                lMap[mid] = false
                this.bubbleTranslateLoading = lMap
                var eMap = this.bubbleTranslateError
                eMap[mid] = !ok
                this.bubbleTranslateError = eMap
            }
        }
    }

    /**
     * 同步 viewModel.messageList → displayMessages
     */
    /**
     * 顶部 Video Chat Join 条的数据：chatFull/channelFull.call → activeCall，phone.getGroupCall → 人数。
     * iOS 由 updateGroupCall 推送驱动 CachedData.activeCall；这里开页取一次 + 15s 复查，
     * 自己入会/离开由 GroupCallSession 状态即时反映。
     */
    private func applyGroupCallSchedule(at: Int64): Unit {
        this.activeGroupCallSchedule = at
        this.activeGroupCallCountdown = groupCallCountdownText(at)
        if (at > 0 && !this.groupCallCountdownRunning) {
            this.groupCallCountdownRunning = true
            let _ = spawn {
                while (this.groupCallPanelAlive && this.activeGroupCallSchedule > 0) {
                    sleep(Duration.second * 1)
                    let text = groupCallCountdownText(this.activeGroupCallSchedule)
                    launch { this.activeGroupCallCountdown = text }
                }
                this.groupCallCountdownRunning = false
            }
        }
    }

    private func startGroupCallPanelSync(): Unit {
        let pType = this.viewModel.peerType
        let pid = this.viewModel.chatId
        if (pType != "chat" && pType != "channel") { return }
        if (this.groupCallPanelAlive) { return }
        this.groupCallPanelAlive = true
        // 即时刷新靠 updateGroupCall 推送；下面的循环只是 2 分钟一次的兜底
        setActiveGroupCallListener(Some({ chatId: Int64, callId: Int64, hash: Int64, count: Int32 =>
            if (chatId == pid || chatId == 0) {
                let joined = callId != 0 && getGroupCallSession().isActiveFor(callId)
                launch {
                    if (this.groupCallPanelAlive) {
                        this.activeGroupCallId = callId
                        this.activeGroupCallHash = hash
                        this.activeGroupCallCount = count
                        this.activeGroupCallJoined = joined
                        if (callId == 0) { this.applyGroupCallSchedule(0) }
                    }
                }
                // 推送里不带 schedule_date：通话有变化时补查一次（预约 → 开始时这个值会清零）
                if (callId != 0) {
                    let _ = spawn {
                        var at: Int64 = 0
                        match (getCallsService().getGroupCall(callId, hash)) {
                            case Some(info) => at = Int64(info.scheduleDate)
                            case None => ()
                        }
                        let atCopy = at
                        launch { if (this.groupCallPanelAlive) { this.applyGroupCallSchedule(atCopy) } }
                    }
                }
            }
        }))
        let _ = spawn {
            var first = true
            while (this.groupCallPanelAlive) {
                try {
                    if (!first) { getPeerInfoService().invalidateGroupFullInfo(pid) }
                    first = false
                    let full = getPeerInfoService().getGroupFullInfo(pType, pid)
                    var count: Int32 = 0
                    var scheduleAt: Int64 = 0
                    if (full.activeCallId != 0) {
                        match (getCallsService().getGroupCall(full.activeCallId, full.activeCallAccessHash)) {
                            case Some(info) =>
                                count = info.participantCount
                                scheduleAt = Int64(info.scheduleDate)
                            case None => ()
                        }
                    }
                    let sched = scheduleAt
                    let joined = full.activeCallId != 0 && getGroupCallSession().isActiveFor(full.activeCallId)
                    let cid = full.activeCallId
                    let chash = full.activeCallAccessHash
                    let cnt = count
                    launch {
                        this.activeGroupCallId = cid
                        this.activeGroupCallHash = chash
                        this.activeGroupCallCount = cnt
                        this.activeGroupCallJoined = joined
                        this.applyGroupCallSchedule(sched)
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] group call panel sync failed: ${e}")
                }
                sleep(Duration.second * 120)
            }
        }
    }

    private func openActiveGroupCall(): Unit {
        if (this.activeGroupCallId == 0) { return }
        let pType = this.viewModel.peerType
        let pid = this.viewModel.chatId
        var canManage = false
        match (getRealChatListService().getCachedChat(pType, pid)) {
            // creator，或具 manage_call（chatAdminRights flags.11）的管理员
            case Some(c) => canManage = c.isCreator || (c.adminRightsFlags & (1 << 11)) != 0
            case None => ()
        }
        routerPush("GroupCallScreen", "${this.activeGroupCallId}:${this.activeGroupCallHash}::${pType}:${pid}:${if (canManage) { "1" } else { "0" }}")
    }

    /**
     * P2-121/P2-122: 同步 VM 的 subtitleText / typingText / pinnedCount 到 Page @State
     *
     * 每秒轮询一次，将 VM 的 @Publish 字段同步到 Page @State，保持副标题/置顶条刷新。
     * @Publish 字段变化本身已通过 @Observed/@Publish 机制触发 UI rebuild，
     * 但 Page 自己的 @State（subtitleText / chatTypingText / pinnedCount）需要手动同步。
     */
    private func startSubtitleAndPinnedSync() {
        spawn {
            while (this._syncActive) {
                let vmSubtitle = this.viewModel.subtitleText
                let vmTyping = this.viewModel.typingText
                let vmPinnedCount = this.viewModel.pinnedMessageIds.size
                if (vmSubtitle != this.subtitleText) {
                    launch { this.subtitleText = vmSubtitle }
                }
                if (vmTyping != this.chatTypingText) {
                    launch { this.chatTypingText = vmTyping }
                }
                if (vmPinnedCount != this.pinnedCount) {
                    launch { this.pinnedCount = vmPinnedCount }
                }
                let vmJoinRequired = this.viewModel.channelJoinRequired
                let vmJoinRequestNeeded = this.viewModel.channelJoinRequestNeeded
                let vmIsBroadcast = this.viewModel.channelIsBroadcast
                if (vmJoinRequired != this.channelJoinRequiredMirror
                    || vmJoinRequestNeeded != this.channelJoinRequestNeededMirror
                    || vmIsBroadcast != this.channelIsBroadcastMirror) {
                    launch {
                        this.channelJoinRequiredMirror = vmJoinRequired
                        this.channelJoinRequestNeededMirror = vmJoinRequestNeeded
                        this.channelIsBroadcastMirror = vmIsBroadcast
                    }
                }
                sleep(Duration.millisecond * 1000)
            }
        }
    }

    /** Prepare the extracted-message overlay and bind actions to this message. */
    private func presentReactionOverlay(
        message: Message,
        sourceY: Float64,
        sourceHeight: Float64
    ): Unit {
        let msgId = message.id
        let isSent = message.isSent
        let content = message.content
        let senderName = message.senderName
        // P2-119: 检测是否有媒体（照片/文档/视频）可保存
        let hasMedia = (message.photoId != 0 || message.documentId != 0)
        let pinnedMessageId = this.viewModel.pinnedMessageId
        let peerType = this.viewModel.peerType

        getReactionOverlayService().showReactionOverlay(
            onSelectReaction: { emoji: String =>
                this.viewModel.toggleReaction(msgId, emoji)
            },
            onSelectCustomReaction: { documentId: Int64 =>
                let peerTypeCopy = this.viewModel.peerType
                let peerIdCopy = this.viewModel.chatId
                let _ = spawn {
                    let success = getReactionSelectionService().sendCustomEmojiReaction(
                        peerTypeCopy,
                        peerIdCopy,
                        Int32(msgId),
                        documentId
                    )
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] custom reaction result=${success}")
                    if (success) { this.viewModel.loadMessages() }
                }
            },
            onReply: { =>
                this.viewModel.setReplyTo(msgId, content, senderName)
            },
            onEdit: { =>
                // 编辑前输入框里的草稿留作 composeInputState，编辑结束后还原。
                if (this.viewModel.editingMsgId == 0) {
                    this.composeTextBeforeEdit = this.inputText
                }
                this.viewModel.startEditing(msgId, content)
                this.setComposerText(content)
                // iOS ChatControllerLoadDisplayNode.swift:1805-1812：进入编辑即 inputMode = .text 并
                // ensureInputViewFocused() —— 输入框取焦、系统键盘弹出。真实 blur → 延迟取焦，
                // 与表情键切回系统键盘同一条已验证的焦点流转；等长按浮层先收起再取焦。
                if (this.entityKeyboardVisible()) { this.closeEntityKeyboard() }
                this.blurComposer()
                let _ = spawn {
                    sleep(Duration.millisecond * 300)
                    launch {
                        FocusControl.requestFocus(CHAT_INPUT_FIELD_ID)
                    }
                }
            },
            onPinToggle: { =>
                if (this.viewModel.pinnedMessageId == msgId) {
                    this.viewModel.unpinMessage()
                } else {
                    this.viewModel.pinMessageWithOptions(
                        msgId,
                        content,
                        silent: false,
                        pmOneside: false
                    )
                    launch { this.pinnedCount = this.viewModel.pinnedMessageIds.size }
                }
            },
            onPinForMe: { =>
                this.viewModel.pinMessageWithOptions(
                    msgId,
                    content,
                    silent: false,
                    pmOneside: true
                )
                launch { this.pinnedCount = this.viewModel.pinnedMessageIds.size }
            },
            onForward: { =>
                this.forwardMsgId = msgId
                this.forwardMsgIds = this.forwardTargetIds(message)
                this.forwardDropAuthor = false
                this.forwardDropCaptions = false
                this.loadForwardDialogs()
                this.showForwardPicker = true
            },
            onSelectMode: { =>
                let temp = HashMap<Int64, Bool>()
                temp[msgId] = true
                this.selectedMessageIds = temp
                this.setMultiSelectMode(true)
            },
            onSeenBy: { =>
                this.readParticipantsMsgId = msgId
                this.viewModel.fetchReadParticipants(msgId)
                this.showReadParticipants = true
            },
            onCopy: { =>
                this.viewModel.copyMessageText(msgId)
            },
            onSpeak: { =>
                let capturedText = content
                spawn {
                    let svc = getSpeakService()
                    let _ = svc.speakText(capturedText)
                }
            },
            onTranslate: { =>
                this.translateBubbleMessage(msgId, getSelectedTranslateLang())
            },
            onCopyLink: { =>
                let capturedMsgId = msgId
                this.viewModel.exportMessageLink(capturedMsgId, { =>
                    launch {
                        this.linkCopiedToast = true
                    }
                    spawn {
                        sleep(Duration.millisecond * 2000)
                        launch {
                            this.linkCopiedToast = false
                        }
                    }
                })
            },
            // Report options live in a separate dialog because selecting a
            // context-menu action dismisses the extracted overlay.
            onReportOpen: { =>
                let capturedMsgId = msgId
                let vmCapture = this.viewModel
                let uiCtxCapture = getUIContext()
                this.viewModel.fetchReportOptions(
                    capturedMsgId,
                    { texts: Array<String> =>
                        showReportOptionsDialog(uiCtxCapture, texts, { optIdx: Int64 =>
                            submitReportOption(uiCtxCapture, vmCapture, capturedMsgId, optIdx, { =>
                                launch {
                                    this.reportDoneToast = true
                                }
                                spawn {
                                    sleep(Duration.millisecond * 2000)
                                    launch {
                                        this.reportDoneToast = false
                                    }
                                }
                            })
                        })
                    },
                    { =>
                        launch {
                            this.reportDoneToast = true
                        }
                        spawn {
                            sleep(Duration.millisecond * 2000)
                            launch {
                                this.reportDoneToast = false
                            }
                        }
                    },
                    { =>
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] fetchReportOptions error msgId=${capturedMsgId}")
                    }
                )
            },
            onSave: { =>
                this.saveMessageMedia(message)
            },
            // imgmenu 批次："Copy Photo"（iOS 照片 context menu Copy 的 D-tier 对齐：
            // 复制 file:// URI 纯文本进系统剪贴板，见 copyMediaFileUri fidelity gap 注释）
            onCopyMedia: { =>
                this.copyMessagePhoto(message)
            },
            onDelete: { =>
                let targetMsgId = msgId
                if (message.status == "sending") {
                    // S3-25: iOS Conversation.ContextMenuCancelSending → PendingMessageManager
                    // cancels the upload and the local message disappears; no confirmation.
                    let cancelled = this.viewModel.cancelSendingMessage(targetMsgId)
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Cancel Sending msgId=${targetMsgId} ok=${cancelled}")
                    return
                }
                let uiCtx = getUIContext()
                let cancelBtn = AlertDialogButtonOptions(
                    value: "Cancel",
                    action: { => () }
                )
                if (this.viewModel.isSavedMessagesChat()) {
                    // S9-03: iOS presentDeleteMessageOptions (ChatControllerAdminBanUsers.swift:663-670):
                    // in Saved Messages only deleteLocally exists, titled
                    // Chat_ConfirmationRemoveFromSavedMessages when the message is effectively
                    // incoming (forwarded from someone else), otherwise Chat_ConfirmationDeleteFromSavedMessages.
                    let savedTitle = if (!message.isSent) { "Remove from Saved Messages" } else { "Delete from Saved Messages" }
                    let savedBtn = AlertDialogButtonOptions(
                        value: savedTitle,
                        fontColor: 0xFFFF3B30,
                        action: { =>
                            this.viewModel.deleteMessage(targetMsgId, revoke: false)
                        }
                    )
                    uiCtx.showAlertDialog(AlertDialogParamWithOptions(
                        title: "",
                        message: "",
                        autoCancel: true,
                        buttons: [cancelBtn, savedBtn]
                    ))
                    return
                }
                let forMeBtn = AlertDialogButtonOptions(
                    value: "Delete for Me",
                    fontColor: 0xFFFF3B30,
                    action: { =>
                        this.viewModel.deleteMessage(targetMsgId, revoke: false)
                    }
                )
                let forAllBtn = AlertDialogButtonOptions(
                    value: "Delete for Everyone",
                    fontColor: 0xFFFF3B30,
                    action: { =>
                        this.viewModel.deleteMessage(targetMsgId, revoke: true)
                    }
                )
                uiCtx.showAlertDialog(AlertDialogParamWithOptions(
                    title: "Delete Message",
                    message: "This will permanently delete the message.",
                    autoCancel: true,
                    buttons: [cancelBtn, forMeBtn, forAllBtn]
                ))
            },
            onViewReplies: { =>
                this.openMessageThread(message)
            },
            onSaveTone: { =>
                let toneMessage = message
                let tonePeerType = this.viewModel.peerType
                let tonePeerId = this.viewModel.chatId
                spawn { saveMessageAsNotificationSound(toneMessage, tonePeerType, tonePeerId) }
            },
            onDismiss: { => this.dismissMessageContextOverlay() }
        )

        this._messageContextGeneration += 1
        this.messageContextMessage = message
        this.messageContextSourceY = sourceY
        this.messageContextSourceHeight = sourceHeight
        this.messageContextIsSent = isSent
        this.messageContextHasText = content.size > 0
        this.messageContextHasMedia = hasMedia
        this.messageContextCanTranslate = getTranslateService().canTranslateText(content)
        this.messageContextPeerType = peerType
        // iOS canViewReadStats / Save for Notifications gating (see
        // services/MessageContextExtrasService.cj).
        prefetchMessageContextConfig()
        prefetchSavedNotificationSounds()
        this.messageContextReadStats = canShowMessageReadStats(
            message, peerType, this.viewModel.chatId, this.viewModel.channelIsBroadcast
        )
        this.messageContextSaveTone = canSaveMessageAsNotificationSound(message)
        this.messageContextSaveTitle = this.mediaSaveMenuTitle(message)
        this.messageContextDeleteTitle = this.messageDeleteMenuTitle(message)
        this.messageContextRepliesTitle = this.messageRepliesMenuTitle(message)
        let senderNames = HashMap<Int64, String>()
        for (m in this.viewModel.messageList) {
            if (m.senderId != 0 && m.senderName.size > 0) { senderNames[m.senderId] = m.senderName }
        }
        this.messageContextSenderNames = senderNames
        this.messageContextIsPinned = pinnedMessageId == msgId
        this.messageContextHiddenStableId = message.identityKey()
        // The overlay is a child of the page root Stack, while the source rect
        // comes from ComponentUtils in window coordinates, which include the
        // page's IME avoidance offset (see components/OverlayGeometry.cj).
        // Convert into root space and hand over the band that is actually
        // visible: below the status bar, above the gesture bar or raised IME.
        var rootY = 0.0
        var rootHeight = this.messageContextScreenHeight
        match (measureOverlaySlot(CHAT_ROOM_ROOT_ID)) {
            case Some(rect) =>
                rootY = this.pxToVp(rect.y)
                let measuredHeight = this.pxToVp(rect.h)
                if (measuredHeight > 0.0) { rootHeight = measuredHeight }
            case None => ()
        }
        let windowHeight = if (this.pageRootHeightVp > 0.0) { this.pageRootHeightVp } else { rootY + rootHeight }
        let imeHeight = if (this.lastImeHeightVpForPhase > 80.0) { this.lastImeHeightVpForPhase } else { 0.0 }
        let bottomInset = if (imeHeight > getSafeAreaBottom()) { imeHeight } else { getSafeAreaBottom() }
        var visibleTop = getSafeAreaTop() - rootY
        if (visibleTop < 0.0) { visibleTop = 0.0 }
        var visibleBottom = windowHeight - bottomInset - rootY
        if (visibleBottom > rootHeight) { visibleBottom = rootHeight }
        let localSourceY = sourceY - rootY
        this.messageContextSourceY = localSourceY
        this.messageContextVisibleTop = visibleTop
        this.messageContextVisibleBottom = visibleBottom
        Hilog.info(0, "CjTelegram", "[MessageContext] source=${localSourceY}/${sourceHeight} rootY=${rootY} visible=${visibleTop}..${visibleBottom} ime=${imeHeight}")
        // The overlay starts the extracted message over its source and moves
        // it only as far as needed to keep the actions on screen.
        this.messageContextTargetY = localSourceY
        this.messageContextVisible = true
        this.messageContextDismissing = false
    }

    /**
     * iOS ChatInterfaceStateContextMenus.swift:2049-2060: the destructive row reads
     * "Cancel Sending" while the message is still sending, "Remove" in Saved Messages
     * for an effectively-incoming message (S9-03), otherwise "Delete".
     */
    /** iOS CISCM:1497/1531: Save Video for videos, Save Image for photos, Save to Files otherwise. */
    private func mediaSaveMenuTitle(message: Message): String {
        if (message.photoId != 0) { return "Save Image" }
        if (message.messageType == "video" || message.messageType == "gif" || message.messageType == "video_note"
            || message.documentMimeType.startsWith("video/")) { return "Save Video" }
        if (message.documentMimeType.startsWith("image/")) { return "Save Image" }
        return "Save to Files"
    }

    /**
     * S5-04: iOS ChatInterfaceStateContextMenus.swift:1555-1592. Only inside a group-type channel
     * (supergroup). When the group has a linked discussion channel, every message carries a
     * threadId (StoreMessage_Telegram.swift:1168 sets it for the channel namespace) and
     * threadMessageCount stays 0 → Conversation.ContextViewThread "View Thread"; otherwise a
     * ReplyThreadMessageAttribute with count > 0 → Conversation.ContextViewReplies "View N Replies".
     */
    private func messageRepliesMenuTitle(message: Message): String {
        if (message.status == "sending" || message.id <= 0) { return "" }
        if (this.viewModel.peerType != "channel" || this.viewModel.channelIsBroadcast) { return "" }
        if (this.viewModel.linkedChatId != 0) {
            return trOr("Conversation.ContextViewThread", "View Thread")
        }
        if (message.repliesCount <= 0) { return "" }
        if (message.repliesCount == 1) {
            return trOr("Conversation.ContextViewReplies_1", "View %@ Reply").replace("%@", "1")
        }
        return trOr("Conversation.ContextViewReplies_any", "View %@ Replies").replace("%@", "${message.repliesCount}")
    }

    /**
     * S5-04: iOS openReplyThread → fetchChannelReplyThreadMessage (messages.getDiscussionMessage)
     * then the thread history (messages.getReplies), shown as the Comments / Replies screen.
     */
    private func openMessageThread(message: Message): Unit {
        let pt = this.viewModel.peerType
        let pid = this.viewModel.chatId
        let msgId = message.id
        let count = Int64(message.repliesCount)
        this.threadTitle = this.threadTitleText(message.repliesIsComments, count)
        this.threadMessages = ArrayList<Message>()
        this.threadRoot = message
        this.threadHasRoot = true
        this.threadLoading = true
        this.showMessageThread = true
        this.blurComposer()
        Hilog.info(0, "CjTelegram", "[MessageThread] open peer=${pt}:${pid} msg=${msgId} replies=${count}")
        let _ = spawn {
            let result = getMessageThreadService().loadThread(pt, pid, msgId)
            launch {
                this.threadLoading = false
                if (result.success) {
                    match (result.rootMessage) {
                        case Some(root) =>
                            this.threadRoot = root
                            this.threadHasRoot = true
                        case None => ()
                    }
                    this.threadMessages = result.replies
                    // The discussion-group copy of a post carries no reply count (View Thread path):
                    // title from the loaded thread, like iOS ChatTitleView after the thread resolves.
                    this.threadTitle = this.threadTitleText(message.repliesIsComments || result.isChannelPost,
                        Int64(result.replies.size))
                    Hilog.info(0, "CjTelegram", "[MessageThread] loaded replies=${result.replies.size}")
                } else {
                    Hilog.info(0, "CjTelegram", "[MessageThread] load failed: ${result.errorMessage}")
                    showToast(trOr("Login.UnknownError", "An error occurred, please try again later."))
                }
            }
        }
    }

    /**
     * iOS ChatTitleView.swift:412-414: Conversation.TitleComments_* / TitleReplies_* ("[%@]Comments"
     * with the count bold), or TitleCommentsEmpty / TitleRepliesEmpty when the count is 0.
     */
    private func threadTitleText(isComments: Bool, count: Int64): String {
        if (isComments) {
            if (count == 0) { return trOr("Conversation.TitleCommentsEmpty", "Comments") }
            return if (count == 1) { "1 Comment" } else { "${count} Comments" }
        }
        if (count == 0) { return trOr("Conversation.TitleRepliesEmpty", "Replies") }
        return if (count == 1) { "1 Reply" } else { "${count} Replies" }
    }

    /** S2-72 / S2-74: iOS ChatInterfaceInputContexts .commands accessory / botMenuButton .commands. */
    private func showBotCommandsAccessory(): Bool {
        return this.botCommandsCount > 0 && this.inputText.isEmpty() && this.viewModel.editingMsgId == 0
    }

    private func showBotMenuButton(): Bool {
        if (!this.peerIsBotMirror || this.viewModel.peerType != "user") { return false }
        return this.botMenuButtonKind == 2 || this.botMenuButtonKind == 1 || (this.botMenuButtonKind == 0 && this.botCommandsCount > 0)
    }

    /** iOS updateShowCommands: list the bot commands (the "/" context query drives the panel). */
    private func openBotCommandsList(): Unit {
        Hilog.info(0, "CjTelegram", "[BotCommands] open list count=${this.botCommandsCount}")
        this.botKeyboardShown = false
        this.closeAttachmentPanel()
        this.setComposerText("/")
        this.contextQueryVM.onInputChanged("/")
    }

    /** iOS menuButtonPressed: web app menu → openWebView; commands → updateShowCommands. */
    private func onBotMenuButton(): Unit {
        triggerHaptic("impact", "light")
        if (this.botMenuButtonKind == 2 && this.botMenuButtonUrl.size > 0) {
            Hilog.info(0, "CjTelegram", "[BotMenu] web app ${this.botMenuButtonUrl}")
            routerPush("WebAppPage", this.botMenuButtonUrl)
            return
        }
        this.openBotCommandsList()
    }

    /** iOS sendBotCommand: tapping a command in the list sends it right away. */
    private func sendBotCommand(command: String) {
        let text = "/" + command
        Hilog.info(0, "CjTelegram", "[BotCommands] send ${text}")
        this.contextQueryVM.clearSuggestions()
        this.setComposerText("")
        let _ = this.viewModel.sendMessage(text)
        this.scrollToBottom()
    }

    private func messageDeleteMenuTitle(message: Message): String {
        if (message.status == "sending") { return "Cancel Sending" }
        if (this.viewModel.isSavedMessagesChat() && !message.isSent) { return "Remove" }
        return "Delete"
    }

    private func dismissMessageContextOverlay(): Unit {
        if (this.messageContextDismissing || !this.messageContextVisible) { return }
        this._messageContextGeneration += 1
        // Restore the real list node synchronously before a reaction callback
        // mutates/reuses its MessageBubble. Leaving it hidden until the delayed
        // animation completion can permanently carry opacity=0 into the reused
        // node when the reaction update refreshes the message list.
        this.messageContextHiddenStableId = 0
        this.messageContextDismissing = true
        spawn {
            sleep(Duration.millisecond * 210)
            launch {
                this.messageContextVisible = false
                this.messageContextDismissing = false
            }
        }
    }

    private func emojiEffectX(isSent: Bool, screenWidth: Float64): Float64 {
        // iOS ChatMessageAnimatedStickerItemNode starts with the 112pt emoji
        // frame, expands it by one width on both sides (336pt total), then
        // offsets outgoing effects another width to the left. On a 360pt
        // screen this puts both incoming and outgoing effect canvases almost
        // edge-to-edge instead of clipping most of an outgoing effect at the
        // right edge.
        return if (isSent) { screenWidth - 334.0 } else { -2.0 }
    }

    private func removeEmojiEffect(token: Int64): Unit {
        let next = ArrayList<ChatEmojiEffectOverlayItem>()
        for (item in this.emojiEffectItems) {
            if (item.token != token) { next.add(item) }
        }
        this.emojiEffectItems = next.toArray()
    }

    /**
     * S3-16: enter / leave selection mode (iOS ChatControllerImpl updateChatPresentationInterfaceState
     * withSelectedMessages / withoutSelectionState). MessageBubble receives isMultiSelectMode only through
     * its @State init (D-160: updateWithValueParams has no caller), so the bubbles already on screen keep
     * the old value: they stay enabled, swallow the tap and the ListItem.onClick that toggles the
     * selection never fires. Flip the mount guard (same mechanism as the theme switch, see
     * msgBubbleMountToggle) so every visible bubble is rebuilt with the new mode.
     */
    private func setMultiSelectMode(on: Bool): Unit {
        if (this.isMultiSelectMode == on) { return }
        this.isMultiSelectMode = on
        this.msgBubbleMountToggle = !this.msgBubbleMountToggle
    }

    /** S3-16: selection toggle shared by the check circle and the whole row. */
    private func toggleMessageSelection(msgId: Int64): Unit {
        // W5 S3-16: the tap did reach here ("[MessageBubble] selection tap" in hilog) but the
        // page kept "1 selected". `var temp = this.selectedMessageIds` aliases the very HashMap
        // the @State holds; mutating it in place and assigning the same reference back is not
        // observed as a change, so neither the "N selected" label nor the check circles / row
        // highlight re-rendered. onSelectMode (which works) always installs a fresh map — do
        // the same here: copy, toggle, assign the new instance.
        let temp = HashMap<Int64, Bool>()
        for ((id, v) in this.selectedMessageIds) { temp[id] = v }
        if (temp.contains(msgId)) {
            let _r = temp.remove(msgId)
        } else {
            temp[msgId] = true
        }
        this.selectedMessageIds = temp
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] toggleMessageSelection msgId=${msgId} selected=${temp.size}")
    }

    /** Selected ids in chronological (ascending id) order, like iOS forwardMessages(messages.sorted). */
    private func selectedMessageIdsSorted(): ArrayList<Int64> {
        let selIds = ArrayList<Int64>()
        for ((id, _v) in this.selectedMessageIds) { selIds.add(id) }
        var i: Int64 = 1
        while (i < selIds.size) {
            let v = selIds[i]
            var j: Int64 = i - 1
            while (j >= 0 && selIds[j] > v) {
                selIds[j + 1] = selIds[j]
                j -= 1
            }
            selIds[j + 1] = v
            i += 1
        }
        return selIds
    }

    private func findDisplayedMessage(messageId: Int64): Option<Message> {
        for (entry in this.displayMessages) {
            if (entry.message.id == messageId) { return Some(entry.message) }
            for (grouped in entry.groupedMessages) {
                if (grouped.id == messageId) { return Some(grouped) }
            }
        }
        return None
    }

    private func registerEmojiInteractionUpdates(): Unit {
        if (this._emojiInteractionSubscriptionToken >= 0) { return }
        this._emojiInteractionSubscriptionToken = getUpdatesManager().addEmojiInteractionSubscriber({
            _userId: Int64, emoji: String, messageId: Int64, interactionJson: String =>
            let root = JsonParser.parseObject(interactionJson)
            if (root.getInt("v") != 1) { return }
            let animations = root.getArray("a")
            if (animations.size() == 0 || animations.size() > 7) { return }
            for (animation in animations.getObjects()) {
                let index = animation.getInt("i")
                let delayMs = Int64(animation.getFloat("t") * 1000.0)
                let _ = spawn {
                    if (delayMs > 0) { sleep(Duration.millisecond * delayMs) }
                    launch {
                        match (this.findDisplayedMessage(messageId)) {
                            case Some(message) => this.presentEmojiInteraction(
                                message,
                                emoji,
                                requestedIndex: index,
                                shouldSend: false
                            )
                            case None => Hilog.info(0, "CjTelegram", "[EmojiInteraction] remote message not visible msgId=${messageId}")
                        }
                    }
                }
            }
            let _ = spawn { getChatTitleActivityService().sendEmojiInteractionSeen(emoji) }
        })
    }

    private func registerUserStatusUpdates(): Unit {
        if (this._userStatusSubscriptionToken >= 0) { return }
        this._userStatusSubscriptionToken = getUpdatesManager().addUserStatusSubscriber({
            userId: Int64, isOnline: Bool =>
            this.viewModel.onUserStatusUpdate(userId, isOnline)
            if (this.viewModel.peerType == "user" && userId == this.viewModel.chatId
                && !this.viewModel.isSavedMessagesChat()) {
                let text = if (isOnline) { "online" } else { "last seen recently" }
                launch { this.subtitleText = text }
            }
        })
    }

    private func presentEmojiInteraction(
        message: Message,
        emoji: String,
        requestedIndex!: Int64 = -1,
        shouldSend!: Bool = true
    ): Unit {
        let sourceId = "message_context_source_" + message.identityKey().toString()
        var sourceY = 0.0
        var sourceHeight = 112.0
        var screenWidth = this.messageContextScreenWidth
        try {
            let rectangle = ComponentUtils.getRectangleById(sourceId)
            let uiContext = this.getUIContext()
            sourceY = match (uiContext.px2vp(rectangle.windowOffset.y.px)) {
                case Some(value) => value.value
                case None => rectangle.windowOffset.y
            }
            sourceHeight = match (uiContext.px2vp(rectangle.size.height.px)) {
                case Some(value) => value.value
                case None => rectangle.size.height
            }
            screenWidth = match (uiContext.px2vp(rectangle.size.width.px)) {
                case Some(value) => value.value
                case None => rectangle.size.width
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[EmojiInteraction] geometry failed msgId=${message.id}: ${e}")
        }
        let effectY = sourceY + sourceHeight * 0.5 - 168.0
        let effectX = this.emojiEffectX(message.isSent, screenWidth)
        let previousIndex = this._previousEmojiEffectIndex
        let _ = spawn {
            let selection = if (requestedIndex >= 0) {
                prepareAnimatedEmojiEffectAtIndex(emoji, requestedIndex)
            } else {
                prepareAnimatedEmojiEffect(emoji, previousIndex)
            }
            if (selection.loaded) {
                launch {
                    this._emojiEffectToken += 1
                    this._previousEmojiEffectIndex = selection.index
                    let item = ChatEmojiEffectOverlayItem()
                    item.token = this._emojiEffectToken
                    item.documentId = selection.documentId
                    item.x = effectX
                    item.y = effectY
                    let next = ArrayList<ChatEmojiEffectOverlayItem>()
                    var start: Int64 = 0
                    if (this.emojiEffectItems.size >= 4) { start = this.emojiEffectItems.size - 3 }
                    for (i in start..this.emojiEffectItems.size) { next.add(this.emojiEffectItems[i]) }
                    next.add(item)
                    this.emojiEffectItems = next.toArray()
                    Hilog.info(0, "CjTelegram", "[EmojiInteraction] show effect msgId=${message.id} index=${selection.index} token=${item.token} frame=(${item.x},${item.y},336x336)")
                }
                // The local animation must not wait for an MTProto round trip.
                // Sending remains on this worker after the UI launch is queued.
                if (shouldSend) {
                    getChatTitleActivityService().sendEmojiInteraction(emoji, message.id, selection.index)
                }
            }
        }
    }

    /**
     * imgmenu 批次返修：长按菜单 Save Image / Save to Files。
     * 真实保存链路不变（SaveToCameraRollService.saveImageToGallery/saveVideoToGallery →
     * photoAccessHelper.showAssetsCreationDialog 系统确认弹窗 → 用户同意后写入系统相册，
     * 免 WRITE_IMAGEVIDEO 权限，见该服务文档注释）；本轮补齐 loading/结果反馈：
     * 未下载先出 "Downloading…"，保存结果回调（非 UI 线程，launch{} 包裹）出
     * "Saved to Gallery"（用户在系统弹窗点拒绝 = iOS 取消保存语义，静默清除，不按失败提示）。
     */
    private func saveMessageMedia(message: Message): Unit {
        if (message.photoId != 0) {
            // 保存始终用最大尺寸：仅当已缓存的就是最大 type 才直接存，否则下最大。
            // （气泡现缓存 "x"800px，若不判最大会存 800px 而非原图最大）
            let largestType = if (message.photoLargestType.size > 0) { message.photoLargestType } else { "y" }
            if (message.photoLocalPath.size > 0 && message.photoLocalPath.contains("_${largestType}.jpg")) {
                getSaveToCameraRollService().saveImageToGallery(message.photoLocalPath, { ok: Bool =>
                    this.onMediaSaveResult(ok)
                })
                return
            }
            this.showMediaToast("Downloading…", autoClear: false)
            spawn {
                let fullResUri = this.viewModel.downloadFullResPhoto(message)
                if (fullResUri.size > 0) {
                    launch {
                        message.photoLocalPath = fullResUri
                        getSaveToCameraRollService().saveImageToGallery(fullResUri, { ok: Bool =>
                            this.onMediaSaveResult(ok)
                        })
                    }
                } else {
                    launch { this.showMediaToast("Download failed", autoClear: true) }
                }
            }
            return
        }

        if (message.documentId == 0) { return }
        let saveDownloadedDocument = { =>
            let path = message.documentLocalPath
            if (path.size == 0) {
                this.showMediaToast("Download failed", autoClear: true)
                return
            }
            if (message.documentMimeType.startsWith("image/")) {
                getSaveToCameraRollService().saveImageToGallery(path, { ok: Bool =>
                    this.onMediaSaveResult(ok)
                })
            } else if (message.documentMimeType.startsWith("video/")) {
                getSaveToCameraRollService().saveVideoToGallery(path, { ok: Bool =>
                    this.onMediaSaveResult(ok, isVideo: true)
                })
            }
        }
        if (message.documentLocalPath.size > 0) {
            saveDownloadedDocument()
        } else {
            this.showMediaToast("Downloading…", autoClear: false)
            spawn {
                this.viewModel.downloadDocumentForMessage(message)
                launch { saveDownloadedDocument() }
            }
        }
    }

    /**
     * showAssetsCreationDialog 结果 → 吐司反馈。回调可能在非 UI 线程（S-001），
     * @State 写入经 showMediaToast 内部 launch{} 包裹。
     * ok=false 含"用户在系统确认弹窗点了拒绝"（iOS 取消语义）→ 静默清除 loading 吐司。
     */
    private func onMediaSaveResult(ok: Bool, isVideo!: Bool = false): Unit {
        if (ok) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] media saved to gallery (user confirmed) video=${isVideo}")
            // S3-10: iOS Gallery_ImageSaved / Gallery_VideoSaved undo overlay text; the .mediaSaved
            // UndoOverlayControllerNode stays for originalRemainingSeconds = 3 (UndoOverlayControllerNode.swift:1047ff).
            let savedText = if (isVideo) { "Video Saved" } else { "Image Saved" }
            launch { this.showMediaToast(savedText, autoClear: true, durationMs: 3000) }
        } else {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] media save declined or failed")
            launch { this.showMediaToast("", autoClear: false) }
        }
    }

    /**
     * imgmenu 批次："Copy Photo" 长按菜单动作。
     * D-tier 与 iOS 的差距：iOS UIPasteboard 收原始图片字节；本平台 UDMF PixelMap C-NDK
     * 符号无 KB 文档覆盖（见 SaveToCameraRollService.copyMediaFileUri 注释），复制标准化
     * file:// URI 纯文本进系统剪贴板。菜单项仅在 photoLocalPath 非空时展示（MessageBubble）。
     */
    private func copyMessagePhoto(message: Message): Unit {
        let path = if (message.photoLocalPath.size > 0) { message.photoLocalPath } else { message.documentLocalPath }
        if (path.size == 0) { return }
        if (getSaveToCameraRollService().copyMediaFileUri(path)) {
            this.showMediaToast("Photo copied", autoClear: true)
        } else {
            this.showMediaToast("Copy failed", autoClear: true)
        }
    }

    /**
     * 媒体操作吐司统一入口。text 空串 = 立即清除。autoClear=true 时 2 秒后自动清除
     * （版本号防旧计时器清掉新吐司）。必须在 UI 线程调用（非 UI 线程调用方自行 launch{} 包裹）。
     */
    private func showMediaToast(text: String, autoClear!: Bool, durationMs!: Int64 = 2000): Unit {
        this.mediaActionToast = text
        this.mediaToastVersion = this.mediaToastVersion + 1
        if (autoClear && text.size > 0) {
            let ver = this.mediaToastVersion
            spawn {
                sleep(Duration.millisecond * durationMs)
                launch {
                    if (this.mediaToastVersion == ver) {
                        this.mediaActionToast = ""
                    }
                }
            }
        }
    }

    /**
     * 批 3：消息列表改为**推送驱动**，删除原 500ms 指纹轮询。
     *
     * 原实现每 500ms 拉一次 viewModel.messageList，用
     *   count + lastId + photoCount + docCount + reactionKey + statusKey
     * 六项指纹判断"数据是否变了"。两个问题：
     *   1. 结构性漏刷新 —— 指纹**不含 content**，对方编辑消息后本端六项全不变，
     *      displayMessages 永不重建；必须上下滑动触发分页让 count 变化才显现。实测复现。
     *   2. 每 500ms 对全量消息拼 statusKey / reactionKey 字符串，O(n) 常驻开销。
     *
     * 改为订阅 MessageHistoryView 的变更推送（经 ChatRoomViewModel 转发）：
     * 容器一变就回调，不需要枚举"哪些字段算变化"，也就不存在漏字段的失效模式。
     * 对齐 iOS：ViewTracker 在每次 transaction 提交后 pipe.putNext 给订阅方
     * （ViewTracker.swift:235/330），UI 从不轮询消息。
     *
     * 仍保留一个低频循环，只做**不经 MessageHistoryView** 的两项同步：
     * 会话标题与头像 URL。它们不属于消息容器，且比对成本是两次字符串比较，
     * 与原先的 O(n) 指纹不可同日而语。
     */
    private func startMessageSync() {
        // 订阅推送。所有会改变列表呈现的路径都已有明确推送点：
        //   · 增删改消息      -> history.insert / remove / insertMany
        //   · 原地改字段      -> refreshMessageSnapshot()（下载回填、已读回执、失败标记、reaction 头像）
        this._lastRenderKey = ""
        this.viewModel.setMessagesChangedHandler({ => this.rebuildDisplayMessages() })
        // 首帧：订阅只覆盖"之后"的变更，进入页面时容器里可能已有内容（本地缓存秒开）。
        this.rebuildDisplayMessages()
        this._syncGeneration += 1
        let generation = this._syncGeneration

        // 兜底循环：标题 / 头像的常规更新已在 rebuildDisplayMessages 内与消息渲染同帧完成；
        // 此处只覆盖「长时间没有任何消息变更、但头像下载完成或群名被改」的场景。
        // 成本为两次字符串比较，与改造前每 500ms 对全量消息拼 statusKey/reactionKey 的
        // O(n) 指纹不可同日而语。
        spawn {
            while (this._syncActive && generation == this._syncGeneration) {
                sleep(Duration.millisecond * 2000)
                if (!this._syncActive || generation != this._syncGeneration) { break }
                let vmName = this.viewModel.chatName
                let latestAvatarUrl = if (getSelectedChatPeerType() == "chat" || getSelectedChatPeerType() == "channel") {
                    getUserPhotoService().getChatPhotoPath(getSelectedChatId())
                } else {
                    getUserPhotoService().getUserPhotoPath(this.avatarPeerId())
                }
                if (vmName.size > 0 && vmName != this.chatName) {
                    launch { this.chatName = vmName }
                }
                if (latestAvatarUrl.size > 0 && latestAvatarUrl != this.chatAvatarUrl) {
                    launch { this.chatAvatarUrl = latestAvatarUrl }
                }
            }
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] Title/avatar fallback sync stopped")
        }
    }

    /**
     * P2-398: 外语检测（翻译条可见性）。canTranslateChatText 每条都跑 LangDetect + 支持语言 /
     * 忽略语言表比对并各打一行 hilog，放在后台线程；结果按代号回 UI 线程，旧一轮结果不覆盖新的。
     * 只取 (isSent, content) 快照，不把 Message 对象带到后台。
     */
    private func scheduleForeignLanguageDetection(messages: ArrayList<Message>): Unit {
        this._foreignDetectGeneration += 1
        let generation = this._foreignDetectGeneration
        let snapshot = ArrayList<(Bool, String)>()
        for (m in messages) { snapshot.add((m.isSent, m.content)) }
        let _ = spawn {
            var hasForeign = false
            let service = getTranslateService()
            for ((isSent, content) in snapshot) {
                if (!isSent && service.canTranslateChatText(content)) {
                    hasForeign = true
                    break
                }
            }
            let detected = hasForeign
            launch {
                if (generation != this._foreignDetectGeneration) { return }
                if (!this.chatTransEnabled) {
                    this.chatTransDetectedForeignLang = detected
                }
            }
        }
    }

    /**
     * 依据当前消息快照重建 displayMessages。
     *
     * 由推送回调驱动，运行在 UI 线程（ChatRoomViewModel.publishSnapshot 的 launch 内），
     * 故可直接写 @State，无需再包 launch。滚动需要延时，另起 spawn 等待后再回投。
     */
    private func rebuildDisplayMessages(): Unit {
        let currentMessages = this.viewModel.messageList
        let currentCount = currentMessages.size
        this.syncBotKeyboard(currentMessages)

        var currentLastId: Int64 = -1
        // 尾部身份：用 stableId 而非 id。发送成功时 id 会从本地计数器号换成服务端号，
        // 而 stableId 全程不变（MessageHistoryView 分配/继承），正是用来判定
        // 「这还是不是同一条消息」的。判据用途见下方滚动分支。
        var currentLastStableId: Int64 = -1
        if (currentCount > 0) {
            currentLastId = currentMessages[currentCount - 1].id
            currentLastStableId = currentMessages[currentCount - 1].identityKey()
        }

        computeMessageGroupPositions(currentMessages)
        // P2-112: 标注未读分隔线位置
        let firstUnreadMsgId = this.viewModel.firstUnreadId
        computeUnreadSeparator(currentMessages, firstUnreadMsgId, this.viewModel.unreadCountForAnchor)

        let newList = ArrayList<MessageEntry>()
        var displayIndex: Int64 = 0
        while (displayIndex < currentMessages.size) {
            let first = currentMessages[displayIndex]
            let grouped = ArrayList<Message>()
            grouped.add(first)
            var nextIndex = displayIndex + 1
            if (first.groupedId != 0) {
                while (nextIndex < currentMessages.size && currentMessages[nextIndex].groupedId == first.groupedId) {
                    grouped.add(currentMessages[nextIndex])
                    nextIndex += 1
                }
            }

            if (grouped.size > 1) {
                let last = grouped[grouped.size - 1]
                first.isLastInGroup = last.isLastInGroup
                first.isSingleMessage = first.isFirstInGroup && last.isLastInGroup
                first.isMiddleInGroup = false
                first.time = last.time
                first.views = last.views
            }
            let entry = MessageEntry(first, groupedMessages: grouped)
            if (this._searchHighlightQuery.size > 0 && this._searchHighlightIds.contains(first.id)) {
                entry.searchHighlight = this._searchHighlightQuery
            }
            newList.add(entry)
            displayIndex = nextIndex
        }

        // P2-398: 外语检测 → 翻译条可见性。见 scheduleForeignLanguageDetection：逐条 LangDetect
        // 此前在 UI 线程同步跑（每条一行 hilog），首屏 44 条也要先过一遍；现改后台线程、
        // 只在渲染产物变化时触发（下方 renderChanged 分支）。

        // 渲染层幂等：服务端整表刷新（10s 轮询、发送后 getHistory）每次都产出**全新**
        // Message 对象，事件驱动会如实推送；但若最终渲染产物一模一样，重建 displayMessages
        // 只会让 ForEach 全量重挂，视觉上就是"闪一下"（实测：发消息时闪）。
        //
        // 与被删掉的 500ms 指纹的本质区别：那是「猜哪些字段算变化」，漏了 content 就漏刷新；
        // 这里比的是**最终渲染产物** —— MessageEntry.toString() 含 id/content/status/isEdited/
        // 媒体路径/分组媒体/reactions/分组标志/未读分隔线，正是 ForEach 的 diff 依据，漏不了字段。
        //
        // 成本：O(n) 字符串拼接，但只在**收到推送时**发生；空闲期零开销。
        // 原先是无条件每 500ms 拼一次，与此不可同日而语。
        var renderKey = ""
        for (e in newList) {
            renderKey = renderKey + e.toString() + "|"
        }
        let renderChanged = renderKey != this._lastRenderKey

        // 标题 / 头像与 displayMessages 在**同一帧**落地。
        // 批 3 曾把它们拆到独立的 1s 循环，导致头像更新与消息渲染落在不同帧，
        // 表现为收到消息时头像"闪一下"。慢循环保留为兜底（见 startMessageSync），
        // 但常规路径由本处覆盖，恢复改造前的原子性。
        let vmName = this.viewModel.chatName
        if (vmName.size > 0 && vmName != this.chatName) {
            this.chatName = vmName
        }
        let latestAvatarUrl = if (getSelectedChatPeerType() == "chat" || getSelectedChatPeerType() == "channel") {
            getUserPhotoService().getChatPhotoPath(getSelectedChatId())
        } else {
            getUserPhotoService().getUserPhotoPath(this.avatarPeerId())
        }
        if (latestAvatarUrl.size > 0 && latestAvatarUrl != this.chatAvatarUrl) {
            this.chatAvatarUrl = latestAvatarUrl
        }
        if (renderChanged) {
            this._lastRenderKey = renderKey
            this.displayMessages = newList
            this.messageSource.setEntries(newList)
            chatOpenPerfMark("displayCommitted count=${newList.size}")
            this.warmLatestVoice(currentMessages)
            if (!this.chatTransEnabled) {
                this.scheduleForeignLanguageDetection(currentMessages)
            }

            // 对齐 iOS HoleReload 的 stationaryItemRange：旧消息头插与锚点恢复属于
            // 同一笔列表事务。ArkUI 没有向 Cangjie 暴露 maintainVisibleContentPosition，
            // 因而用 stableId 找到头插后的新索引，并用 -旧 visualY 保留像素偏移。
            // 这里不能 spawn/sleep；延迟到下一帧会先显示新列表头，再跳回锚点。
            if (this._olderAnchorPending && this._olderAnchorStableId >= 0) {
                var anchorIndex: Int64 = -1
                var ai: Int64 = 0
                while (ai < newList.size) {
                    if (newList[ai].message.identityKey() == this._olderAnchorStableId) {
                        anchorIndex = ai
                        break
                    }
                    ai += 1
                }
                if (anchorIndex >= 0) {
                    let anchorStableId = this._olderAnchorStableId
                    let anchorVisualY = this._olderAnchorVisualY
                    try {
                        this.listScroller.scrollToIndex(
                            Int32(anchorIndex),
                            smooth: false,
                            align: ScrollAlign.Start,
                            options: ScrollToIndexOptions(extraOffset: (-anchorVisualY).vp)
                        )
                        this._olderAnchorPending = false
                        this._olderAnchorStableId = -1
                        Hilog.info(0, "CjTelegram",
                            "[ChatRoomPage] HoleReload stationary anchor restored idx=${anchorIndex}, stableId=${anchorStableId}, visualY=${anchorVisualY}")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram",
                            "[ChatRoomPage] HoleReload stationary anchor restore failed: ${e}")
                    }
                }
            }
        }

        // 初次进入始终使用 upperBound（最新端）。List 的索引空间是 newList，
        // 不是原始 currentMessages：相册/消息组会把多条 Message 合并为一个
        // MessageEntry，因此目标必须使用实际渲染项数。
        let renderedCount = newList.size
        if (renderedCount > 0 && !this._initialScrollDone) {
            this._initialScrollDone = true
            let targetLast = Int32(renderedCount - 1)
            spawn {
                // 让 ForEach 完成本次数据提交后立即贴底；只跨一个渲染帧，
                // 不安排多个会与节点可见性竞争的重复滚动。
                sleep(Duration.millisecond * 16)
                launch {
                    chatOpenPerfMark("initialScrollIssued")
                    try {
                        this.listScroller.scrollToIndex(targetLast, smooth: false, align: ScrollAlign.End)
                    } catch (_e: Exception) {
                        try { this.listScroller.scrollEdge(Edge.Bottom) } catch (_e2: Exception) {}
                    }
                    this._initialScrollSettled = true
                    this.showScrollToLatestButton = false
                    // LazyForEach 在本次跳转时只按估算高度布局了末项之上的条目，
                    // 末项自身的媒体/链接预览也常在之后才定高：钉住最新端，
                    // 下一帧再贴一次底，此后由尺寸变化回调维持。
                    this._pinnedToLatest = true
                    this.requestRepinToLatest()
                }
            }
        } else if (currentLastStableId != this._lastRenderedStableId) {
            // **尾部**来了新消息 → 滚到底部。
            //
            // 判据演进（两次都因为判错「什么算新消息」而出问题）：
            //   ① 最初「最后一条 id 变了」：发送成功时 history.update 把本地计数器 id 换成
            //      服务端 id（实测 101→504），id 变了但那还是同一条消息，于是在 insert 后
            //      96ms 又排一次滚动 —— 两次带动画滚动挤在 100ms 内，就是肉眼看到的"闪"。
            //   ② 改「消息数量增加了」：治好了闪，却**分不清消息加在头部还是尾部**。
            //      往上翻历史时 onReachStart → loadMoreHistory → history.prependAll 在
            //      **头部**插入 20 条，count 同样增加 → 判据命中 → 列表被拽回底部。
            //      表现为「往上滑几页后自动跳回最下面」。
            //   ③ 现判据「最后一条的 stableId 变了」：stableId 由 MessageHistoryView 分配、
            //      本地转云端时继承，**只有尾部真的换了一条消息才会变**。
            //        · 发送 sending→sent 换号 → stableId 不变 → 不滚（治好①的闪）
            //        · 收到新消息追加到尾部 → stableId 变 → 滚
            //        · prependAll 加载更早历史 → 尾部没动 → 不滚（治好②的跳）
            //
            // 对齐 iOS：Message.stableId（Postbox/Sources/Message.swift:689）是独立于
            //   MessageId 的身份，本地转云端由 updateMessage 沿用旧值
            //   （MessageHistoryTable.swift:1831）。
            //   更根本的是 iOS **从不从「数量变化」反推该不该滚** —— 滚动位置是每次
            //   history 更新的显式属性（ChatHistoryViewUpdate.HistoryView 的
            //   `scrollPosition: ChatHistoryViewScrollPosition?`，ChatHistoryListNode.swift:78）：
            //   加载更早历史时传 nil、靠 stationaryItemRange 保持锚点，只有新消息才带滚动意图。
            //   仓颉侧没有这条通道，用 stableId 判定尾部身份是最接近的等价物。
            // ★ 只在用户**本来就在底部**时才自动滚过去。
            //
            // 对齐 iOS：ChatHistoryListNode 判 `historyView.originalView.laterId == nil`
            // （已在最新端）**且**列表处于底部位置才跟随新消息；否则不动列表，由
            // ChatController 显示带未读计数的「回到底部」按钮，把是否跳转交给用户。
            //
            // 注意 hasMoreNewer 挡不住这件事：它只表示「服务端没有更新的消息待加载」，
            // 不表示「用户此刻停在底部」。用户翻到中间时 hasMoreNewer 仍为 false，
            // 旧实现会把他一把拽回底部 —— 正在读历史时尤其突兀。
            //
            // _lastVisibleIndex 是 displayMessages（即 newList）的索引；不能拿它与
            // currentMessages.size 比较，否则只要历史里有相册/消息组，就会把实际位于
            // 底部的用户误判为离开底部。
            // 它是**新消息插入前**记录的可见尾部索引，此时 renderedCount 已含新项，
            // 故「在底部」的判据是 >= renderedCount - 2（留一格容差）。
            // -1 表示尚未产生过滚动事件（首屏），按在底部处理。
            let atBottom = this._lastVisibleIndex < 0 || this._lastVisibleIndex >= renderedCount - 2
            // **自己发的消息必须跟随**，与是否在底部无关 —— 否则在翻历史时发一条，
            // 列表不动，用户看不到自己刚发出去的内容。iOS 同样对 outgoing 强制滚动。
            let isOwnMessage = currentMessages[currentCount - 1].isSent
            let shouldFollow = atBottom || isOwnMessage || this._pinnedToLatest
            if (!this.viewModel.hasMoreNewer && !shouldFollow) {
                // 别人发来 + 用户不在底部：不动列表，只累计提示计数
                launch { this.pendingNewCount = this.pendingNewCount + 1 }
            }
            if (!this.viewModel.hasMoreNewer && shouldFollow) {
                let targetLast = Int32(renderedCount - 1)
                spawn {
                    sleep(Duration.millisecond * 100)
                    launch {
                        // 用 scrollToIndex(smooth: false) 而非 scrollEdge：
                        // SDK 原文 —— scrollToIndex 的 smooth「If false, scroll to index item
                        // **without animation**. The default value is false.」；
                        // 而 scrollEdge(value: Edge) 没有任何关闭动画的开关，其配套的
                        // ScrollEdgeOptions 只有 velocity（scroll.cj.d:490），即它本就是动画滚动。
                        // 新消息到底部时的那段动画正是残留「闪」的可查证来源之一。
                        try {
                            this.listScroller.scrollToIndex(targetLast, smooth: false, align: ScrollAlign.End)
                        } catch (_e: Exception) {
                            try { this.listScroller.scrollEdge(Edge.Bottom) } catch (_e2: Exception) {}
                        }
                        // 新气泡（发送中→已发送、链接预览、图片尺寸）还会继续长高，
                        // 钉住最新端直到用户自己拖离底部。
                        this._pinnedToLatest = true
                        this.requestRepinToLatest()
                    }
                }
            }
        }
        this._lastRenderedId = currentLastId
        this._lastRenderedStableId = currentLastStableId
    }

    /**
     * iOS ChatHistoryListNode.processDisplayedItemRangeChanged 的历史预取阈值：
     * 普通消息在距边界 5 个 item 时预取；边界附近存在消息组时收紧到 1 个 item。
     */
    private func olderHistoryPrefetchThreshold(): Int64 {
        var inspectCount: Int64 = this.displayMessages.size
        if (inspectCount > 5) { inspectCount = 5 }
        var index: Int64 = 0
        while (index < inspectCount) {
            if (this.displayMessages[index].groupedMessages.size > 1) {
                return if (this._historyScrollFast) { 6 } else { 1 }
            }
            index += 1
        }
        // 上翻已改为本地优先（ChatRoomViewModel.loadMoreHistory 先查本地表），
        // 补一页的代价从「一次 MTProto RTT」降到「一次本地查询」，因此可以把预取
        // 提前更多、让用户永远撞不到边界：常速 12、快速手势 24。
        // iOS 之所以只要 5，是因为它背后同样是本地 Postbox；口径现在一致了。
        return if (this._historyScrollFast) { 24 } else { 12 }
    }

    /**
     * 在用户抵达历史边界前预取下一页，并保存当前第一条可见消息的 stationary 锚点。
     * reachedBoundary 只控制慢网兜底提示；正常预取不显示 loading。
     */
    private func preloadOlderHistory(firstVisibleIndex: Int64, reachedBoundary: Bool): Unit {
        if (!this._initialScrollSettled || !this.viewModel.hasMoreHistory) { return }

        // 闸门用「本地翻页是否在跑」，不再用 isLoading —— 后者覆盖整个网络往返，
        // 会把已经能从本地供上的下一页一起挡住（表现为撞到顶部干等）。
        if (this.viewModel.isPagingLocal) {
            if (reachedBoundary) { this.isLoadingOlderUI = true }
            return
        }
        if (firstVisibleIndex < 0 || firstVisibleIndex > this.olderHistoryPrefetchThreshold()) { return }

        var anchorStableId: Int64 = -1
        var anchorVisualY: Float64 = 0.0
        if (firstVisibleIndex < this.displayMessages.size) {
            anchorStableId = this.displayMessages[firstVisibleIndex].message.identityKey()
            try {
                let anchorRect = this.listScroller.getItemRect(Int32(firstVisibleIndex))
                if (anchorRect.y.isSome()) {
                    anchorVisualY = anchorRect.y.getOrThrow()
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram",
                    "[ChatRoomPage] Read older-history prefetch anchor rect failed: ${e}")
            }
        }

        this._olderAnchorStableId = anchorStableId
        this._olderAnchorVisualY = anchorVisualY
        this._olderAnchorPending = anchorStableId >= 0
        this.isLoadingOlderUI = reachedBoundary
        Hilog.info(0, "CjTelegram",
            "[ChatRoomPage] HoleReload prefetch anchor captured idx=${firstVisibleIndex}, stableId=${anchorStableId}, visualY=${anchorVisualY}, boundary=${reachedBoundary}")
        this.viewModel.loadMoreHistory()

        spawn {
            var waitCount: Int64 = 0
            while (this.viewModel.isLoading && waitCount < 100) {
                sleep(Duration.millisecond * 100)
                waitCount += 1
            }
            launch { this.isLoadingOlderUI = false }
        }
    }
    
    private func rootWallpaperUri(): String {
        var path = getChatBgDisplayPath()
        if (this.chatWallpaperInfo.wallpaperType == WallpaperType.CustomImage && this.chatWallpaperInfo.imageUri.size > 0) {
            path = this.chatWallpaperInfo.imageUri
        }
        if (path.startsWith("file://")) { return path }
        if (path.size > 0) { return "file://${path}" }
        return ""
    }

    // F-P3 · 字号按比例从 presentation.chatFontSize 派生（对位 ChatListItem.swift:2294-2297
    // floor(base * n/17)，基数固定 17；同一形态的既有先例见 components/ChatListItem.cj:103
    // scaledFontSize()，那份用 listsFontSize，这里改用 chatFontSize——两个快照字段语义不同，
    // 不得混用）。返回 Float64 而非 Int64：`.fontSize()` 形参是 `?Length`，字面量整数能直接传入
    // 是本 SDK 对字面量的隐式类型推断特例（S-006），已定型的整数表达式不享有这条便利，
    // Float64 通过 `extend Float64 <: Length` 满足接口。
    private func scaledFontSize(numerator: Int64): Float64 {
        let scaled = Int64(Float64(this.presentation.chatFontSize) * Float64(numerator) / 17.0)
        return Float64(scaled)
    }

    // F-P3 · D-125 刷新探针：MessageBubble(:1961) 的四个主题入参必须是本文件自己的裸 @State
    // 字段（不能是 this.presentation.xxx 嵌套访问），零高度探针范式抄
    // pages/AppearanceSettingsPage.cj:419-423 refreshRightValueMirrors() / :723。
    /**
     * 会话壁纸层（iOS WallpaperBackgroundNode）。入参逐项走裸 @State 镜像字段（D-125/D-156），
     * 按 wpPatternOverlayMirror 分两个分支（S7-107），外层再由 wpMountToggle 包一层重挂载守卫（S6-05）。
     */
    @Builder
    func chatWallpaperLayer() {
        if (this.wpPatternOverlayMirror) {
            WallpaperBackgroundComponent(
                wallpaperType: this.wpTypeMirror,
                solidColor: this.wpSolidColorMirror,
                gradientColorStart: this.wpGradientColorStartMirror,
                gradientColorEnd: this.wpGradientColorEndMirror,
                gradientAngle: this.wpGradientAngleMirror,
                imageUri: this.wpImageUriMirror,
                fallbackColor: 0xFFE8E6DF,
                gradientColors: this.wpGradientColorsMirror,
                phase: this.wpPhaseMirror,
                patternColor: this.wpPatternColorMirror,
                patternIntensity: this.wpPatternIntensityMirror,
                dimmingIntensity: this.wpDimmingIntensityMirror,
                isDarkMode: this.wpIsDarkModeMirror,
                imageDisplayMode: this.wpImageDisplayModeMirror,
                imageBlurEnabled: this.wpImageBlurEnabledMirror,
                imageBlurStrength: this.wpImageBlurStrengthMirror,
                patternFile: this.wpPatternFileMirror,
                patternOverlayEnabled: true
            )
        } else {
            WallpaperBackgroundComponent(
                wallpaperType: this.wpTypeMirror,
                solidColor: this.wpSolidColorMirror,
                gradientColorStart: this.wpGradientColorStartMirror,
                gradientColorEnd: this.wpGradientColorEndMirror,
                gradientAngle: this.wpGradientAngleMirror,
                imageUri: this.wpImageUriMirror,
                fallbackColor: 0xFFE8E6DF,
                gradientColors: this.wpGradientColorsMirror,
                phase: this.wpPhaseMirror,
                patternColor: this.wpPatternColorMirror,
                patternIntensity: this.wpPatternIntensityMirror,
                dimmingIntensity: this.wpDimmingIntensityMirror,
                isDarkMode: this.wpIsDarkModeMirror,
                imageDisplayMode: this.wpImageDisplayModeMirror,
                imageBlurEnabled: this.wpImageBlurEnabledMirror,
                imageBlurStrength: this.wpImageBlurStrengthMirror,
                patternFile: this.wpPatternFileMirror,
                patternOverlayEnabled: false
            )
        }
    }

    private func refreshBubbleColorMirrors(): String {
        // [ChatOpenPerf] 本探针是 build() 的第一个节点：首次进入即首次构建开始。
        if (!this._perfFirstBuildMarked) {
            this._perfFirstBuildMarked = true
            chatOpenPerfMark("firstBuild")
        }
        // PresentationData on iOS publishes a new effective wallpaper together with the
        // auto-night presentation. Mirror that coupling here: a live light/dark transition must
        // not leave the already-mounted conversation on the previous wallpaper.
        if (this.wpPresentationDarkMirror != this.presentation.isDark) {
            this.wpPresentationDarkMirror = this.presentation.isDark
            this.reloadChatWallpaper()
            this.setChatSystemBars()
        }
        let nextOutColor = this.presentation.bubbleOutColor
        let nextInColor = this.presentation.bubbleInColor
        let nextTextColor = this.presentation.textColor
        let nextStrokeColor = this.presentation.bubbleStrokeColor
        // 只在镜像真的变了时才翻转守卫 toggle。无条件翻转会让每次 build() 都销毁重建
        // 整屏气泡；不翻转则已挂载实例永远拿不到新色。相等时不写 @State，本探针在
        // build() 期间运行，避免自触发的额外一轮渲染。
        if (this.msgBubbleOutColorMirror != nextOutColor ||
            this.msgBubbleInColorMirror != nextInColor ||
            this.msgBubbleOutTextColorMirror != nextTextColor ||
            this.msgBubbleInTextColorMirror != nextTextColor ||
            this.msgBubbleStrokeColorMirror != nextStrokeColor) {
            this.msgBubbleOutColorMirror = nextOutColor
            this.msgBubbleInColorMirror = nextInColor
            this.msgBubbleOutTextColorMirror = nextTextColor
            this.msgBubbleInTextColorMirror = nextTextColor
            this.msgBubbleStrokeColorMirror = nextStrokeColor
            this.msgBubbleMountToggle = !this.msgBubbleMountToggle
        }
        // F-1（RC-W3）：WallpaperBackgroundComponent(:1878) 的镜像，同一探针内无条件刷新——
        // 不需要变化守卫，因为该组件没有挂载守卫、每次随 chatWallpaperInfo 整体重赋值一起
        // 重新构造（见字段声明处的注释）；这里只需保证组件下一次构造时镜像已是最新值。
        this.wpTypeMirror = this.chatWallpaperInfo.wallpaperType
        this.wpSolidColorMirror = this.chatWallpaperInfo.solidColor
        this.wpGradientColorsMirror = this.chatWallpaperInfo.gradientColors
        this.wpGradientColorStartMirror = this.chatWallpaperInfo.gradientColorStart
        this.wpGradientColorEndMirror = this.chatWallpaperInfo.gradientColorEnd
        this.wpGradientAngleMirror = this.chatWallpaperInfo.gradientAngle
        this.wpPhaseMirror = this.chatWallpaperInfo.phase
        // rootWallpaperUri() 保留给真正的 CustomImage 用（F-1 边界条件）：它在 CustomImage 分支
        // 里返回 chatWallpaperInfo.imageUri 并做 file:// 归一化，其余类型分支返回的默认底图路径
        // 对组件无意义——WallpaperBackgroundComponent 按 wallpaperType 选分支，非 CustomImage
        // 分支根本不读 imageUri（见组件 :403 isCustomImage() 判断），所以这里可以安全复用同一
        // 函数而不会让非图片壁纸又被默认底图顶替。
        this.wpImageUriMirror = this.rootWallpaperUri()
        this.wpImageDisplayModeMirror = this.chatWallpaperInfo.imageDisplayMode
        this.wpImageBlurEnabledMirror = this.chatWallpaperInfo.imageBlurEnabled
        this.wpImageBlurStrengthMirror = this.chatWallpaperInfo.imageBlurStrength
        this.wpDimmingIntensityMirror = this.chatWallpaperInfo.dimmingIntensity
        this.wpPatternColorMirror = this.chatWallpaperInfo.patternColor
        this.wpPatternIntensityMirror = this.chatWallpaperInfo.patternIntensity
        this.wpIsDarkModeMirror = this.chatWallpaperInfo.isDarkMode
        // F-3（RC-3）：同一批无条件赋值，紧随其余 wp* 镜像之后，形状同型。
        this.wpPatternFileMirror = this.chatWallpaperInfo.patternFile
        this.wpPatternOverlayMirror = this.chatWallpaperInfo.patternOverlayEnabled
        return ""
    }

    /** 打开应用内位置页（pages/LocationViewPage.cj + ets/pages/LocationViewPage.ets）。 */
    private func openLocationView(m: Message, lat: Float64, lng: Float64, title: String): Unit {
        let obj = JsonObject()
        obj.setString("peerType", this.viewModel.peerType)
        obj.setInt("peerId", this.viewModel.chatId)
        obj.setInt("msgId", m.id)
        obj.setString("lat", lat.toString())
        obj.setString("lng", lng.toString())
        obj.setBool("isLive", m.isLiveLocation)
        obj.setInt("period", Int64(m.liveLocationPeriod))
        obj.setInt("timestamp", m.rawTimestamp)
        obj.setInt("editDate", m.editDate)
        obj.setBool("isSent", m.isSent)
        obj.setInt("senderId", m.senderId)
        obj.setString("senderName", m.senderName)
        obj.setString("title", title)
        obj.setString("venueTitle", m.venueTitle)
        obj.setString("venueAddress", m.venueAddress)
        // routerPush(route) 单参版本会 setPending(route, "{}") 覆盖参数，必须用双参版本一次传入。
        routerPush("LocationViewPage", obj.toJsonString())
    }

    // D-160 重挂载守卫的被守卫体：把 MessageBubble(...) 抽成 @Builder，避免两个分支
    // 各维护一份同样的具名参数表（对象型入参的 @Builder 先例：
    // components/StickerKeyboardPanel.cj:283 buildPackTab(pack: StickerPackInfo, idx: Int64)、
    // components/GifPanel.cj:263 buildGifCell(g: GifItem)，均已编译通过）。
    @Builder
    private func buildMessageBubbleInstance(entry: MessageEntry) {
        MessageBubble(
            message: entry.message,
            voicePlaybackEpoch: this.voicePlaybackEpoch,
            groupedMessages: entry.groupedMessages,
            // F-P3: theme-derived bubble colours (D-125 bare-@State
            // mirrors, refreshed once per build() — see
            // refreshBubbleColorMirrors()). Component-side fields stay
            // @State (F-2b keeps them so, because two of the four call
            // sites are outside every allowlist and @Prop has no default
            // in this SDK), so a mounted instance is never re-fed; the
            // caller-side remount guard at the call site is what makes a
            // theme change land. Both halves are required.
            bubbleOutColor: this.msgBubbleOutColorMirror,
            bubbleInColor: this.msgBubbleInColorMirror,
            bubbleStrokeColor: this.msgBubbleStrokeColorMirror,
            bubbleOutTextColor: this.msgBubbleOutTextColorMirror,
            bubbleInTextColor: this.msgBubbleInTextColorMirror,
            // F-2b 同批的调用点半边：MessageBubble 的这六个主题
            // 入参改 @Prop 后本 SDK 不支持默认值，四个调用点必须
            // 全部显式传值。本屏没有 per-peer name color 来源
            // （AppearanceSettingsPage 才有 nameColorHex()），故后两个
            // 传组件侧当前默认字面量，行为逐像素不变。
            replyAuthorAccentColor: 0x317AFF,
            bubbleOutAccentTextColor: 0x00A700,
            // Keep the source node mounted and visible beneath the
            // page blur. Hiding it couples list-node opacity to the
            // reaction refresh/reuse cycle and can make the message
            // stay invisible after selecting an emoji.
            contextPreviewHidden: false,
            // Selection mode owns row gestures; disable the
            // message context menu until selection ends.
            isMultiSelectMode: this.isMultiSelectMode,
            // S3-16: in selection mode the bubble row itself reports the tap
            // (iOS ChatMessageItemView selection: tap anywhere on the row toggles it).
            onSelectionTap: { msg: Message => this.toggleMessageSelection(msg.id) },
            // 回合前恢复 main 能力（R-2）：群/频道消息的发送者名头部、左侧 34pt
            // 头像列、频道帖浏览数均由组件侧 isGroupOrChannel() 门控（MessageBubble.cj:468）。
            // 本调用点此前不传 ⇒ 组件默认 "user"，群与频道消息全部按 1v1 渲染。
            // 对位 origin/main:ChatRoomPage.cj:2027，写法同本文件 :4161/:4213。
            peerType: this.viewModel.peerType,
            // S4-12: in-chat search query painted inside this bubble (empty = none).
            searchHighlightText: entry.searchHighlight,
            // 回合前恢复 main 能力（R-3）：点击 GIF 气泡触发下载并播放。组件侧声明
            // （MessageBubble.cj:131）与调用（:1397）都在，此前本调用点未传 ⇒ 默认空
            // 闭包，点 GIF 无反应。逐字对位 origin/main:ChatRoomPage.cj:2083-2089。
            onGifTap: { msg: Message =>
                if (!this.isMultiSelectMode) {
                    let _ = spawn {
                        this.viewModel.downloadDocumentForMessage(msg)
                    }
                }
            },
            // P2-397/P2-400: 内联翻译状态（per-message prop 注入）
            showTranslation: this.bubbleTranslateShow.contains(entry.message.id) && this.bubbleTranslateShow[entry.message.id],
            translatedText: if (this.bubbleTranslateTexts.contains(entry.message.id)) { this.bubbleTranslateTexts[entry.message.id] } else { "" },
            isTranslating: this.bubbleTranslateLoading.contains(entry.message.id) && this.bubbleTranslateLoading[entry.message.id],
            translateError: this.bubbleTranslateError.contains(entry.message.id) && this.bubbleTranslateError[entry.message.id],
            showOriginal: this.bubbleShowOriginal.contains(entry.message.id) && this.bubbleShowOriginal[entry.message.id],
            translateToLangName: this.getTranslateLangName(),
            onShowOriginalToggle: { showOrig: Bool =>
                let msgId = entry.message.id
                var origMap = this.bubbleShowOriginal
                origMap[msgId] = showOrig
                this.bubbleShowOriginal = origMap
            },
            onReactionTap: { emoji: String =>
                if (!this.isMultiSelectMode) {
                    if (emoji.startsWith("custom|")) {
                        let parts = emoji.split("|")
                        if (parts.size >= 2) {
                            let documentId = try { Int64.parse(parts[1]) } catch (_: Exception) { 0 }
                            if (documentId != 0) {
                                let peerTypeCopy = this.viewModel.peerType
                                let peerIdCopy = this.viewModel.chatId
                                let messageIdCopy = entry.message.id
                                let _ = spawn {
                                    let success = getReactionSelectionService().sendCustomEmojiReaction(
                                        peerTypeCopy, peerIdCopy, Int32(messageIdCopy), documentId
                                    )
                                    if (success) { this.viewModel.loadMessages() }
                                }
                            }
                        }
                    } else {
                        this.viewModel.toggleReaction(entry.message.id, emoji)
                    }
                }
            },
            onReactionCountTap: { msgId: Int64 =>
                if (!this.isMultiSelectMode) {
                    this.reactorListMsgId = msgId
                    this.viewModel.fetchReactorsList(msgId)
                    this.showReactorList = true
                }
            },
            onAnimatedEmojiTap: { msg: Message, emoji: String =>
                Hilog.info(0, "CjTelegram", "[EmojiInteraction] page tap msgId=${msg.id} emoji=${emoji}")
                this.presentEmojiInteraction(msg, emoji)
            },
            // S3-02: iOS doubleTap → sendDefaultReaction (ReactionSettings.quickReaction).
            onDoubleTap: { msg: Message =>
                if (!this.isMultiSelectMode && msg.id > 0 && msg.messageType != "service") {
                    let quick = getTelegramCoreSettingsService().getQuickReaction()
                    Hilog.info(0, "CjTelegram", "[QuickReaction] double tap msgId=${msg.id} → ${quick}")
                    this.viewModel.toggleReaction(msg.id, quick)
                }
            },
            onLongPress: {
                sourceY: Float64,
                sourceHeight: Float64 =>
                // Context-menu callbacks are disabled together with MessageBubble
                // while multi-select mode owns the row gesture.
                this.presentReactionOverlay(
                    entry.message,
                    sourceY,
                    sourceHeight
                )
            },
            // iOS ChatMessageBubbleItemNode.swipeToReplyGesture → setupReply.
            swipeToReplyEnabled: !this.channelJoinRequiredMirror && !this.viewModel.isRestrictedSendMsg,
            onReply: { =>
                if (!this.isMultiSelectMode) {
                    this.viewModel.setReplyTo(entry.message.id, entry.message.content, entry.message.senderName)
                }
            },
            onImageTap: { msg: Message =>
                if (!this.isMultiSelectMode) {
                    if (msg.messageType == "photo" && msg.photoLocalPath.isEmpty() && msg.photoDownloadState != 0) {
                        // S7-93: auto-download suppressed → tap fetches the photo on demand.
                        this.viewModel.downloadPhotoOnTap(msg)
                    } else {
                        this.openImageViewer(msg)
                    }
                }
            },
            onVideoTap: { msg: Message =>
                if (!this.isMultiSelectMode) {
                    this.openVideoPlayer(msg)
                }
            },
            onVoiceTap: { msg: Message =>
                if (!this.isMultiSelectMode) {
                    this.toggleVoicePlayback(msg)
                }
            },
            onFileTap: { msg: Message =>
                if (!this.isMultiSelectMode) {
                    this.downloadFile(msg)
                }
            },
            onInvoiceTap: { msg: Message =>
                if (!this.isMultiSelectMode) {
                    let peerId = this.viewModel.chatId
                    let accessHash = getRealMessageService().getAccessHashForUser(peerId)
                    let isChannel = if (this.viewModel.peerType == "channel") { "1" } else { "0" }
                    routerPush("BotPaymentsPage", "${peerId}:${accessHash}:${msg.id}:${isChannel}")
                }
            },
            onWebUrlTap: { url: String =>
                if (!this.isMultiSelectMode) {
                    if (url.startsWith("http://") || url.startsWith("https://")) {
                        this.openWebUrlExternal(url)
                    } else {
                        this.openWebUrl(url)
                    }
                }
            },
            onWebPreviewTap: { url: String =>
                if (!this.isMultiSelectMode) {
                    this.openWebUrlExternal(url)
                }
            },
            // P2-183: 位置气泡点击 → 应用内 LocationDetailPage（替代外部 Google Maps 网页）
            onLocationTap: { lat: Float64, lng: Float64, title: String =>
                if (!this.isMultiSelectMode) {
                    // iOS openChatMessage(.map) → LocationViewController（应用内地图页，ArkTS 整页）。
                    this.openLocationView(entry.message, lat, lng, title)
                }
            },
            onVoteTap: { msgId: Int64, optIdx: Int64 =>
                if (!this.isMultiSelectMode) {
                    this.viewModel.sendVote(msgId, optIdx)
                }
            },
            onReplyTap: { replyMsgId: Int64 =>
                if (!this.isMultiSelectMode) {
                    this.jumpToReplyMessage(replyMsgId)
                }
            },
            // P2-395: 壁纸 flag + 渐变色（供 P2-396 气泡几何渐变填充）
            withWallpaper: this.chatWallpaperInfo.wallpaperType == WallpaperType.MultiColorGradient || this.chatWallpaperInfo.wallpaperType == WallpaperType.TwoColorGradient || this.chatWallpaperInfo.wallpaperType == WallpaperType.PatternWallpaper,
            wallpaperGradientColors: this.chatWallpaperInfo.gradientColors
        )
    }

    public func build() {
            Stack {
                // D-125 refresh probe: zero-height, invisible, runs refreshBubbleColorMirrors()
                // once per build() pass so the bare @State mirrors below are current before
                // MessageBubble(:1961) reads them.
                Text(this.refreshBubbleColorMirrors()).height(0).fontSize(0)
                // F-1（RC-W3）：会话页壁纸层此前只有一个裸 Image，rootWallpaperUri() 只在
                // CustomImage 类型时才切换到用户选的图，其余三类（纯色/双色渐变/多色渐变）与
                // 图案壁纸一律回落到 getChatBgDisplayPath() 落盘的默认底图，四类壁纸里三类在
                // 会话页零反应。换成 components/WallpaperBackgroundComponent（该组件文件不在
                // 本 feature allowlist，只调用不修改），调用形态照
                // pages/AppearanceSettingsPage.cj:1056-1067 已落地的同型调用点，入参逐项走
                // 上面声明的裸 @State 镜像字段（D-125/D-156）。CustomImage 分支在组件内部同样
                // 存在（imageUri 走 wpImageUriMirror），本轮已 PASS 的图片路径不受影响。
                // 不在调用点链式 .width()/.height()/.backgroundColor()：这三者组件内部
                // build() 根节点已经自带（components/WallpaperBackgroundComponent.cj:401-421，
                // 100.percent/100.percent + CustomImage 空 URI 时的 fallbackColor 兜底），且
                // AppearanceSettingsPage.cj:1056-1067 的同型调用点同样不链式修饰符——链式修饰符
                // 会让宏把整个表达式解到组件框架内部 27 参数（含 6 个 @State canvas 字段 +
                // LocalStorage）的内部构造重载而非关键字构造，编译报
                // "expected 27 arguments, found 16"。
                // S7-107：patternOverlayEnabled 是组件的普通 var（非 @Prop），只在构造时生效；而本页
                // wpPatternOverlayMirror 在首帧之后才由 refreshBubbleColorMirrors() 填入，组件一直停在
                // 构造时的 false，图案层（iOS WallpaperBackgroundNode patternImageLayer）从不挂载。
                // 按镜像值分两个分支，值变化即重建组件，图案层随之挂上。
                // S6-05：外层按 wpMountToggle 分两枝，翻转即整层重建（见字段声明处注释）。
                if (this.wpMountToggle) {
                    this.chatWallpaperLayer()
                } else {
                    this.chatWallpaperLayer()
                }
                Column {
                    // iOS-style compact chat header. iOS ChatController.swift:6336
                    // chatTitleView.tapAction → .openChatInfo(expandAvatar: false)：点标题进资料页；
                    // 头像按钮同样进资料页（expandAvatar: true）。搜索入口在资料页头部按钮。
                    Row {
                        Row {
                            Text("‹")
                                .fontSize(this.scaledFontSize(38))
                                .fontColor(0x317AFF)
                        }
                        .width(42)
                        .height(42)
                        .borderRadius(21)
                        // F-3/RC-C: 返回胶囊底接进本页 :84 那条已建成的快照通道。源侧
                        // ChatController.swift:6631 的整屏色板重算里，导航胶囊底走
                        // theme.rootController.navigationBar.*，不是字面量；快照的
                        // backgroundColor 浅色态就是 0xF2F2F7（core/storage/AppTheme.cj:536），
                        // 深色态 0x1C1C1E，故浅色态逐像素不变。
                        .backgroundColor(this.presentation.backgroundColor)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ _evt => routerPop() })

                        Blank().layoutWeight(1)
                        Row {
                            Column {
                                Row {
                                    if (this.viewModel.isSecretChatPeer()) {
                                        // S8-08：iOS ChatTitleView 秘密聊天标题前置锁图标（chatList.secretTitleColor）
                                        Image(@r(app.media.clist_ic_secretchat))
                                            .width(16)
                                            .height(16)
                                            .fillColor(0xFF00B12C)
                                            .margin(right: 3)
                                    }
                                    Text(this.chatName)
                                        .fontSize(this.scaledFontSize(16))
                                        .fontWeight(FontWeight.Bold)
                                        // F-3/RC-C: 会话标题接快照 textColor（浅色 0x000000）。
                                        .fontColor(this.presentation.textColor)
                                        .maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                    if (this.peerIsVerified || this.chatName == "Telegram") {
                                        Text("✓")
                                            .fontSize(this.scaledFontSize(10))
                                            .fontWeight(FontWeight.Bold)
                                            .fontColor(0xFFFFFF)
                                            .width(17)
                                            .height(17)
                                            .borderRadius(8.5)
                                            .backgroundColor(0x168ACD)
                                            .textAlign(TextAlign.Center)
                                            .margin(left: 5)
                                    } else if (this.channelMutedMirror) {
                                        // iOS ChatTitleView.swift:328-338：会话静音（且非认证标）时标题右侧
                                        // titleRightIcon = .mute（PresentationResourcesChat.chatTitleMuteIcon，
                                        // 取 navigationBar.controlColor 0x7e8791）。
                                        Image(@r(app.media.clist_ic_muted))
                                            .width(this.scaledFontSize(13))
                                            .height(this.scaledFontSize(13))
                                            .fillColor(0x7E8791)
                                            .margin(left: 3)
                                    }
                                }
                                .alignItems(VerticalAlign.Center)
                                if (this.chatName != "Telegram" && (this.chatTypingText.size > 0 || this.subtitleText.size > 0)) {
                                    Text(if (this.chatTypingText.size > 0) { this.chatTypingText } else { this.subtitleText })
                                        .fontSize(this.scaledFontSize(11))
                                        .fontColor(if (this.chatTypingText.size > 0) { 0x317AFF } else { 0x8E8E93 })
                                        .maxLines(1)
                                        .textOverflow(TextOverflow.Ellipsis)
                                }
                            }
                            .alignItems(HorizontalAlign.Center)
                        }
                        .constraintSize(maxWidth: 210)
                        .height(42)
                        .padding(left: 18, right: 18)
                        .borderRadius(21)
                        // F-3/RC-C: 标题胶囊底，同 :1662 的取值理由。
                        .backgroundColor(this.presentation.backgroundColor)
                        .justifyContent(FlexAlign.Center)
                        .onClick({ _evt => this.openCurrentPeerInfo() })

                        Blank().layoutWeight(1)
                        if (this.viewModel.isSavedMessagesChat() && this.savedHasChats) {
                            Stack {
                                Image(@r(app.media.media_ic_more))
                                    .width(24)
                                    .height(24)
                                    .fillColor(this.presentation.textColor)
                            }
                            .width(42)
                            .height(42)
                            .borderRadius(21)
                            .backgroundColor(this.presentation.backgroundColor)
                            .margin(right: 8)
                            .onClick({ _evt => this.showSavedModeMenu = true })
                        }
                        Row {
                            if (this.chatName == "Telegram") {
                                Image(@r(app.media.startIcon))
                                    .width(42)
                                    .height(42)
                                    .borderRadius(21)
                            } else if (this.viewModel.isSavedMessagesChat()) {
                                // iOS 自聊天导航栏头像为 Saved Messages 书签（AvatarNode savedMessagesIcon）
                                Avatar(
                                    displayName: this.chatName,
                                    avatarSize: 42,
                                    peerId: this.viewModel.chatId,
                                    specialPeer: AvatarSpecialPeer.SavedMessages
                                )
                            } else if (this.chatAvatarUrl.size > 0) {
                                Image(this.chatAvatarUrl)
                                    .width(42)
                                    .height(42)
                                    .borderRadius(21)
                                    .objectFit(ImageFit.Cover)
                            } else {
                                Text(if (this.chatName.size > 0) { String(this.chatName.toRuneArray()[0]).toAsciiUpper() } else { "?" })
                                    .fontSize(this.scaledFontSize(18))
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFFFF)
                                    .width(42)
                                    .height(42)
                                    .borderRadius(21)
                                    .backgroundColor(0xFF2A9EF1)
                                    .textAlign(TextAlign.Center)
                            }
                        }
                        .width(42)
                        .height(42)
                        // S2-02：导航栏头像 → 资料页头像直接展开（iOS expandAvatar: true）
                        .onClick({ _evt => this.openCurrentPeerInfo(expandAvatar: true) })
                    }
                    .width(100.percent)
                    .height(58)
                    .padding(left: 10, right: 10, top: 8, bottom: 8)
                    .alignItems(VerticalAlign.Center)
                    .backgroundColor(Color.Transparent)

                    // iOS ChatReportPeerTitlePanelNode：非联系人 / 自动归档会话的操作栏（高 40，按钮均分，右侧关闭）
                    if (!this.peerBarButtons.isEmpty() && !this.viewModel.hasBlockedPeer) {
                        this.peerActionBar()
                    }

                    // Phase P0-2: 使用 MessageSearch 组件替代内联搜索栏
                    if (this.showMessageSearch) {
                        MessageSearch(
                            onClose: { =>
                                this.showMessageSearch = false
                                this.setSearchHighlight("", ArrayList<Int64>())
                            },
                            onJumpToMessage: { msgId: Int64 =>
                                // S4-12: same path as a reply jump — centre the target, flash it
                                // (highlightedMessageId, iOS navigateToMessage highlightedState) and
                                // load around it when it is outside the current window.
                                this.jumpToReplyMessage(msgId)
                            },
                            onHighlightChange: { query: String, ids: ArrayList<Int64> =>
                                this.setSearchHighlight(query, ids)
                            },
                            onOpenCalendar: { =>
                                this.openCalendarFromSearch()
                            }
                        )
                    }

                    // 副标题（typing > presence）已在导航栏标题下渲染（见上方 chatTypingText/subtitleText Text），
                    // 原 `if (false && …)` 的重复副标题行已删除。

                    // ==================== P2-398: 整聊天翻译条 ====================
                    // iOS 对应 TranslateUI/ChatTranslation 顶部条
                    // 条件：检测到对方消息（chatTransDetectedForeignLang=true）或翻译已开启
                    // 状态机：
                    //   chatTransEnabled=false → 显示 "🌐 Translate to <lang>"（点击 → enableChatTranslation）
                    //   chatTransEnabled=true  → 显示 "📄 Show Original"（点击 → disableChatTranslation）
                    //   chatTransIsTranslating=true → 显示 "⏳ Translating..."（不可点击）
                    if (this.isPremiumAccount() && this.translationSettings.translateChats && (this.chatTransDetectedForeignLang || this.chatTransEnabled)) {
                        Row {
                            if (this.chatTransIsTranslating) {
                                Text("⏳ Translating...")
                                    .fontSize(this.scaledFontSize(14))
                                    .fontColor(0x8E8E93)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.Center)
                            } else if (this.chatTransEnabled) {
                                // 资源保真修复：真实矢量图标（Chat/Context Menu/Globe.imageset/globe (1).pdf 转 SVG）替代 emoji 字形
                                Row {
                                    Image(@r(app.media.chatroom_ic_translate))
                                        .width(14)
                                        .height(14)
                                        .fillColor(0x317AFF)
                                        .margin(right: 4)
                                    Text(trSource("Show Original"))
                                        .fontSize(this.scaledFontSize(14))
                                        .fontColor(0x317AFF)
                                }
                                    .layoutWeight(1)
                                    .justifyContent(FlexAlign.Center)
                                    .onClick({ evt =>
                                        this.chatTransEnabled = false
                                        this.disableChatTranslation()
                                    })
                            } else {
                                // 资源保真修复：真实矢量图标（Chat/Context Menu/Globe.imageset/globe (1).pdf 转 SVG）替代 emoji 字形
                                Row {
                                    Image(@r(app.media.chatroom_ic_translate))
                                        .width(14)
                                        .height(14)
                                        .fillColor(0x317AFF)
                                        .margin(right: 4)
                                    Text("Translate to ${this.getTranslateLangName()}")
                                        .fontSize(this.scaledFontSize(14))
                                        .fontColor(0x317AFF)
                                }
                                    .layoutWeight(1)
                                    .justifyContent(FlexAlign.Center)
                                    .onClick({ evt =>
                                        this.chatTransEnabled = true
                                        this.enableChatTranslation()
                                    })
                            }
                            // 资源保真修复：真实矢量图标（Chat/Context Menu/Clear.imageset/ic_lt_clear.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.chatroom_ic_close))
                                .width(14)
                                .height(14)
                                .fillColor(0x999999)
                                .padding(left: 8, right: 8)
                                .onClick({ evt =>
                                    this.chatTransDetectedForeignLang = false
                                    if (this.chatTransEnabled) {
                                        this.chatTransEnabled = false
                                        this.disableChatTranslation()
                                    }
                                })
                        }
                        .width(100.percent)
                        .height(36)
                        .padding(left: 12, right: 8)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF0F8FF)
                        .borderWidth(0.5)
                        .borderColor(0xD0E8FF)
                    }

                    // ==================== P2-122: 置顶消息条（多条轮播 + 计数器） ====================
                    // 显示: "Pinned #N of M" label + 消息文本 + 关闭按钮
                    // 点击条目 → scrollToMessage(当前 pinnedMessageId) + cycle 到下一条
                    // 点击 ✕ → unpinMessage（对所有人取消）
                    if (this.viewModel.pinnedMessageId > 0) {
                        Row {
                            // 左侧竖线装饰（仿 Telegram iOS pinned bar 橙色竖线）
                            Divider()
                                .vertical(true)
                                .height(36)
                                .strokeWidth(3)
                                .color(0xFF9500)
                            Column {
                                // 置顶标签行：显示 "Pinned #N of M"（多条时显示序号）
                                Text(
                                    if (this.pinnedCount > 1) {
                                        "Pinned #${Int64(this.viewModel.currentPinnedIndex) + 1} of ${this.pinnedCount}"
                                    } else {
                                        "Pinned Message"
                                    }
                                )
                                    .fontSize(this.scaledFontSize(11))
                                    .fontColor(0xFF9500)
                                    .fontWeight(FontWeight.Medium)
                                Text(this.viewModel.pinnedMessageText)
                                    .fontSize(this.scaledFontSize(13))
                                    .fontColor(this.presentation.textColor)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            .padding(left: 8)
                            .onClick({ evt =>
                                // 点击条目：跳转到当前置顶消息并 cycle 到下一条
                                let jumpId = this.viewModel.cyclePinnedMessage()
                                this.scrollToMessage(jumpId)
                                // 同步计数显示
                                this.pinnedCount = this.viewModel.pinnedMessageIds.size
                            })

                            // 关闭按钮 — 取消置顶（对所有人）
                            // 资源保真修复：真实矢量图标（Chat/Context Menu/Clear.imageset/ic_lt_clear.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.chatroom_ic_close))
                                .width(16)
                                .height(16)
                                .fillColor(0x999999)
                                .padding(8)
                                .onClick({ evt =>
                                    this.viewModel.unpinMessage()
                                    // 同步清零本地 pinned 状态
                                    launch {
                                        var newIds = ArrayList<Int64>()
                                        var newTexts = ArrayList<String>()
                                        for (i in 0..this.viewModel.pinnedMessageIds.size) {
                                            if (this.viewModel.pinnedMessageIds[i] != this.viewModel.pinnedMessageId) {
                                                newIds.add(this.viewModel.pinnedMessageIds[i])
                                                newTexts.add(this.viewModel.pinnedMessageTexts[i])
                                            }
                                        }
                                        this.viewModel.pinnedMessageIds = newIds
                                        this.viewModel.pinnedMessageTexts = newTexts
                                        this.pinnedCount = newIds.size
                                        if (newIds.isEmpty()) {
                                            this.viewModel.pinnedMessageId = 0
                                            this.viewModel.pinnedMessageText = ""
                                        } else {
                                            this.viewModel.currentPinnedIndex = 0
                                            this.viewModel.pinnedMessageId = newIds[0]
                                            this.viewModel.pinnedMessageText = newTexts[0]
                                        }
                                    }
                                })
                        }
                        .width(100.percent)
                        .padding(left: 12, right: 12, top: 6, bottom: 6)
                        .backgroundColor(this.presentation.cardColor)
                        .borderWidth(0.5)
                        .borderColor(0xE0E0E0)
                    }

                    // ==================== Video Chat Join 条（iOS GroupCallNavigationAccessoryPanel，高 50） ====================
                    if (this.activeGroupCallId != 0 && !this.activeGroupCallJoined) {
                        Row {
                            Column {
                                // iOS Conversation.ScheduledVoiceChat / ScheduledVoiceChatStarts{Today,Tomorrow,On}Short
                                Text(if (this.activeGroupCallSchedule > 0) { "Scheduled Video Chat" } else { "Video Chat" })
                                    .fontSize(this.scaledFontSize(15))
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(this.presentation.textColor)
                                Text(if (this.activeGroupCallSchedule > 0) { formatScheduledCallStarts(this.activeGroupCallSchedule) } else if (this.activeGroupCallCount <= 0) { "Tap to join" } else if (this.activeGroupCallCount == 1) { "1 participant" } else { "${this.activeGroupCallCount} participants" })
                                    .fontSize(this.scaledFontSize(13))
                                    .fontColor(0x8E8E93)
                                    .margin(top: 1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            if (this.activeGroupCallSchedule > 0) {
                                // 预约态：渐变胶囊里是倒计时（iOS GroupCallNavigationAccessoryPanel scheduled 分支）
                                Text(this.activeGroupCallCountdown)
                                    .fontSize(this.scaledFontSize(15))
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                                    .height(28)
                                    .padding(left: 12, right: 12)
                                    .borderRadius(14)
                                    .linearGradient(angle: 90.0, colors: [(Color(0xFF0077FF), 0.0), (Color(0xFF7C5CFF), 0.55), (Color(0xFFC751C0), 1.0)])
                            } else {
                                Text("JOIN")
                                    .fontSize(this.scaledFontSize(15))
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFF)
                                    .height(28)
                                    .padding(left: 12, right: 12)
                                    .borderRadius(14)
                                    .backgroundColor(0x007AFF)
                            }
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 12)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(this.presentation.cardColor)
                        .borderWidth(0.5)
                        .borderColor(0xE0E0E0)
                        .onClick({ _evt => this.openActiveGroupCall() })
                    }

                    // ==================== 1. 消息列表（P2-395: WallpaperBackgroundComponent 背景层） ====================
                    Stack(alignContent: Alignment.Bottom) {   // Bottom：供「N 条新消息」浮层贴底；List 为满尺寸，不受影响
                        // S8-08：秘密聊天空态说明卡（iOS ChatEmptyNode contentType .secret →
                        // ChatEmptyNodeSecretChatContent）。历史为空时居中显示，有消息后消失。
                        if (this.viewModel.isSecretChatPeer() && this.viewModel.initialLoadDone && this.displayMessages.isEmpty()) {
                            this.secretChatEmptyCard()
                        }
                        // P2-112: 顶部 loading 指示器（向上翻页时显示）
                        if (this.isLoadingOlderUI) {
                            Row {
                                Text("Loading earlier messages...")
                                    .fontSize(this.scaledFontSize(13))
                                    .fontColor(0x8E8E93)
                            }
                            .width(100.percent)
                            .height(32)
                            .justifyContent(FlexAlign.Center)
                            .backgroundColor(Color.Transparent)
                        }

                        // 首屏定位：List 等数据到位再挂载，并以末项为 initialIndex（SDK List.init(space, initialIndex,
                        // scroller)）。此前 List 先以空数据挂载，数据到达后从 index 0 起实例化整屏气泡，16ms 后
                        // scrollToIndex 跳到末端再实例化一屏 —— 首屏气泡构建做了两遍，正是点开会话后"壳已
                        // 显示、消息迟迟不出"的主因之一。对位 iOS ChatHistoryListNode 倒置列表从最新端起布局。
                        // 空会话不挂 List：所有 listScroller 调用均已有 try 守卫或按 displayMessages 下标前置判断。
                        if (this.displayMessages.size > 0) {
                        List(space: 0, initialIndex: Int32(this.displayMessages.size - 1), scroller: this.listScroller) {
                            // 显式 keyGenerator：不再依赖框架默认键值规则（文档只说「与 index 有关」，
                            // 且 API 参考与本机 SDK 声明不一致，无法确定其确切行为）。
                            // MessageEntry.toString() 的身份段已改用 Message.stableId（identityKey()），
                            // 故本地消息发出后 id 从计数器号换成服务端号时，键值不变 → 组件不重建 → 不闪。
                            // 内容字段仍在键里，内容一变照常重建（这是当前架构下唯一的刷新途径：
                            // MessageBubble.message 是常规成员变量，kb.py《@Prop》明确「常规变量的变化
                            // 不会触发 UI 刷新，只有状态变量才能触发」）。
                            // 类型依据：KeyGeneratorFunc<T> = (T, Int64) -> String（common.cj.d:10957）
                            // LazyForEach：只实例化可见区 + cachedCount 的条目。原 ForEach 全量挂载，
                            // 每条气泡的 Canvas 离屏面随分页累积，GL 内存涨到 2.1GB 被系统
                            // RENDER_MEMORY_OVER_ERROR 杀掉（2026-09-15 真机实锤）。
                            LazyForEach(this.messageSource, itemGenerator: { entry: MessageEntry, index: Int64 =>
                                ListItem {
                                    Column {
                                        // P2-112: 未读分隔线（"N 条未读消息"）
                                        if (entry.message.showUnreadSeparator) {
                                            Row {
                                                Text(entry.message.unreadSeparatorText)
                                                    .fontSize(this.scaledFontSize(13))
                                                    .fontColor(0x8E8E93)
                                                    .padding(left: 12, right: 12, top: 4, bottom: 4)
                                                    .backgroundColor(0xE8E6DF)
                                                    .borderRadius(12)
                                            }
                                            .width(100.percent)
                                            .height(28)
                                            .justifyContent(FlexAlign.Center)
                                            .margin(top: 4, bottom: 4)
                                        }
                                        // P2-114: 多选模式 — 在气泡左侧显示选中标记
                                        if (this.isMultiSelectMode) {
                                            Row {
                                                Text(if (this.selectedMessageIds.contains(entry.message.id)) { "✓" } else { "○" })
                                                    .fontSize(this.scaledFontSize(18))
                                                    .fontColor(if (this.selectedMessageIds.contains(entry.message.id)) { 0x317AFF } else { 0x8E8E93 })
                                                    .margin(right: 8)
                                            }
                                            .width(28)
                                            .onClick({ evt =>
                                                this.toggleMessageSelection(entry.message.id)
                                            })
                                        }
                                        // D-160/D-184 重挂载守卫（F-2b 的调用方义务）。MessageBubble 的六个主题
                                        // 入参是 @State：宏生成的 init 只在构造时做一次值拷贝
                                        // (state_macro_manage/cj_generate_var_decl.cj: ObservedProperty(info, v.get()))，
                                        // 之后父组件再也喂不进去；唯一的原地回灌通道 updateWithValueParams 全仓零调用方。
                                        // 而本 ForEach 的 keyGenerator 只含消息身份+内容，不含主题色，主题切换不改键、
                                        // 不重建。故用两个内容相同但源码位置不同的分支强制销毁重建：
                                        // custom_view.cj:790-800 ifElseBranchUpdateFunction 在 branchId 未变时直接 return、
                                        // 连分支体都不执行；branchId 一变才执行分支体，从而重新走 MessageBubble 的 init。
                                        if (this.msgBubbleMountToggle) {
                                            this.buildMessageBubbleInstance(entry)
                                        } else {
                                            this.buildMessageBubbleInstance(entry)
                                        }
                                    }
                                    // 气泡定高晚于贴底滚动（图片/视频尺寸、链接预览、贴纸、发送状态）：
                                    // 钉在最新端时随之贴底，等价于 iOS 倒置列表里尾部气泡向上长高。
                                    // 挂在 ListItem 内的 Column 上：它相对父容器的位置不随列表滚动变化，
                                    // 回调只在自身尺寸变化时触发。
                                    .onAreaChange({ oldArea: Area, newArea: Area =>
                                        if (oldArea.height.value != newArea.height.value) {
                                            this.requestRepinToLatest()
                                        }
                                    })
                                }
                                .backgroundColor(if (this.highlightedMessageId > 0 && entry.message.id == this.highlightedMessageId) { 0x33FFC107 } else {
                                    if (this.isMultiSelectMode && this.selectedMessageIds.contains(entry.message.id)) { 0x33317AFF } else { Color.Transparent }
                                })
                                // S3-16: in selection mode the tap is resolved by MessageBubble
                                // itself (onSelectionTap above) — the row root spans the full
                                // width, so no ListItem.onClick here (it would toggle twice).
                                // P2-118: 精确可见区已读上报 — 滚入可见(ratio≥0.5)时触发 readHistory
                                .onVisibleAreaChange([0.5], { isVisible: Bool, ratio: Float64 =>
                                    if (isVisible && !entry.message.isSent) {
                                        let msgId = entry.message.id
                                        this.viewModel.reportVisibleRead(msgId)
                                    }
                                })
                            }, keyGenerator: { entry: MessageEntry, _idx: Int64 =>
                                // 键值 = 身份段 + 内容段。
                                //
                                // 身份段用 Message.stableId（identityKey()）而非 id：本地消息发出后
                                // id 会从计数器号换成服务端号（实测 101→602），用 id 会让 ForEach 认为
                                // 「换了一条消息」而重建组件。对齐 iOS Message.stableId
                                // （Postbox/Sources/Message.swift:689，本地转云端时由 updateMessage
                                // 沿用旧值，MessageHistoryTable.swift:1831）。
                                //
                                // 内容段**必须保留**。实测（纯身份 key 实验）：key 稳定时组件确实被复用
                                // （无第二次 aboutToAppear），但**不会原地更新** —— 双勾要退出重进才出现，
                                // 图片下载完不显示。根因见 kb.py《@Prop》：「常规变量的变化不会触发 UI 刷新，
                                // 只有状态变量才能触发 UI 刷新」，而 MessageBubble.message 是常规成员变量。
                                //
                                // 代价：内容一变即重建组件，最后一条气泡会闪一下。这是 ForEach 单一 key
                                // 同时承担「身份」与「内容」双重职责的必然结果 —— iOS 是两条通道
                                // （stableId 定身份 → updateNode 传内容，ChatListItem.swift:541/:572）。
                                // 根治需给 MessageBubble 补状态通道，见 docs/state_channel_design.md。
                                entry.toString()
                            })
                        }
                        .width(100.percent)
                        // 主轴不定高：内容不足一屏时 List 按内容高度收缩，由外层 Stack(alignContent: Bottom)
                        // 贴到输入面板上方；满屏后以父容器为上限滚动。对位 iOS ChatHistoryListNode 倒置
                        // 列表（ChatHistoryListNode.swift:946-948，原点在底部 inset）：新建群只有一两条
                        // 消息时也紧贴输入区。此前满高列表把短历史顶在最上方，键盘弹起整页上移后
                        // 服务消息与刚发的消息都被移出屏幕，聊天区看起来全空白（E6）。
                        .constraintSize(maxHeight: 100.percent)
                        .backgroundColor(Color.Transparent)
                        .scrollBar(BarState.Auto)
                        // 可见区外各预挂 4 条：回滚时气泡已就绪，同时把常驻 Canvas 数量封顶。
                        .cachedCount(4)
                        // P2-112: 向上滚动到顶时加载更早历史
                        .onReachStart({
                            =>
                            this.preloadOlderHistory(Int64(0), true)
                        })
                        // 记录最后一个可见项，供「是否在底部」判定使用。
                        // SDK: onScrollIndex(event: ?(Int32, Int32, Int32) -> Unit)
                        //      —— 子组件进入或离开显示区域时触发，三参为 first / last / center。
                        .onScrollIndex({ first: Int32, last: Int32, _center: Int32 =>
                            if (!this._perfFirstLayoutMarked) {
                                this._perfFirstLayoutMarked = true
                                chatOpenPerfMark("listFirstLayout first=${first} last=${last}")
                            }
                            this._firstVisibleIndex = Int64(first)
                            this._lastVisibleIndex = Int64(last)
                            // 对齐 iOS：不要等 onReachStart，距历史边界 5 个 item 时即预取。
                            this.preloadOlderHistory(Int64(first), false)
                            this.prioritizeVisibleMedia(Int64(first), Int64(last))
                            // iOS shouldDisplayDownButton 只看是否处于 upperBound：离开最新端
                            // 即显示下箭头，不依赖期间是否恰好收到了新消息。
                            let atLatest = !this.viewModel.hasMoreNewer &&
                                Int64(last) >= this.displayMessages.size - 1
                            this.showScrollToLatestButton = !atLatest
                            if (atLatest && this.pendingNewCount > 0) {
                                this.pendingNewCount = 0
                            }
                        })
                        .onDidScroll({ yDelta: Float64, scrollState: ScrollState =>
                            // fling 期间 ArkUI 一帧可跨越多个 item。提前扩大 hole 预取跑道，
                            // 让 44 条窗口覆盖网络往返，避免高速上划撞到旧窗口边界。
                            if (yDelta > 22.0 || yDelta < -22.0) {
                                this._historyScrollFast = true
                            }
                            // 用户手指拖离底部 / 向历史方向惯性滑动 → 解除「钉在最新端」。
                            // 程序化无动画滚动报 Idle，不会误解除（ScrollState.Idle 文档）。
                            if (this._pinnedToLatest) {
                                let userDrag = scrollState == ScrollState.Scroll
                                let flingToHistory = scrollState == ScrollState.Fling && yDelta < 0.0
                                if ((userDrag || flingToHistory) && !this.listScroller.isAtEnd()) {
                                    this._pinnedToLatest = false
                                }
                            }
                        })
                        .onScrollStop({ =>
                            this._historyScrollFast = false
                            // 用户自己滑回最新端：重新钉住（iOS isScrollAtBottomPosition 恢复为 true）。
                            if (!this.viewModel.hasMoreNewer && this.listScroller.isAtEnd()) {
                                this._pinnedToLatest = true
                            }
                        })
                        // 视口高度变化（键盘/表情面板/回复条挤压列表）：钉住时保持底边不动，
                        // 对位 iOS listInsets.top 随 containerInsets.bottom + inputPanelsHeight 更新。
                        .onAreaChange({ oldArea: Area, newArea: Area =>
                            this._listViewportHeightVp = newArea.height.value
                            if (oldArea.height.value != newArea.height.value) {
                                this.requestRepinToLatest()
                            }
                        })
                        // P2-112: 向下滚动到底时加载更新消息（仅 hasMoreNewer 时触发）
                        .onReachEnd({
                            =>
                            if (this.viewModel.hasMoreNewer && !this.viewModel.isLoadingNewer) {
                                this.viewModel.loadNewerMessages()
                            }
                        })
                        } // if (this.displayMessages.size > 0)

                        // iOS ChatHistoryNavigationButtons：不在最新端时始终显示圆形下箭头；
                        // 期间收到的新消息才额外叠加计数徽标。
                        if (this.showScrollToLatestButton) {
                            Row {
                                Blank()
                                Stack(alignContent: Alignment.TopEnd) {
                                    Row {
                                        Image(@r(app.media.chatroom_ic_scroll_down))
                                            .width(22)
                                            .height(22)
                                    }
                                    .width(44)
                                    .height(44)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(VerticalAlign.Center)
                                    .backgroundColor(0xF2FFFFFF)
                                    .borderRadius(22)
                                    .shadow(radius: 8.0, color: 0x26000000, offsetX: 0.0, offsetY: 2.0)

                                    if (this.pendingNewCount > 0) {
                                        Text("${this.pendingNewCount}")
                                            .fontSize(this.scaledFontSize(11))
                                            .fontWeight(FontWeight.Medium)
                                            .fontColor(Color.White)
                                            .textAlign(TextAlign.Center)
                                            .minFontSize(8)
                                            .width(22)
                                            .height(18)
                                            .backgroundColor(0xFFFF3B30)
                                            .borderRadius(9)
                                    }
                                }
                                .width(50)
                                .height(50)
                                .onClick({ _evt =>
                                    this.navigateToLatest()
                                })
                            }
                            .width(100.percent)
                            .padding(right: 10, bottom: 10)
                        }
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .backgroundColor(Color.Transparent)
                    // iOS clickThroughMessage routes a non-interactive history tap
                    // to dismissInput. Child media/link actions still run normally;
                    // the bubbled history tap closes the entity keyboard in one tap.
                    .onClick({ _evt =>
                        if (this.entityKeyboardVisible()) { this.closeEntityKeyboard() }
                    })

                    // ==================== 2. 回复/编辑预览条 ====================
                    if (this.viewModel.replyToMsgId > 0) {
                        Row {
                            Column {
                                Text(this.viewModel.replyToSenderName)
                                    .fontSize(this.scaledFontSize(13))
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(0x317AFF)
                                Text(this.viewModel.replyToText)
                                    .fontSize(this.scaledFontSize(12))
                                    .fontColor(0x666666)
                                    .maxLines(1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            .padding(left: 12)
                            .borderWidth(0)
                            
                            // 资源保真修复：真实矢量图标（Chat/Context Menu/Clear.imageset/ic_lt_clear.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.chatroom_ic_close))
                                .width(18)
                                .height(18)
                                .fillColor(0x999999)
                                .padding(8)
                                .onClick({ evt =>
                                    this.viewModel.cancelReply()
                                })
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 12, right: 12)
                        .backgroundColor(0xF0F8FF)
                        .alignItems(VerticalAlign.Center)
                        .borderWidth(1)
                        .borderColor(0xE0E0E0)
                    }
                    
                    if (this.viewModel.editingMsgId > 0) {
                        Row {
                            Column {
                                Text("Editing")
                                    .fontSize(this.scaledFontSize(13))
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(0xFF9500)
                                Text(this.viewModel.editingOriginalText)
                                    .fontSize(this.scaledFontSize(12))
                                    .fontColor(0x666666)
                                    .maxLines(1)
                            }
                            .layoutWeight(1)
                            .alignItems(HorizontalAlign.Start)
                            .padding(left: 12)
                            
                            // 资源保真修复：真实矢量图标（Chat/Context Menu/Clear.imageset/ic_lt_clear.pdf 转 SVG）替代 emoji 字形
                            Image(@r(app.media.chatroom_ic_close))
                                .width(18)
                                .height(18)
                                .fillColor(0x999999)
                                .padding(8)
                                .onClick({ evt =>
                                    this.viewModel.cancelEdit()
                                    this.setComposerText(this.composeTextBeforeEdit)
                                    this.composeTextBeforeEdit = ""
                                })
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 12, right: 12)
                        .backgroundColor(0xFFF8F0)
                        .alignItems(VerticalAlign.Center)
                        .borderWidth(1)
                        .borderColor(0xE0E0E0)
                    }
                    
                    // ==================== P2-114: 多选底部操作栏 ====================
                    if (this.isMultiSelectMode) {
                        Row {
                            Button(trSource("Cancel"))
                                .fontSize(this.scaledFontSize(14))
                                .fontColor(0x317AFF)
                                .backgroundColor(Color.Transparent)
                                .height(36)
                                .onClick({ evt =>
                                    this.setMultiSelectMode(false)
                                    this.selectedMessageIds = HashMap<Int64, Bool>()
                                })
                            Blank()
                            Text("${this.selectedMessageIds.size} selected")
                                .fontSize(this.scaledFontSize(14))
                                .fontColor(this.presentation.textColor)
                            Blank()
                            // 批量转发
                            Button(trSource("Forward"))
                                .fontSize(this.scaledFontSize(14))
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.selectedMessageIds.isEmpty()) { 0xCCCCCC } else { 0x317AFF })
                                .height(36)
                                .borderRadius(18)
                                .enabled(!this.selectedMessageIds.isEmpty())
                                .onClick({ evt =>
                                    let selIds = this.selectedMessageIdsSorted()
                                    this.forwardMsgIds = selIds
                                    this.forwardDropAuthor = false
                                    this.forwardDropCaptions = false
                                    this.loadForwardDialogs()
                                    this.showForwardPicker = true
                                })
                            // 批量删除 (3-button AlertDialog)
                            Button(trSource("Delete"))
                                .fontSize(this.scaledFontSize(14))
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.selectedMessageIds.isEmpty()) { 0xCCCCCC } else { 0xFFFF3B30 })
                                .height(36)
                                .borderRadius(18)
                                .margin(left: 8)
                                .enabled(!this.selectedMessageIds.isEmpty())
                                .onClick({ evt =>
                                    let selIds = ArrayList<Int64>()
                                    for ((id, _v) in this.selectedMessageIds) { selIds.add(id) }
                                    let uiCtx = getUIContext()
                                    let cancelBtn = AlertDialogButtonOptions(
                                        value: "Cancel",
                                        action: { => () }
                                    )
                                    let forMeBtn = AlertDialogButtonOptions(
                                        value: "Delete for Me",
                                        fontColor: 0xFFFF3B30,
                                        action: { =>
                                            this.viewModel.deleteMessages(selIds, revoke: false)
                                            this.setMultiSelectMode(false)
                                            this.selectedMessageIds = HashMap<Int64, Bool>()
                                        }
                                    )
                                    let forAllBtn = AlertDialogButtonOptions(
                                        value: "Delete for Everyone",
                                        fontColor: 0xFFFF3B30,
                                        action: { =>
                                            this.viewModel.deleteMessages(selIds, revoke: true)
                                            this.setMultiSelectMode(false)
                                            this.selectedMessageIds = HashMap<Int64, Bool>()
                                        }
                                    )
                                    uiCtx.showAlertDialog(AlertDialogParamWithOptions(
                                        title: "Delete ${selIds.size} Message(s)",
                                        message: "This will permanently delete the selected messages.",
                                        autoCancel: true,
                                        buttons: [cancelBtn, forMeBtn, forAllBtn]
                                    ))
                                })
                        }
                        .width(100.percent)
                        .height(60)
                        .padding(left: 12, right: 12, top: 8, bottom: 8)
                        .backgroundColor(this.presentation.cardColor)
                        .borderWidth(1)
                        .borderColor(0xE0E0E0)
                    }

                    // ==================== 3. 底部输入面板 (P2-120 增强版) ====================
                    if (!this.isMultiSelectMode) {
                    Column {

                        // P2-120-①③: @mention / #hashtag / /command 补全面板
                        // P2-038: inline_bot 结果面板（键盘上方）— 横向媒体网格或纵向列表
                        // 显示在输入行上方；点击候选项将文本插入或发送内联 bot 结果
                        if (this.contextQueryVM.showSuggestions) {
                            if (this.contextQueryVM.activeQueryType == "inline_bot") {
                                // P2-038: Inline Bot 结果面板 —— 键盘上方专用面板
                                // 对应 iOS HorizontalListContextResultsChatInputContextPanelNode /
                                //           VerticalListContextResultsChatInputContextPanelNode
                                Column {
                                    // switch-PM 按钮置顶（flags.2?InlineBotSwitchPM）
                                    if (this.contextQueryVM.inlineBotSwitchPmText.size > 0) {
                                        Row {
                                            Text(this.contextQueryVM.inlineBotSwitchPmText)
                                                .fontSize(this.scaledFontSize(15))
                                                .fontColor(0x317AFF)
                                                .layoutWeight(1)
                                                .maxLines(1)
                                            Text(">")
                                                .fontSize(this.scaledFontSize(14))
                                                .fontColor(0x317AFF)
                                        }
                                        .width(100.percent)
                                        .height(44)
                                        .padding(left: 16, right: 12)
                                        .backgroundColor(0xF7F7F7)
                                        .alignItems(VerticalAlign.Center)
                                        .onClick({ _evt =>
                                            // switch-PM: 打开与 bot 的私聊（由调用方处理导航）
                                            Hilog.info(0, "CjTelegram", "[ChatRoomPage] switch-PM tapped: startParam=${this.contextQueryVM.inlineBotSwitchPmStartParam}")
                                            this.contextQueryVM.clearSuggestions()
                                        })

                                        Divider().color(0xE5E5EA).strokeWidth(0.5)
                                    }

                                    // switch-webview 接线点（P2-029 负责实现）
                                    if (this.contextQueryVM.inlineBotSwitchWebviewText.size > 0) {
                                        Row {
                                            Text(this.contextQueryVM.inlineBotSwitchWebviewText)
                                                .fontSize(this.scaledFontSize(15))
                                                .fontColor(0x317AFF)
                                                .layoutWeight(1)
                                                .maxLines(1)
                                        }
                                        .width(100.percent)
                                        .height(44)
                                        .padding(left: 16, right: 12)
                                        .backgroundColor(0xF7F7F7)
                                        .alignItems(VerticalAlign.Center)
                                        .onClick({ _evt =>
                                            Hilog.info(0, "CjTelegram", "[ChatRoomPage] switch-webview tapped (P2-029): url=${this.contextQueryVM.inlineBotSwitchWebviewUrl}")
                                        })

                                        Divider().color(0xE5E5EA).strokeWidth(0.5)
                                    }

                                    if (this.contextQueryVM.inlineBotIsGallery) {
                                        // 横向媒体网格（photo/gif/sticker）
                                        // 对应 iOS HorizontalListContextResultsChatInputContextPanelNode
                                        List(space: 4) {
                                            ForEach(
                                                this.contextQueryVM.queryResults,
                                                itemGenerator: { item: ContextQueryResultItem, _idx: Int64 =>
                                                    ListItem {
                                                        Column {
                                                            Column {
                                                                Text(this.inlineResultTypeLabel(item.inlineResultType))
                                                                    .fontSize(this.scaledFontSize(11))
                                                                    .fontColor(0x8E8E93)
                                                            }
                                                            .width(80)
                                                            .height(80)
                                                            .backgroundColor(0xE5E5EA)
                                                            .borderRadius(6)
                                                            .justifyContent(FlexAlign.Center)
                                                            .alignItems(HorizontalAlign.Center)

                                                            if (item.inlineTitle.size > 0) {
                                                                Text(item.inlineTitle)
                                                                    .fontSize(this.scaledFontSize(10))
                                                                    .fontColor(0x555555)
                                                                    .maxLines(1)
                                                                    .width(80)
                                                                    .margin(top: 2)
                                                            }
                                                        }
                                                        .alignItems(HorizontalAlign.Center)
                                                        .onClick({ _evt =>
                                                            this.onInlineBotResultSelected(item)
                                                        })
                                                    }
                                                }
                                            )
                                        }
                                        .listDirection(Axis.Horizontal)
                                        .height(104)
                                        .width(100.percent)
                                        .padding(left: 8, right: 8, top: 8, bottom: 8)
                                        .scrollBar(BarState.Off)
                                    } else {
                                        // 纵向结果列表（article/contact/location/venue/game/document）
                                        // 对应 iOS VerticalListContextResultsChatInputContextPanelNode
                                        List {
                                            ForEach(
                                                this.contextQueryVM.queryResults,
                                                itemGenerator: { item: ContextQueryResultItem, _idx: Int64 =>
                                                    ListItem {
                                                        Row {
                                                            Column {
                                                                Text(this.inlineResultTypeIcon(item.inlineResultType))
                                                                    .fontSize(this.scaledFontSize(16))
                                                            }
                                                            .width(40)
                                                            .height(40)
                                                            .backgroundColor(0xE8F4FF)
                                                            .borderRadius(8)
                                                            .justifyContent(FlexAlign.Center)
                                                            .alignItems(HorizontalAlign.Center)
                                                            .margin(right: 12)

                                                            Column {
                                                                Text(if (item.inlineTitle.size > 0) { item.inlineTitle } else { item.inlineSendText })
                                                                    .fontSize(this.scaledFontSize(15))
                                                                    .fontColor(this.presentation.textColor)
                                                                    .maxLines(1)
                                                                if (item.inlineDescription.size > 0) {
                                                                    Text(item.inlineDescription)
                                                                        .fontSize(this.scaledFontSize(12))
                                                                        .fontColor(0x8E8E93)
                                                                        .maxLines(2)
                                                                        .margin(top: 2)
                                                                }
                                                            }
                                                            .alignItems(HorizontalAlign.Start)
                                                            .layoutWeight(1)
                                                        }
                                                        .width(100.percent)
                                                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                                                        .alignItems(VerticalAlign.Center)
                                                        .onClick({ _evt =>
                                                            this.onInlineBotResultSelected(item)
                                                        })
                                                    }
                                                }
                                            )
                                        }
                                        .width(100.percent)
                                        .height(200)
                                        .scrollBar(BarState.Off)
                                        .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xE5E5EA))
                                    }
                                }
                                .width(100.percent)
                                .backgroundColor(this.presentation.cardColor)
                                .borderWidth(1)
                                .borderColor(0xE5E5EA)
                            } else {
                                // @mention / #hashtag / /command 补全面板（非 inline_bot）
                                List {
                                    ForEach(
                                        this.contextQueryVM.queryResults,
                                        itemGenerator: { item: ContextQueryResultItem, _idx: Int64 =>
                                            ListItem {
                                                Row {
                                                    Column {
                                                        Text(if (item.queryType == "mention") {
                                                            if (item.username.size > 0) { "@" + item.username } else { item.displayName }
                                                        } else if (item.queryType == "hashtag") {
                                                            "#" + item.hashtagText
                                                        } else if (item.queryType == "command") {
                                                            "/" + item.commandText
                                                        } else {
                                                            item.inlineTitle
                                                        })
                                                            .fontSize(this.scaledFontSize(15))
                                                            .fontColor(this.presentation.textColor)
                                                            .maxLines(1)
                                                        if (item.queryType == "command" && item.commandDescription.size > 0) {
                                                            Text(item.commandDescription)
                                                                .fontSize(this.scaledFontSize(12))
                                                                .fontColor(0x8E8E93)
                                                                .maxLines(1)
                                                                .margin(top: 2)
                                                        }
                                                        if (item.queryType == "mention" && item.displayName.size > 0 && item.username.size > 0) {
                                                            Text(item.displayName)
                                                                .fontSize(this.scaledFontSize(12))
                                                                .fontColor(0x8E8E93)
                                                                .maxLines(1)
                                                                .margin(top: 2)
                                                        }
                                                    }
                                                    .alignItems(HorizontalAlign.Start)
                                                    .layoutWeight(1)
                                                }
                                                .width(100.percent)
                                                .padding(left: 16, right: 16, top: 8, bottom: 8)
                                                .onClick({ _evt =>
                                                    if (item.queryType == "command") {
                                                        this.sendBotCommand(item.commandText)
                                                        return
                                                    }
                                                    let replacement = this.contextQueryVM.onResultSelected(item)
                                                    if (replacement.size > 0) {
                                                        this.setComposerText(replacement)
                                                    }
                                                })
                                            }
                                        }
                                    )
                                }
                                .width(100.percent)
                                .height(180)
                                .backgroundColor(this.presentation.cardColor)
                                .borderWidth(1)
                                .borderColor(0xE5E5EA)
                                .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA))
                            }
                        }

                        // P2-120-②: 内联格式工具条（Bold / Italic / Underline / Strike / Code / Spoiler）
                        // 仅 showFormatBar=true 时显示，插入 markdown 标记到输入文本末尾
                        if (this.showFormatBar) {
                            Row {
                                Button("B")
                                    .width(36)
                                    .height(32)
                                    .fontSize(this.scaledFontSize(14))
                                    .fontColor(0x317AFF)
                                    .backgroundColor(0xF0F0F0)
                                    .borderRadius(8)
                                    .margin(right: 4)
                                    .onClick({ evt =>
                                        this.appendComposerText("****")
                                    })
                                Button("I")
                                    .width(36)
                                    .height(32)
                                    .fontSize(this.scaledFontSize(14))
                                    .fontColor(0x317AFF)
                                    .backgroundColor(0xF0F0F0)
                                    .borderRadius(8)
                                    .margin(right: 4)
                                    .onClick({ evt =>
                                        this.appendComposerText("____")
                                    })
                                Button(trSource("S"))
                                    .width(36)
                                    .height(32)
                                    .fontSize(this.scaledFontSize(14))
                                    .fontColor(0x317AFF)
                                    .backgroundColor(0xF0F0F0)
                                    .borderRadius(8)
                                    .margin(right: 4)
                                    .onClick({ evt =>
                                        this.appendComposerText("~~~~")
                                    })
                                Button("<>")
                                    .width(36)
                                    .height(32)
                                    .fontSize(this.scaledFontSize(12))
                                    .fontColor(0x317AFF)
                                    .backgroundColor(0xF0F0F0)
                                    .borderRadius(8)
                                    .margin(right: 4)
                                    .onClick({ evt =>
                                        this.appendComposerText("``")
                                    })
                                Button("||")
                                    .width(36)
                                    .height(32)
                                    .fontSize(this.scaledFontSize(13))
                                    .fontColor(0x317AFF)
                                    .backgroundColor(0xF0F0F0)
                                    .borderRadius(8)
                                    .onClick({ evt =>
                                        this.appendComposerText("||||")
                                    })
                            }
                            .width(100.percent)
                            .height(44)
                            .padding(left: 12, right: 12, top: 6, bottom: 6)
                            .backgroundColor(0xF8F8F8)
                            .borderWidth(1)
                            .borderColor(0xE5E5EA)
                        }

                        // iOS ChatTextInputPanelNode.stickersNode：输入框里只有一个
                        // emoji 时，输入栏上方浮出匹配的贴纸建议条。设置里那条
                        // "Suggest Stickers by Emoji" 早就有开关也持久化了，
                        // 但一直没有消费方。
                        // ⚠️ 只加同级节点、不新增容器层级 —— 见 syntax_error.md R-145。
                        // iOS EmojiSuggestionsComponent：输入 `:关键词` 时在输入栏上方
                        // 浮出 Emoji 候选，选中后把 `:关键词` 整段替换掉。
                        if (this.emojiSuggestionQuery().size > 0) {
                            EmojiSuggestionStrip(
                                query: this.emojiSuggestionQuery(),
                                onSelectEmoji: { emoji: String =>
                                    this.applyEmojiSuggestion(emoji)
                                },
                                onSelectCustomEmoji: { item: StickerItem =>
                                    this.replaceSuggestionToken("")
                                    this.appendCustomEmoji(item)
                                }
                            )
                        }

                        if (this.stickerSuggestionQuery().size > 0) {
                            StickerSuggestionStrip(
                                query: this.stickerSuggestionQuery(),
                                onSelectSticker: { item: StickerItem =>
                                    this.setComposerText("")
                                    this.sendStickerMessage(item)
                                }
                            )
                        }

                        // P2-120-④: 特殊发送态
                        if (this.viewModel.isSecretChatPeer() && this.secretHandshakePending) {
                            // S8-08：iOS SecretChatHandshakeStatusInputPanelNode —— 发起方在对端接受前，
                            // 输入栏只显示 DialogList.AwaitingEncryption 状态文案（居中 15pt，无输入框）。
                            Row {
                                Text(this.secretHandshakeStatusText())
                                    .fontSize(this.scaledFontSize(15))
                                    .fontColor(this.presentation.textColor)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.Center)
                                    .maxLines(2)
                                    .textOverflow(TextOverflow.Ellipsis)
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(left: 16, right: 16, top: 8, bottom: 8)
                            .backgroundColor(this.presentation.cardColor)
                        } else if (this.interactiveBotStartPayload.size > 0) {
                            Row {
                                Button(trSource("Start"))
                                    .width(100.percent)
                                    .height(50)
                                    .fontSize(this.scaledFontSize(17))
                                    .fontColor(0xFFFFFFFF)
                                    .backgroundColor(0xFF3390EC)
                                    .borderRadius(25)
                                    .onClick({ _ => this.sendInteractiveBotStart() })
                            }
                            .width(100.percent)
                            .height(62)
                            .padding(left: 16, right: 16, top: 6, bottom: 6)
                            .backgroundColor(this.presentation.cardColor)
                        } else if (this.channelJoinRequiredMirror || this.channelIsLeft) {
                            // E5 / iOS ChatChannelSubscriberInputPanelNode：未加入的频道 / 超级群 →
                            // 居中 accent Join 按钮（centerAction isAccent → .activeTint）+ 右侧消息
                            // 搜索（rightPanelItems "search" → beginMessageSearch），加入前不暴露输入框。
                            // 文案按 Channel.JoinChannel / Group.JoinGroup / Group.ApplyToJoin 区分。
                            Row {
                                Button(if (this.channelJoinBusy) { "Joining…" } else { this.channelJoinButtonTitle() })
                                    .layoutWeight(1)
                                    .height(44)
                                    .fontSize(this.scaledFontSize(17))
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFFFF)
                                    .backgroundColor(0xFF168ACD)
                                    .borderRadius(22)
                                    .enabled(!this.channelJoinBusy)
                                    .onClick({ _ => this.joinCurrentChannel() })

                                Row {
                                    Image(@r(app.media.chatroom_ic_search))
                                        .width(22)
                                        .height(22)
                                        .fillColor(this.presentation.textColor)
                                }
                                .width(44)
                                .height(44)
                                .borderRadius(22)
                                .backgroundColor(this.presentation.backgroundColor)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .margin(left: 8)
                                .onClick({ _ => this.showMessageSearch = true })
                            }
                            .width(100.percent)
                            .height(60)
                            .padding(left: 12, right: 12, top: 8, bottom: 8)
                            .backgroundColor(Color.Transparent)
                        } else if (this.isBroadcastSubscriber()) {
                            // iOS ChatChannelSubscriberInputPanelNode（CSP:49/51）：已加入、不能发帖的频道
                            // 底栏只有 Mute / Unmute（.panel 背景，accent 文字）+ 右侧搜索；点按 togglePeerMuted。
                            Row {
                                Button(if (this.channelMuteBusy) { "Updating…" } else if (this.channelMutedMirror) { trSource("Unmute") } else { trSource("Mute") })
                                    .layoutWeight(1)
                                    .height(44)
                                    .fontSize(this.scaledFontSize(17))
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFF168ACD)
                                    .backgroundColor(this.presentation.backgroundColor)
                                    .borderRadius(22)
                                    .enabled(!this.channelMuteBusy)
                                    .onClick({ _ => this.toggleChannelMute() })

                                Row {
                                    Image(@r(app.media.chatroom_ic_search))
                                        .width(22)
                                        .height(22)
                                        .fillColor(this.presentation.textColor)
                                }
                                .width(44)
                                .height(44)
                                .borderRadius(22)
                                .backgroundColor(this.presentation.backgroundColor)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .margin(left: 8)
                                .onClick({ _ => this.showMessageSearch = true })
                            }
                            .width(100.percent)
                            .height(60)
                            .padding(left: 12, right: 12, top: 8, bottom: 8)
                            .backgroundColor(Color.Transparent)
                        } else if (this.viewModel.isRestrictedSendMsg) {
                            // 发言限制：显示提示文案，隐藏输入框
                            Row {
                                Text("You can't send messages in this chat")
                                    .fontSize(this.scaledFontSize(14))
                                    .fontColor(0x8E8E93)
                                    .layoutWeight(1)
                                    .textAlign(TextAlign.Center)
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(left: 16, right: 16, top: 8, bottom: 8)
                            .backgroundColor(this.presentation.cardColor)
                        } else if (this.viewModel.hasBlockedPeer) {
                            // 已屏蔽对方：显示 Unblock 按钮
                            Row {
                                Button(trSource("Unblock"))
                                    .width(120)
                                    .height(36)
                                    .fontSize(this.scaledFontSize(15))
                                    .fontColor(0xFFFFFF)
                                    .backgroundColor(0xFF3B30)
                                    .borderRadius(18)
                                    .onClick({ evt =>
                                        this.viewModel.unblockPeer()
                                    })
                            }
                            .width(100.percent)
                            .height(52)
                            .justifyContent(FlexAlign.Center)
                            .backgroundColor(this.presentation.cardColor)
                        } else {
                            // 正常输入行（含慢速模式覆盖）
                            Row {
                                if (this.voiceRecording) {
                                    this.voiceRecordingBar()
                                } else {
                                if (this.showBotMenuButton()) {
                                    // S2-74: iOS ChatTextInputPanelNode.menuButton (Conversation.InputMenu)
                                    Row {
                                        Text(if (this.botMenuButtonKind == 2 && this.botMenuButtonText.size > 0) {
                                            this.botMenuButtonText
                                        } else {
                                            trOr("Conversation.InputMenu", "Menu")
                                        })
                                            .fontSize(this.scaledFontSize(15))
                                            .fontWeight(FontWeight.Medium)
                                            .fontColor(0xFFFFFF)
                                            .maxLines(1)
                                    }
                                    .height(32)
                                    .padding(left: 12, right: 12)
                                    .borderRadius(16)
                                    .backgroundColor(0x317AFF)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(VerticalAlign.Center)
                                    .margin(right: 4)
                                    .onClick({ _evt => this.onBotMenuButton() })
                                }
                                Row {
                                    Image(@r(app.media.chatroom_ic_attach))
                                        .width(22)
                                        .height(22)
                                        .fillColor(0x8E8E93)
                                }
                                    .width(42)
                                    .height(42)
                                    .borderRadius(21)
                                    // F-3/RC-C: 附件按钮圆底，源侧走 theme.chat.inputPanel.*。
                                    .backgroundColor(this.presentation.backgroundColor)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(VerticalAlign.Center)
                                    .onClick({ evt =>
                                        this.toggleAttachmentPanel()
                                    })

                                Stack(alignContent: Alignment.End) {
                                    // 历史：customKeyboard 参数在本机宏版本无适配，此前用 TextInput +
                                    // enableKeyboardOnFocus（Plan C）做焦点-IME 解耦。
                                    // WP-D (S2-18/19/24)：TextInput → RichEditor（选区回调 + 逐 span 样式）。
                                    // RichEditor 没有 enableKeyboardOnFocus / stopEditing：面板在场时
                                    // 编辑器改为失焦（焦点哨兵），切回键盘时 requestFocus 弹 IME。
                                    // 占位符与圆角底色放在这个底层同级节点上（6.1 绑定的 RichEditor
                                    // 没有 placeholder 属性）。
                                    Text(if (this.inputText.isEmpty()) { trSource("Message") } else { "" })
                                        .width(100.percent)
                                        .height(42)
                                        .fontSize(COMPOSER_FONT_SIZE)
                                        .fontColor(0x8E8E93)
                                        .textAlign(TextAlign.Start)
                                        .padding(left: 16, right: 44.0 + this.inputAccessoryExtraWidth())
                                        // F-3/RC-C: 输入框底接快照 backgroundColor。
                                        .backgroundColor(this.presentation.backgroundColor)
                                        .borderRadius(21)
                                    // 不可见焦点哨兵（CountrySelectionPage 先例）：blurComposer 把焦点移到
                                    // 这里让编辑器失焦 → IME 收起。
                                    Text(trSource(""))
                                        .width(1)
                                        .height(1)
                                        .opacity(0.0)
                                        .focusable(true)
                                        .id(CHAT_FOCUS_SINK_ID)
                                    // WP-E: 输入内容镜像（见 CHAT_INPUT_MIRROR_ID 注释）。maxLines(1)
                                    // 避免 1vp 宽度下长文本逐字折行的无谓测量。
                                    Text(this.inputText)
                                        .width(1)
                                        .height(1)
                                        .maxLines(1)
                                        .opacity(0.0)
                                        .id(CHAT_INPUT_MIRROR_ID)
                                    RichEditor(this.chatRichController)
                                        // 供底部面板的地球键 FocusControl 定位（switchToTextInput）
                                        .id(CHAT_INPUT_FIELD_ID)
                                        .width(100.percent)
                                        .height(42)
                                        .padding(left: 16, right: 44.0 + this.inputAccessoryExtraWidth(), top: 10, bottom: 10)
                                        .onReady({ => this.onComposerReady() })
                                        .onDidChange({ _before: TextRange, _after: TextRange =>
                                            this.syncComposerFromEditor()
                                        })
                                        .onImeInputComplete({ result: RichEditorTextSpanResult =>
                                            this.onComposerImeComplete(result)
                                        })
                                        .onDeleteComplete({ => this.syncComposerFromEditor() })
                                        // 系统菜单粘贴：onPaste 在内容落地前触发，延后一帧回灌 inputText
                                        //（onDidChange 为主路径，这里兜底）。
                                        .onPaste({ _evt: PasteEvent =>
                                            let _ = spawn {
                                                sleep(Duration.millisecond * 60)
                                                launch { this.syncComposerFromEditor() }
                                            }
                                        })
                                        .onSelect({ sel: RichEditorSelection => this.onComposerSelect(sel) })
                                        // iOS：文字输入获得焦点即从 Bot 按钮键盘切回文本输入（inputMode .text）
                                        // WP-F P0-1：每次取焦再断言 RESIZE 避让（ChatRoomPage.ets chatRoom.keyboardAvoid），
                                        // 上层 GroupCallScreen 退出时会把 UIContext 复位成 OFFSET。
                                        .onFocus({ =>
                                            this.botKeyboardShown = false
                                            callArk("chatRoom.keyboardAvoid", "resize")
                                        })
                                        .onBlur({ => this.hideComposerFormatBar() })
                                        .onClick({ _evt => this.hideComposerFormatBar() })
                                        .onAppear({ =>
                                            // 从实体态切回：把焦点交还本字段让系统 IME 弹出
                                            //（仅显式请求过时，冷进页不抢焦）。
                                            if (this.wantSystemKeyboardFocus) {
                                                this.wantSystemKeyboardFocus = false
                                                FocusControl.requestFocus(CHAT_INPUT_FIELD_ID)
                                            }
                                        })

                                    // iOS ChatInterfaceInputContexts.swift:193/276 输入框内附件（左→右）：
                                    // 自动删除计时器（输入为空）· 表情/贴纸 · Bot 键盘（输入为空）。
                                    Row {
                                    if (this.showBotCommandsAccessory()) {
                                        // S2-72: iOS AccessoryIconCommands ("/", VoiceOver.BotCommands)
                                        Text("/")
                                            .fontSize(20)
                                            .fontWeight(FontWeight.Medium)
                                            .fontColor(0x8E8E93)
                                            .height(32)
                                            .padding(left: 6, right: 6)
                                            .margin(right: 4)
                                            .onClick({ _evt => this.openBotCommandsList() })
                                    }
                                    if (this.showScheduledAccessory()) {
                                        // S2-70: iOS AccessoryIconSchedule（Chat/Input/Text/ScheduleInput：带箭头的空心表盘）
                                        // → openScheduledMessages。此前用的 loc_ic_clock 是实心圆盘 + 同色指针，渲染成一个灰点。
                                        Image(@r(app.media.chatroom_ic_acc_scheduled))
                                            .width(22)
                                            .height(22)
                                            .fillColor(0x8E8E93)
                                            .margin(right: 8)
                                            .onClick({ _evt => this.openScheduledMessages() })
                                    }
                                    if (this.showAutoremoveAccessory()) {
                                        Text(shortAutoremoveText(this.autoremoveTimeoutSec))
                                            .fontSize(14)
                                            .fontWeight(FontWeight.Medium)
                                            .fontColor(0x8E8E93)
                                            .height(32)
                                            .padding(left: 5, right: 5)
                                            .margin(right: 4)
                                            .onClick({ _evt => this.openCurrentPeerInfo() })
                                    }
                                    // S2-28: iOS ChatTextInputPanelNode accessory — the emoji glyph
                                    // becomes the keyboard glyph while the entity panel replaces the IME.
                                    Image(if (this.showEmojiPicker || this.showStickerKeyboard || this.showGifPanel) {
                                        @r(app.media.chatroom_ic_acc_keyboard)
                                    } else {
                                        @r(app.media.chatroom_ic_emoji)
                                    })
                                        .width(if (this.showEmojiPicker || this.showStickerKeyboard || this.showGifPanel) { 29 } else { 22 })
                                        .height(if (this.showEmojiPicker || this.showStickerKeyboard || this.showGifPanel) { 24 } else { 22 })
                                        .objectFit(ImageFit.Contain)
                                        .fillColor(0x8E8E93)
                                        .margin(right: if (this.showBotKeyboardAccessory()) { 8 } else { 0 })
                                        .onClick({ _evt =>
                                            this.botKeyboardShown = false
                                            if (this.entityKeyboardVisible()) {
                                                // iOS：面板开着时该按钮语义是「切回系统键盘」
                                                //（图标显示为键盘）。与 🌐 同一套真实
                                                // blur → 延迟取焦流转，IME 弹出。
                                                this.closeEntityKeyboard()
                                                this.blurComposer()
                                                let _ = spawn {
                                                    sleep(Duration.millisecond * 80)
                                                    launch {
                                                        FocusControl.requestFocus(CHAT_INPUT_FIELD_ID)
                                                    }
                                                }
                                            } else {
                                                // 回到上次那个页签，与 iOS 一致：
                                                // 在 GIFs 页关掉键盘、再打开，iOS 仍是 GIFs。
                                                // 此前这里硬编码 "emoji"，每次重开都跳回表情页。
                                                // entityTab 由 selectEntityTab 维护，
                                                // closeEntityKeyboard 不会清它。
                                                this.selectEntityTab(this.entityTab)
                                                // 面板可能在 IME 仍在场时完成首次布局（键盘上方），
                                                // IME 收起后整体下移 —— 主动重量覆盖层几何。
                                                this.scheduleOverlayRemeasure("emojiKey")
                                                // 互斥：IME 若开着先收。RichEditor 没有
                                                // enableKeyboardOnFocus，面板在场时不再回取焦
                                                //（取焦即弹 IME）；表情经控制器追加，不需要焦点。
                                                this.blurComposer()
                                            }
                                            this.closeAttachmentPanel()
                                            this.showVoiceRecorder = false
                                        })
                                    if (this.showBotKeyboardAccessory()) {
                                        if (this.botKeyboardShown) {
                                            Image(@r(app.media.chatroom_ic_acc_keyboard))
                                                .width(29)
                                                .height(24)
                                                .objectFit(ImageFit.Contain)
                                                .onClick({ _evt => this.hideBotKeyboardToText() })
                                        } else {
                                            Image(@r(app.media.chatroom_ic_acc_botkeyboard))
                                                .width(22)
                                                .height(22)
                                                .onClick({ _evt => this.showBotKeyboard() })
                                        }
                                    }
                                    }
                                    .height(42)
                                    // 右侧留白挂在 Row 外侧（margin），不进 Row 的命中区域：
                                    // Row 盖在 TextInput 上，留白若在子项 margin 里会挡住
                                    // 该处对输入框的点按（输入框点不起、键盘不弹）。
                                    .margin(right: if (this.showBotKeyboardAccessory() && this.botKeyboardShown) { 10 } else { 12 })
                                    .alignItems(VerticalAlign.Center)
                                }
                                    .layoutWeight(1)
                                    .height(42)
                                    .margin(left: 8)
                                }

                                if (this.slowmodeCountdownText.size > 0) {
                                    Column {
                                        Text(this.slowmodeCountdownText)
                                            .fontSize(this.scaledFontSize(12))
                                            .fontColor(0xFFFFFF)
                                            .textAlign(TextAlign.Center)
                                    }
                                    .width(42)
                                    .height(42)
                                    .backgroundColor(0xCCCCCC)
                                    .borderRadius(21)
                                    .justifyContent(FlexAlign.Center)
                                    .margin(left: 8)
                                } else {
                                    // S2-58 (WP-E): ArkUI Image 默认可拖拽 —— 按住麦克风/相机/发送键
                                    // 一挪就触发系统「拖到小艺」接管触摸（录音被 Cancel）。6.1 仓颉绑定
                                    // 没有 draggable(false)，改用 Stack：最上层盖一块同尺寸透明 Column
                                    // 承接命中（同级后者先命中并阻断下方兄弟，图标节点永远不被命中、
                                    // 不会起拖拽），触摸事件照常冒泡到本 Stack 的 onTouch / onClick。
                                    Stack(alignContent: Alignment.Center) {
                                        if (this.inputText.isEmpty()) {
                                            if (this.voiceRecording && this.voiceLocked) {
                                                Image(@r(app.media.media_ic_send))
                                                    .width(22).height(22).fillColor(0xFFFFFF)
                                            } else if (this.mediaModeVideo) {
                                                Image(@r(app.media.media_ic_attach_video))
                                                    .width(22).height(22)
                                                    .fillColor(if (this.voiceRecording) { 0xFFFFFF } else { 0x8E8E93 })
                                            } else {
                                                Image(@r(app.media.media_ic_mic))
                                                    .width(22).height(22)
                                                    .fillColor(if (this.voiceRecording) { 0xFFFFFF } else { 0x8E8E93 })
                                            }
                                        } else {
                                            Image(@r(app.media.media_ic_send))
                                                .width(22).height(22).fillColor(0xFFFFFF)
                                        }
                                        Column {}
                                            .width(42)
                                            .height(42)
                                    }
                                        .width(42)
                                        .height(42)
                                        // F-3/RC-C: 只改 empty 分支（麦克风态圆底）；
                                        // 0xFF9500 / 0x317AFF 两个发送态分支不动。
                                        .backgroundColor(if (this.voiceRecording) {
                                            if (this.voiceLocked) { 0x317AFF } else { 0xFF3B30 }
                                        } else if (this.inputText.isEmpty()) { this.presentation.backgroundColor } else {
                                            if (this.viewModel.editingMsgId > 0) { 0xFF9500 } else { 0x317AFF }
                                        })
                                        .borderRadius(21)
                                        .margin(left: 8)
                                        // S032：长按发送键（有文本时）弹出发送选项；
                                        // 沿用 ChatListItem 的 onTouch+定时器长按实现（无 LongPressGesture 先例）
                                        .onTouch({ evt =>
                                            match (evt.eventType) {
                                                case TouchType.Down =>
                                                    if (this.voiceRecording && this.voiceLocked) {
                                                        // 锁定态：该键是发送键，走 onClick
                                                        ()
                                                    } else {
                                                    this.sendPressActive = true
                                                    this.sendPressGeneration += 1
                                                    let generation = this.sendPressGeneration
                                                    if (evt.touches.size > 0) {
                                                        this.voiceTouchStartX = evt.touches[0].x
                                                        this.voiceTouchStartY = evt.touches[0].y
                                                    }
                                                    // 有文本：500ms 长按弹发送选项；空输入：250ms 按住即开录
                                                    let holdMs: Int64 = if (this.inputText.isEmpty()) { 250 } else { 500 }
                                                    spawn {
                                                        sleep(Duration.millisecond * holdMs)
                                                        launch {
                                                            if (this.sendPressActive && generation == this.sendPressGeneration) {
                                                                this.suppressNextSendClick = true
                                                                if (this.inputText.isEmpty()) {
                                                                    if (this.mediaModeVideo) {
                                                                        this.sendPressActive = false
                                                                        this.launchVideoNoteCapture()
                                                                    } else {
                                                                        this.startVoiceRecordingWithPermission()
                                                                    }
                                                                } else {
                                                                    this.sendPressActive = false
                                                                    this.openSendContextMenu()
                                                                }
                                                            }
                                                        }
                                                    }
                                                    }
                                                case TouchType.Move =>
                                                    if (this.voiceRecording && !this.voiceLocked && evt.touches.size > 0) {
                                                        let dx = evt.touches[0].x - this.voiceTouchStartX
                                                        let dy = evt.touches[0].y - this.voiceTouchStartY
                                                        if (dx < -90.0) {
                                                            // iOS「Slide to cancel」
                                                            this.finishVoiceRecording(true)
                                                        } else if (dy < -90.0) {
                                                            // iOS 上滑锁定，松手不发，改点发送键
                                                            this.voiceLocked = true
                                                            this.sendPressActive = false
                                                            this.suppressNextSendClick = false
                                                            triggerHaptic("impact", "light")
                                                        }
                                                    }
                                                case TouchType.Up =>
                                                    this.sendPressActive = false
                                                    if (this.voiceRecording && !this.voiceLocked) {
                                                        this.finishVoiceRecording(false)
                                                    }
                                                case TouchType.Cancel =>
                                                    // S2-58: the system took the touch over (drag-to-assistant,
                                                    // gesture navigation …). iOS ChatTextInputMediaRecordingButton
                                                    // treats a cancelled recognizer as cancel, never as send.
                                                    this.sendPressActive = false
                                                    if (this.voiceRecording && !this.voiceLocked) {
                                                        Hilog.info(0, "CjTelegram", "[VoiceRecord] touch cancelled by system → discard recording")
                                                        this.finishVoiceRecording(true)
                                                    }
                                                case _ => ()
                                            }
                                        })
                                        .onClick({ evt =>
                                            if (this.voiceRecording && this.voiceLocked) {
                                                // 锁定态的发送键
                                                this.suppressNextSendClick = false
                                                this.finishVoiceRecording(false)
                                                return
                                            }
                                            if (this.suppressNextSendClick) {
                                                this.suppressNextSendClick = false
                                                return
                                            }
                                            if (this.inputText.isEmpty()) {
                                                // iOS：点按麦克风键切换 语音 / 圆形视频 模式（按住才录）
                                                this.mediaModeVideo = !this.mediaModeVideo
                                                triggerHaptic("impact", "light")
                                            } else {
                                                if (this.viewModel.editingMsgId > 0) {
                                                    this.viewModel.confirmEdit(this.inputText)
                                                    this.setComposerText(this.composeTextBeforeEdit)
                                                    this.composeTextBeforeEdit = ""
                                                } else {
                                                    this.sendMessageWithFormat()
                                                }
                                            }
                                        })
                                }
                            }
                            .width(100.percent)
                            .height(58)
                            .padding(left: 8, right: 8, top: 8, bottom: 8)
                            .alignItems(VerticalAlign.Center)
                        }

                        // WP-D (S2-18/19/24)：iOS 编辑菜单的 Format 子菜单。系统选区菜单
                        //（剪切/复制/粘贴/全选…）仍浮在输入框上方不动；本条在选区存在时
                        // 贴在输入栏下方，Format → Quote/Spoiler/Bold/Italic/Monospace/Link/
                        // Strikethrough/Underline/Code（ChatTextInputPanelNode.swift:5095-5152 顺序）。
                        if (this.composerFormatBarVisible && !this.voiceRecording) {
                            this.composerFormatBar()
                        }

                        // 与 iOS ChatEntityKeyboardInputNode 一致：实体键盘是输入区的一部分，
                        // 出现时压缩消息列表并把输入栏顶起，而不是盖在聊天页上的半屏弹窗。
                        //
                        // ⚠️ 不要在这里给这段子树再包一层 Stack 去做 iOS 那种浮动底栏：
                        // 试过抽成独立组件 EntityKeyboardHost + Stack，cjc 静默挂死（R-145）；
                        // 换成 .position() 移出布局流后编过了，但子组件收不到页签切换
                        // （调用点传的是函数返回值，见 auth/PhoneInputPage.cj:81 的实测记录），
                        // 贴纸面板整个点不开。浮动胶囊只是观感，代价远大于收益，已回退。
                        if (!USE_CUSTOM_KEYBOARD_CONTAINER && this.entityKeyboardVisible()) {
                            this.entityKeyboardBuilder()
                        }
                        // iOS ChatButtonKeyboardInputNode：回复键盘占据键盘区
                        if (this.botKeyboardShown && this.botKeyboardMessageId != 0 && !this.entityKeyboardVisible() &&
                            !this.voiceRecording) {
                            this.botReplyKeyboardPanel()
                        }
                    }
                    .width(100.percent)
                    }
                }
                .width(100.percent)
                .height(100.percent)
                // ArkTS shell 把壁纸扩展到系统栏下方；交互内容仍按真机
                // 36vp 状态栏 / 28vp 手势区避让，保持与改造前相同的像素位置。
                .padding(top: 36, bottom: this.rootBottomInsetVp())

                // ==================== 覆盖层：附件面板 ====================
                if (this.showAttachmentPanel) {
                    // iOS AttachmentController：底部锚定 sheet + 自带遮罩（组件内实现），
                    // 不再是悬在 55% 高度的浮层。
                    AttachmentPanel(
                        bottomInset: 28.0,
                        contentHeightVp: this.attachContentHeightVp(),
                        onGridGeometry: { x: Float64, y: Float64, w: Float64, h: Float64 =>
                            this.onAttachGridGeometry(x, y, w, h)
                        },
                        onTabChanged: { t: String => this.onAttachTabChanged(t) },
                        // iOS 对齐：普通用户私聊隐藏 Poll；群/频道/收藏夹(self)显示。
                        // iOS ChatControllerOpenAttachmentMenu.swift:185：私聊仅 Bot / 收藏夹可发投票
                        canSendPolls: this.viewModel.peerType != "user" || this.viewModel.chatId == this.viewModel.currentUserId ||
                            this.peerIsBotMirror,
                        // File 页签「Select from Gallery」：图片/视频按文件（不压缩）发送
                        onPickGalleryAsFile: { =>
                            this.closeAttachmentPanel()
                            this.pickGalleryAsFile()
                        },
                        // File 页签「Select from Files」：系统文档选择器，任意类型
                        onPickSystemFile: { =>
                            this.closeAttachmentPanel()
                            this.pickSystemFile()
                        },
                        // Audio 页签「Select from Files」：系统文档选择器，音频后缀
                        onPickAudioFile: { =>
                            this.closeAttachmentPanel()
                            this.pickAudioDocument()
                        },
                        // File/Audio 列表：按引用直接发送
                        onSendRecent: { item: AttachFileItem =>
                            this.closeAttachmentPanel()
                            this.viewModel.sendDocumentByReference(item.docId, item.accessHash, item.fileReference)
                        },
                        onSendLocation: { lat: Float64, lng: Float64, _name: String =>
                            this.closeAttachmentPanel()
                            this.viewModel.sendLocation(lat, lng)
                        },
                        onSendLiveLocation: { _lat: Float64, _lng: Float64, duration: Int64 =>
                            this.closeAttachmentPanel()
                            // 走 LiveLocationManagerViewModel：发送后注册 4s 广播会话（iOS liveLocationManager），
                            // 直接 sendLiveLocation 只发一次坐标、永不更新。
                            getLiveLocationManagerViewModel().startSharing(
                                this.viewModel.peerType, this.viewModel.chatId, period: Int32(duration))
                        },
                        onMapGeometry: { x: Float64, y: Float64, w: Float64, h: Float64, lat: Float64, lng: Float64 =>
                            this.onAttachMapGeometry(x, y, w, h, lat, lng)
                        },
                        onSendVenue: { v: VenueItemData =>
                            this.closeAttachmentPanel()
                            this.viewModel.sendVenue(v.latitude, v.longitude, v.title, v.address, v.provider, v.venueId, v.type_)
                        },
                        onSendContact: { c: ContactDisplayData =>
                            this.closeAttachmentPanel()
                            this.viewModel.sendContact(c.phone, c.firstName, c.lastName, "")
                        },
                        onClose: { =>
                            this.closeAttachmentPanel()
                        }
                    )
                    // 投票页签：ComposePollScreenComponent 在 pages 包，组件层不能反向依赖，
                    // 按占位块几何在同一 Stack 里叠放（与 ArkTS 图库网格同一思路）。
                    if (this.attachTab == "poll" && this.attachGridHPx > 0.0) {
                        Column {
                            ComposePollScreenComponent(
                                embedded: true,
                                onSendSuccess: { => this.closeAttachmentPanel() },
                                onCancel: { => this.closeAttachmentPanel() }
                            )
                        }
                        .width(100.percent)
                        .height(this.pxToVp(this.attachGridHPx))
                        .position(x: 0, y: this.pxToVp(this.attachGridYPx))
                        .backgroundColor(0xFFF2F2F7)
                        .clip(true)
                    }
                }

                // ==================== Fix1 覆盖层：联系人选择器 ====================
                if (this.showContactPicker) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ evt =>
                            this.showContactPicker = false
                        })

                    Column {
                        // 标题行
                        Row {
                            Text(trSource("Cancel"))
                                .fontSize(this.scaledFontSize(17))
                                .fontColor(0x0088CC)
                                .onClick({ evt =>
                                    this.showContactPicker = false
                                })
                            Blank()
                            Text("Send Contact")
                                .fontSize(this.scaledFontSize(17))
                                .fontWeight(FontWeight.Bold)
                            Blank()
                            Row {}.width(50)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        Divider().color(0xE5E5EA).strokeWidth(0.5)

                        if (this.contactPickerLoading) {
                            Column {
                                LoadingProgress()
                                    .width(36)
                                    .height(36)
                                    .color(0x0088CC)
                            }
                            .width(100.percent)
                            .height(120)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                        } else if (this.contactPickerList.isEmpty()) {
                            Text("No contacts")
                                .fontSize(this.scaledFontSize(15))
                                .fontColor(0x8E8E93)
                                .margin(top: 24, bottom: 24)
                        } else {
                            List(space: 0) {
                                ForEach(this.contactPickerList.toArray(), itemGenerator: { contact: ContactDisplayData, _idx: Int64 =>
                                    ListItem {
                                        Column {
                                            Row {
                                                Column {
                                                    Text(contact.getDisplayName())
                                                        .fontSize(this.scaledFontSize(16))
                                                        .fontColor(this.presentation.textColor)
                                                    Text(contact.phone)
                                                        .fontSize(this.scaledFontSize(13))
                                                        .fontColor(0x8E8E93)
                                                        .margin(top: 2)
                                                }
                                                .layoutWeight(1)
                                                .alignItems(HorizontalAlign.Start)
                                            }
                                            .width(100.percent)
                                            .height(56)
                                            .padding(left: 16, right: 16)
                                            .alignItems(VerticalAlign.Center)

                                            Divider().color(0xE5E5EA).strokeWidth(0.5).margin(left: 16)
                                        }
                                        .onClick({ evt =>
                                            this.showContactPicker = false
                                            this.viewModel.sendContact(contact.phone, contact.firstName, contact.lastName, "")
                                        })
                                    }
                                })
                            }
                            .layoutWeight(1)
                        }
                    }
                    .width(100.percent)
                    .height(60.percent)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(topLeft: 16, topRight: 16)
                    .position(x: 0, y: 40.percent)
                }

                // ==================== 覆盖层：PhotoPicker ====================
                if (this.showPhotoPicker) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ evt =>
                            this.showPhotoPicker = false
                        })
                    
                    Column {
                        PhotoPicker(
                            maxSelect: 1,  // 当前只支持单张发送
                            onSelect: { photos: ArrayList<SelectedPhoto> =>
                                this.showPhotoPicker = false
                                if (!photos.isEmpty()) {
                                    this.sendSelectedPhoto(photos[0])
                                }
                            },
                            onClose: { =>
                                this.showPhotoPicker = false
                            }
                        )
                    }
                    .width(100.percent)
                    .position(x: 0, y: 30.percent)
                }
                
                // ==================== P2-356: 覆盖层：剪贴板媒体粘贴预览发送 ====================
                // MediaPasteboardUIComponent.onConfirm 真接调用方：
                //   用户点击"发送"→ collectSelected() → onConfirm(selected) → viewModel.sendPasteboardMediaItems(items)
                //     → 逐项 readFile(uri) → sendPhoto/sendDocument
                if (this.showPastePreview) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ _evt =>
                            this.showPastePreview = false
                        })

                    Column {
                        MediaPasteboardUIComponent(
                            onConfirm: { items: ArrayList<PasteboardItem> =>
                                // P2-356: onConfirm 真接调用方 — 关闭面板并触发真实 enqueue 发送
                                this.showPastePreview = false
                                this.viewModel.sendPasteboardMediaItems(items)
                            },
                            onCancel: { =>
                                this.showPastePreview = false
                            }
                        )
                    }
                    .width(100.percent)
                    .position(x: 0, y: 30.percent)
                }

                // ==================== 覆盖层：VoiceRecorder ====================
                if (this.showVoiceRecorder) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ evt =>
                            this.showVoiceRecorder = false
                        })
                    
                    Column {
                        VoiceRecorder(
                            onComplete: { result: VoiceRecordResult =>
                                this.showVoiceRecorder = false
                                this.sendVoiceMessage(result)
                            },
                            onCancel: { =>
                                this.showVoiceRecorder = false
                            }
                        )
                    }
                    .width(100.percent)
                    .position(x: 0, y: 50.percent)
                }
                
                // ==================== 覆盖层：PollCreator (Phase I4) ====================
                if (this.showPollCreator) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ evt =>
                            this.showPollCreator = false
                        })

                    // Fix2: 呈现 quiz-capable 的 ComposePollScreenComponent 作全屏模态 overlay，
                    // 替换旧内联 3-选项 stub（无 quiz/anonymous/multiple 开关）。
                    // 该组件 send 走 ComposePollService.sendPoll，peer 经全局
                    // getSelectedChatId/PeerType 读取；openPollCreator() 已在呈现前用当前会话
                    // peer 重申这两个全局，保证发到当前会话。
                    Column {
                        ComposePollScreenComponent(
                            onSendSuccess: { =>
                                this.showPollCreator = false
                            },
                            onCancel: { =>
                                this.showPollCreator = false
                            }
                        )
                    }
                    .width(100.percent)
                    .height(100.percent)
                }

                // ==================== 覆盖层：LocationPicker (Phase LOC-4: 真实 GPS) ====================
                if (this.showLocationPicker) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ evt =>
                            this.showLocationPicker = false
                        })

                    Column {
                        LocationPicker(
                            onSendLocation: { lat: Float64, lng: Float64, name: String =>
                                this.showLocationPicker = false
                                Hilog.info(0, "CjTelegram", "[ChatRoomPage] LOC-4: Sending real GPS location")
                                this.viewModel.sendLocation(lat, lng)
                            },
                            onSendLiveLocation: { lat: Float64, lng: Float64, duration: Int64 =>
                                this.showLocationPicker = false
                                Hilog.info(0, "CjTelegram", "[ChatRoomPage] LOC-4: Sending real GPS live location")
                                getLiveLocationManagerViewModel().startSharing(
                                    this.viewModel.peerType, this.viewModel.chatId, period: Int32(duration))
                            },
                            onClose: { =>
                                this.showLocationPicker = false
                            }
                        )
                    }
                    .width(100.percent)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(topLeft: 16, topRight: 16)
                    .position(x: 0, y: 20.percent)
                }

                // ==================== 覆盖层：发送中指示器 ====================
                if (this.isSendingMedia) {
                    Column {
                        Column {
                            LoadingProgress()
                                .width(32)
                                .height(32)
                                .color(0xFFFFFF)
                            Text(this.uploadMediaLabel)
                                .fontSize(this.scaledFontSize(14))
                                .fontColor(0xFFFFFF)
                                .margin(top: 8)
                        }
                        .padding(16)
                        .backgroundColor(0xCC000000)
                        .borderRadius(12)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(Color.Transparent)
                    // S3-25: the indicator stays up for the whole upload (a 120 MB file = minutes) and this
                    // full-screen transparent Column swallowed every touch meanwhile, so the pending
                    // message could not be long-pressed for Cancel Sending. iOS has no modal here: the
                    // message row shows its own progress and stays interactive. No hitTestBehavior in the
                    // Cangjie bindings (D-149); enabled(false) is the project pattern for a see-through
                    // overlay (emojiEffectItems below).
                    .enabled(false)
                }
                
                // ==================== 覆盖层：视频下载中指示器 ====================
                if (this.isDownloadingVideo) {
                    Column {
                        Row {
                            Text("Downloading video...")
                                .fontSize(this.scaledFontSize(14))
                                .fontColor(0xFFFFFF)
                                .padding(left: 16, right: 16, top: 8, bottom: 8)
                        }
                        .backgroundColor(0x66000000)
                        .borderRadius(8)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                }
                

                ForEach(this.emojiEffectItems, itemGenerator: { effect: ChatEmojiEffectOverlayItem, _effectIndex: Int64 =>
                    Stack {
                        AnimatedEmojiEffectComponent(
                            documentId: effect.documentId,
                            displaySize: 336.0,
                            onComplete: { => this.removeEmojiEffect(effect.token) }
                        )
                    }
                        .id("animatedEmojiEffect_${effect.token}")
                        .width(336.0)
                        .height(336.0)
                        .enabled(false)
                        .position(x: effect.x, y: effect.y)
                }, keyGenerator: { effect: ChatEmojiEffectOverlayItem, _effectIndex: Int64 =>
                    effect.token.toString()
                })

                // The extracted context controller stays local to the visible
                // chat page and reuses the message renderer for visual parity.
                if (this.messageContextVisible) {
                    MessageContextOverlay(
                        message: this.messageContextMessage,
                        sourceY: this.messageContextSourceY,
                        targetY: this.messageContextTargetY,
                        sourceHeight: this.messageContextSourceHeight,
                        screenHeight: this.messageContextScreenHeight,
                        screenWidth: this.messageContextScreenWidth,
                        visibleTop: this.messageContextVisibleTop,
                        visibleBottom: this.messageContextVisibleBottom,
                        isSent: this.messageContextIsSent,
                        hasText: this.messageContextHasText,
                        hasMedia: this.messageContextHasMedia,
                        showTranslate: this.messageContextCanTranslate,
                        peerType: this.messageContextPeerType,
                        peerId: this.viewModel.chatId,
                        readStatsEnabled: this.messageContextReadStats,
                        readStatsSenderNames: this.messageContextSenderNames,
                        saveToneEnabled: this.messageContextSaveTone,
                        saveTitle: this.messageContextSaveTitle,
                        deleteTitle: this.messageContextDeleteTitle,
                        repliesTitle: this.messageContextRepliesTitle,
                        isPinned: this.messageContextIsPinned,
                        withWallpaper: this.chatWallpaperInfo.wallpaperType == WallpaperType.MultiColorGradient || this.chatWallpaperInfo.wallpaperType == WallpaperType.TwoColorGradient || this.chatWallpaperInfo.wallpaperType == WallpaperType.PatternWallpaper,
                        wallpaperGradientColors: this.chatWallpaperInfo.gradientColors,
                        dismissing: this.messageContextDismissing
                    )
                }

                // S2-37：贴纸长按预览（iOS PeekController 全屏覆盖层）。挂在页根 Stack 上、
                // 实体键盘之后 ⇒ 盖住面板页签条与输入栏；上下按 36/28vp 状态栏/手势带避让，
                // 菜单完整落在安全区内（R7V 之前画在面板内，菜单下半截被页签条和屏底压住）。
                if (this.stickerPreviewVisible) {
                    StickerPreviewOverlay(
                        sticker: this.stickerPreviewRequest.sticker,
                        isFavorite: this.stickerPreviewRequest.isFavorite,
                        isRecent: this.stickerPreviewRequest.isRecent,
                        canSendSilently: this.stickerPreviewRequest.canSendSilently,
                        screenHeightVp: this.messageContextScreenHeight,
                        topInsetVp: 36.0,
                        bottomInsetVp: 28.0,
                        onSend: this.stickerPreviewRequest.onSend,
                        onSendSilently: this.stickerPreviewRequest.onSendSilently,
                        onSchedule: this.stickerPreviewRequest.onSchedule,
                        onFavorite: this.stickerPreviewRequest.onFavorite,
                        onViewPack: this.stickerPreviewRequest.onViewPack,
                        onRemoveFromRecents: this.stickerPreviewRequest.onRemoveFromRecents,
                        onClose: this.stickerPreviewRequest.onClose
                    )
                }

                // P2-119: Link Copied 吐司提示（居中悬浮，2 秒后自动消失）
                if (this.linkCopiedToast) {
                    Row {
                        Text(trSource("Link copied to clipboard"))
                            .fontSize(this.scaledFontSize(14))
                            .fontColor(0xFFFFFF)
                            .padding(left: 16, right: 16)
                    }
                    .height(40)
                    .backgroundColor(0xCC000000)
                    .borderRadius(20)
                    .alignItems(VerticalAlign.Center)
                    .alignSelf(ItemAlign.Center)
                    .margin(bottom: 60)
                }

                // P2-119 r1: Report Done 吐司提示（举报提交成功，2 秒后自动消失）
                if (this.reportDoneToast) {
                    Row {
                        Text("Message reported")
                            .fontSize(this.scaledFontSize(14))
                            .fontColor(0xFFFFFF)
                            .padding(left: 16, right: 16)
                    }
                    .height(40)
                    .backgroundColor(0xCC000000)
                    .borderRadius(20)
                    .alignItems(VerticalAlign.Center)
                    .alignSelf(ItemAlign.Center)
                    .margin(bottom: 100)
                }

                // imgmenu 批次：媒体保存/复制结果吐司（Downloading… / Saved to Gallery /
                // Photo copied，同上方吐司惯例，autoClear 由 showMediaToast 控制）
                if (this.mediaActionToast.size > 0) {
                    Row {
                        Text(this.mediaActionToast)
                            .fontSize(this.scaledFontSize(14))
                            .fontColor(0xFFFFFF)
                            .padding(left: 16, right: 16)
                    }
                    .height(40)
                    .backgroundColor(0xCC000000)
                    .borderRadius(20)
                    .alignItems(VerticalAlign.Center)
                    .alignSelf(ItemAlign.Center)
                    .margin(bottom: 140)
                }

                // ==================== P2-116: 覆盖层：Reactor 列表 ====================
                if (this.showReactorList) {
                    buildReactorListOverlay()
                }

                // ==================== P2-118: 覆盖层：已读参与者列表 ====================
                if (this.showReadParticipants) {
                    buildReadParticipantsOverlay()
                }

                if (this.showSavedModeMenu) {
                    buildSavedModeMenu()
                }

                // ==================== 全屏覆盖：ImageViewer ====================
                // imgmenu 批次：接入转发/删除回调（查看器只上报意图，消息级业务在本页承接：
                // Forward → 既有 forward picker → messages.forwardMessages；
                // Delete → 确认弹窗 → viewModel.deleteMessage → messages.deleteMessages）
                if (this.showImageViewer) {
                    ImageViewer(
                        images: this.imageViewerImages,
                        initialIndex: this.imageViewerIndex,
                        onClose: { =>
                            this.showImageViewer = false
                        },
                        onForwardRequest: { msgId: Int64 =>
                            this.forwardFromImageViewer(msgId)
                        },
                        onDeleteRequest: { msgId: Int64 =>
                            this.confirmDeleteFromImageViewer(msgId)
                        }
                    )
                }
                
                // ==================== 全屏覆盖：VideoPlayer ====================
                if (this.showVideoPlayer) {
                    VideoPlayer(
                        video: this.videoPlayerData,
                        onClose: { =>
                            this.showVideoPlayer = false
                        }
                    )
                }
                
                // ==================== 覆盖层：FileBrowser（文件选择器） ====================
                if (this.showFileBrowser) {
                    // 半透明背景
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x80000000)
                        .onClick({ evt =>
                            this.showFileBrowser = false
                        })
                    
                    FileBrowser(
                        filesDir: getAppFilesDir(),
                        onSelect: { path: String, name: String, mime: String =>
                            this.showFileBrowser = false
                            // Phase P6-11: 视频消息（圆形）模式 → sendSelectedVideoNote
                            if (this._videoNoteMode && (mime.contains("video") || name.contains(".mp4") || name.contains(".mov"))) {
                                this._videoNoteMode = false
                                this._videoSelectMode = false
                                this.sendSelectedVideoNote(path, name)
                            // Phase P6-1: 视频选择模式 → sendSelectedVideo
                            } else if (this._videoSelectMode && (mime.contains("video") || name.contains(".mp4") || name.contains(".mov"))) {
                                this._videoSelectMode = false
                                this.sendSelectedVideo(path, name, mime)
                            } else {
                                this._videoSelectMode = false
                                this._videoNoteMode = false
                                this.sendSelectedFile(path, name, mime)
                            }
                        },
                        onClose: { =>
                            this.showFileBrowser = false
                            this._videoSelectMode = false
                            this._videoNoteMode = false
                        }
                    )
                }
                
                // ==================== S2-70: Schedule Message sheet ====================
                if (this.showScheduleSheet) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x66000000)
                        .onClick({ _evt => this.showScheduleSheet = false })
                    Column {
                        Blank()
                        Column {
                            Text(trOr("Conversation.ScheduleMessage.Title", "Schedule Message"))
                                .fontSize(this.scaledFontSize(17))
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.presentation.textColor)
                                .margin(top: 14, bottom: 4)
                            DateTimePicker(
                                initialUnixSec: this.scheduleSheetInitialSec,
                                mode: "datetime",
                                minUnixSec: DateTime.now().toUnixTimeStamp().toSeconds() + 60,
                                onConfirm: { picked: Int64 => this.confirmScheduleMessage(picked) },
                                onCancel: { => this.showScheduleSheet = false },
                                confirmLabel: { picked: Int64 => this.scheduleButtonLabel(picked) }
                            )
                        }
                        .width(100.percent)
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(16)
                        .padding(bottom: getSafeAreaBottom() + 8.0)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .justifyContent(FlexAlign.End)
                }

                // ==================== S5-04: Comments / Replies thread screen ====================
                if (this.showMessageThread) {
                    Column {
                        Row {
                            Text("‹ " + trOr("Common.Back", "Back"))
                                .fontSize(this.scaledFontSize(17))
                                .fontColor(0x0088CC)
                                .onClick({ _evt => this.showMessageThread = false })
                            Blank()
                            Text(this.threadTitle)
                                .fontSize(this.scaledFontSize(17))
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.presentation.textColor)
                            Blank()
                            Row {}.width(60)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 16, right: 16)
                        .margin(top: getSafeAreaTop())
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(this.presentation.cardColor)

                        List() {
                            ListItem {
                                Column {
                                    if (this.threadHasRoot) {
                                        MessageBubble(
                                            message: this.threadRoot,
                                            voicePlaybackEpoch: 0,
                                            isMultiSelectMode: true,
                                            peerType: this.viewModel.peerType,
                                            withWallpaper: false,
                                            wallpaperGradientColors: Array<UInt32>()
                                        )
                                    }
                                    Row {
                                        Text(if (this.threadLoading) { "" } else {
                                            if (this.threadMessages.isEmpty()) {
                                                trOr("Conversation.EmptyPlaceholder", "No messages here yet...")
                                            } else { this.threadTitle }
                                        })
                                            .fontSize(this.scaledFontSize(13))
                                            .fontColor(0x8E8E93)
                                            .padding(left: 12, right: 12, top: 4, bottom: 4)
                                            .backgroundColor(0xE8E6DF)
                                            .borderRadius(12)
                                    }
                                    .width(100.percent)
                                    .justifyContent(FlexAlign.Center)
                                    .margin(top: 8, bottom: 4)
                                }
                                .width(100.percent)
                            }
                            ForEach(this.threadMessages.toArray(), itemGenerator: { msg: Message, _idx: Int64 =>
                                ListItem {
                                    MessageBubble(
                                        message: msg,
                                        voicePlaybackEpoch: 0,
                                        isMultiSelectMode: true,
                                        peerType: this.viewModel.peerType,
                                        withWallpaper: false,
                                        wallpaperGradientColors: Array<UInt32>()
                                    )
                                }
                            }, keyGenerator: { msg: Message, _idx: Int64 => "thread_${msg.id}" })
                        }
                        .width(100.percent)
                        .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(this.presentation.backgroundColor)
                }

                // ==================== S2-70: Scheduled Messages screen ====================
                if (this.showScheduledMessages) {
                    Column {
                        Row {
                            Text("‹ " + trOr("Common.Back", "Back"))
                                .fontSize(this.scaledFontSize(17))
                                .fontColor(0x0088CC)
                                .onClick({ _evt => this.showScheduledMessages = false })
                            Blank()
                            Text(trOr("ScheduledMessages.Title", "Scheduled Messages"))
                                .fontSize(this.scaledFontSize(17))
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.presentation.textColor)
                            Blank()
                            Row {}.width(60)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 16, right: 16)
                        .margin(top: getSafeAreaTop())
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(this.presentation.cardColor)

                        if (this.scheduledMessages.isEmpty()) {
                            Column {
                                Blank()
                                Text(if (this.scheduledMessagesLoading) { "" } else {
                                    trOr("ScheduledMessages.EmptyPlaceholder", "No scheduled messages here yet...")
                                })
                                    .fontSize(this.scaledFontSize(15))
                                    .fontColor(0x8E8E93)
                                Blank()
                            }
                            .width(100.percent)
                            .layoutWeight(1)
                        } else {
                            List() {
                                ForEach(this.scheduledMessages.toArray(), itemGenerator: { msg: Message, _idx: Int64 =>
                                    ListItem {
                                        Column {
                                            Row {
                                                Text(this.scheduledDateLabel(msg))
                                                    .fontSize(this.scaledFontSize(13))
                                                    .fontColor(0x8E8E93)
                                                    .padding(left: 12, right: 12, top: 4, bottom: 4)
                                                    .backgroundColor(0xE8E6DF)
                                                    .borderRadius(12)
                                            }
                                            .width(100.percent)
                                            .justifyContent(FlexAlign.Center)
                                            .margin(top: 8, bottom: 4)
                                            MessageBubble(
                                                message: msg,
                                                voicePlaybackEpoch: 0,
                                                isMultiSelectMode: true,
                                                withWallpaper: false,
                                                wallpaperGradientColors: Array<UInt32>()
                                            )
                                        }
                                        .width(100.percent)
                                        .onClick({ _evt => this.openScheduledMessageActions(msg) })
                                    }
                                }, keyGenerator: { msg: Message, _idx: Int64 => "sched_${msg.id}_${msg.rawTimestamp}" })
                            }
                            .width(100.percent)
                            .layoutWeight(1)
                        }
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(this.presentation.backgroundColor)
                }

                // ==================== 覆盖层：Forward Target Picker (Phase P0-1) ====================
                if (this.showForwardPicker) {
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0x33000000)
                        .onClick({ evt =>
                            this.showForwardPicker = false
                            this.forwardSearchText = ""
                        })

                    Column {
                        // 标题行
                        Row {
                            Text(trSource("Cancel"))
                                .fontSize(this.scaledFontSize(17))
                                .fontColor(0x0088CC)
                                .onClick({ evt =>
                                    this.showForwardPicker = false
                                    this.forwardSearchText = ""
                                })
                            Blank()
                            Text("Forward to...")
                                .fontSize(this.scaledFontSize(17))
                                .fontWeight(FontWeight.Bold)
                            Blank()
                            Row {}.width(50)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)

                        // P2-115: 转发选项 — 隐藏发送者 / 隐藏 caption
                        Column {
                            Row {
                                Text("Hide Sender Name")
                                    .fontSize(this.scaledFontSize(15))
                                    .fontColor(this.presentation.textColor)
                                    .layoutWeight(1)
                                Toggle(ToggleType.Switch, isOn: this.forwardDropAuthor)
                                    .onChange({ isOn: Bool =>
                                        this.forwardDropAuthor = isOn
                                    })
                            }
                            .width(100.percent)
                            .height(44)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)

                            Row {
                                Text(trSource("Hide Captions"))
                                    .fontSize(this.scaledFontSize(15))
                                    .fontColor(this.presentation.textColor)
                                    .layoutWeight(1)
                                Toggle(ToggleType.Switch, isOn: this.forwardDropCaptions)
                                    .onChange({ isOn: Bool =>
                                        this.forwardDropCaptions = isOn
                                    })
                            }
                            .width(100.percent)
                            .height(44)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                        }
                        // F-3/RC-C: 转发选择器 "Hide Captions" 卡底，同一 token。
                        .backgroundColor(this.presentation.backgroundColor)
                        .borderRadius(10)
                        .margin(left: 16, right: 16, bottom: 8)

                        // 搜索框（P2-RETRO-w5-chatroom: 转发选择器 TextInput → SearchBar 原子）
                        // SearchBar 是 @Component，不能直接链内置属性（D-120），外包 Column 容器。
                        Column {
                            SearchBar(
                                loading: false,
                                backArrow: false,
                                text: this.forwardSearchText,
                                hint: "Search chats...",
                                onChange: { value: String =>
                                    this.forwardSearchText = value
                                }
                            )
                        }
                        .margin(left: 16, right: 16, bottom: 8)

                        // 对话列表
                        List(space: 0) {
                            ForEach(this.getFilteredForwardDialogs(), itemGenerator: { entry: ChatEntry, _idx: Int64 =>
                                ListItem {
                                    Row {
                                        // 头像圆形
                                        Column {
                                            Text(entry.chat.avatarText)
                                                .fontSize(this.scaledFontSize(16))
                                                .fontColor(0xFFFFFF)
                                                .fontWeight(FontWeight.Bold)
                                        }
                                        .width(44)
                                        .height(44)
                                        .borderRadius(22)
                                        .backgroundColor(entry.chat.avatarColor)
                                        .justifyContent(FlexAlign.Center)
                                        .alignItems(HorizontalAlign.Center)
                                        .margin(right: 12)

                                        // 名称 + 最后消息预览
                                        Column {
                                            Text(entry.chat.name)
                                                .fontSize(this.scaledFontSize(16))
                                                .fontWeight(FontWeight.Medium)
                                                .fontColor(this.presentation.textColor)
                                                .maxLines(1)
                                            if (entry.chat.lastMessage.size > 0) {
                                                Text(entry.chat.lastMessage)
                                                    .fontSize(this.scaledFontSize(13))
                                                    .fontColor(0x8E8E93)
                                                    .maxLines(1)
                                                    .margin(top: 2)
                                            }
                                        }
                                        .alignItems(HorizontalAlign.Start)
                                        .layoutWeight(1)
                                    }
                                    .width(100.percent)
                                    .padding(left: 16, right: 16, top: 10, bottom: 10)
                                    .onClick({ evt =>
                                        this.executeForward(entry.chat)
                                    })
                                }
                            })
                        }
                        .layoutWeight(1)
                        .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 72, endMargin: 0))
                    }
                    .width(100.percent)
                    .height(80.percent)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(topLeft: 16, topRight: 16)
                    .position(x: 0, y: 20.percent)
                }
                if (this.showJoinInviteDialog) { this.joinInviteDialog() }
                if (this.showNewContactSheet) { this.newContactSheet() }
                if (this.showBlockPeerSheet) { this.blockPeerSheet() }
                if (this.showComposerLinkSheet) { this.composerLinkSheet() }
            }
            .width(100.percent)
            .height(100.percent)
            .id(CHAT_ROOM_ROOT_ID)
            .onAreaChange({ _: Area, newArea: Area =>
                this.messageContextScreenWidth = newArea.width.value
                this.messageContextScreenHeight = newArea.height.value
            })
            .onAppear({ => this.handleAppear() })
            .onDisAppear({ => this.cleanup() })
            // 定时发送的时间选择器。用 bindSheet 而不是手搓覆盖层：
            // DateTimePicker 自己不画背景，裸放在 Stack 上会让底下的消息气泡透出来
            // （实测就是这个效果）。bindSheet 自带背景板与模态语义，
            // 与 AutoNightSettingsPage 里既有的用法一致。
            .bindSheet(
                this.showSchedulePicker,
                this.buildSchedulePickerSheet,
                options: SheetOptions(onDisappear: { => launch { this.showSchedulePicker = false } })
            )
    }

    @Builder
    func buildSchedulePickerSheet() {
        DateTimePicker(
            initialUnixSec: this.scheduleInitialUnix,
            mode: "datetime",
            onConfirm: { picked: Int64 => this.confirmSchedule(picked) },
            onCancel: { => this.showSchedulePicker = false }
        )
    }

    // ==================== 消息发送 ====================

    // ==================== WP-D: RichEditor 输入框（S2-18 / S2-19 / S2-24） ====================

    /** RichEditorController 没有 stopEditing：把焦点移到不可见哨兵即 blur，IME 随之收起。 */
    private func blurComposer(): Unit {
        this.hideComposerFormatBar()
        let _ = FocusControl.requestFocus(CHAT_FOCUS_SINK_ID)
    }

    private func composerBaseStyle(): RichEditorTextStyle {
        return RichEditorTextStyle(fontColor: this.presentation.textColor, fontSize: COMPOSER_FONT_SIZE)
    }

    /** 编辑器当前纯文本（各文本 span 的 value 顺序拼接）。 */
    private func composerPlainText(): String {
        let sb = StringBuilder()
        try {
            for (span in this.chatRichController.getSpans()) {
                match (span) {
                    case t: RichEditorTextSpanResult => sb.append(t.value)
                    case _ => ()
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Composer] getSpans failed: ${e}")
        }
        return sb.toString()
    }

    /** 程序化整体改写输入框文本（草稿恢复 / 编辑态 / 提及替换 / 发送后清空）。样式与链接、引用记录随之清零。 */
    private func setComposerText(value: String): Unit {
        this.inputText = value
        this.composerLinkUrls = HashMap<String, String>()
        this.composerQuotes = ArrayList<String>()
        this.hideComposerFormatBar()
        this.composerNeedsBaseStyle = value.isEmpty()
        this.composerSyncSuppressed = true
        try {
            this.chatRichController.deleteSpans()
            if (!value.isEmpty()) {
                let _ = this.chatRichController.addTextSpan(content: value,
                    options: RichEditorTextSpanOptions(style: this.composerBaseStyle()))
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Composer] setText failed: ${e}")
        }
        this.composerSyncSuppressed = false
    }

    /** 在文本末尾追加（表情面板 / 自定义表情占位 / 工具条标记），既有样式 span 不动。 */
    private func appendComposerText(value: String): Unit {
        if (value.isEmpty()) { return }
        this.inputText = this.inputText + value
        this.hideComposerFormatBar()
        this.composerSyncSuppressed = true
        try {
            let _ = this.chatRichController.addTextSpan(content: value,
                options: RichEditorTextSpanOptions(style: this.composerBaseStyle()))
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Composer] append failed: ${e}")
        }
        this.composerSyncSuppressed = false
        this.composerNeedsBaseStyle = false
    }

    /** 编辑器内容变化 → 回灌 inputText（原 TextInput.onChange 的两个消费方原样保留）。 */
    private func syncComposerFromEditor(): Unit {
        if (this.composerSyncSuppressed) { return }
        let text = this.composerPlainText()
        if (text.isEmpty()) { this.composerNeedsBaseStyle = true }
        if (this.composerFormatBarVisible) { this.hideComposerFormatBar() }
        if (text == this.inputText) { return }
        this.updateInputText(text)
        this.contextQueryVM.onInputChanged(text)
    }

    /** 控制器挂上后把已恢复的草稿 / 语音条替换期间保留的文本写回编辑器。 */
    private func onComposerReady(): Unit {
        this.composerNeedsBaseStyle = this.inputText.isEmpty()
        if (this.inputText.isEmpty()) { return }
        let text = this.inputText
        if (this.composerPlainText() == text) { return }
        this.composerSyncSuppressed = true
        try {
            this.chatRichController.deleteSpans()
            let _ = this.chatRichController.addTextSpan(content: text,
                options: RichEditorTextSpanOptions(style: this.composerBaseStyle()))
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Composer] ready restore failed: ${e}")
        }
        this.composerSyncSuppressed = false
        Hilog.info(0, "CjTelegram", "[Composer] ready restored ${text.size} bytes")
    }

    /** IME 落字：空编辑器里首次输入继承系统默认样式（深色态近黑不可读），补成主题文本色。 */
    private func onComposerImeComplete(result: RichEditorTextSpanResult): Unit {
        if (this.composerNeedsBaseStyle) {
            this.composerNeedsBaseStyle = false
            match (result.spanPosition.spanRange) {
                case Some(range) =>
                    let (spanStart, _spanEnd) = range
                    let (a, b) = result.offsetInSpan
                    let start = spanStart + a
                    let end = spanStart + b
                    if (end > start) {
                        try {
                            this.chatRichController.updateSpanStyle(start: start, end: end,
                                textStyle: this.composerBaseStyle())
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[Composer] base style failed: ${e}")
                        }
                    }
                case None => ()
            }
        }
        this.syncComposerFromEditor()
    }

    private func onComposerSelect(sel: RichEditorSelection): Unit {
        let (start, end) = sel.selection
        if (end <= start) { return }
        this.composerSelStart = start
        this.composerSelEnd = end
        if (!this.composerFormatBarVisible) {
            this.composerFormatBarVisible = true
            this.composerFormatSubmenuOpen = false
        }
        Hilog.info(0, "CjTelegram", "[Composer] select ${start}..${end}")
    }

    private func hideComposerFormatBar(): Unit {
        this.composerFormatBarVisible = false
        this.composerFormatSubmenuOpen = false
    }

    /** RichEditor 偏移单位实测判定：末 span 的 spanRange 终点等于 UTF-16 总长即 UTF-16，否则按码点。 */
    private func composerEditorUsesUtf16(): Bool {
        var runeTotal: Int32 = 0
        var utf16Total: Int32 = 0
        var lastEnd: Int32 = -1
        try {
            for (span in this.chatRichController.getSpans()) {
                match (span) {
                    case t: RichEditorTextSpanResult =>
                        runeTotal = runeTotal + Int32(t.value.toRuneArray().size)
                        utf16Total = utf16Total + telegramUtf16Length(t.value)
                        match (t.spanPosition.spanRange) {
                            case Some(range) =>
                                let (_s, e) = range
                                lastEnd = e
                            case None => ()
                        }
                    case _ => ()
                }
            }
        } catch (_e: Exception) {}
        if (runeTotal == utf16Total) { return true }
        return lastEnd == utf16Total
    }

    /** 按编辑器偏移单位截取 [start, end) 的文本。 */
    private func composerSlice(text: String, start: Int32, end: Int32): String {
        let utf16 = this.composerEditorUsesUtf16()
        let sb = StringBuilder()
        var pos: Int32 = 0
        for (r in text.toRuneArray()) {
            let w: Int32 = if (utf16 && UInt32(r) > 0xffff) { 2 } else { 1 }
            if (pos >= start && pos < end) { sb.append(r.toString()) }
            pos = pos + w
        }
        return sb.toString()
    }

    private func composerSelectedText(): String {
        return this.composerSlice(this.composerPlainText(), this.composerSelStart, this.composerSelEnd)
    }

    /**
     * 对选区内每个文本 span 的重叠部分整体重写样式（读回现有样式 → mutate → 全字段写回），
     * 不依赖 updateSpanStyle 对未设字段的语义。
     */
    private func composerRewriteRange(start: Int32, end: Int32, mutate: (ComposerSpanStyle) -> Unit): Unit {
        let base = this.presentation.textColor
        try {
            for (span in this.chatRichController.getSpans(start: start, end: end)) {
                match (span) {
                    case t: RichEditorTextSpanResult =>
                        var spanStart: Int32 = 0
                        match (t.spanPosition.spanRange) {
                            case Some(range) =>
                                let (s0, _e0) = range
                                spanStart = s0
                            case None => ()
                        }
                        let (a, b) = t.offsetInSpan
                        var from = spanStart + a
                        var to = spanStart + b
                        if (from < start) { from = start }
                        if (to > end) { to = end }
                        if (to <= from) { continue }
                        let style = ComposerSpanStyle.fromResult(t.textStyle)
                        mutate(style)
                        this.chatRichController.updateSpanStyle(start: from, end: to, textStyle: style.toRichStyle(base))
                    case _ => ()
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Composer] rewrite ${start}..${end} failed: ${e}")
        }
    }

    /** 选区内所有文本 span 都已带该格式 → 与 iOS 一致按“取消”处理。 */
    private func composerRangeHas(start: Int32, end: Int32, kind: String): Bool {
        var seen = false
        var all = true
        try {
            for (span in this.chatRichController.getSpans(start: start, end: end)) {
                match (span) {
                    case t: RichEditorTextSpanResult =>
                        seen = true
                        if (!ComposerSpanStyle.fromResult(t.textStyle).has(kind)) { all = false }
                    case _ => ()
                }
            }
        } catch (_e: Exception) {}
        return seen && all
    }

    /** Format 子菜单项（iOS formatAttributesBold/Italic/... 的 toggle 语义）。 */
    private func applyComposerFormat(kind: String): Unit {
        let start = this.composerSelStart
        let end = this.composerSelEnd
        if (end <= start) {
            this.hideComposerFormatBar()
            return
        }
        Hilog.info(0, "CjTelegram", "[Composer] format kind=${kind} range=${start}..${end}")
        if (kind == "link") {
            this.openComposerLinkSheet()
            return
        }
        if (kind == "quote") {
            this.toggleComposerQuote(start, end)
        } else {
            let remove = this.composerRangeHas(start, end, kind)
            let baseKey = ""
            this.composerRewriteRange(start, end, { st: ComposerSpanStyle =>
                match (kind) {
                    case "bold" => st.bold = !remove
                    case "italic" => st.italic = !remove
                    case "underline" =>
                        st.underline = !remove
                        if (!remove) { st.strike = false }
                    case "strike" =>
                        st.strike = !remove
                        if (!remove) { st.underline = false }
                    case "spoiler" =>
                        st.colorKey = if (remove) { baseKey } else { composerHex6(COMPOSER_SPOILER_COLOR) }
                    case "code" =>
                        st.mono = !remove
                        st.colorKey = if (remove) { baseKey } else { composerHex6(COMPOSER_CODE_COLOR) }
                    case "pre" =>
                        st.mono = !remove
                        st.colorKey = if (remove) { baseKey } else { composerHex6(COMPOSER_PRE_COLOR) }
                    case _ => ()
                }
            })
            Hilog.info(0, "CjTelegram", "[Composer] format applied kind=${kind} remove=${remove}")
        }
        this.hideComposerFormatBar()
        try { this.chatRichController.closeSelectionMenu() } catch (_e: Exception) {}
    }

    /** Quote：段落缩进作视觉提示，引用文本按内容记录，发送时匹配成 messageEntityBlockquote。 */
    private func toggleComposerQuote(start: Int32, end: Int32): Unit {
        let quoted = this.composerSelectedText()
        if (quoted.isEmpty()) { return }
        var existing = false
        for (q in this.composerQuotes) { if (q == quoted) { existing = true } }
        let kept = ArrayList<String>()
        for (q in this.composerQuotes) { if (q != quoted) { kept.add(q) } }
        if (!existing) { kept.add(quoted) }
        this.composerQuotes = kept
        try {
            this.chatRichController.updateParagraphStyle(start: start, end: end,
                style: RichEditorParagraphStyle(leadingMargin: if (existing) { 0 } else { 14 }))
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Composer] quote paragraph style failed: ${e}")
        }
        let verb = if (existing) { "removed" } else { "added" }
        Hilog.info(0, "CjTelegram", "[Composer] quote ${verb} '${quoted}'")
    }

    /** iOS TextFormat.AddLinkTitle / EditLinkTitle：Link 项打开 URL 输入弹层。 */
    private func openComposerLinkSheet(): Unit {
        let selected = this.composerSelectedText()
        if (selected.isEmpty()) {
            this.hideComposerFormatBar()
            return
        }
        this.composerLinkText = selected
        var initial = ""
        match (this.composerLinkUrls.get(selected)) {
            case Some(url) => initial = url
            case None => ()
        }
        this.composerLinkEditing = initial.size > 0
        this.composerLinkUrlInput = initial
        this.composerLinkError = false
        this.showComposerLinkSheet = true
        Hilog.info(0, "CjTelegram", "[Composer] link sheet text='${selected}' edit=${this.composerLinkEditing}")
    }

    private func confirmComposerLink(): Unit {
        let svc = getChatTextLinkEditService()
        let raw = this.composerLinkUrlInput.trimAscii()
        let start = this.composerSelStart
        let end = this.composerSelEnd
        let text = this.composerLinkText
        if (raw.isEmpty()) {
            // 与 iOS apply("") 一致：空 URL 表示移除链接
            let _ = this.composerLinkUrls.remove(text)
            this.composerRewriteRange(start, end, { st: ComposerSpanStyle =>
                st.colorKey = ""
                st.underline = false
            })
            Hilog.info(0, "CjTelegram", "[Composer] link removed '${text}'")
        } else {
            let normalized = svc.normalizeUrl(raw)
            if (!svc.isValidLinkUrl(normalized)) {
                this.composerLinkError = true
                Hilog.info(0, "CjTelegram", "[Composer] link rejected '${raw}'")
                return
            }
            this.composerLinkUrls[text] = normalized
            this.composerRewriteRange(start, end, { st: ComposerSpanStyle =>
                st.colorKey = composerHex6(COMPOSER_LINK_COLOR)
                st.underline = true
                st.strike = false
            })
            Hilog.info(0, "CjTelegram", "[Composer] link applied '${text}' -> ${normalized}")
        }
        this.showComposerLinkSheet = false
        this.hideComposerFormatBar()
        try { this.chatRichController.closeSelectionMenu() } catch (_e: Exception) {}
    }

    private func addComposerFormatEntity(list: ArrayList<DraftFormatEntity>, kind: String,
        runeStart: Int32, runeEnd: Int32, utf16Start: Int32, utf16End: Int32, url: String): Unit {
        if (runeEnd <= runeStart) { return }
        // 相邻同类实体合并（iOS 的 attributed string 同一属性连续 run 只产一个实体）
        if (list.size > 0) {
            let last = list[list.size - 1]
            if (last.entityType == kind && last.url == url &&
                last.runeOffset + last.runeLength == runeStart) {
                last.runeLength = runeEnd - last.runeOffset
                last.utf16Length = utf16End - last.utf16Offset
                return
            }
        }
        let e = DraftFormatEntity()
        e.entityType = kind
        e.runeOffset = runeStart
        e.runeLength = runeEnd - runeStart
        e.utf16Offset = utf16Start
        e.utf16Length = utf16End - utf16Start
        e.url = url
        list.add(e)
    }

    /**
     * 发送前从 RichEditor span 抽取格式实体：offset 用码点（本地气泡）与 UTF-16（TL）两套口径，
     * 由本函数按 span 文本自行累计，不依赖编辑器的偏移单位。
     */
    private func collectComposerFormatEntities(): ArrayList<DraftFormatEntity> {
        let result = ArrayList<DraftFormatEntity>()
        var runePos: Int32 = 0
        var utf16Pos: Int32 = 0
        let kinds = ["bold", "italic", "underline", "strike", "code", "pre", "spoiler", "textUrl"]
        let perKind = HashMap<String, ArrayList<DraftFormatEntity>>()
        for (k in kinds) { perKind[k] = ArrayList<DraftFormatEntity>() }
        var spanCount = 0
        try {
            for (span in this.chatRichController.getSpans()) {
                match (span) {
                    case t: RichEditorTextSpanResult =>
                        spanCount = spanCount + 1
                        let runeLen = Int32(t.value.toRuneArray().size)
                        let utf16Len = telegramUtf16Length(t.value)
                        let style = ComposerSpanStyle.fromResult(t.textStyle)
                        for (k in kinds) {
                            if (style.has(k)) {
                                var url = ""
                                if (k == "textUrl") {
                                    match (this.composerLinkUrls.get(t.value)) {
                                        case Some(u) => url = u
                                        case None => ()
                                    }
                                    if (url.isEmpty()) { continue }
                                }
                                this.addComposerFormatEntity(perKind[k], k, runePos, runePos + runeLen,
                                    utf16Pos, utf16Pos + utf16Len, url)
                            }
                        }
                        runePos = runePos + runeLen
                        utf16Pos = utf16Pos + utf16Len
                    case _ => ()
                }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[Composer] collect entities failed: ${e}")
        }
        for (k in kinds) {
            for (e in perKind[k]) { result.add(e) }
        }
        // Quote：按记录的文本在最终内容里定位
        if (this.composerQuotes.size > 0) {
            let text = this.inputText
            let runes = text.toRuneArray()
            for (q in this.composerQuotes) {
                let qRunes = q.toRuneArray()
                if (qRunes.size == 0 || qRunes.size > runes.size) { continue }
                var found: Int64 = -1
                var i: Int64 = 0
                while (i + qRunes.size <= runes.size && found < 0) {
                    var ok = true
                    var j: Int64 = 0
                    while (j < qRunes.size) {
                        if (runes[i + j] != qRunes[j]) {
                            ok = false
                            break
                        }
                        j = j + 1
                    }
                    if (ok) { found = i }
                    i = i + 1
                }
                if (found < 0) { continue }
                var prefix = ""
                var p: Int64 = 0
                while (p < found) {
                    prefix = prefix + runes[p].toString()
                    p = p + 1
                }
                let e = DraftFormatEntity()
                e.entityType = "blockquote"
                e.runeOffset = Int32(found)
                e.runeLength = Int32(qRunes.size)
                e.utf16Offset = telegramUtf16Length(prefix)
                e.utf16Length = telegramUtf16Length(q)
                result.add(e)
            }
        }
        if (result.size > 0 || spanCount > 1) {
            Hilog.info(0, "CjTelegram", "[Composer] entities=${result.size} spans=${spanCount}")
            for (e in result) {
                Hilog.info(0, "CjTelegram", "[Composer] entity ${e.entityType} rune=${e.runeOffset}+${e.runeLength} utf16=${e.utf16Offset}+${e.utf16Length}")
            }
        }
        return result
    }

    @Builder
    func composerFormatChip(title: String, kind: String) {
        Text(title)
            .fontSize(15)
            .fontColor(0xFF007AFF)
            .height(32)
            .padding(left: 12, right: 12)
            .borderRadius(16)
            .backgroundColor(this.presentation.backgroundColor)
            .margin(right: 8)
            .onClick({ _evt => this.applyComposerFormat(kind) })
    }

    @Builder
    func composerFormatBar() {
        Row {
            if (!this.composerFormatSubmenuOpen) {
                Text(trOr("TextFormat.Format", "Format"))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFF007AFF)
                    .height(32)
                    .padding(left: 14, right: 14)
                    .borderRadius(16)
                    .backgroundColor(this.presentation.backgroundColor)
                    .onClick({ _evt =>
                        Hilog.info(0, "CjTelegram", "[Composer] format menu open")
                        this.composerFormatSubmenuOpen = true
                    })
                Blank()
                Image(@r(app.media.chatroom_ic_close))
                    .width(14)
                    .height(14)
                    .fillColor(0x8E8E93)
                    .padding(8)
                    .onClick({ _evt => this.hideComposerFormatBar() })
            } else {
                Scroll {
                    Row {
                        this.composerFormatChip(trOr("TextFormat.Quote", "Quote"), "quote")
                        this.composerFormatChip(trOr("TextFormat.Spoiler", "Spoiler"), "spoiler")
                        this.composerFormatChip(trOr("TextFormat.Bold", "Bold"), "bold")
                        this.composerFormatChip(trOr("TextFormat.Italic", "Italic"), "italic")
                        this.composerFormatChip(trOr("TextFormat.Monospace", "Monospace"), "code")
                        this.composerFormatChip(trOr("TextFormat.Link", "Link"), "link")
                        this.composerFormatChip(trOr("TextFormat.Strikethrough", "Strikethrough"), "strike")
                        this.composerFormatChip(trOr("TextFormat.Underline", "Underline"), "underline")
                        this.composerFormatChip(trOr("TextFormat.Code", "Code"), "pre")
                    }
                    .alignItems(VerticalAlign.Center)
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .layoutWeight(1)
                .height(44)
            }
        }
        .width(100.percent)
        .height(44)
        .padding(left: 12, right: 8)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.presentation.cardColor)
    }

    /** iOS chatTextLinkEditController：Add Link / Edit Link，URL 字段，Cancel / Done。 */
    @Builder
    func composerLinkSheet() {
        Stack(alignContent: Alignment.Center) {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0x66000000)
                .onClick({ _evt => this.showComposerLinkSheet = false })
            Column {
                Text(if (this.composerLinkEditing) {
                    trOr("TextFormat.EditLinkTitle", "Edit Link")
                } else {
                    trOr("TextFormat.AddLinkTitle", "Add Link")
                })
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                    .margin(top: 18, bottom: 8)
                Text(trOr("TextFormat.AddLinkText", "The link will be displayed as \"%@\".").replace("%@", this.composerLinkText))
                    .fontSize(13)
                    .fontColor(this.presentation.secondaryTextColor)
                    .textAlign(TextAlign.Center)
                    .padding(left: 16, right: 16)
                    .margin(bottom: 12)
                TextInput(text: this.composerLinkUrlInput, placeholder: trOr("TextFormat.AddLinkPlaceholder", "URL"))
                    .width(100.percent)
                    .height(40)
                    .fontSize(15)
                    .fontColor(this.presentation.textColor)
                    .backgroundColor(this.presentation.backgroundColor)
                    .borderRadius(8)
                    .borderWidth(if (this.composerLinkError) { 1 } else { 0 })
                    .borderColor(0xFFFF3B30)
                    .onChange({ value: String =>
                        this.composerLinkUrlInput = value
                        this.composerLinkError = false
                    })
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .height(44)
                        .onClick({ _evt => this.showComposerLinkSheet = false })
                    Text(trSource("Done"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .height(44)
                        .onClick({ _evt => this.confirmComposerLink() })
                }
                .width(100.percent)
                .margin(top: 12)
            }
            .width(84.percent)
            .padding(left: 16, right: 16, bottom: 4)
            .backgroundColor(this.presentation.cardColor)
            .borderRadius(14)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
    }

    private func updateInputText(value: String): Unit {
        // 尾部继续输入不会改变既有 entity 坐标；任意中间编辑先清空 span，避免把
        // document_id 绑定到错误文本。后续 RichEditor 会提供逐 span 编辑映射。
        if (!value.startsWith(this.inputText)) {
            this.customEmojiDraftEntities.clear()
        }
        this.inputText = value
    }

    private func appendCustomEmoji(item: StickerItem): Unit {
        if (item.documentId == 0) { return }
        let alt = if (item.altEmoji.isEmpty()) { "\u{fffc}" } else { item.altEmoji }
        let entity = CustomEmojiDraftEntity()
        entity.runeOffset = Int32(this.inputText.toRuneArray().size)
        entity.runeLength = Int32(alt.toRuneArray().size)
        entity.utf16Offset = telegramUtf16Length(this.inputText)
        entity.utf16Length = telegramUtf16Length(alt)
        entity.documentId = item.documentId
        entity.alt = alt
        this.customEmojiDraftEntities.add(entity)
        this.appendComposerText(alt)
    }

    // Source ChatControllerNode.swift:831/2107/3556 also gates on
    // presentationData.reduceMotion. This project has no reduce-motion
    // setting surface (repo-wide zero hits), so only the existing
    // fullTranslucency gate is wired. Do not invent a reduce-motion switch.
    private func gradientAnimationAllowed(): Bool {
        return getTelegramCoreSettingsService().getPsFullTranslucency()
    }

    private func advanceChatGradientPhase(): Unit {
        if (!this.gradientAnimationAllowed()) {
            return
        }
        if (this.chatWallpaperInfo.wallpaperType.ordinal() != 3 &&
            this.chatWallpaperInfo.wallpaperType.ordinal() != 4) {
            return
        }
        this.chatWallpaperInfo.phase = advanceSharedGradientPhase()
        this.wpPhaseMirror = this.chatWallpaperInfo.phase
    }

    func sendMessage(): Unit {
        let content = this.inputText
        let formatEntities = this.collectComposerFormatEntities()
        if (this.customEmojiDraftEntities.isEmpty()) {
            this.viewModel.sendMessage(content, formatEntities: formatEntities)
        } else {
            this.viewModel.sendMessageWithCustomEmojiEntities(
                content, this.customEmojiDraftEntities, formatEntities: formatEntities)
        }
        this.customEmojiDraftEntities = ArrayList<CustomEmojiDraftEntity>()
        this.setComposerText("")
        this.scrollToBottom()
        this.advanceChatGradientPhase()
    }

    /**
     * P2-120-②: 带格式实体的消息发送
     *
     * inputText 中含 markdown 标记（如 **bold**），由 ViewModel.sendMessage 内
     * parseMarkdown 解析后通过 sendMessageWithEntities 传给服务端。
     * 格式工具条状态在发送后清除。
     */
    func sendMessageWithFormat(silent!: Bool = false, scheduleDate!: Int32 = 0, effectId!: Int64 = 0): Unit {
        let content = this.inputText
        if (content.isEmpty()) { return }
        // S2-70: after a successful schedule iOS opens the Scheduled Messages screen
        // (ChatMessageDisplaySendMessageOptions.swift:285 openScheduledMessages).
        let onScheduled: Option<(Bool) -> Unit> = if (scheduleDate > 0) {
            Some({ ok: Bool =>
                launch {
                    if (ok) {
                        this.hasScheduledMessagesMirror = true
                        this.openScheduledMessages()
                    }
                }
            })
        } else { None }
        // WP-D: 从 RichEditor span 抽取 Format 菜单施加的实体（S2-18/19/24）。
        let formatEntities = this.collectComposerFormatEntities()
        if (this.customEmojiDraftEntities.isEmpty()) {
            let _ = this.viewModel.sendMessage(content, silent: silent, scheduleDate: scheduleDate,
                effectId: effectId, onScheduled: onScheduled, formatEntities: formatEntities)
        } else {
            let _ = this.viewModel.sendMessageWithCustomEmojiEntities(
                content, this.customEmojiDraftEntities, silent: silent, scheduleDate: scheduleDate,
                effectId: effectId, onScheduled: onScheduled, formatEntities: formatEntities)
        }
        this.customEmojiDraftEntities = ArrayList<CustomEmojiDraftEntity>()
        this.setComposerText("")
        // 清除格式工具条状态
        this.showFormatBar = false
        // 清除联想补全状态
        this.contextQueryVM.clearSuggestions()
        // 检查慢速模式 — 若 slowmodeTimeoutSeconds > 0，启动倒计时
        if (this.viewModel.slowmodeTimeoutSeconds > 0) {
            let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
            let nextAllow = nowSec + Int64(this.viewModel.slowmodeTimeoutSeconds)
            launch { this.viewModel.slowmodeNextSendTimestamp = nextAllow }
            this.startSlowmodeCountdown()
        }
        this.scrollToBottom()
        this.advanceChatGradientPhase()
    }

    /**
     * P2-120-④: 启动慢速模式倒计时显示（每秒更新一次 slowmodeCountdownText）
     *
     * 倒计时在后台 spawn 中循环，直到 slowmodeNextSendTimestamp 过期。
     * 通过 slowmodeCountdownText 字段驱动 UI 刷新。
     */
    func startSlowmodeCountdown(): Unit {
        spawn {
            var remaining: Int64 = Int64(this.viewModel.slowmodeTimeoutSeconds)
            while (remaining > 0) {
                let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
                let diff = this.viewModel.slowmodeNextSendTimestamp - nowSec
                if (diff <= 0) {
                    launch {
                        this.slowmodeCountdownText = ""
                        this.viewModel.slowmodeNextSendTimestamp = 0
                    }
                    break
                }
                let displaySec = diff
                launch { this.slowmodeCountdownText = "${displaySec}s" }
                sleep(Duration.millisecond * 1000)
                remaining = diff - 1
            }
            launch { this.slowmodeCountdownText = "" }
        }
    }

    /**
     * 对齐 iOS scrollToEndOfHistory()：若当前位置的 history window 尚未抵达
     * upperBound，先直接换成最新窗口，再滚到末项；无需逐页填满 newer hole。
     */
    private func navigateToLatest(): Unit {
        this.pendingNewCount = 0
        // iOS scrollToEndOfHistory 之后列表处于 isScrollAtBottomPosition：
        // 发送/点下箭头后钉住最新端，新气泡落地与后续长高都贴底显示。
        this._pinnedToLatest = true
        if (this.viewModel.hasMoreNewer) {
            this.viewModel.loadLatestHistory()
            spawn {
                var waitCount: Int64 = 0
                while (this.viewModel.isLoadingNewer && waitCount < 100) {
                    sleep(Duration.millisecond * 50)
                    waitCount += 1
                }
                sleep(Duration.millisecond * 50)
                launch {
                    if (!this.viewModel.hasMoreNewer && this.displayMessages.size > 0) {
                        try {
                            this.listScroller.scrollToIndex(
                                Int32(this.displayMessages.size - 1),
                                smooth: false,
                                align: ScrollAlign.End)
                        } catch (_e: Exception) {}
                        this.showScrollToLatestButton = false
                    }
                }
            }
        } else if (this.displayMessages.size > 0) {
            try {
                this.listScroller.scrollToIndex(
                    Int32(this.displayMessages.size - 1),
                    smooth: true,
                    align: ScrollAlign.End)
            } catch (_e: Exception) {}
            this.showScrollToLatestButton = false
        }
    }

    func scrollToBottom(): Unit {
        this.navigateToLatest()
    }

    /**
     * 钉住最新端时的贴底请求（见 _pinnedToLatest）。由列表视口尺寸变化与气泡
     * 尺寸变化触发；同帧多次请求合并，推迟一帧让 List 完成本轮布局后再滚。
     */
    private func requestRepinToLatest(): Unit {
        if (!this._pinnedToLatest || this._repinScheduled) { return }
        this._repinScheduled = true
        let _ = spawn {
            sleep(Duration.millisecond * 16)
            launch {
                this._repinScheduled = false
                if (!this._pinnedToLatest || this.viewModel.hasMoreNewer) { return }
                let count = this.displayMessages.size
                if (count == 0) { return }
                try {
                    this.listScroller.scrollToIndex(Int32(count - 1), smooth: false, align: ScrollAlign.End)
                } catch (_e: Exception) {
                    try { this.listScroller.scrollEdge(Edge.Bottom) } catch (_e2: Exception) {}
                }
            }
        }
    }
    
    // ==================== Phase H1.5: 照片选择与发送 ====================
    
    /**
     * 发送选中的照片
     */
    func sendSelectedPhoto(photo: SelectedPhoto): Unit {
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Sending selected photo: ${photo.uri}")
        let capturedCaption = this.inputText
        this.isSendingMedia = true
        this.uploadMediaLabel = "Sending photo..."
        this.setComposerText("")
        spawn {
            try {
                var realPath = photo.uri
                if (realPath.startsWith("file://")) {
                    realPath = realPath[7..]
                }
                // iOS 发图默认按长边 1280 px 压成 JPEG（原图走"以文件发送"）；此前直接上传相册原图 2–3 MB
                var sendName = photo.fileName
                let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                let c = ImageCompressBridge.compress(realPath, 1280, 80)
                if (c.ok && c.path.size > 0) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] photo compressed → ${c.width}x${c.height} ${c.bytes}B in ${DateTime.now().toUnixTimeStamp().toMilliseconds() - t0}ms")
                    realPath = c.path
                    if (!sendName.toAsciiLower().endsWith(".jpg") && !sendName.toAsciiLower().endsWith(".jpeg")) {
                        sendName = sendName + ".jpg"
                    }
                }
                let photoData = readFileBytes(realPath)
                if (c.ok && c.path.size > 0) {
                    try { FileIo.unlink(c.path) } catch (_e: Exception) {}
                }
                if (photoData.size > 0) {
                    this.viewModel.sendPhoto(photoData, sendName, capturedCaption)
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Empty photo file")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] Send photo error: ${e}")
            }
            launch { this.isSendingMedia = false }
        }
    }

    /**
     * 系统相册选图发送（免权限）。
     * 反转链路: callArkAsync(PICK_PHOTO_ALBUM, {}) → PhotoPickerImpl.ets
     *   PhotoViewPicker.select(IMAGE) → 拷贝 URI 到 cacheDir → 回传沙箱 paths。
     * result: {"ok":bool, "status":"picked"|"cancelled"|"error", "paths":[...]}。
     * cancelled/error 优雅处理不崩；picked 时逐个 sendSelectedPhoto。
     */
    private func pickPhotoFromSystemAlbum(): Unit {
        callArkAsync(PICK_PHOTO_ALBUM, "{}", { res =>
            let ok = jsonBoolFieldPhoto(res, "ok")
            let status = jsonStringFieldPhoto(res, "status")
            if (!ok || status == "cancelled" || status == "error") {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] album pick ended: ok=${ok} status=${status}")
                return
            }
            let paths = jsonStringArrayFieldPhoto(res, "paths")
            if (paths.isEmpty()) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] album pick returned no paths")
                return
            }
            for (path in paths) {
                if (path.size == 0) { continue }
                var fileName = path
                match (path.lastIndexOf("/")) {
                    case Some(idx) => fileName = path[(idx + 1)..path.size]
                    case None => ()
                }
                let photo = SelectedPhoto(uri: path, fileName: fileName, fileSize: 0)
                launch { this.sendSelectedPhoto(photo) }
            }
        })
    }

    /** iOS openStickerEditor：选图后进入贴纸专用编辑器，而不是直接跳到建包页。 */
    private func openCustomStickerCreator(): Unit {
        callArkAsync(PICK_PHOTO_ALBUM, "{}", { res =>
            let ok = jsonBoolFieldPhoto(res, "ok")
            let status = jsonStringFieldPhoto(res, "status")
            if (!ok || status != "picked") {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] sticker photo pick ended status=${status}")
                return
            }
            let paths = jsonStringArrayFieldPhoto(res, "paths")
            if (paths.isEmpty() || paths[0].isEmpty()) { return }
            let sourcePath = paths[0]
            routerPush(
                "CustomStickerEditorPage",
                this.viewModel.peerType + "|" + this.viewModel.chatId.toString() + "|" + sourcePath)
        })
    }

    /**
     * Fix2: 打开 quiz-capable 的投票创建器（ComposePollScreenComponent overlay）。
     * 该组件内部通过全局 getSelectedChatId()/getSelectedChatPeerType() 读取目标 peer，
     * 呈现前用当前会话 viewModel 的 peer 重申这两个全局，避免全局状态漂移导致投票发错会话。
     */
    private func openPollCreator(): Unit {
        setSelectedChat(this.viewModel.chatId, this.viewModel.chatName, this.viewModel.peerType)
        this.showPollCreator = true
    }

    /**
     * Fix1: 打开联系人选择器并异步加载真实联系人列表
     * getContacts() 内部是阻塞式网络请求，必须放到 spawn 中执行。
     */
    private func openContactPicker(): Unit {
        this.showContactPicker = true
        this.contactPickerLoading = true
        spawn {
            try {
                let svc = getRealContactService()
                let contacts = svc.getContacts()
                launch {
                    this.contactPickerList = contacts
                    this.contactPickerLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] openContactPicker failed: ${e}")
                launch {
                    this.contactPickerLoading = false
                }
            }
        }
    }

    /**
     * Phase P6-1: 发送用户选择的视频文件
     * 使用 ChatRoomViewModel.sendVideo() → RealMessageService.sendVideo()
     */
    func sendSelectedVideo(filePath: String, fileName: String, mimeType: String): Unit {
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Sending video: ${fileName} (${mimeType})")
        let capturedCaption = this.inputText
        this.isSendingMedia = true
        this.uploadMediaLabel = "Sending video..."
        this.setComposerText("")
        spawn {
            try {
                // iOS 发视频默认转码到 ≤1280 长边 / ~2.2 Mbps H.264（原片走"以文件发送"）；
                // 此前直接上传相机原片（1080p 15 Mbps，2.5 s 就 4.6 MB）。先探元数据决定是否转码。
                var srcPath = filePath
                var probe = VideoThumbnailBridge.probe(filePath, 320)
                var srcBytes: Int64 = 0
                try { srcBytes = FileIo.stat(filePath).size } catch (_e: Exception) {}
                let maxDim = if (probe.width > probe.height) { probe.width } else { probe.height }
                let bps: Int64 = if (probe.durationMs > 0) { srcBytes * 8 * 1000 / probe.durationMs } else { 0 }
                if (maxDim > 1280 || bps > 3_000_000) {
                    let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                    let fit = RoundVideoBridge.fitVideo(filePath, filePath + ".fit.mp4", 1280, 2_200_000)
                    if (fit.ok) {
                        srcPath = filePath + ".fit.mp4"
                        probe = VideoThumbnailBridge.probe(srcPath, 320)
                        var outBytes: Int64 = 0
                        try { outBytes = FileIo.stat(srcPath).size } catch (_e: Exception) {}
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] video transcoded ${maxDim}px ${bps / 1000}kbps ${srcBytes}B → ${fit.width}x${fit.height} ${outBytes}B in ${DateTime.now().toUnixTimeStamp().toMilliseconds() - t0}ms")
                    } else {
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] video transcode failed (${fit.error}); sending original")
                    }
                }
                let fileData = readFileBytes(srcPath)
                if (srcPath != filePath) {
                    try { FileIo.unlink(srcPath) } catch (_e: Exception) {}
                }
                if (fileData.size > 0) {
                    let mime = if (mimeType.contains("video")) { mimeType } else { "video/mp4" }
                    // Fix3: 解析 MP4/MOV 真实 duration/宽/高（非 MP4 或解析失败时为 0，等价原行为）
                    let meta = extractMp4Metadata(fileData)
                    // 系统元数据优先（宽高已套旋转矩阵、时长精确），tkhd 解析兜底
                    let vw: Int32 = if (probe.width > 0) { probe.width } else { meta.width }
                    let vh: Int32 = if (probe.height > 0) { probe.height } else { meta.height }
                    let vdur: Float64 = if (probe.durationMs > 0) { Float64(probe.durationMs) / 1000.0 } else { meta.duration }
                    let thumb = probe.jpeg
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video meta: ${vdur}s ${vw}x${vh} (tkhd ${meta.width}x${meta.height}) thumb=${thumb.size}B")
                    this.viewModel.sendVideo(fileData, fileName, mime, vdur, vw, vh, capturedCaption, thumbData: thumb)
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video sent: ${fileName} (${fileData.size} bytes)")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video file is empty: ${filePath}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video send error: ${e}")
            }
            launch { this.isSendingMedia = false }
        }
    }

    /**
     * Phase P6-11: 启动视频消息（圆形 Video Note）录制
     * 
     * 使用系统相机录制视频，返回后通过 FileBrowser 选择视频
     * 选择的视频将作为 roundMessage 发送
     */
    private func launchVideoNoteCapture(): Unit {
        // iOS VideoMessageCameraScreen：前置摄像头、按住即录、400×400 方形 + 首帧缩略图。
        // 这里走 CameraPage round 模式（前置、进入即录、点快门停止），录完原生中心裁方 400×400
        // 再作 video_note 发送；替代原「系统录像 + 应用内文件浏览器」路径。
        setCameraLaunchOptions(mode: "round", front: true, autoStart: true)
        registerCameraMediaHandler({ path: String => this.processRoundVideoAndSend(path) })
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] video note: opening round camera")
        routerPush("CameraPage", "")
    }

    /** 录完的 mp4 → 方形 400×400（音频直通）→ sendSelectedVideoNote；转码失败则原片发送 */
    private func processRoundVideoAndSend(path: String): Unit {
        this.isSendingMedia = true
        this.uploadMediaLabel = "Processing video note..."
        spawn {
            let outPath = path + ".round.mp4"
            let r = RoundVideoBridge.squareVideo(path, outPath, 400, 270)
            if (r.ok) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] round video ready: ${r.width}x${r.height} ${r.durationMs}ms")
                try { FileIo.unlink(path) } catch (_e: Exception) {}
                launch { this.sendSelectedVideoNote(outPath, "video_note.mp4") }
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] round video transcode failed (${r.error}); sending original")
                launch { this.sendSelectedVideoNote(path, "video_note.mp4") }
            }
        }
    }

    /**
     * Phase P6-11: 发送用户选择的视频作为圆形视频消息 (Video Note)
     * 使用 ChatRoomViewModel.sendVideoNote() → RealMessageService.sendVideoNote(roundMessage=true)
     */
    func sendSelectedVideoNote(filePath: String, fileName: String): Unit {
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Sending video note: ${fileName}")
        this.isSendingMedia = true
        this.uploadMediaLabel = "Sending video note..."
        spawn {
            try {
                let fileData = readFileBytes(filePath)
                if (fileData.size > 0) {
                    // Fix3: 提取真实时长；video note 尺寸按 iOS 圆形约定固定 240x240（由 service 设定）
                    let meta = extractMp4Metadata(fileData)
                    // iOS 圆形视频 400x400 + JPEG 缩略图；这里用真实元数据（无则按 400 方形）+ 首帧缩略图
                    let probe = VideoThumbnailBridge.probe(filePath, 320)
                    let mw: Int32 = if (probe.width > 0) { probe.width } else { meta.width }
                    let mh: Int32 = if (probe.height > 0) { probe.height } else { meta.height }
                    let w: Int32 = if (mw > 0) { mw } else { 400 }
                    let h: Int32 = if (mh > 0) { mh } else { 400 }
                    let vdur: Float64 = if (probe.durationMs > 0) { Float64(probe.durationMs) / 1000.0 } else { meta.duration }
                    let thumb = probe.jpeg
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video note meta: ${vdur}s ${w}x${h} thumb=${thumb.size}B")
                    // 缩略图落本地，发送中的气泡就能显示圆形画面
                    var thumbPath = ""
                    if (thumb.size > 0) {
                        try {
                            let thumbDir = getAppFilesDir() + "/thumbs"
                            try { FileIo.mkdir(thumbDir) } catch (_e: Exception) {}
                            let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
                            let tp = thumbDir + "/thumb_local_${ts}.jpg"
                            let tf = FileIo.open(tp, mode: 0o1101)
                            FileIo.write(tf.fd, thumb)
                            FileIo.close(tf)
                            thumbPath = "file://" + tp
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[ChatRoomPage] video note thumb save failed: ${e}")
                        }
                    }
                    this.viewModel.sendVideoNote(fileData, fileName, vdur, width: w, height: h, thumbData: thumb, thumbPath: thumbPath)
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video note sent: ${fileName} (${fileData.size} bytes)")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video note file is empty: ${filePath}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] Video note send error: ${e}")
            }
            launch { this.isSendingMedia = false }
        }
    }

    /**
     * 发送用户从 FileBrowser 选择的文件
     */
    func sendSelectedFile(filePath: String, fileName: String, mimeType: String): Unit {
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Sending file: ${fileName} (${mimeType})")
        let capturedCaption = this.inputText
        this.isSendingMedia = true
        this.uploadMediaLabel = "Sending file..."
        this.setComposerText("")
        spawn {
            try {
                let fileData = readFileBytes(filePath)
                if (fileData.size > 0) {
                    this.viewModel.sendDocument(fileData, fileName, mimeType, capturedCaption)
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] File sent: ${fileName} (${fileData.size} bytes)")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] File is empty: ${filePath}")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] File send error: ${e}")
            }
            launch { this.isSendingMedia = false }
        }
    }

    /** 多文件按选择顺序串行上传，避免多个 MTProto 请求并发争用同一 client。 */
    private func sendSelectedFiles(filePaths: ArrayList<String>, fileNames: ArrayList<String>): Unit {
        if (filePaths.isEmpty()) { return }
        let batchCaption = this.inputText
        this.isSendingMedia = true
        this.uploadMediaLabel = "Sending files..."
        this.setComposerText("")
        spawn {
            var captionPending = batchCaption
            var i: Int64 = 0
            while (i < Int64(filePaths.size)) {
                let path = filePaths[i]
                if (path.size > 0) {
                    let name = if (i < Int64(fileNames.size) && fileNames[i].size > 0) {
                        fileNames[i]
                    } else {
                        attachFileNameOf(path)
                    }
                    try {
                        let data = readFileBytes(path)
                        if (data.size > 0) {
                            let mime = mimeTypeForExtension(attachExtOf(name))
                            this.viewModel.sendDocument(data, name, mime, captionPending)
                            captionPending = ""
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Batch file send error ${name}: ${e}")
                    }
                }
                i += 1
            }
            launch { this.isSendingMedia = false }
        }
    }
    
    // ==================== Phase H4: 语音消息发送 ====================
    
    /**
     * 发送语音消息
     */
    func sendVoiceMessage(result: VoiceRecordResult): Unit {
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Sending voice: ${result.duration}s, file=${result.filePath}")
        this.isSendingMedia = true
        this.uploadMediaLabel = "Sending voice..."
        spawn {
            try {
                if (result.filePath.size > 0) {
                    let voiceData = readFileBytes(result.filePath)
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Voice file read: ${voiceData.size} bytes")
                    if (voiceData.size > 0) {
                        // iOS：48 kHz PCM → Opus 30 kbps OGG（audio/ogg）+ 100 采样 5bit 波形。
                        // 服务端只把 audio/ogg 当语音，WAV 会被降级成普通音频文件。
                        let oggPath = result.filePath + ".ogg"
                        let enc = VoiceEncoderBridge.encodeToOgg(result.filePath, oggPath, 48000)
                        var sentOgg = false
                        if (enc.ok) {
                            let oggData = readFileBytes(oggPath)
                            try { FileIo.unlink(oggPath) } catch (_e: Exception) {}
                            if (oggData.size > 0) {
                                var dur: Int32 = Int32((enc.durationMs + 500) / 1000)
                                if (dur < 1) { dur = 1 }
                                Hilog.info(0, "CjTelegram", "[ChatRoomPage] Voice encoded: ${oggData.size} B ogg, ${enc.durationMs} ms, waveform=${enc.waveform.size}B")
                                this.viewModel.sendVoice(oggData, "voice.ogg", dur, enc.waveform, mimeType: "audio/ogg")
                                sentOgg = true
                            }
                        } else {
                            Hilog.info(0, "CjTelegram", "[ChatRoomPage] Voice encode failed (${enc.error}), falling back to WAV")
                        }
                        if (!sentOgg) {
                            let waveformBytes = encodeWaveform5bit(result.waveform)
                            this.viewModel.sendVoice(voiceData, "voice_${result.duration}s.wav", result.duration, waveformBytes)
                        }
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Voice sent via sendVoice")
                    } else {
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Voice file is empty")
                    }
                    try { FileIo.unlink(result.filePath) } catch (_e: Exception) {}
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] Voice send error: ${e}")
            }
            launch { this.isSendingMedia = false }
        }
    }

    // ==================== P2-371: 发送贴纸 ====================

    /** 三个面板互斥，切页签就是把其中一个置 true */
    @Builder
    func entityKeyboardTab(tab: String, label: String) {
        Column {
            Text(label)
                .fontSize(13)
                .fontColor(if (this.entityTabActive(tab)) { 0x007AFF } else { 0x8E8E93 })
        }
        // 76 而不是 88：底栏要同时放下地球、⚙、⌫ 三个 36vp 的按钮。
        // 加地球键时忘了给它腾空间，结果整行溢出、**退格键被挤出屏幕**——
        // 树里直接查不到 ⌫。新增元素必须重算整行宽度预算。
        .width(76)
        .height(34)
        .borderRadius(17)
        .backgroundColor(if (this.entityTabActive(tab)) { 0xFFFFFFFF } else { Color.Transparent })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.selectEntityTab(tab) })
    }

    /**
     * 实体键盘内容（页签条 + 三面板）。同一份 builder 服务两条路径：
     * 新路径绑在实体态 TextInput 的 customKeyboard 上；旧路径（开关回退）
     * 作为页面布局条件渲染。⚠️ 保持在类内 @Builder —— 独立 @Component
     * 曾触发 cjc 静默挂死（R-145，见旧位置注释）。
     */
    @Builder
    func entityKeyboardBuilder(): Unit {
        Column {
            if (this.showStickerKeyboard) {
                StickerKeyboardPanel(
                    contentHeightVp: this.entityPanelContentHeightVp(),
                    peerType: this.viewModel.peerType,
                    peerId: this.viewModel.chatId,
                    initialContentOffset: this.stickerKeyboardOffset,
                    onContentOffsetChanged: { value: Float64 =>
                        this.stickerKeyboardOffset = value
                    },
                    onSelectSticker: { s: StickerItem =>
                        // iOS 发送贴纸后保留实体键盘，便于连续发送。
                        this.sendStickerMessage(s)
                    },
                    onSendStickerSilently: { s: StickerItem =>
                        this.sendStickerMessage(s, silent: true)
                    },
                    onScheduleSticker: { s: StickerItem =>
                        this.openSchedulePicker(s)
                    },
                    onCreateSticker: { =>
                        this.closeEntityKeyboard()
                        this.openCustomStickerCreator()
                    },
                    onOpenSettings: { =>
                        this.closeEntityKeyboard()
                        routerPush("StickersSettingsPage", "")
                    },
                    // 贴纸面板无内嵌搜索输入（搜索胶囊直接跳添加贴纸页，
                    // iOS canFocus=false 对位），不参与 IME 紧凑态回报。
                    onClose: { => this.closeEntityKeyboard() },
                    // S2-37：长按预览在页根 Stack 呈现，见 stickerPreviewVisible。
                    hostsStickerPreview: true,
                    onPresentStickerPreview: { req: StickerPreviewRequest =>
                        this.stickerPreviewRequest = req
                        this.stickerPreviewVisible = true
                        Hilog.info(0, "CjTelegram",
                            "[ChatRoomPage] sticker preview present doc=${req.sticker.documentId}" +
                            " screen=${this.messageContextScreenHeight}")
                    },
                    onDismissStickerPreview: { =>
                        this.stickerPreviewVisible = false
                    }
                )
            } else if (this.showGifPanel) {
                GifPanel(
                    contentHeightVp: this.entityPanelContentHeightVp(),
                    initialTabOrdinal: this.gifKeyboardTab,
                    onTabChanged: { value: Int32 => this.gifKeyboardTab = value },
                    initialContentOffset: this.gifKeyboardOffset,
                    onContentOffsetChanged: { value: Float64 =>
                        this.gifKeyboardOffset = value
                    },
                    onSelectGif: { g: GifItem => this.sendGifMessage(g) },
                    onSendGifSilently: { g: GifItem =>
                        this.sendGifMessage(g, silent: true)
                    },
                    onScheduleGif: { g: GifItem =>
                        this.openGifSchedulePicker(g)
                    },
                    onClose: { => this.closeEntityKeyboard() },
                    onSearchActiveChanged: { active: Bool =>
                        this.setPanelSearchActive(active)
                    }
                )
            } else {
                EmojiPicker(
                    contentHeightVp: this.entityPanelContentHeightVp(),
                    peerType: this.viewModel.peerType,
                    peerId: this.viewModel.chatId,
                    initialContentOffset: this.emojiKeyboardOffset,
                    onContentOffsetChanged: { value: Float64 =>
                        this.emojiKeyboardOffset = value
                    },
                    onSelectEmoji: { emoji: String =>
                        this.appendComposerText(emoji)
                    },
                    onSelectCustomEmoji: { item: StickerItem =>
                        this.appendCustomEmoji(item)
                    },
                    onClose: { => this.closeEntityKeyboard() },
                    onSearchActiveChanged: { active: Bool =>
                        this.setPanelSearchActive(active)
                    }
                )
            }
            if (!this.panelCompactSearch()) {
                this.entityKeyboardTabs()
            }
        }
        .width(100.percent)
        .height(this.entityPanelHeightVp())
        // 28vp 手势带由面板自己吃下（页根同刻撤掉等量 padding）：
        // 面板底边贴到屏幕底，页签行悬在手势带上方 —— 与系统 IME 的
        // 键区/底部指示条关系一致，下方不再露聊天背景条。
        // 紧凑搜索态改 6vp（下面是 IME，手势带归它管）。
        .padding(bottom: this.panelBottomPadVp())
        // emoji 页签 + 合成器就绪时转透明：underlay surface 画底色与表情帧，
        // 仓颉层（头行/按钮/静态格）浮其上；其它页签维持自绘底色。
        .backgroundColor(this.entityPanelBgColor())
        // 出现/退场与系统键盘一致：整体自底滑入/滑出（250ms EaseOut，
        // 与系统 IME 弹出时长一致）。布局位移不进 animateTo（见 selectEntityTab 注释）。
        .transition(
            TransitionEffect.move(TransitionEdge.Bottom)
                .animation(AnimateParam(duration: 250, curve: Curve.EaseOut))
        )
    }

    @Builder
    func entityKeyboardTabs() {
        Row {
            // iOS EntityKeyboard.swift:661 —— emoji 页底部左侧是一个地球键
            // （EntityInputGlobeIcon），动作是 switchToTextInput()：收起表情面板、
            // 把焦点交回文字输入框。此前我们没有这个入口，用户只能伸手去够
            // 输入栏右侧的 😊。
            // 与退格键一样只在 emoji 页出现（iOS 两者都是 id: "emoji" 的附件按钮）。
            if (this.entityTabActive("emoji")) {
                Text("\u{1F310}")
                    .fontSize(19)
                    .width(36)
                    .height(38)
                    .textAlign(TextAlign.Center)
                    .margin(right: 4)
                    .onClick({ _evt =>
                        this.closeEntityKeyboard()
                        // 真实 blur（stopEditing）→ 属性落地 → 重取焦，产生真焦点
                        // 事件，enableKeyboardOnFocus 已翻 true → 系统 IME 弹出。
                        this.blurComposer()
                        let _ = spawn {
                            sleep(Duration.millisecond * 80)
                            launch { FocusControl.requestFocus(CHAT_INPUT_FIELD_ID) }
                        }
                    })
            }
            Row {
                this.entityKeyboardTab("gif", "GIFs")
                this.entityKeyboardTab("sticker", "Stickers")
                this.entityKeyboardTab("emoji", "Emoji")
            }
            .height(38)
            .padding(left: 2, right: 2)
            .backgroundColor(0x18000000)
            .borderRadius(19)

            Text("⚙")
                .fontSize(20)
                .fontColor(0x697078)
                .width(36)
                .height(38)
                .textAlign(TextAlign.Center)
                .margin(left: 8)
                .onClick({ _evt =>
                    this.closeEntityKeyboard()
                    routerPush("StickersSettingsPage", "")
                })

            // iOS EntityKeyboardBottomPanelComponent 在 Emoji 页常驻一个退格键
            if (this.entityTabActive("emoji")) {
                Text("⌫")
                    .fontSize(19)
                    .fontColor(0x697078)
                    .width(36)
                    .height(38)
                    .textAlign(TextAlign.Center)
                    .margin(left: 4)
                    .onClick({ _evt => this.deleteBackwards() })
            }
        }
        .width(100.percent)
        .height(48)
        .padding(left: 8, right: 8, top: 5, bottom: 5)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(0xF2F2F7)
    }

    /**
     * iOS 的 peek 菜单选 Schedule 会弹 ChatScheduleTimeScreen 选时间。
     * 这里复用仓里已有的 DateTimePicker（P2-414，对应 iOS DatePickerNode），
     * 默认落在「一小时后」——和 iOS 一样给一个合理起点而不是当前时刻。
     */
    private func openSchedulePicker(sticker: StickerItem): Unit {
        this.scheduleTargetSticker = sticker
        this.scheduleTargetGif = GifItem()
        this.scheduleInitialUnix = DateTime.now().toUnixTimeStamp().toSeconds() + 3600
        this.closeEntityKeyboard()
        this.showSchedulePicker = true
    }

    private func openGifSchedulePicker(gif: GifItem): Unit {
        this.scheduleTargetGif = gif
        this.scheduleTargetSticker = StickerItem()
        this.scheduleInitialUnix = DateTime.now().toUnixTimeStamp().toSeconds() + 3600
        this.closeEntityKeyboard()
        this.showSchedulePicker = true
    }

    private func confirmSchedule(pickedUnixSec: Int64): Unit {
        this.showSchedulePicker = false
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        if (pickedUnixSec <= nowSec) {
            showToast("Pick a time in the future")
            return
        }
        if (this.scheduleTargetSticker.documentId != 0) {
            this.sendStickerMessage(
                this.scheduleTargetSticker, silent: false, scheduleDate: Int32(pickedUnixSec))
            showToast("Sticker scheduled")
            return
        }
        if (this.scheduleTargetGif.documentId != 0 || this.scheduleTargetGif.isInlineResult()) {
            this.sendGifMessage(
                this.scheduleTargetGif, silent: false, scheduleDate: Int32(pickedUnixSec))
            showToast("GIF scheduled")
        }
    }

    private func selectEntityTab(tab: String): Unit {
        this.entityTab = tab
        // 面板占位会压缩消息列表视口：List 保持的是「距顶偏移」，视口变矮后
        // 最新消息被顶出屏下（真机：切表情键盘后要手划才见最新）。
        // 若切换前用户在底部，面板挂载后一帧把列表重新钉回底部（无动画）。
        let wasAtBottom = this._lastVisibleIndex < 0 ||
            this._lastVisibleIndex >= Int64(this.displayMessages.size) - 2
        if (wasAtBottom && this.displayMessages.size > 0) {
            let targetLast = Int32(this.displayMessages.size - 1)
            let _ = spawn {
                sleep(Duration.millisecond * 120)
                launch {
                    try {
                        this.listScroller.scrollToIndex(targetLast, smooth: false, align: ScrollAlign.End)
                    } catch (_e: Exception) {
                        try { this.listScroller.scrollEdge(Edge.Bottom) } catch (_e2: Exception) {}
                    }
                }
            }
        }
        // ⚠️ 不要把这三个状态写进 animateTo 闭包：animateTo 内挂载条件子树
        // 会生成「动画快照代 + 上屏代」两代实例，上屏代收不到 aboutToAppear、
        // 从不订阅 doc 池 —— 真机实锤帧钟每秒送 700 帧而屏幕纹丝不动。
        // 滑入动画由面板节点自身的 .transition(move Bottom) 承担。
        this.showEmojiPicker = tab == "emoji"
        this.showStickerKeyboard = tab == "sticker"
        this.showGifPanel = tab == "gif"
    }

    private var imeHeightWatcher: Option<ChatImeHeightCallback> = None
    private var imeWatcherRegistered: Bool = false
    private var lastImeHeightVpForPhase: Float64 = 0.0

    private func registerImeHeightWatcher(): Unit {
        if (this.imeWatcherRegistered) { return }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    // 顺手取窗口高度（vp）供面板高度钳制（R-145：根容器挂
                    // onAreaChange 会让 cjc 挂死，改走窗口属性）。
                    let rect = getLastWindow(ctx).getWindowProperties().windowRect
                    this.pageRootHeightVp = this.pxToVp(Float64(rect.height))
                    let cb = ChatImeHeightCallback({ px: Float64 =>
                        // 窗口回调线程 → UI 线程再写状态/全局（S-001）。
                        launch {
                            let vp = this.pxToVp(px)
                            let wasUp = this.lastImeHeightVpForPhase > 80.0
                            let nowUp = vp > 80.0
                            if (wasUp != nowUp) {
                                this.advanceChatGradientPhase()
                            }
                            this.lastImeHeightVpForPhase = vp
                            if (nowUp) {
                                this.scheduleImeInsetMeasure(vp)
                            } else if (this.imeInsetVp >= 0.0) {
                                this.imeInsetVp = -1.0
                            }
                            if (vp > 200.0) {
                                g_lastImeHeightVp = vp
                                // iOS：键盘与附件 sheet 同一时间只present一个 ——
                                // 键盘升起（点输入框/输入栏其他入口）即收掉附件面板。
                                if (this.showAttachmentPanel) {
                                    this.closeAttachmentPanel()
                                }
                                if (this.entityKeyboardVisible()) {
                                    if (this.panelSearchActive) {
                                        // iOS 复刻：面板内搜索聚焦时不互斥 ——
                                        // 面板收成搜索条+结果带贴在 IME 上方。
                                        this.panelImeUpVp = vp
                                    } else {
                                        // 互斥：面板开着时 IME 升起（点输入框）——
                                        // 「IME 先升、面板后拆」的非法顺序会让键盘
                                        // 避让按面板在场时计算，输入栏被 IME 盖没
                                        //（真机截图实锤）。复放已验证的焦点舞步：
                                        // 关面板 → stopEditing 收掉半升 IME →
                                        // 80ms 后重新取焦，IME 带正确避让重升。
                                        this.closeEntityKeyboard()
                                        this.blurComposer()
                                        let _ = spawn {
                                            sleep(Duration.millisecond * 80)
                                            launch {
                                                FocusControl.requestFocus(CHAT_INPUT_FIELD_ID)
                                            }
                                        }
                                    }
                                }
                            } else if (vp <= 1.0) {
                                // IME 收起：退出紧凑搜索态，面板恢复全高
                                //（搜索文本与结果保留，对位 iOS 收键盘后的形态）。
                                if (this.panelImeUpVp != 0.0) { this.panelImeUpVp = 0.0 }
                            }
                            // 键盘任一方向变化都会让面板整体位移；占位块自身不变，
                            // onAreaChange 不再触发 —— 布局稳定后主动重量覆盖层几何。
                            this.scheduleOverlayRemeasure("ime=${Int64(vp)}")
                        }
                    })
                    getLastWindow(ctx).on(WindowCallbackType.KeyboardHeightChange, cb)
                    this.imeHeightWatcher = Some(cb)
                    this.imeWatcherRegistered = true
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] ime watcher register failed: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 覆盖层几何统一重量入口（components/OverlayGeometry.cj）。
     * 两拍：60ms 等键盘避让/面板布局落地，260ms 兜底等动画结束；
     * 各面板重量后只有几何真变了才推送，重复调用无副作用。
     */
    private func scheduleOverlayRemeasure(reason: String): Unit {
        let _ = spawn {
            sleep(Duration.millisecond * 60)
            launch { remeasureAllOverlays(reason) }
            sleep(Duration.millisecond * 200)
            launch { remeasureAllOverlays("${reason}#settle") }
        }
    }

    private func unregisterImeHeightWatcher(): Unit {
        if (!this.imeWatcherRegistered) { return }
        this.imeWatcherRegistered = false
        match ((getGlobalAbilityContext(), this.imeHeightWatcher)) {
            case (Some(ctx), Some(cb)) =>
                try {
                    getLastWindow(ctx).off(WindowCallbackType.KeyboardHeightChange, cb)
                } catch (_: Exception) {}
            case _ => ()
        }
        this.imeHeightWatcher = None
    }

    private func pxToVp(px: Float64): Float64 {
        match (this.getUIContext().px2vp(px.px)) {
            case Some(v) => v.value
            case None => 0.0
        }
    }

    /**
     * 实体面板总高（vp）= 系统 IME 实测高度，做到与系统键盘完全同尺寸。
     * KeyboardHeightChange 回调喂的是 px；未测到（本会话还没弹过 IME）时
     * 用进程级记忆，仍没有则兜底 363（335 内容 + 28 手势带）。
     */
    /** 页面根高度（vp），onAreaChange 维护，用于面板高度钳制。 */
    private var pageRootHeightVp: Float64 = 0.0

    /**
     * 面板内搜索的紧凑态（iOS EmojiSearchHeaderView 复刻）：
     * 面板里的搜索框聚焦 → IME 升起时**不再互斥关面板**，面板收成
     * 「搜索行 + 一条结果带」贴在 IME 上方；IME 收起或取消搜索恢复全高。
     * panelSearchActive 由三个面板经 onSearchActiveChanged 回报；
     * panelImeUpVp 由 IME 高度回调维护（0 = IME 未起）。
     */
    @State var panelSearchActive: Bool = false
    @State var panelImeUpVp: Float64 = 0.0

    private func panelCompactSearch(): Bool {
        return this.panelSearchActive && this.panelImeUpVp > 0.0
    }

    private func setPanelSearchActive(active: Bool): Unit {
        this.panelSearchActive = active
        if (!active) { this.panelImeUpVp = 0.0 }
    }

    private func panelBottomPadVp(): Float64 {
        // 紧凑态下面是 IME，手势带由 IME 自己管；全高态吃 28vp 手势带。
        if (this.panelCompactSearch()) { return 6.0 }
        return 28.0
    }

    private func entityPanelHeightVp(): Float64 {
        // 紧凑搜索态：54 搜索行 + 120 结果带 + 6 底距（iOS 键盘上方那条）。
        if (this.panelCompactSearch()) { return 180.0 }
        var h = 363.0
        if (g_lastImeHeightVp > 200.0) { h = g_lastImeHeightVp }
        // 钳制：无 IME 记忆的会话兜底 363 可能超过可用空间（页签被顶出屏，
        // 真机实锤）。至少给聊天区+输入栏留 240vp。
        if (this.pageRootHeightVp > 300.0 && h > this.pageRootHeightVp - 240.0) {
            h = this.pageRootHeightVp - 240.0
        }
        return h
    }

    /** 内容区高度 = 面板总高 - 页签行 48 - 手势带 28（页签行高见 entityKeyboardTabs）。 */
    private func entityPanelContentHeightVp(): Float64 {
        // 紧凑搜索态：无页签行，只扣底距。
        if (this.panelCompactSearch()) { return 174.0 }
        let h = this.entityPanelHeightVp() - 48.0 - 28.0
        if (h < 200.0) { return 200.0 }
        return h
    }

    private func entityPanelBgColor(): UInt32 {
        // 对齐鸿蒙系统键盘的浅灰底（真机 IME 取色 ≈ #F1F3F5）。
        return 0xFFF1F3F5
    }

    /** 面板可见时页根撤掉 28vp 手势带内边距（露边的根因），由面板自己吃满到屏底。 */
    private func rootBottomInsetVp(): Float64 {
        if (this.entityKeyboardVisible()) { return 0.0 }
        // WP-F P0-1：系统 IME 在场时页面按 RESIZE 收缩（ChatRoomPage.ets），键盘盖住手势带，
        // 底距按实测的根容器与键盘顶的重叠量补（通常 0），不再固定 28。
        if (this.imeInsetVp >= 0.0) { return this.imeInsetVp }
        return 28.0
    }

    /**
     * WP-F P0-1：IME 升起后根容器底边相对键盘顶的重叠量（vp）。-1 = IME 未起（用 28 手势带）。
     * RESIZE 模式下页面高度 = 窗口高 - 键盘高，根容器底边即键盘顶，重叠 0；若宿主把
     * expandSafeArea 的系统底栏扩展仍算进页面高度，则重叠 = 被键盘盖住的那段，补成底距，
     * 输入栏始终贴在键盘上沿而不被盖住。
     */
    @State var imeInsetVp: Float64 = -1.0

    private func scheduleImeInsetMeasure(imeVp: Float64): Unit {
        let _ = spawn {
            sleep(Duration.millisecond * 80)
            launch { this.measureImeInset(imeVp, "first") }
            sleep(Duration.millisecond * 260)
            launch { this.measureImeInset(imeVp, "settle") }
        }
    }

    private func measureImeInset(imeVp: Float64, phase: String): Unit {
        // 期间 IME 已收起：不要用过期高度覆盖。
        if (this.lastImeHeightVpForPhase <= 80.0) { return }
        var inset = 0.0
        match (measureOverlaySlot(CHAT_ROOM_ROOT_ID)) {
            case Some(rect) =>
                let rootBottomVp = this.pxToVp(rect.y + rect.h)
                let windowHeightVp = if (this.pageRootHeightVp > 0.0) { this.pageRootHeightVp } else { rootBottomVp }
                let keyboardTopVp = windowHeightVp - imeVp
                let overlap = rootBottomVp - keyboardTopVp
                if (overlap > 0.5) { inset = overlap }
                if (inset > imeVp) { inset = imeVp }
                Hilog.info(0, "CjTelegram",
                    "[ChatRoomPage] ime inset ${phase}: rootBottom=${rootBottomVp} window=${windowHeightVp} ime=${imeVp} overlap=${overlap} -> inset=${inset}")
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] ime inset ${phase}: root not measurable, inset=0")
        }
        if (this.imeInsetVp != inset) { this.imeInsetVp = inset }
    }

    /**
     * 附件面板开关（iOS ChatController.openAttachmentMenu 语义）。
     * 互斥：iOS 弹 AttachmentController 时键盘必然先落 —— 打开前既关表情/贴纸实体面板，
     * 也用 stopEditing() 收掉系统 IME（真实 blur，同本页 🌐/表情键那条已验证的焦点流转），
     * 否则面板会浮在键盘之上，两者同屏。
     */
    private func toggleAttachmentPanel(): Unit {
        let opening = !this.showAttachmentPanel
        this.showPhotoPicker = false
        this.showVoiceRecorder = false
        this.closeEntityKeyboard()
        if (opening) {
            this.blurComposer()
            this.attachTab = "gallery"
            this.showAttachmentPanel = true
            // 挂起式请求：用户在 ArkTS 图库网格里点一张 → 回调发送
            this.requestAttachPick()
            this.scheduleOverlayRemeasure("attachOpen")
        } else {
            this.closeAttachmentPanel()
        }
    }

    // ==================== 附件面板内嵌图库网格（ArkTS 覆盖层） ====================
    // 通道与表情/贴纸网格同构：仓颉占位块量出全局几何 → callArk 推给壳层渲染
    // PhotoPickerComponent（免权限）。见 components/AttachmentPanel.cj 头注释。
    private var attachGridXPx: Float64 = 0.0
    private var attachGridYPx: Float64 = 0.0
    private var attachGridWPx: Float64 = 0.0
    private var attachGridHPx: Float64 = 0.0

    @State var attachTab: String = "gallery"

    private func attachContentHeightVp(): Float64 {
        // iOS AttachmentController 默认展开约占竖屏 2/3；扣掉抓手 20 + 头 44 + 按钮条 57 + 安全区 28
        if (this.pageRootHeightVp > 400.0) {
            let h = this.pageRootHeightVp * 0.66 - 149.0
            return if (h < 320.0) { 320.0 } else { h }
        }
        return 320.0
    }

    private func onAttachTabChanged(t: String): Unit {
        this.attachTab = t
        // 只有 gallery 页签需要 ArkTS 图库网格；其余页签隐藏覆盖层
        this.pushAttachGrid(this.showAttachmentPanel && t == "gallery")
        if (t != "location") { this.pushAttachMap(false) }
    }

    // ---- Location 页签系统地图（HMS Map Kit，ArkTS 覆盖层）----
    private var attachMapXPx: Float64 = 0.0
    private var attachMapYPx: Float64 = 0.0
    private var attachMapWPx: Float64 = 0.0
    private var attachMapHPx: Float64 = 0.0
    private var attachMapLat: Float64 = 0.0
    private var attachMapLng: Float64 = 0.0

    private func pushAttachMap(visible: Bool): Unit {
        let show = visible && this.showAttachmentPanel && this.attachTab == "location"
        let payload = "{\"visible\":${show},\"x\":${Int64(this.attachMapXPx)}," +
            "\"y\":${Int64(this.attachMapYPx)},\"w\":${Int64(this.attachMapWPx)}," +
            "\"h\":${Int64(this.attachMapHPx)},\"lat\":${this.attachMapLat},\"lng\":${this.attachMapLng}}"
        callArk("attachMap.update", payload)
    }

    private func onAttachMapGeometry(x: Float64, y: Float64, w: Float64, h: Float64, lat: Float64, lng: Float64): Unit {
        this.attachMapXPx = x
        this.attachMapYPx = y
        this.attachMapWPx = w
        this.attachMapHPx = h
        this.attachMapLat = lat
        this.attachMapLng = lng
        this.pushAttachMap(true)
    }

    private func pushAttachGrid(visible: Bool): Unit {
        let show = visible && this.attachTab == "gallery"
        let payload = "{\"visible\":${show},\"x\":${Int64(this.attachGridXPx)}," +
            "\"y\":${Int64(this.attachGridYPx)},\"w\":${Int64(this.attachGridWPx)}," +
            "\"h\":${Int64(this.attachGridHPx)}}"
        callArk("attachGrid.update", payload)
    }

    private func onAttachGridGeometry(x: Float64, y: Float64, w: Float64, h: Float64): Unit {
        this.attachGridXPx = x
        this.attachGridYPx = y
        this.attachGridWPx = w
        this.attachGridHPx = h
        this.pushAttachGrid(this.showAttachmentPanel)
    }

    private func closeAttachmentPanel(): Unit {
        if (!this.showAttachmentPanel) { return }
        this.showAttachmentPanel = false
        this.pushAttachGrid(false)
        this.pushAttachMap(false)
    }

    /**
     * 图库网格选图 → 沙箱路径 → 走既有 sendSelectedPhoto 发送。
     * 面板关闭时 ArkTS 侧会以 cancelled 回调收尾，不会悬挂。
     */
    /**
     * iOS 附件菜单的 Audio 项：选一个音频文件当文档发送。
     * 反转链路：callArkAsync(PICK_DOCUMENT, {suffixes}) → DocumentPickerImpl.ets
     *   → picker.DocumentViewPicker → 拷贝到沙箱 → 回传本地路径 → sendSelectedFile。
     */
    private func pickAudioDocument(): Unit {
        callArkAsync(PICK_DOCUMENT,
            "{\"suffixes\":[\".mp3\",\".m4a\",\".aac\",\".flac\",\".wav\",\".ogg\"],\"maxSelectNumber\":9}",
            { res =>
                let ok = jsonBoolFieldPhoto(res, "ok")
                let paths = jsonStringArrayFieldPhoto(res, "paths")
                if (!ok || paths.isEmpty()) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] audio pick ended without file")
                    return
                }
                let names = jsonStringArrayFieldPhoto(res, "names")
                this.closeAttachmentPanel()
                this.sendSelectedFiles(paths, names)
            })
    }

    /**
     * File 页签「Select from Gallery」（iOS presentFileGallery）：系统相册选图片/视频，
     * 按**文件**发送（不走压缩的 sendPhoto），保留原文件名与类型。
     */
    private func pickGalleryAsFile(): Unit {
        callArkAsync(PICK_PHOTO_ALBUM, "{\"mime\":\"imagevideo\",\"maxSelectNumber\":9}", { res =>
            let ok = jsonBoolFieldPhoto(res, "ok")
            let status = jsonStringFieldPhoto(res, "status")
            if (!ok || status != "picked") { return }
            let paths = jsonStringArrayFieldPhoto(res, "paths")
            let names = jsonStringArrayFieldPhoto(res, "names")
            this.closeAttachmentPanel()
            this.sendSelectedFiles(paths, names)
        })
    }

    /** File 页签「Select from Files」（iOS presentICloudFileGallery）：系统文档选择器，任意类型 */
    private func pickSystemFile(): Unit {
        callArkAsync(PICK_DOCUMENT, "{\"suffixes\":[],\"maxSelectNumber\":9}", { res =>
            let ok = jsonBoolFieldPhoto(res, "ok")
            let paths = jsonStringArrayFieldPhoto(res, "paths")
            let names = jsonStringArrayFieldPhoto(res, "names")
            if (!ok || paths.isEmpty()) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] file pick ended without file")
                return
            }
            this.closeAttachmentPanel()
            this.sendSelectedFiles(paths, names)
        })
    }

    private func requestAttachPick(): Unit {
        callArkAsync("attachGrid.pick", "{}", { res =>
            let ok = jsonBoolFieldPhoto(res, "ok")
            let status = jsonStringFieldPhoto(res, "status")
            if (!ok || status != "picked") {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] attach grid pick ended: status=${status}")
                return
            }
            let paths = jsonStringArrayFieldPhoto(res, "paths")
            let kinds = jsonStringArrayFieldPhoto(res, "kinds")
            // 先关闭一次面板，再逐项投递；kinds 与 paths 由 ArkTS 按下标对齐。
            this.closeAttachmentPanel()
            var index: Int64 = 0
            while (index < Int64(paths.size)) {
                let path = paths[index]
                if (path.size == 0) {
                    index += 1
                    continue
                }
                var fileName = path
                match (path.lastIndexOf("/")) {
                    case Some(idx) => fileName = path[(idx + 1)..path.size]
                    case None => ()
                }
                let name = fileName
                let kind = if (index < Int64(kinds.size)) { kinds[index] } else { "photo" }
                if (kind == "video") {
                    // 网格里选的是视频（iOS 图库网格同样图片视频混排）
                    launch {
                        this.sendSelectedVideo(path, name, "video/mp4")
                    }
                } else {
                    let photo = SelectedPhoto(uri: path, fileName: name, fileSize: 0)
                    launch {
                        this.sendSelectedPhoto(photo)
                    }
                }
                index += 1
            }
        })
    }

    private func closeEntityKeyboard(): Unit {
        // 同 selectEntityTab：不进 animateTo；退场动画由 transition 承担。
        this.showEmojiPicker = false
        this.showStickerKeyboard = false
        this.showGifPanel = false
        // S2-37：面板随键盘拆除后预览不能孤悬在页根上。
        this.stickerPreviewVisible = false
        this.panelSearchActive = false
        this.panelImeUpVp = 0.0
        // 播放池清账：帧钟层杀流后若 streams 表残留死账，重开面板时
        // drive 会认为「流已存在」而不再起播 —— 「重开全静 + 孤儿重生
        // 循环卡顿」的根源（真机用户实锤）。
        getKeyboardDocPlayback().stopAll()
        getKeyboardDocPlayback().setCanvasDelegated(ArrayList<Int64>())
        // 页面级兜底收割：面板条件渲染被拆时，其内部格子在本版本 ArkUI 收不到
        // 任何销毁回调（R-146 的页面级变体，真机实测返回键关面板后 6 条僵尸流
        // 常驻——既占播放槽，又把「前台空闲」判据卡在 >0，AnimationCache 构建器
        // 因此永远不干活）。面板已关 = 键盘流必然全部无主，按最大代收割。
        getKeyboardFrameClock().stopKeyboardStreams(9223372036854775807)
    }

    private func entityKeyboardVisible(): Bool {
        return this.showEmojiPicker || this.showStickerKeyboard || this.showGifPanel
    }

    private func entityTabActive(tab: String): Bool {
        match (tab) {
            case "sticker" => return this.showStickerKeyboard
            case "gif" => return this.showGifPanel
            case _ => return this.showEmojiPicker
        }
    }


    /**
     * iOS deleteBackwards：按「一个可见字符」删，而不是一个 UTF-16 code unit。
     * Emoji 常常是多码位序列（🇨🇳、👩‍❤️‍💋‍👨、带肤色的 👍🏽），按码元删会把序列拆坏。
     * 若删掉的正好是一个自定义表情占位，同时把对应的 draft entity 摘掉。
     */
    private func deleteBackwards(): Unit {
        let runes = this.inputText.toRuneArray()
        if (runes.size == 0) { return }
        let removed = trailingGraphemeLength(runes)
        var next = ""
        var index: Int64 = 0
        let keep = Int64(runes.size) - removed
        while (index < keep) {
            next = next + runes[index].toString()
            index = index + 1
        }
        this.setComposerText(next)
        this.dropCustomEmojiEntitiesBeyond(Int32(keep))
    }

    private func dropCustomEmojiEntitiesBeyond(runeCount: Int32): Unit {
        let kept = ArrayList<CustomEmojiDraftEntity>()
        for (entity in this.customEmojiDraftEntities) {
            if (entity.runeOffset + entity.runeLength <= runeCount) { kept.add(entity) }
        }
        this.customEmojiDraftEntities = kept
    }

    /** 读一次「Suggest Stickers by Emoji」；Preferences 是同步 IO，放后台读。 */
    private func loadStickerSuggestionSetting(): Unit {
        let _ = spawn {
            let enabled = getStickersService().readLocalSetting("stickers_suggest_by_emoji")
            launch { this.suggestStickersByEmoji = enabled }
        }
    }

    /**
     * 末尾的 `:关键词` 片段（不含冒号）。要求冒号前是行首或空白，
     * 关键词只允许字母数字下划线 —— 否则 "http://" 这类会误触发。
     */
    private func emojiSuggestionQuery(): String {
        if (this.entityKeyboardVisible()) { return "" }
        let runes = this.inputText.toRuneArray()
        var index = Int64(runes.size) - 1
        var token = ""
        while (index >= 0) {
            let ch = runes[index]
            if (ch == r':') {
                if (index > 0 && !isSuggestionBoundary(runes[index - 1])) { return "" }
                if (token.size < 2 || token.size > 24) { return "" }
                return token
            }
            if (!isSuggestionWordChar(ch)) { return "" }
            token = ch.toString() + token
            index = index - 1
        }
        return ""
    }

    /** 把末尾的 `:关键词` 换成给定文本。 */
    private func replaceSuggestionToken(replacement: String): Unit {
        let token = this.emojiSuggestionQuery()
        if (token.isEmpty()) { return }
        let dropCount = Int64(token.toRuneArray().size) + 1
        let runes = this.inputText.toRuneArray()
        let keep = Int64(runes.size) - dropCount
        var head = ""
        var index: Int64 = 0
        while (index < keep) {
            head = head + runes[index].toString()
            index = index + 1
        }
        this.setComposerText(head + replacement)
        this.dropCustomEmojiEntitiesBeyond(Int32(keep))
    }

    private func applyEmojiSuggestion(emoji: String): Unit {
        this.replaceSuggestionToken(emoji)
    }

    /**
     * 建议条的查询串：与 iOS 一致，只在**整个输入框就是一个 emoji** 时才触发，
     * 否则正常打字过程中会不停弹条打断输入。开关关掉时返回空串。
     */
    private func stickerSuggestionQuery(): String {
        if (!this.suggestStickersByEmoji) { return "" }
        if (this.entityKeyboardVisible()) { return "" }
        let text = this.inputText
        if (text.isEmpty() || text.size > 32) { return "" }
        if (!isSingleEmoji(text)) { return "" }
        return text
    }

    func sendStickerMessage(sticker: StickerItem): Unit {
        this.sendStickerMessage(sticker, silent: false)
    }

    /** silent / scheduleDate 对应 iOS peek 菜单里的 sendSticker(silentPosting:schedule:)。 */
    func sendStickerMessage(
        sticker: StickerItem, silent!: Bool, scheduleDate!: Option<Int32> = None
    ): Unit {
        let s = sticker
        let quiet = silent
        let scheduleAt = scheduleDate
        let peerType = this.viewModel.peerType
        let peerId = this.viewModel.chatId
        let replyTo = Int32(this.viewModel.replyToMsgId)
        if (replyTo > 0) {
            this.viewModel.cancelReply()
        }
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] sendStickerMessage docId=${s.documentId} replyTo=${replyTo}")
        // iOS 会在消息入队的同一刻更新 CloudRecentStickers，不能等待下一次面板网络刷新。
        let stickerStore = getEntityKeyboardStore()
        let stickerToken = stickerStore.currentToken()
        stickerStore.recordRecentlyUsedSticker(stickerToken, s)
        let _ = spawn {
            let service = getStickersService()
            if (service.saveRecentSticker(s)) {
                let recent = service.getRecentStickers()
                if (recent.success) {
                    stickerStore.publishRecentStickers(stickerToken, recent.stickers.toArray())
                }
            }
        }
        let _ = spawn {
            let svc = getStickersService()
            let result = svc.sendSticker(
                peerType, peerId, s, replyToMsgId: replyTo, silent: quiet, scheduleDate: scheduleAt)
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] sticker sent ok")
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] sticker send failed")
            }
        }
    }

    // ==================== P2-373: 发送 GIF ====================

    func sendGifMessage(gif: GifItem): Unit {
        this.sendGifMessage(gif, silent: false)
    }

    /** silent / scheduleDate 与贴纸同源：iOS 的 GIF 上下文菜单同样有这两项。 */
    func sendGifMessage(
        gif: GifItem, silent!: Bool, scheduleDate!: Option<Int32> = None
    ): Unit {
        let g = gif
        let quiet = silent
        let scheduleAt = scheduleDate
        let peerType = this.viewModel.peerType
        let peerId = this.viewModel.chatId
        let replyTo = Int32(this.viewModel.replyToMsgId)
        if (replyTo > 0) { this.viewModel.cancelReply() }
        Hilog.info(0, "CjTelegram",
            "[ChatRoomPage] sendGifMessage docId=${g.documentId} inline=${g.isInlineResult()} replyTo=${replyTo}")
        let _ = spawn {
            if (g.isInlineResult()) {
                let messageService = getRealMessageService()
                let peerHash = if (peerType == "user") {
                    messageService.getAccessHashForUser(peerId)
                } else if (peerType == "channel") {
                    messageService.getAccessHashForChannel(peerId)
                } else { 0 }
                let sent = getWebSearchService().sendSelectedResult(
                    g.queryId, g.resultId, peerId, peerHash,
                    peerType: peerType, replyToMsgId: replyTo,
                    silent: quiet, scheduleDate: scheduleAt)
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] inline GIF sent=${sent}")
                return
            }
            let svc = getGifService()
            // Saved/internal GIFs are ordinary inputMediaDocument messages.
            let gifAsSticker = StickerItem()
            gifAsSticker.documentId = g.documentId
            gifAsSticker.accessHash = g.accessHash
            gifAsSticker.fileReference = g.fileReference
            gifAsSticker.dcId = g.dcId
            gifAsSticker.mimeType = g.mimeType
            let stickerSvc = getStickersService()
            let result = stickerSvc.sendSticker(
                peerType, peerId, gifAsSticker, replyToMsgId: replyTo,
                silent: quiet, scheduleDate: scheduleAt)
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] GIF sent ok")
                // Also save to recent GIFs
                let _ = svc.saveGif(g)
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] GIF send failed")
            }
        }
    }

    private func encodeWaveform5bit(samples: ArrayList<Int32>): Array<Byte> {
        if (samples.size == 0) { return Array<Byte>(0, repeat: 0) }
        let totalBits: Int64 = samples.size * 5
        let byteCount: Int64 = (totalBits + 7) / 8
        let result = Array<Byte>(byteCount, repeat: 0)
        var bitPos: Int32 = 0
        for (s in samples) {
            var val5: Int32 = s
            if (val5 > 31) { val5 = 31 }
            if (val5 < 0) { val5 = 0 }
            let byteIdx: Int32 = bitPos / 8
            let bitOff: Int32 = bitPos % 8
            let existing0: Int32 = Int32(result[Int64(byteIdx)]) & 0xFF
            result[Int64(byteIdx)] = UInt8((existing0 | (val5 << bitOff)) & 0xFF)
            if (bitOff + 5 > 8 && Int64(byteIdx + 1) < result.size) {
                let existing1: Int32 = Int32(result[Int64(byteIdx + 1)]) & 0xFF
                result[Int64(byteIdx + 1)] = UInt8((existing1 | (val5 >> (8 - bitOff))) & 0xFF)
            }
            bitPos += 5
        }
        return result
    }
    
    // ==================== Phase H2: 全屏图片查看 ====================

    /**
     * 系统返回键（ArkTS onBackPressed 同步转来）：全屏媒体查看器打开时只关闭查看器、留在本会话，
     * 与查看器 ✕ 同一路径（iOS GalleryController.swift:1464 donePressed → dismiss(forceAway: false)）。
     * 返回 true 表示已消费；false 交回 NavDestination 默认出栈。
     */
    private func handleSystemBack(): Bool {
        if (this.showImageViewer) {
            this.showImageViewer = false
            return true
        }
        if (this.showVideoPlayer) {
            this.showVideoPlayer = false
            return true
        }
        return false
    }
    
    /**
     * 打开 ImageViewer（Phase P5-14: 先用中等尺寸打开，后台下载全分辨率替换）
     * 收集当前聊天中所有照片消息，定位到点击的那张
     */
    func openImageViewer(msg: Message): Unit {
        let images = ArrayList<ImageItem>()
        var targetIndex: Int64 = 0
        var idx: Int64 = 0
        
        // 收集需要升级为全分辨率的照片
        let photosNeedFullRes = ArrayList<Message>()
        
        for (m in this.viewModel.messageList) {
            if (m.messageType == "photo" && m.photoLocalPath.size > 0) {
                let item = ImageItem(
                    url: m.photoLocalPath,
                    photoId: m.photoId,
                    caption: if (m.content.size > 0 && m.content != m.mediaDescription) { m.content } else { "" },
                    senderName: m.senderName,
                    timeText: m.time,
                    msgId: m.id
                )
                images.add(item)
                if (m.id == msg.id) {
                    targetIndex = idx
                }
                // Phase P5-14: 如果当前路径是 _m 尺寸，标记需要全分辨率
                if (m.photoLocalPath.contains("_m.jpg")) {
                    photosNeedFullRes.add(m)
                }
                idx += 1
            }
        }
        
        if (images.isEmpty()) { return }
        
        this.imageViewerImages = images
        this.imageViewerIndex = targetIndex
        this.showImageViewer = true
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] ImageViewer: ${images.size} photos, index=${targetIndex}")
        
        // Phase P5-14: 后台下载全分辨率照片（优先下载当前查看的那张）
        if (photosNeedFullRes.size > 0) {
            spawn {
                for (m in photosNeedFullRes) {
                    let fullResUri = this.viewModel.downloadFullResPhoto(m)
                    if (fullResUri.size > 0) {
                        m.photoLocalPath = fullResUri
                        let photoId = m.photoId
                        let uri = fullResUri
                        launch {
                            for (img in this.imageViewerImages) {
                                if (img.photoId == photoId) {
                                    img.url = uri
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // ==================== Phase H3: 全屏视频播放 ====================
    
    /**
     * 打开 VideoPlayer
     * 
     * 流程（匹配 TelegramHarmony handleVideoTap）:
     * 1. documentLocalPath 存储的是缩略图（thumbnail），不是视频文件
     * 2. 通过 ViewModel.downloadVideoForPlayback 下载完整视频（会暂停轮询避免 MTProto 冲突）
     * 3. 下载完成后用 ArkUI Video 组件播放
     */
    func openVideoPlayer(msg: Message): Unit {
        let thumbnailPath = msg.documentLocalPath  // 缩略图路径（可能为空）
        let caption = if (msg.content.size > 0 && msg.content != msg.mediaDescription) { msg.content } else { "" }
        let msgDuration = msg.videoDuration
        
        if (msg.documentId == 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] No documentId for video, cannot download")
            let video = VideoData(url: "", duration: msgDuration, thumbnailUrl: thumbnailPath, caption: caption)
            this.videoPlayerData = video
            this.showVideoPlayer = true
            return
        }
        
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Opening video: docId=${msg.documentId}, size=${msg.documentSize}, thumb=${thumbnailPath}")
        this.isDownloadingVideo = true
        
        // 在 spawn 前捕获所有需要的值到 let 常量
        let msgDocId = msg.documentId
        let msgAccessHash = msg.documentAccessHash
        let msgFileRef = msg.documentFileReference
        let msgDcId = msg.documentDcId
        let msgSize = msg.documentSize
        let msgThumb = thumbnailPath
        let msgCaption = caption
        
        spawn {
            let videoUri = this.viewModel.downloadVideoForPlayback(
                msgDocId, msgAccessHash, msgFileRef, msgDcId, msgSize
            )
            
            let video = VideoData(
                url: videoUri,
                duration: msgDuration,
                thumbnailUrl: msgThumb,
                caption: msgCaption
            )
            
            if (videoUri.size > 0) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] VideoPlayer opened with: ${videoUri}")
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] VideoPlayer opened without video (download failed)")
            }
            
            launch {
                this.isDownloadingVideo = false
                this.videoPlayerData = video
                this.showVideoPlayer = true
            }
        }
    }
    
    // ==================== Phase P5-12: 语音播放（增强版）====================

    /**
     * 首帧预热最近一条语音：先把磁盘缓存路径回填到消息，再把 AVPlayer 推到
     * prepared。这样用户第一次点击也只剩 play，与已完成后的重播走同一快路径。
     */
    private func warmLatestVoice(messages: ArrayList<Message>): Unit {
        if (messages.isEmpty()) { return }
        if (getVoicePlayerManager().currentMessageId != -1) { return }
        var index = messages.size - 1
        while (index >= 0) {
            let msg = messages[index]
            if (msg.messageType == "voice") {
                if (msg.documentLocalPath.size > 0) {
                    this._voiceWarmMessageId = msg.id
                    getVoicePlayerManager().preload(msg.id, msg.documentLocalPath)
                } else if (msg.documentId != 0 && this._voiceWarmMessageId != msg.id) {
                    this._voiceWarmMessageId = msg.id
                    let warmMessageId = msg.id
                    spawn {
                        this.viewModel.downloadVoiceForMessage(msg)
                        launch {
                            if (this._voiceWarmMessageId == warmMessageId && msg.documentLocalPath.size > 0) {
                                getVoicePlayerManager().preload(msg.id, msg.documentLocalPath)
                                this.refreshMessageListForVoice()
                            } else if (msg.documentLocalPath.size == 0) {
                                this._voiceWarmMessageId = -1
                            }
                        }
                    }
                }
                return
            }
            index -= 1
        }
    }
    
    /**
     * Phase P5-12: 切换语音消息播放/暂停
     * 增强: 如果语音文件未下载，先下载再播放
     */
    func toggleVoicePlayback(msg: Message): Unit {
        let player = getVoicePlayerManager()
        
        // 如果正在播放同一条消息 → 直接切换暂停/恢复
        if (player.currentMessageId == msg.id) {
            player.play(msg.id, msg.documentLocalPath, msg.audioDuration)
            this.refreshMessageListForVoice()
            return
        }
        
        // 如果文件已下载 → 直接播放
        if (msg.documentLocalPath.size > 0) {
            this._voicePlaybackRequestGeneration += 1
            this._pendingVoiceDownloadMessageId = -1
            player.play(msg.id, msg.documentLocalPath, msg.audioDuration)
            this.refreshMessageListForVoice()
            Hilog.info(0, "CjTelegram", "[ChatRoom] Voice play: msgId=${msg.id}, duration=${msg.audioDuration}")
            return
        }
        
        // 文件未下载 → 先下载再播放
        if (msg.documentId == 0) { return }
        if (this._pendingVoiceDownloadMessageId == msg.id) {
            Hilog.info(0, "CjTelegram", "[ChatRoom] Voice download already pending: msgId=${msg.id}")
            return
        }
        this._voicePlaybackRequestGeneration += 1
        let requestGeneration = this._voicePlaybackRequestGeneration
        this._pendingVoiceDownloadMessageId = msg.id
        Hilog.info(0, "CjTelegram", "[ChatRoom] Voice download needed: msgId=${msg.id}")
        this.refreshMessageListForVoice()
        
        let msgId = msg.id
        let duration = msg.audioDuration
        spawn {
            this.viewModel.downloadVoiceForMessage(msg)
            if (requestGeneration != this._voicePlaybackRequestGeneration ||
                this._pendingVoiceDownloadMessageId != msgId) {
                Hilog.info(0, "CjTelegram", "[ChatRoom] Voice autoplay superseded: msgId=${msgId}")
                return
            }
            this._pendingVoiceDownloadMessageId = -1
            if (msg.documentLocalPath.size > 0) {
                let p = getVoicePlayerManager()
                p.play(msgId, msg.documentLocalPath, duration)
                Hilog.info(0, "CjTelegram", "[ChatRoom] Voice auto-play after download: msgId=${msgId}")
            } else {
                Hilog.info(0, "CjTelegram", "[ChatRoom] Voice download failed, no local path for msgId=${msgId}")
            }
            launch { this.refreshMessageListForVoice() }
        }
    }
    
    /** 一条语音自然播完 → 播放列表里它之后的第一条语音（iOS 连续播放） */
    private func playNextVoiceAfter(msgId: Int64): Unit {
        var found = false
        for (m in this.viewModel.messageList) {
            if (found && m.messageType == "voice" && m.id != msgId) {
                Hilog.info(0, "CjTelegram", "[ChatRoom] Voice continuous play: ${msgId} → ${m.id}")
                this.toggleVoicePlayback(m)
                return
            }
            if (m.id == msgId) { found = true }
        }
    }

    /**
     * Phase P5-12: 轻量级消息列表刷新（触发波形重绘）
     */
    private func refreshMessageListForVoice(): Unit {
        this.voicePlaybackEpoch += 1
        // 播放进度不改变消息数据。重发整张消息快照会在一次点击尚未收尾时重建
        // ListItem/手势节点，导致同一触摸重复切换；裸 @State 版本足以驱动气泡 @Prop。
    }
    
    // ==================== Phase H5: 文件下载 ====================
    
    /**
     * 下载文档/文件消息 或 打开已下载文件
     */
    func downloadFile(msg: Message): Unit {
        if (msg.documentId == 0) { return }

        if (msg.documentMimeType.startsWith("image/")) {
            if (msg.documentLocalPath.size > 0) {
                this.openDocumentImageViewer(msg)
                return
            }
            if (msg.isFileDownloading) { return }
            let recentImage = makeRecentDownloadEntry(msg, this.viewModel.peerType, this.viewModel.chatId, this.chatName)
            spawn {
                // iOS records user-initiated file fetches in Recent Downloads.
                beginRecentDownload(recentImage)
                this.viewModel.downloadDocumentForMessage(msg)
                finishRecentDownload(recentImage, msg.documentLocalPath)
                if (msg.documentLocalPath.size > 0) {
                    launch { this.openDocumentImageViewer(msg) }
                }
            }
            return
        }
        
        // 已下载 → 使用系统应用打开
        if (msg.documentLocalPath.size > 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] Opening file: ${msg.documentLocalPath}")
            this.openFileWithSystem(msg.documentLocalPath, msg.documentMimeType)
            return
        }
        
        // 正在下载中 → 忽略重复点击
        if (msg.isFileDownloading) { return }
        
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] Downloading file: docId=${msg.documentId}")
        let recordRecent = isRecentDownloadCandidate(msg)
        let recentFile = makeRecentDownloadEntry(msg, this.viewModel.peerType, this.viewModel.chatId, this.chatName)
        spawn {
            // FetchManagerImpl.swift:265: user-initiated file fetches feed the
            // global search "Downloads" tab.
            if (recordRecent) { beginRecentDownload(recentFile) }
            this.viewModel.downloadDocumentForMessage(msg)
            if (recordRecent) { finishRecentDownload(recentFile, msg.documentLocalPath) }
            // The tap asked for the file: once the fetch lands, hand it to the
            // system viewer (iOS opens the document preview for a fetched file).
            if (msg.documentLocalPath.size > 0) {
                launch { this.openFileWithSystem(msg.documentLocalPath, msg.documentMimeType) }
            }
        }
    }

    /**
     * Visible rows (plus the List's cachedCount margin) fetch their photos at
     * interactive priority, like iOS media nodes fetching when displayed.
     * Album rows contribute every grouped message.
     */
    private func prioritizeVisibleMedia(first: Int64, last: Int64): Unit {
        if (first < 0 || last < first) { return }
        let count = this.displayMessages.size
        var start = first - 2
        if (start < 0) { start = 0 }
        var end = last + 2
        if (end >= count) { end = count - 1 }
        let visible = ArrayList<Message>()
        var index = start
        while (index <= end) {
            let entry = this.displayMessages[index]
            if (entry.groupedMessages.size > 1) {
                for (grouped in entry.groupedMessages) { visible.add(grouped) }
            } else {
                visible.add(entry.message)
            }
            index += 1
        }
        this.viewModel.prioritizeVisibleMedia(visible)
    }

    private func openDocumentImageViewer(msg: Message): Unit {
        let source = if (msg.documentLocalPath.size > 0) { msg.documentLocalPath } else { msg.documentThumbnailPath }
        if (source.size == 0) { return }
        let images = ArrayList<ImageItem>()
        images.add(ImageItem(url: source, photoId: msg.documentId, caption: msg.content, msgId: msg.id))
        this.imageViewerImages = images
        this.imageViewerIndex = 0
        this.showImageViewer = true
    }

    /**
     * imgmenu 批次：ImageViewer 内 Forward 按钮 → 关闭查看器并打开既有转发选择器
     * （复用长按菜单 onForward 同一管线：forward picker → messages.forwardMessages）。
     */
    /**
     * V5 C7: iOS ChatInterfaceStateContextMenus.swift:1930
     * `forwardMessages(selectAll || isImage ? messages : [message])` — `messages` is the whole
     * grouping-key album, so long-pressing a photo inside an album forwards every message of the
     * album (all photos + the caption), not just the pressed one. Non-photo albums forward only
     * the pressed message, like iOS.
     */
    private func forwardTargetIds(message: Message): ArrayList<Int64> {
        let ids = ArrayList<Int64>()
        if (message.groupedId != 0 && message.photoId != 0) {
            for (m in this.viewModel.messageList) {
                if (m.groupedId == message.groupedId && m.id > 0) { ids.add(m.id) }
            }
        }
        if (ids.isEmpty()) { ids.add(message.id) }
        return ids
    }

    private func forwardFromImageViewer(msgId: Int64): Unit {
        this.showImageViewer = false
        this.forwardMsgId = msgId
        this.forwardMsgIds = ArrayList<Int64>()
        this.forwardMsgIds.add(msgId)
        this.forwardDropAuthor = false
        this.forwardDropCaptions = false
        this.loadForwardDialogs()
        this.showForwardPicker = true
    }

    /**
     * imgmenu 批次：ImageViewer 内 Delete 按钮 → 确认弹窗（Delete for Me / Everyone，
     * 同长按菜单 onDelete 惯例）→ viewModel.deleteMessage（messages.deleteMessages）→ 关闭查看器。
     */
    private func confirmDeleteFromImageViewer(msgId: Int64): Unit {
        let targetMsgId = msgId
        let uiCtx = getUIContext()
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel",
            action: { => () }
        )
        let forMeBtn = AlertDialogButtonOptions(
            value: "Delete for Me",
            fontColor: 0xFFFF3B30,
            action: { =>
                this.viewModel.deleteMessage(targetMsgId, revoke: false)
                this.showImageViewer = false
            }
        )
        let forAllBtn = AlertDialogButtonOptions(
            value: "Delete for Everyone",
            fontColor: 0xFFFF3B30,
            action: { =>
                this.viewModel.deleteMessage(targetMsgId, revoke: true)
                this.showImageViewer = false
            }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: "Delete Photo",
            message: "This will permanently delete the photo.",
            autoCancel: true,
            buttons: [cancelBtn, forMeBtn, forAllBtn]
        ))
    }
    
    /**
     * 使用系统应用打开文件
     * 通过 startAbility + Want 拉起文件处理应用
     */
    private func openFileWithSystem(fileUri: String, mimeType: String): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                // 将 MIME 类型映射为 UTD（Uniform Type Descriptor）
                let utdType = this.mimeToUtdType(mimeType)
                // Another app can only read a sandbox file through the
                // bundle-authority URI (fileUri.getUriFromPath form:
                // file://<bundle>/data/storage/...). The empty-authority
                // file:///data/... form made the system previewer fail.
                let shareUri = this.sandboxShareUri(fileUri)
                
                let want = Want(
                    flags: Flags.FLAG_AUTH_READ_URI_PERMISSION,
                    uri: shareUri,
                    action: "ohos.want.action.viewData",
                    dataType: utdType
                )
                
                try {
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] startAbility: ${shareUri} (${utdType})")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] openFile failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] No context for openFile")
        }
    }
    
    private func sandboxShareUri(uri: String): String {
        let path = if (uri.startsWith("file://")) { uri[7..uri.size] } else { uri }
        if (path.startsWith("/")) {
            return "file://" + CHATROOM_FILE_URI_BUNDLE + path
        }
        return uri
    }

    /**
     * MIME 类型 → UTD type 映射
     */
    private func mimeToUtdType(mime: String): String {
        if (mime.contains("pdf")) { return "general.pdf" }
        if (mime.contains("image")) { return "general.image" }
        if (mime.contains("video")) { return "general.video" }
        if (mime.contains("audio")) { return "general.audio" }
        if (mime.contains("text")) { return "general.plain-text" }
        if (mime.contains("zip") || mime.contains("rar") || mime.contains("7z")) { return "general.archive" }
        if (mime.contains("word") || mime.contains("doc")) { return "general.composite-content" }
        if (mime.contains("sheet") || mime.contains("xls")) { return "general.composite-content" }
        if (mime.contains("presentation") || mime.contains("ppt")) { return "general.composite-content" }
        return "general.object"
    }
    
    // ==================== Phase P2-3: 网页链接打开 ====================

    // ==================== Phase P6-4: 跳转到回复消息 ====================
    
    /**
     * 滚动到指定消息 ID 并高亮
     * 
     * 1. 在 displayMessages 中查找目标消息索引
     * 2. 如果找到：平滑滚动到该索引并高亮 1.5 秒
     * 3. 如果未找到：目标消息不在当前加载范围（暂不支持跨范围加载）
     */
    private func jumpToReplyMessage(targetMsgId: Int64): Unit {
        if (targetMsgId <= 0) { return }
        if (this.scrollToAndHighlight(targetMsgId)) { return }
        // 对齐 iOS ChatControllerNavigateToMessage：目标不在当前历史窗口时，先以目标为锚点
        // 加载一窗历史（ChatHistoryLocation.InitialSearch(.id)），再居中定位并高亮。
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-4: reply target ${targetMsgId} not loaded, loading around it")
        this.viewModel.loadHistoryAround(Int32(targetMsgId), { =>
            this.retryScrollToAndHighlight(targetMsgId, 10)
        })
    }

    // loadHistoryAround 的回调与 displayMessages 快照重建不在同一帧，按 100ms 间隔重试。
    private func retryScrollToAndHighlight(targetMsgId: Int64, remaining: Int64,
                                           align!: ScrollAlign = ScrollAlign.Center): Unit {
        if (this.scrollToAndHighlight(targetMsgId, align: align)) { return }
        if (remaining <= 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-4: reply target ${targetMsgId} unavailable after load")
            return
        }
        let _ = spawn {
            sleep(Duration.millisecond * 100)
            launch { this.retryScrollToAndHighlight(targetMsgId, remaining - 1, align: align) }
        }
    }

    /**
     * 在当前显示列表中定位目标消息（含相册组内的子消息），居中滚动并高亮。
     * iOS 的 navigateToMessage 以 .center 位置滚动，并按 highlightedState 高亮
     * （ChatControllerLoadDisplayNode.swift:5438-5460，普通跳转 0.7s / 引用 1.5s 后清除）。
     */
    private func scrollToAndHighlight(targetMsgId: Int64, align!: ScrollAlign = ScrollAlign.Center): Bool {
        let msgs = this.displayMessages
        let targetIndex = this.displayIndexOfMessage(targetMsgId)
        if (targetIndex < 0) { return false }
        this._pinnedToLatest = false
        try {
            this.listScroller.scrollToIndex(Int32(targetIndex), smooth: true, align: align)
        } catch (_e: Exception) {}
        let highlightId = msgs[targetIndex].message.id
        this.highlightedMessageId = highlightId
        let _ = spawn {
            sleep(Duration.millisecond * 1500)
            launch {
                if (this.highlightedMessageId == highlightId) { this.highlightedMessageId = 0 }
            }
        }
        this.settleJumpTarget(highlightId, 8, align: align)
        return true
    }

    /** 目标消息（含相册组内子消息）在 displayMessages 中的索引，-1 = 不在当前窗口。 */
    private func displayIndexOfMessage(targetMsgId: Int64): Int64 {
        let msgs = this.displayMessages
        var idx: Int64 = 0
        while (idx < msgs.size) {
            if (msgs[idx].message.id == targetMsgId) { return idx }
            for (g in msgs[idx].groupedMessages) {
                if (g.id == targetMsgId) { return idx }
            }
            idx += 1
        }
        return -1
    }

    /**
     * S9-30：跳转落点校验。smooth scrollToIndex 在 LazyForEach 估算高度 / 上翻 HoleReload
     * 锚点回滚下会停在目标之外（实测目标气泡只露出底部一截、大半被顶栏方向裁掉）。
     * 等列表落一帧后用 getItemRect 校验目标是否完整落在视口内，没落稳就用无动画
     * Center 再滚一次，最多 remaining 轮；iOS navigateToMessage(.center) 的落点是确定的。
     */
    private func settleJumpTarget(targetMsgId: Int64, remaining: Int64,
                                  align!: ScrollAlign = ScrollAlign.Center): Unit {
        if (remaining <= 0) { return }
        let wantTop = match (align) {
            case ScrollAlign.Start => true
            case _ => false
        }
        let _ = spawn {
            sleep(Duration.millisecond * 250)
            launch {
                let idx = this.displayIndexOfMessage(targetMsgId)
                if (idx < 0) { return }
                let viewport = this._listViewportHeightVp
                var settled = false
                try {
                    let rect = this.listScroller.getItemRect(Int32(idx))
                    if (viewport > 0.0 && rect.y.isSome() && rect.height.isSome()) {
                        let y = rect.y.getOrThrow()
                        let h = rect.height.getOrThrow()
                        if (h > 0.0) {
                            settled = if (wantTop) {
                                // 顶对齐（日历跳转）：目标顶边贴视口顶，或列表已到尽头无法再上顶但目标完整可见
                                (y >= -1.0 && y <= 1.0) || (y >= 0.0 && y + h <= viewport && idx + 1 >= this.displayMessages.size)
                            } else if (h >= viewport) {
                                y <= 0.0 && y + h >= viewport
                            } else {
                                y >= 0.0 && y + h <= viewport
                            }
                        }
                    }
                } catch (_e: Exception) {}
                if (settled) { return }
                Hilog.info(0, "CjTelegram",
                    "[ChatRoomPage] jump target ${targetMsgId} not settled (idx=${idx}, viewport=${viewport}), re-aligning")
                this._pinnedToLatest = false
                try {
                    this.listScroller.scrollToIndex(Int32(idx), smooth: false, align: align)
                } catch (_e: Exception) {}
                this.settleJumpTarget(targetMsgId, remaining - 1, align: align)
            }
        }
    }
    
    // ==================== Phase P6-2: 系统相机启动 ====================

    /**
     * 启动系统相机拍照并直接发送
     * 
     * 使用 startAbilityForResult 拉起系统相机，拍照完成后从回调中获取照片 URI，
     * 读取照片数据后直接发送，无需经过 PhotoPicker。
     */
    private func launchSystemCamera(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let want = Want(
                    action: "ohos.want.action.imageCapture"
                )
                try {
                    ctx.startAbilityForResult(want, { err: Option<BusinessException>, data: Option<AbilityResult> =>
                        match (err) {
                            case Some(e) =>
                                Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera error: ${e.message}")
                                launch { this.showPhotoPicker = true }
                            case None =>
                                match (data) {
                                    case Some(result) =>
                                        this.handleCameraResult(result)
                                    case None =>
                                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera returned no data")
                                        launch { this.showPhotoPicker = true }
                                }
                        }
                    })
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Launched system camera")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera launch failed: ${e}")
                    this.showPhotoPicker = true
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: No ability context for camera")
                this.showPhotoPicker = true
        }
    }

    /**
     * 处理相机拍照返回结果
     * resultCode == 0 表示拍照成功，从 want.uri 获取照片路径并发送
     */
    private func handleCameraResult(result: AbilityResult): Unit {
        if (result.resultCode != 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera cancelled or failed, resultCode=${result.resultCode}")
            return
        }

        let photoUri = result.want.uri
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera result URI: ${photoUri}")

        if (photoUri.size == 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera returned empty URI, fallback to PhotoPicker")
            launch { this.showPhotoPicker = true }
            return
        }

        this.uploadMediaLabel = "Sending photo..."
        launch { this.isSendingMedia = true }
        spawn {
            this.processCameraPhoto(photoUri)
        }
    }

    /**
     * 读取相机拍摄的照片并发送
     * 支持 file:// 和 datashare:// 两种 URI 格式
     */
    private func processCameraPhoto(photoUri: String): Unit {
        try {
            var filePath = photoUri
            if (filePath.startsWith("file://")) {
                filePath = filePath[7..]
            }

            let cacheDir = getAppFilesDir() + "/camera"
            try { FileIo.mkdir(cacheDir) } catch (_e: Exception) {}

            let timestamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let cacheName = "camera_${timestamp}.jpg"
            let cachePath = cacheDir + "/" + cacheName

            if (filePath.startsWith("/")) {
                let photoData = readFileBytes(filePath)
                if (photoData.size > 0) {
                    let file = FileIo.open(cachePath, mode: 0o1101)
                    FileIo.write(file.fd, photoData)
                    FileIo.close(file)
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera photo cached: ${cachePath} (${photoData.size} bytes)")
                    
                    let photo = SelectedPhoto(uri: "file://" + cachePath, fileName: cacheName, fileSize: Int64(photoData.size))
                    launch { this.sendSelectedPhoto(photo) }
                    return
                }
            }

            let srcFile = FileIo.open(photoUri, mode: 0o0)
            let stat = FileIo.stat(srcFile.fd)
            if (stat.size > 0) {
                let buffer = Array<Byte>(stat.size, repeat: 0)
                let bytesRead = FileIo.read(srcFile.fd, buffer)
                FileIo.close(srcFile)
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Read ${bytesRead} bytes from camera URI")

                let dstFile = FileIo.open(cachePath, mode: 0o1101)
                FileIo.write(dstFile.fd, buffer)
                FileIo.close(dstFile)

                let photo = SelectedPhoto(uri: "file://" + cachePath, fileName: cacheName, fileSize: stat.size)
                launch { this.sendSelectedPhoto(photo) }
            } else {
                FileIo.close(srcFile)
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Camera photo file is empty")
                launch { this.isSendingMedia = false }
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] P6-2: Failed to process camera photo: ${e}")
            launch { this.isSendingMedia = false }
        }
    }

    /**
     * 根据浏览器偏好路由打开 URL
     * 通过 BrowserService.resolveUrl 获取规范化 URL 和路由决策：
     *   - BrowserMode.InApp   → BrowserScreen（鸿蒙 Web 组件原生加载 URL，P2-BrowserScreen 已注册）
     *   - BrowserMode.External → 走 system Want(viewData) 拉起外部浏览器
     */
    // ==================== 邀请链接：站内加入 ====================

    @State var showJoinInviteDialog: Bool = false
    @State var joinInviteTitle: String = ""
    @State var joinInviteSubtitle: String = ""
    @State var joinInviteHash: String = ""
    @State var joinInviteRequestNeeded: Bool = false
    @State var joinInviteBusy: Bool = false

    /** t.me/+HASH、t.me/joinchat/HASH、tg://join?invite=HASH → HASH；非邀请链接返回 "" */
    private func inviteHashFromUrl(url: String): String {
        var rest = url
        for (prefix in ["https://", "http://"]) {
            if (rest.startsWith(prefix)) { rest = rest[prefix.size..] }
        }
        for (host in ["t.me/", "telegram.me/", "telegram.dog/"]) {
            if (rest.startsWith(host)) {
                let path = rest[host.size..]
                if (path.startsWith("+")) { return path[1..].split("?")[0] }
                if (path.startsWith("joinchat/")) { return path["joinchat/".size..].split("?")[0] }
                return ""
            }
        }
        if (rest.startsWith("tg://join?invite=")) { return rest["tg://join?invite=".size..] }
        return ""
    }

    private func tryHandleInviteLink(url: String): Bool {
        let hash = this.inviteHashFromUrl(url)
        if (hash.size == 0) { return false }
        this.showMediaToast("Checking invite link…", autoClear: true)
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] invite link tapped url=${url} hash=${hash} -> checkChatInvite")
        let _ = spawn {
            let info = getJoinLinkPreviewService().checkChatInvite(hash)
            Hilog.info(0, "CjTelegram",
                "[ChatRoomPage] invite link result hash=${hash} invalid=${info.invalidHash} already=${info.alreadyJoined} peek=${info.peek} chat=${info.chatId} '${info.title}' requestNeeded=${info.requestNeeded}")
            launch {
                if (info.invalidHash) {
                    this.showMediaToast("This invite link is invalid or has expired", autoClear: true)
                } else if (info.alreadyJoined) {
                    this.showMediaToast("", autoClear: false)
                    if (info.chatId > 0) {
                        // R6V S1-61：服务端判定仍是成员（chatInviteAlready）。iOS
                        // JoinLinkPreviewController.swift:90-91 对 .alreadyJoined 直接 navigateToPeer；
                        // 同时该群必须回到会话列表：清掉本会话内可能残留的"已删除"标记，并按
                        // 服务端的 peer（left=false，已在 checkChatInvite 里入缓存）刷新列表。
                        getRealChatListService().clearDialogRemoved(
                            normalizeDialogPeerType(if (info.isChannel) { "channel" } else { "chat" }), info.chatId)
                        match (getChatListVM()) {
                            case Some(vm) => vm.refreshWithPullDown()
                            case None => ()
                        }
                        this.openJoinedChat(info.chatId, info.title, info.isChannel)
                    } else {
                        this.showMediaToast("You are already a member", autoClear: true)
                    }
                } else {
                    this.joinInviteHash = hash
                    this.joinInviteRequestNeeded = info.requestNeeded
                    this.joinInviteTitle = info.title
                    this.joinInviteSubtitle = if (info.isChannel) {
                        "${info.participantsCount} subscribers"
                    } else {
                        "${info.participantsCount} members"
                    }
                    this.showMediaToast("", autoClear: false)
                    this.showJoinInviteDialog = true
                }
            }
        }
        return true
    }

    private func confirmJoinInvite(): Unit {
        if (this.joinInviteBusy) { return }
        this.joinInviteBusy = true
        let hash = this.joinInviteHash
        let fallbackTitle = this.joinInviteTitle
        let _ = spawn {
            let r = getJoinLinkPreviewService().joinChatInvite(hash)
            launch {
                this.joinInviteBusy = false
                this.showJoinInviteDialog = false
                if (r.requestSent) {
                    this.showMediaToast("Join request sent", autoClear: true)
                    return
                }
                if (!r.success) {
                    this.showMediaToast(if (r.errorCode.size > 0) { "Could not join: ${r.errorCode}" } else { "Could not join" }, autoClear: true)
                    return
                }
                match (getChatListVM()) {
                    case Some(vm) => vm.refreshWithPullDown()
                    case None => ()
                }
                if (r.chatId > 0) {
                    this.openJoinedChat(r.chatId, if (r.title.size > 0) { r.title } else { fallbackTitle }, r.isChannel)
                } else {
                    this.showMediaToast("Joined ${fallbackTitle}", autoClear: true)
                }
            }
        }
    }

    private func openJoinedChat(chatId: Int64, title: String, isChannel: Bool): Unit {
        setSelectedChat(chatId, title, if (isChannel) { "channel" } else { "chat" })
        routerPush("ChatRoomPage", title)
    }

    @Builder
    func joinInviteDialog() {
        Column {
            Column {
                Text(this.joinInviteTitle)
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 4)
                Text(this.joinInviteSubtitle)
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.showJoinInviteDialog = false })
                    Text(if (this.joinInviteBusy) { "Joining…" } else if (this.joinInviteRequestNeeded) { "Request to Join" } else { "Join" })
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF007AFF)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.confirmJoinInvite() })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ => this.showJoinInviteDialog = false })
    }

    /**
     * iOS ChatController.openPeerMention (ChatController.swift:9466-9526): resolve the
     * username via contacts.resolveUsername and open the peer in-app
     * (defaultNavigationForPeerId → .chat for users and channels), or show
     * Resolve_ErrorNotFound. Previously "tg://resolve?…" fell through to the
     * system browser (W0 S2-72 pre).
     */
    private func openPeerMention(username: String): Unit {
        let name = username
        Hilog.info(0, "CjTelegram", "[ChatRoomPage] openPeerMention @${name}")
        let _ = spawn {
            let peerOpt = getResolveService().resolvePeerByName(name)
            launch {
                match (peerOpt) {
                    case Some(peer) =>
                        let title = if (peer.displayName.size > 0) { peer.displayName } else { name }
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] mention resolved ${peer.peerType}:${peer.peerId} '${title}'")
                        if (peer.peerType == this.viewModel.peerType && peer.peerId == this.viewModel.chatId) {
                            // iOS: same chat already on screen → playShakeAnimation, no push.
                            return
                        }
                        setSelectedChat(peer.peerId, title, peer.peerType)
                        setSelectedChatDraft("")
                        setSelectedChatUsername(name)
                        setSelectedChatBotStartPayload("")
                        routerPush("ChatRoomPage", title)
                    case None =>
                        showAlert(
                            title: "",
                            message: trOr("Resolve.ErrorNotFound", "Sorry, this user doesn't seem to exist."),
                            confirmText: trOr("Common.OK", "OK"),
                            cancelText: ""
                        )
                }
            }
        }
    }

    private func openWebUrl(url: String): Unit {
        if (this.tryHandleInviteLink(url)) { return }
        if (url.startsWith("tg://resolve?domain=")) {
            let mentionName = getDeepLinkRouter().extractUsername(url)
            if (mentionName.size > 0) {
                this.openPeerMention(mentionName)
                return
            }
        }
        // S7-123: t.me/setlanguage/<id> → language pack preview (iOS OpenResolvedUrl.swift:556).
        let languagePackId = languagePackIdentifierFromUrl(url)
        if (languagePackId.size > 0) {
            setPendingLanguagePreviewIdentifier(languagePackId)
            routerPush("LanguageLinkPreviewPage", languagePackId)
            return
        }
        if (!isWhitelistedUrl(url)) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] openWebUrl blocked unsafe scheme: ${url}")
            return
        }
        if (getBrowserService().isBotWebAppUrl(url)) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] openWebUrl bot webapp → WebAppPage: ${url}")
            routerPush("WebAppPage", url)
            return
        }
        let (norm, mode) = getBrowserService().resolveUrl(url)
        match (mode) {
            case BrowserMode.InApp =>
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] openWebUrl InApp → BrowserScreen: ${norm}")
                // Hybrid page globals are isolated; persist the navigation target in the
                // browser's shared tab registry before pushing BrowserScreen.
                getBrowserTabRegistry().updateActiveTab(norm, "")
                routerPush("BrowserScreen", norm)
            case BrowserMode.External =>
                match (getGlobalAbilityContext()) {
                    case Some(ctx) =>
                        let want = Want(
                            action: "ohos.want.action.viewData",
                            uri: norm
                        )
                        try {
                            ctx.startAbility(want)
                            Hilog.info(0, "CjTelegram", "[ChatRoomPage] openWebUrl External: ${norm}")
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[ChatRoomPage] openWebUrl failed: ${e}")
                        }
                    case None =>
                        Hilog.info(0, "CjTelegram", "[ChatRoomPage] No context for openWebUrl")
                }
        }
    }

    private func openWebUrlExternal(url: String): Unit {
        // S7-89: http(s) links honor Privacy → Open Links in (AccountWebBrowserSettings
        // .openExternalBrowser + exceptions, iOS OpenUrl.swift) via openWebUrl's
        // BrowserService.resolveUrl routing: in-app → BrowserScreen, external → system browser.
        this.openWebUrl(url)
    }


    // ==================== Phase P0-2: 搜索跳转辅助方法 ====================

    /**
     * 根据消息 ID 定位并滚动到目标消息
     * 遍历 viewModel.messageList 找到匹配的 index，调用 listScroller.scrollToIndex
     */
    /**
     * S024：搜索态日历入口 → CalendarMessageScreen；选日后经 registerCalendarJumpHandler
     * 回调定位到该日首条消息（不在当前列表时先围绕锚点补一窗历史）。
     */
    private func openCalendarFromSearch(): Unit {
        registerCalendarJumpHandler({ msgId: Int32 =>
            this.jumpToMessageFromCalendar(Int64(msgId))
        })
        routerPush("CalendarMessageScreen", "")
    }

    // ==================== 语音消息：按住即录（iOS ChatTextInputMediaRecordingButton） ====================

    /**
     * MICROPHONE 是 user_grant 权限，只在 module.json5 声明不够；未授权时 libohaudio 的
     * AudioCapturer 创建直接失败（真机实锤：GenerateCapturer failed → 0 bytes）。
     * 先确权再开录；弹了系统授权框时手指必然已抬起，授权回来只在仍按住时才开录，
     * 否则等用户再按一次（iOS 首次也是先弹权限）。
     */
    private func startVoiceRecordingWithPermission(): Unit {
        if (getPermissionsService().checkPermission(PermissionType.Microphone)) {
            this.startVoiceRecording()
            return
        }
        getPermissionsService().requestPermission(PermissionType.Microphone, { ok: Bool =>
            launch {
                if (ok && this.sendPressActive) {
                    this.startVoiceRecording()
                } else if (!ok) {
                    // 已被永久拒绝时系统不再弹框（真机 atm dump: MICROPHONE grantStatus=-1），
                    // 对位 iOS 的「麦克风权限被拒 → 引导去设置」alert：提示 + 打开本应用的系统设置页
                    showToast("Allow microphone access in Settings to record voice messages")
                    this.openAppPermissionSettings()
                }
            }
        })
    }

    private func openAppPermissionSettings(): Unit {
        // APPLICATION_DETAILS_SETTINGS 隐式 action 在本机无接收方（真机：No matching ability）；
        // 走 DeviceAccessService 已验证的 settings MainAbility + application_info_entry 路径
        getDeviceAccessService().openSystemSettings()
    }

    private func startVoiceRecording(): Unit {
        if (this._voiceActive) { return }
        this.closeAttachmentPanel()
        this.closeEntityKeyboard()
        this._voiceActive = true
        this.voiceRecording = true
        this.voiceLocked = false
        this.voiceDuration = 0
        this.voiceWave = ArrayList<Int32>()
        let filesDir = getAppFilesDir()
        if (filesDir.size > 0) {
            let voiceDir = filesDir + "/voice"
            try { FileIo.mkdir(voiceDir) } catch (_e: Exception) {}
            let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
            this._voiceFilePath = voiceDir + "/voice_${ts}.wav"
        }
        triggerHaptic("impact", "medium")
        if (!AudioCaptureService.startCapture()) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] voice: startCapture failed")
        }
        spawn {
            var dur: Int32 = 0
            let wave = ArrayList<Int32>()
            while (this._voiceActive && dur < 600) {
                sleep(Duration.second * 1)
                if (!this._voiceActive) { break }
                dur = dur + 1
                let bytes = AudioCaptureService.getBytesRecorded()
                let level: Int32 = if (bytes > 0) { Int32((bytes / 320) % 33 + 5) } else { Int32((dur * 17 + 23) % 33) }
                if (wave.size < 100) { wave.add(level) }
                let copy = ArrayList<Int32>()
                for (w in wave) { copy.add(w) }
                let d = dur
                launch {
                    this.voiceDuration = d
                    this.voiceWave = copy
                }
            }
        }
    }

    private func finishVoiceRecording(cancelled: Bool): Unit {
        if (!this._voiceActive) { return }
        this._voiceActive = false
        let path = this._voiceFilePath
        let dur = this.voiceDuration
        let wave = ArrayList<Int32>()
        for (w in this.voiceWave) { wave.add(w) }
        this.voiceRecording = false
        this.voiceLocked = false
        if (cancelled || dur < 1) {
            AudioCaptureService.cancelCapture()
            if (path.size > 0) { try { FileIo.unlink(path) } catch (_e: Exception) {} }
            if (!cancelled) { showToast("Hold to record a voice message") }
            return
        }
        spawn {
            let bytesWritten = AudioCaptureService.stopCapture(path)
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] voice: ${dur}s, ${bytesWritten} bytes")
            if (bytesWritten > 0) {
                let result = VoiceRecordResult(filePath: path, duration: dur, waveform: wave)
                launch { this.sendVoiceMessage(result) }
            } else {
                launch { showToast("No audio captured") }
            }
        }
    }

    private func formatVoiceDuration(seconds: Int32): String {
        let m = seconds / 60
        let s = seconds % 60
        return if (s < 10) { "${m}:0${s}" } else { "${m}:${s}" }
    }

    /** 录音态输入栏（替换附件键 + 输入框；麦克风键留在原位承接手势） */
    @Builder
    func voiceRecordingBar() {
        Row {
            Column {}
                .width(10)
                .height(10)
                .borderRadius(5)
                .backgroundColor(0xFF3B30)
            Text(this.formatVoiceDuration(this.voiceDuration))
                .fontSize(16)
                .fontColor(this.presentation.textColor)
                .margin(left: 8)
            Blank().layoutWeight(1)
            if (this.voiceLocked) {
                Text(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0xFF3B30)
                    .onClick({ _evt => this.finishVoiceRecording(true) })
            } else {
                Text("‹ Slide to cancel")
                    .fontSize(15)
                    .fontColor(0x8E8E93)
            }
        }
        .layoutWeight(1)
        .height(42)
        .padding(left: 12, right: 12)
        .alignItems(VerticalAlign.Center)
    }

    /**
     * S032/S221：发送键长按 → ChatSendMessageContextScreen（定时发送 / 静默发送 / 消息效果）。
     * 该屏自行完成发送并 routerPop；成功后经 registerSendContextSentHandler 回调清空输入框。
     */
    private func openSendContextMenu(): Unit {
        let text = this.inputText
        if (text.isEmpty()) { return }
        let pt = this.viewModel.peerType
        let pid = this.viewModel.chatId
        // S2-63 / S2-70: iOS ChatSendMessageActionSheetController → sendCurrentMessage(silently:)
        // / scheduleCurrentMessage; the sheet never sends by itself.
        registerSendContextActionHandler({ action: String, value: Int64 =>
            Hilog.info(0, "CjTelegram", "[SendOptions] action=${action} value=${value}")
            if (action == "silent") {
                this.sendMessageWithFormat(silent: true)
            } else if (action == "effect") {
                this.sendMessageWithFormat(effectId: value)
            } else if (action == "schedule") {
                this.openScheduleSheet()
            }
        })
        this.closeEntityKeyboard()
        routerPush("ChatSendMessageContextScreen", "${pt}|${pid}|${text}")
    }

    // ==================== S2-70: Schedule Message / Scheduled Messages ====================

    /** iOS ChatScheduleTimeController: opens with tomorrow at the current hour:minute. */
    private func openScheduleSheet(): Unit {
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        this.scheduleSheetInitialSec = nowSec + 86400
        this.blurComposer()
        this.showScheduleSheet = true
    }

    /**
     * iOS Conversation.ScheduleMessage.SendToday / SendTomorrow / SendOn button title
     * for the picked time; the time part follows the message timestamp clock.
     */
    private func scheduleButtonLabel(pickedSec: Int64): String {
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        let timeText = formatMessageTime(pickedSec)
        let pickedDay = localDayIndexOf(pickedSec)
        let todayDay = localDayIndexOf(nowSec)
        if (pickedDay == todayDay) {
            return trOr("Conversation.ScheduleMessage.SendToday", "Send today at %@").replace("%@", timeText)
        } else if (pickedDay == todayDay + 1) {
            return trOr("Conversation.ScheduleMessage.SendTomorrow", "Send tomorrow at %@").replace("%@", timeText)
        }
        return trOr("Conversation.ScheduleMessage.SendOn", "Send on %@ at %@")
            .replace("%@ at %@", "${formatFullDate(pickedSec)} at ${timeText}")
    }

    private func confirmScheduleMessage(pickedSec: Int64): Unit {
        this.showScheduleSheet = false
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        // iOS: minimum is one minute from now (ChatScheduleTimeController minimalTime).
        var sendAt = pickedSec
        if (sendAt < nowSec + 60) { sendAt = nowSec + 60 }
        Hilog.info(0, "CjTelegram", "[Schedule] confirm sendAt=${sendAt} (${formatFullDate(sendAt)} ${formatMessageTime(sendAt)})")
        this.sendMessageWithFormat(scheduleDate: Int32(sendAt))
    }

    /** iOS ChatController.openScheduledMessages: push the scheduled-messages history. */
    private func openScheduledMessages(): Unit {
        this.blurComposer()
        this.closeEntityKeyboard()
        this.showScheduledMessages = true
        this.reloadScheduledMessages()
    }

    private func reloadScheduledMessages(): Unit {
        this.scheduledMessagesLoading = true
        let _ = spawn {
            let list = this.viewModel.loadScheduledMessages()
            launch {
                this.scheduledMessages = list
                this.scheduledMessagesLoading = false
                this.hasScheduledMessagesMirror = list.size > 0
                Hilog.info(0, "CjTelegram", "[Schedule] scheduled list size=${list.size}")
            }
        }
    }

    /** iOS ScheduledMessages.ScheduledDate / ScheduledToday label above each scheduled bubble. */
    private func scheduledDateLabel(msg: Message): String {
        let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
        if (localDayIndexOf(msg.rawTimestamp) == localDayIndexOf(nowSec)) {
            return trOr("ScheduledMessages.ScheduledToday", "Scheduled for today")
        }
        return trOr("ScheduledMessages.ScheduledDate", "Scheduled for %@").replace("%@", formatFullDate(msg.rawTimestamp))
    }

    /** iOS scheduled-message context menu: Send Now / Delete (ScheduledMessages.SendNow / .Delete). */
    private func openScheduledMessageActions(msg: Message): Unit {
        let targetId = msg.id
        let uiCtx = getUIContext()
        let cancelBtn = AlertDialogButtonOptions(value: trOr("Common.Cancel", "Cancel"), action: { => () })
        let sendNowBtn = AlertDialogButtonOptions(
            value: trOr("ScheduledMessages.SendNow", "Send Now"),
            action: { =>
                let _ = spawn {
                    let ok = this.viewModel.sendScheduledMessageNow(targetId)
                    Hilog.info(0, "CjTelegram", "[Schedule] sendNow id=${targetId} ok=${ok}")
                    launch { this.reloadScheduledMessages() }
                }
            }
        )
        let deleteBtn = AlertDialogButtonOptions(
            value: trOr("ScheduledMessages.Delete", "Delete Scheduled Message"),
            fontColor: 0xFFFF3B30,
            action: { =>
                let _ = spawn {
                    let ok = this.viewModel.deleteScheduledMessage(targetId)
                    Hilog.info(0, "CjTelegram", "[Schedule] delete id=${targetId} ok=${ok}")
                    launch { this.reloadScheduledMessages() }
                }
            }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: "",
            message: msg.content,
            autoCancel: true,
            buttons: [cancelBtn, sendNowBtn, deleteBtn]
        ))
    }

    /** iOS ChatInterfaceInputContexts: scheduled-messages accessory when input is empty. */
    private func showScheduledAccessory(): Bool {
        return this.hasScheduledMessagesMirror && this.inputText.isEmpty() && this.viewModel.editingMsgId == 0
    }

    /** S8-08：导航栏头像对应的用户 id —— 秘密聊天取对端用户，其余取当前会话 id。 */
    private func avatarPeerId(): Int64 {
        if (this.secretPeerUserId > 0) { return this.secretPeerUserId }
        return getSelectedChatId()
    }

    /** S8-08：iOS EnginePeer.compactDisplayTitle —— 对端 firstName，缺省用会话名。 */
    private func secretPeerCompactTitle(): String {
        var name = this.chatName
        if (this.secretPeerUserId > 0) {
            match (getUserPhotoService().getCachedUser(this.secretPeerUserId)) {
                case Some(u) => if (u.firstName.size > 0) { name = u.firstName }
                case None => ()
            }
        }
        return name
    }

    /** S8-08：iOS DialogList_AwaitingEncryption(compactDisplayTitle)。 */
    private func secretHandshakeStatusText(): String {
        return trOr("DialogList.AwaitingEncryption", "Waiting for %@ to get online...").replace("%@", this.secretPeerCompactTitle())
    }

    /**
     * S8-08：iOS ChatEmptyNodeSecretChatContent（ChatEmptyNode.swift:299-430）——
     * 发起方标题 Conversation.EncryptedPlaceholderTitleOutgoing（semibold 15，居中），
     * 副标题 Conversation.EncryptedDescriptionTitle（13），四行 EncryptedDescription1-4
     * 各带 chatEmptyItemLockIcon（9×13，iconInset 14，行距 11），整卡 inset 15，
     * 底色 / 文字取 serviceMessageColorComponents（与本工程服务消息胶囊同色）。
     */
    @Builder
    func secretChatEmptyLine(text: String) {
        Row {
            Image(@r(app.media.clist_ic_secretchat))
                .width(10)
                .height(13)
                .fillColor(0xFFFFFFFF)
                .margin(right: 4, top: 1)
            Text(text)
                .fontSize(this.scaledFontSize(13))
                .fontColor(0xFFFFFF)
                .layoutWeight(1)
        }
        .width(100.percent)
        .alignItems(VerticalAlign.Top)
        .margin(top: 11)
    }

    @Builder
    func secretChatEmptyCard() {
        Column {
            Column {
                Text(trOr("Conversation.EncryptedPlaceholderTitleOutgoing", "You have invited %@ to join a secret chat.")
                        .replace("%@", this.secretPeerCompactTitle()))
                    .fontSize(this.scaledFontSize(15))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
                    .width(100.percent)
                Text(trOr("Conversation.EncryptedDescriptionTitle", "Secret chats:"))
                    .fontSize(this.scaledFontSize(13))
                    .fontColor(0xFFFFFF)
                    .width(100.percent)
                    .margin(top: 5)
                this.secretChatEmptyLine(trOr("Conversation.EncryptedDescription1", "Use end-to-end encryption"))
                this.secretChatEmptyLine(trOr("Conversation.EncryptedDescription2", "Leave no trace on our servers"))
                this.secretChatEmptyLine(trOr("Conversation.EncryptedDescription3", "Have a self-destruct timer"))
                this.secretChatEmptyLine(trOr("Conversation.EncryptedDescription4", "Do not allow forwarding"))
            }
            .alignItems(HorizontalAlign.Start)
            .constraintSize(maxWidth: 300)
            .padding(15)
            .backgroundColor(0xB0B0B0)
            .borderRadius(16)
        }
        .width(100.percent)
        .height(100.percent)
        .padding(left: 16, right: 16)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    private func jumpToMessageFromCalendar(msgId: Int64): Unit {
        // iOS ChatControllerOpenCalendarSearch.navigateToDay：updatedSearch(nil) 先收起搜索栏再定位
        this.showMessageSearch = false
        this.setSearchHighlight("", ArrayList<Int64>())
        // 按 displayMessages 索引定位（相册组合并后与 messageList 索引不一致，按后者滚会越过目标），
        // 顶对齐：该日首条消息连同其上方的日期 pill 落在视口顶部；不在窗口内先围绕锚点补历史，
        // 快照重建与回调不同帧，按 100ms 重试。
        if (this.scrollToAndHighlight(msgId, align: ScrollAlign.Start)) { return }
        this.viewModel.loadHistoryAround(Int32(msgId), { =>
            this.retryScrollToAndHighlight(msgId, 10, align: ScrollAlign.Start)
        })
    }

    private func hasMessageInList(msgId: Int64): Bool {
        let messages = this.viewModel.messageList
        var i: Int64 = 0
        while (i < Int64(messages.size)) {
            if (messages[i].id == msgId) { return true }
            i += 1
        }
        return false
    }

    /**
     * S4-12: iOS ChatController.updateItemNodesSearchTextHighlightStates — remember the query and
     * the result message ids, then rebuild the display list so the affected bubbles (render key
     * includes MessageEntry.searchHighlight) repaint with the matched text highlighted.
     */
    private func setSearchHighlight(query: String, ids: ArrayList<Int64>): Unit {
        let idMap = HashMap<Int64, Bool>()
        for (id in ids) { idMap[id] = true }
        let changed = query != this._searchHighlightQuery || idMap.size != this._searchHighlightIds.size
        this._searchHighlightQuery = if (ids.isEmpty()) { "" } else { query }
        this._searchHighlightIds = idMap
        if (changed) { this.rebuildDisplayMessages() }
    }

    private func scrollToMessage(msgId: Int64): Unit {
        let messages = this.viewModel.messageList
        var targetIdx: Int64 = -1
        var i: Int64 = 0
        while (i < Int64(messages.size)) {
            if (messages[i].id == msgId) {
                targetIdx = i
                break
            }
            i += 1
        }
        if (targetIdx >= 0) {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] Scrolling to message idx=${targetIdx}")
            this._pinnedToLatest = false
            try {
                this.listScroller.scrollToIndex(Int32(targetIdx), smooth: true, align: ScrollAlign.Center)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] scrollToIndex failed: ${e}")
            }
        } else {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] Message ${msgId} not found in current list")
        }
    }

    // ==================== Phase P0-1: 转发消息辅助方法 ====================
    
    /**
     * 加载对话列表用于转发选择器
     * 优先复用 ChatListViewModel 缓存，无缓存时调 RealChatListService.getDialogs()
     */
    private func loadForwardDialogs(): Unit {
        match (getChatListVM()) {
            case Some(vm) =>
                if (vm.chatList.size > 0) {
                    this.forwardDialogs = vm.chatList
                    Hilog.info(0, "CjTelegram", "[ChatRoomPage] Forward dialogs loaded from cache")
                    return
                }
            case None => ()
        }
        // 缓存为空，异步加载
        spawn {
            try {
                let svc = getRealChatListService()
                let dialogs = svc.getDialogs()
                this.forwardDialogs = dialogs
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] Forward dialogs loaded from service")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatRoomPage] Load forward dialogs failed: ${e}")
            }
        }
    }
    
    /**
     * 获取过滤后的转发目标对话列表（供 build 中 ForEach 使用）
     * 按搜索关键字过滤聊天名称
     */
    private func getFilteredForwardDialogs(): Array<ChatEntry> {
        let result = ArrayList<ChatEntry>()
        let searchLower = this.forwardSearchText.toAsciiLower()
        for (chat in this.forwardDialogs) {
            if (searchLower.size == 0 || chat.name.toAsciiLower().contains(searchLower)) {
                result.add(ChatEntry(chat))
            }
        }
        return result.toArray()
    }
    
    /**
     * 执行转发：关闭选择器 → 调用 ViewModel.forwardMessage → 真实 API 调用
     * 
     * 数据流: onClick → executeForward → ChatRoomViewModel.forwardMessage
     *   → RealMessageService.forwardMessages → messages.forwardMessages TL
     */
    /**
     * 执行转发：关闭选择器 → 调用 ViewModel
     * P2-115: 支持批量转发 + drop_author/drop_media_captions 标志
     * 单条: forwardMsgIds.size == 1; 批量: forwardMsgIds.size > 1
     */
    private func executeForward(targetChat: Chat): Unit {
        let targetId = targetChat.id
        let targetPeerType = targetChat.peerType
        let targetName = targetChat.name
        let dropAuthorCopy = this.forwardDropAuthor
        let dropCaptionsCopy = this.forwardDropCaptions

        // 关闭选择器
        this.showForwardPicker = false
        this.forwardSearchText = ""
        this.forwardDropAuthor = false
        this.forwardDropCaptions = false

        // iOS ChatControllerForwardMessages.swift:250-262: after forwarding, an undo overlay says
        // where the message went ("Message forwarded to Saved Messages" / "... to <chat>").
        let many = this.forwardMsgIds.size > 1
        let toSaved = targetChat.isSavedMessages || (targetPeerType == "user" && targetId != 0 && targetId == getCurrentUserId())
        let tooltip = forwardTooltipText(many, toSaved, targetName)
        let onResult: (Bool) -> Unit = { ok: Bool =>
            if (ok) {
                launch { showToast(tooltip) }
            } else {
                // A rejected forward must not look like success (the message never reaches the target).
                launch { showToast(trOr("Login.UnknownError", "An error occurred, please try again later.")) }
            }
        }
        if (many) {
            // P2-115: 批量转发多条消息
            let idsCopy = ArrayList<Int64>()
            for (id in this.forwardMsgIds) { idsCopy.add(id) }
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] Batch forward ${idsCopy.size} msgs to ${targetName}")
            this.viewModel.forwardMessages(idsCopy, targetPeerType, targetId,
                dropAuthor: dropAuthorCopy, dropMediaCaptions: dropCaptionsCopy, onResult: Some(onResult))
        } else {
            Hilog.info(0, "CjTelegram", "[ChatRoomPage] Forward msg ${this.forwardMsgId} to ${targetName} (${targetPeerType}:${targetId})")
            this.viewModel.forwardMessage(this.forwardMsgId, targetPeerType, targetId,
                dropAuthor: dropAuthorCopy, dropMediaCaptions: dropCaptionsCopy, onResult: Some(onResult))
        }

        // 若多选模式发起的批量转发，退出多选
        if (this.isMultiSelectMode) {
            this.setMultiSelectMode(false)
            this.selectedMessageIds = HashMap<Int64, Bool>()
        }
        this.forwardMsgIds = ArrayList<Int64>()
    }

    // ==================== P2-116: Reactor 列表覆盖层 ====================

    /**
     * 构建 reactor 列表覆盖层
     *
     * iOS 对应: messages.getMessageReactionsList → ReactionListContextMenuContent
     * 在当前覆盖层中显示反应该消息的用户列表。
     *
     * 布局: 半透明背景 + 中央卡片（从 viewModel.reactorsList 实时读取）
     * 遵守 S-013: @Builder 不能是 private。
     */
    // ==================== P2-118: 已读参与者覆盖层 ====================

    /** PeerInfoScreen.openSavedMessagesMoreMenu (PIS:7267-7320). */
    @Builder
    func buildSavedModeMenu() {
        Column {}
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(this.presentation.contextMenuDimColor)
            .onClick({ _evt => this.showSavedModeMenu = false })
        Column {
            Row(space: 10) {
                Blank().width(18)
                Text(trOr("Chat.SavedMessagesModeMenu.ViewAsChats", "View as Chats"))
                    .fontSize(17)
                    .fontColor(this.presentation.contextMenuPrimaryColor)
                    .layoutWeight(1)
            }
            .width(100.percent)
            .height(46)
            .padding(left: 14, right: 14)
            .onClick({ _evt =>
                this.showSavedModeMenu = false
                // iOS replaces the chat with the Saved Messages info screen.
                routerReplaceTop("SavedMessagesPage", "profile")
            })
            Divider().strokeWidth(0.5).color(this.presentation.contextMenuSeparatorColor)
            Row(space: 10) {
                Image(@r(app.media.vc_ic_ctx_check))
                    .width(18)
                    .height(18)
                    .fillColor(this.presentation.contextMenuPrimaryColor)
                Text(trOr("Chat.SavedMessagesModeMenu.ViewAsMessages", "View as Messages"))
                    .fontSize(17)
                    .fontColor(this.presentation.contextMenuPrimaryColor)
                    .layoutWeight(1)
            }
            .width(100.percent)
            .height(46)
            .padding(left: 14, right: 14)
            .onClick({ _evt => this.showSavedModeMenu = false })
        }
        .width(250)
        .backgroundColor(this.presentation.contextMenuBackgroundColor)
        .borderRadius(14)
        .shadow(radius: 18.0, color: 0x30000000, offsetY: 6.0)
        .position(x: this.messageContextScreenWidth - 262.0, y: getSafeAreaTop() + 58.0)
    }

    @Builder
    func buildReadParticipantsOverlay() {
        // 半透明背景 — 点击关闭
        Column {}
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0x66000000)
            .onClick({ evt =>
                this.showReadParticipants = false
            })

        // 卡片
        Column {
            // 标题行
            Row {
                Text("Seen by")
                    .fontSize(this.scaledFontSize(17))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.presentation.textColor)
                    .layoutWeight(1)
                // 资源保真修复：真实矢量图标（Chat/Context Menu/Clear.imageset/ic_lt_clear.pdf 转 SVG）替代 emoji 字形
                Image(@r(app.media.chatroom_ic_close))
                    .width(18)
                    .height(18)
                    .fillColor(0x8E8E93)
                    .padding(9)
                    .onClick({ evt =>
                        this.showReadParticipants = false
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 8, top: 14, bottom: 8)
            .alignItems(VerticalAlign.Center)

            // 参与者列表
            if (this.viewModel.readParticipantsList.isEmpty()) {
                Column {
                    Text(trSource("Loading..."))
                        .fontSize(this.scaledFontSize(14))
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(80)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll() {
                    Column(space: 0) {
                        ForEach(this.viewModel.readParticipantsList.toArray(), itemGenerator: { rec: ReadParticipantRecord, _idx: Int64 =>
                            Row(space: 12) {
                                // 头像占位（首字母圆形）
                                Column {
                                    Text(this.participantInitials(rec.displayName))
                                        .fontSize(this.scaledFontSize(14))
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFFFFFF)
                                }
                                .width(36)
                                .height(36)
                                .borderRadius(18)
                                .backgroundColor(0x5B8BD0)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(HorizontalAlign.Center)
                                // 名称
                                Column {
                                    Text(if (rec.displayName.size > 0) { rec.displayName } else { "User ${rec.userId}" })
                                        .fontSize(this.scaledFontSize(15))
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(this.presentation.textColor)
                                        .maxLines(1)
                                }
                                .layoutWeight(1)
                                .alignItems(HorizontalAlign.Start)
                                // 已读双勾
                                // 资源保真修复：真实矢量图标（还原 iOS generateCheckImage 双勾叠加绘制）替代 emoji 字形
                                Stack {
                                    Image(@r(app.media.chatroom_ic_check))
                                        .width(13)
                                        .height(11)
                                        .fillColor(0x5AC8FA)
                                        .position(x: 0, y: 0)
                                    Image(@r(app.media.chatroom_ic_check))
                                        .width(13)
                                        .height(11)
                                        .fillColor(0x5AC8FA)
                                        .position(x: 5, y: 0)
                                }
                                .width(18)
                                .height(11)
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                        })
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .height(240)
                .scrollBar(BarState.Auto)
            }
        }
        .width(90.percent)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(16)
        .shadow(radius: 16.00, color: 0x33000000, offsetX: 0.0, offsetY: 4.0)
        .position(x: 5.percent, y: 20.percent)
    }

    private func participantInitials(name: String): String {
        if (name.isEmpty()) { return "?" }
        let parts = name.split(" ")
        if (parts.size >= 2) {
            let a = parts[0]
            let b = parts[1]
            if (a.size > 0 && b.size > 0) {
                return a[0..1] + b[0..1]
            }
        }
        if (parts[0].size > 0) {
            return parts[0][0..1]
        }
        return "?"
    }

    @Builder
    func buildReactorListOverlay() {
        // 半透明背景 — 点击关闭
        Column {}
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0x66000000)
            .onClick({ evt =>
                this.showReactorList = false
            })

        // 卡片
        Column {
            // 标题行
            Row {
                Text(trSource("Reactions"))
                    .fontSize(this.scaledFontSize(17))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.presentation.textColor)
                    .layoutWeight(1)
                // 资源保真修复：真实矢量图标（Chat/Context Menu/Clear.imageset/ic_lt_clear.pdf 转 SVG）替代 emoji 字形
                Image(@r(app.media.chatroom_ic_close))
                    .width(18)
                    .height(18)
                    .fillColor(0x8E8E93)
                    .padding(9)
                    .onClick({ evt =>
                        this.showReactorList = false
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 8, top: 14, bottom: 8)
            .alignItems(VerticalAlign.Center)

            // reactor 列表
            if (this.viewModel.reactorsList.isEmpty()) {
                // 加载中
                Column {
                    Text(trSource("Loading..."))
                        .fontSize(this.scaledFontSize(14))
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(80)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll() {
                    Column(space: 0) {
                        ForEach(this.viewModel.reactorsList.toArray(), itemGenerator: { info: ReactorInfo, _idx: Int64 =>
                            Row(space: 12) {
                                // 头像占位（首字母圆形）
                                buildReactorAvatar(info)
                                // 名称 + emoji
                                Column {
                                    Text(info.displayName)
                                        .fontSize(this.scaledFontSize(15))
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(this.presentation.textColor)
                                        .maxLines(1)
                                }
                                .layoutWeight(1)
                                .alignItems(HorizontalAlign.Start)
                                // 反应 emoji
                                Text(info.emoji)
                                    .fontSize(this.scaledFontSize(22))
                            }
                            .width(100.percent)
                            .height(52)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                        })
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .height(240)
                .scrollBar(BarState.Auto)
            }
        }
        .width(90.percent)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(16)
        .shadow(radius: 16.00, color: 0x33000000, offsetX: 0.0, offsetY: 4.0)
        .position(x: 5.percent, y: 20.percent)
    }

    @Builder
    func buildReactorAvatar(info: ReactorInfo) {
        Column {
            Text(this.reactorInitials(info.displayName))
                .fontSize(this.scaledFontSize(14))
                .fontWeight(FontWeight.Medium)
                .fontColor(0xFFFFFF)
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(0x5B8BD0)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    private func reactorInitials(name: String): String {
        if (name.isEmpty()) { return "?" }
        let parts = name.split(" ")
        if (parts.size >= 2) {
            let a = parts[0]
            let b = parts[1]
            if (a.size > 0 && b.size > 0) {
                return a[0..1] + b[0..1]
            }
        }
        if (parts[0].size > 0) {
            return parts[0][0..1]
        }
        return "?"
    }

    // ==================== P2-038: Inline Bot Result Panel Helpers ====================

    /**
     * 返回内联 bot 结果类型的简短标签（用于媒体网格缩略图占位显示）
     * 对应 BotInlineResult.type 字段（TL string: photo/gif/video/audio/voice/document/sticker/location/venue/contact/game/article）
     */
    private func inlineResultTypeLabel(t: String): String {
        if (t == "photo") { return "Photo" }
        if (t == "gif") { return "GIF" }
        if (t == "video") { return "Video" }
        if (t == "audio") { return "Audio" }
        if (t == "voice") { return "Voice" }
        if (t == "document") { return "File" }
        if (t == "sticker") { return "Sticker" }
        if (t == "location") { return "Map" }
        if (t == "venue") { return "Venue" }
        if (t == "contact") { return "Contact" }
        if (t == "game") { return "Game" }
        if (t == "article") { return "Article" }
        return "Media"
    }

    /**
     * 返回内联 bot 结果类型的单字母图标（纵向列表使用）
     */
    private func inlineResultTypeIcon(t: String): String {
        if (t == "photo") { return "P" }
        if (t == "gif") { return "G" }
        if (t == "video") { return "V" }
        if (t == "audio") { return "A" }
        if (t == "voice") { return "V" }
        if (t == "document") { return "F" }
        if (t == "sticker") { return "S" }
        if (t == "location") { return "L" }
        if (t == "venue") { return "V" }
        if (t == "contact") { return "C" }
        if (t == "game") { return "G" }
        if (t == "article") { return "A" }
        return "?"
    }

    /**
     * 用户选中内联 bot 结果后调用
     *
     * P2-038: 对应 iOS ChatController didSelectContextResult(_:uniqueId:)
     * 调用链:
     *   ChatRoomPage.onInlineBotResultSelected(item)
     *     → spawn { WebSearchService.sendSelectedResult(queryId, resultId, peerId, peerAccessHash) }
     *         → getMTProtoClient().sendRequest(MessagesSendInlineBotResult#c0cf7646.toBytes())
     *
     * ctor verified: messages.sendInlineBotResult#c0cf7646
     * iOS ref: Api42.swift:9371 buffer.appendInt32(-1060145594) → 0xc0cf7646
     */
    private func onInlineBotResultSelected(item: ContextQueryResultItem): Unit {
        let capturedQueryId = this.contextQueryVM.inlineBotQueryId
        let capturedResultId = item.resultId
        let capturedPeerId = this.contextQueryVM.peerId
        let capturedPeerHash = this.contextQueryVM.peerAccessHash
        this.contextQueryVM.clearSuggestions()
        let _ = spawn {
            let svc = getWebSearchService()
            let _ = svc.sendSelectedResult(capturedQueryId, capturedResultId, capturedPeerId, capturedPeerHash)
        }
    }
}

// ==================== 辅助函数 ====================

/**
 * 扫描目录查找照片文件
 */
func scanPhotoDirectory(dirPath: String): ArrayList<String> {
    let results = ArrayList<String>()
    try {
        let dirExists = FileIo.access(dirPath)
        if (!dirExists) { return results }
        
        let entries = FileIo.listFile(dirPath)
        for (entry in entries) {
            let filePath = dirPath + "/" + entry
            results.add(filePath)
            Hilog.info(0, "CjTelegram", "[scanPhotoDir] Found: ${filePath}")
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[scanPhotoDir] Error scanning: ${e}")
    }
    return results
}

// ==================== Phase P6-3: 消息分组位置计算 ====================

/**
 * 计算消息列表中每条消息的分组位置
 * 
 * 分组规则：
 * - 相邻消息 senderId 相同
 * - 方向相同（都是 isSent 或都不是）
 * - 时间间隔不超过 180 秒
 * - 不被 service 消息打断
 * 
 * 计算结果直接写入 Message 字段：
 * - isFirstInGroup, isLastInGroup, isMiddleInGroup, isSingleMessage
 * - showDateSeparator, dateSeparatorText
 */
/**
 * P2-112: 标注未读分隔线
 *
 * 对照 iOS unread separator：在 id == firstUnreadId 的消息上方显示"N 条未读消息"分隔线。
 * firstUnreadId == 0 表示无未读，清除所有标注。
 *
 * @param messages       消息列表
 * @param firstUnreadId  第一条未读消息的 ID（0 = 无未读）
 * @param unreadCount    未读消息总数（用于生成分隔线文本）
 */
func computeUnreadSeparator(messages: ArrayList<Message>, firstUnreadId: Int64, unreadCount: Int32): Unit {
    for (m in messages) {
        m.showUnreadSeparator = false
        m.unreadSeparatorText = ""
    }
    if (firstUnreadId <= 0) { return }
    for (m in messages) {
        if (m.id == firstUnreadId) {
            m.showUnreadSeparator = true
            m.unreadSeparatorText = if (unreadCount > 1) {
                "${unreadCount} unread messages"
            } else {
                "1 unread message"
            }
            break
        }
    }
}

func computeMessageGroupPositions(messages: ArrayList<Message>): Unit {
    let count = messages.size
    if (count == 0) { return }

    for (i in 0..count) {
        let msg = messages[i]
        
        // 默认值
        msg.isFirstInGroup = true
        msg.isLastInGroup = true
        msg.isMiddleInGroup = false
        msg.isSingleMessage = true
        msg.showDateSeparator = false
        msg.dateSeparatorText = ""
        
        // 日期分隔线检查（与前一条消息比较）。日界按本地日历（iOS ChatMessageDateHeader 用
        // Calendar.current），不能按 UTC 整除 86400——那会把分隔线放在本地 08:00。
        if (i > 0) {
            let prev = messages[i - 1]
            if (prev.rawTimestamp > 0 && msg.rawTimestamp > 0) {
                let prevDay = localDayIndexOf(prev.rawTimestamp)
                let curDay = localDayIndexOf(msg.rawTimestamp)
                if (prevDay != curDay) {
                    msg.showDateSeparator = true
                    msg.dateSeparatorText = formatDateSeparator(msg.rawTimestamp)
                }
            }
        } else if (msg.rawTimestamp > 0) {
            // 第一条消息也显示日期
            msg.showDateSeparator = true
            msg.dateSeparatorText = formatDateSeparator(msg.rawTimestamp)
        }
        
        // 分组：检查与前一条是否同组
        var sameGroupWithPrev = false
        if (i > 0) {
            let prev = messages[i - 1]
            sameGroupWithPrev = canGroupMessages(prev, msg)
        }
        
        // 分组：检查与后一条是否同组
        var sameGroupWithNext = false
        if (i < count - 1) {
            let next = messages[i + 1]
            sameGroupWithNext = canGroupMessages(msg, next)
        }
        
        // 日期分隔线打断分组
        if (msg.showDateSeparator) {
            sameGroupWithPrev = false
        }
        // 下一条如果有日期分隔线也打断
        if (i < count - 1 && messages[i + 1].showDateSeparator) {
            // 需要再检查下一条的日期分隔（还未计算，手动检查）
            let next = messages[i + 1]
            if (next.rawTimestamp > 0 && msg.rawTimestamp > 0) {
                let curDay = localDayIndexOf(msg.rawTimestamp)
                let nextDay = localDayIndexOf(next.rawTimestamp)
                if (curDay != nextDay) {
                    sameGroupWithNext = false
                }
            }
        }
        
        if (sameGroupWithPrev && sameGroupWithNext) {
            msg.isFirstInGroup = false
            msg.isLastInGroup = false
            msg.isMiddleInGroup = true
            msg.isSingleMessage = false
        } else if (sameGroupWithPrev && !sameGroupWithNext) {
            msg.isFirstInGroup = false
            msg.isLastInGroup = true
            msg.isMiddleInGroup = false
            msg.isSingleMessage = false
        } else if (!sameGroupWithPrev && sameGroupWithNext) {
            msg.isFirstInGroup = true
            msg.isLastInGroup = false
            msg.isMiddleInGroup = false
            msg.isSingleMessage = false
        } else {
            msg.isFirstInGroup = true
            msg.isLastInGroup = true
            msg.isMiddleInGroup = false
            msg.isSingleMessage = true
        }
    }
}

/**
 * 判断两条消息是否可以分为同一组
 * 条件：同 sender、同方向、间隔不超 180 秒、无 service 消息
 */
func canGroupMessages(prev: Message, curr: Message): Bool {
    // service 消息打断分组
    if (prev.messageType == "service" || curr.messageType == "service") {
        return false
    }
    // 通话消息打断分组
    if (prev.isCallMessage || curr.isCallMessage) {
        return false
    }
    // 方向不同
    if (prev.isSent != curr.isSent) {
        return false
    }
    // 发送者不同
    if (prev.senderId != curr.senderId) {
        return false
    }
    // 圆形视频（video_note）在 iOS 是 .none —— 不与任何相邻消息合并
    // （ChatMessageItemImpl.swift:29-31 mediaMergeableStyle）。
    if (prev.messageType == "video_note" || curr.messageType == "video_note") {
        return false
    }
    // 时间间隔：iOS 是 10 分钟
    // （ChatMessageItemImpl.swift:171 abs(lhs - rhs) < Int32(10 * 60)）。
    // 此前写死 180 秒，间隔 3~10 分钟的连续消息我们不合并、iOS 合并。
    if (prev.rawTimestamp > 0 && curr.rawTimestamp > 0) {
        let gap = curr.rawTimestamp - prev.rawTimestamp
        if (gap > 600 || gap < -600) {
            return false
        }
    }
    return true
}

/**
 * 格式化日期分隔线文字
 * 将 UNIX 时间戳转为 "Today"、"Yesterday"、"Feb 15" 等
 */
func formatDateSeparator(timestamp: Int64): String {
    // 今天/昨天与月日都按本地日历（iOS ChatMessageDateHeader：Calendar.current）
    let now = DateTime.now()
    let nowTs = now.toUnixTimeStamp().toSeconds()
    let msgDay = localDayIndexOf(timestamp)
    let todayDay = localDayIndexOf(nowTs)

    if (msgDay == todayDay) {
        return trOr("Weekday.Today", "Today")
    } else if (msgDay == todayDay - 1) {
        return trOr("Weekday.Yesterday", "Yesterday")
    } else {
        // 将时间戳转为本地月+日格式
        let dt = DateTime.fromUnixTimeStamp(Duration.second * timestamp).inLocal()
        let monthVal = dt.monthValue
        let day = dt.dayOfMonth
        let monthKeys = [
            "Time.MonthOfYear_m1", "Time.MonthOfYear_m2", "Time.MonthOfYear_m3",
            "Time.MonthOfYear_m4", "Time.MonthOfYear_m5", "Time.MonthOfYear_m6",
            "Time.MonthOfYear_m7", "Time.MonthOfYear_m8", "Time.MonthOfYear_m9",
            "Time.MonthOfYear_m10", "Time.MonthOfYear_m11", "Time.MonthOfYear_m12"
        ]
        let monthFallbacks = [
            "January %@", "February %@", "March %@", "April %@", "May %@", "June %@",
            "July %@", "August %@", "September %@", "October %@", "November %@", "December %@"
        ]
        // iOS ChatMessageDateHeader（ChatMessageDateHeader.swift:281-288）：不同年份的日期
        // 用 Date.ChatDateHeaderYear「%1$@ %2$@, %3$@」（Month.Gen* + 日 + 年）。不带年份时
        // 跨年的历史会显示成「September 18」在「August 22」之上，看起来像乱序。
        let nowYear = DateTime.fromUnixTimeStamp(Duration.second * nowTs).inLocal().year
        if (monthVal >= 1 && monthVal <= 12 && dt.year != nowYear) {
            let genKeys = [
                "Month.GenJanuary", "Month.GenFebruary", "Month.GenMarch", "Month.GenApril",
                "Month.GenMay", "Month.GenJune", "Month.GenJuly", "Month.GenAugust",
                "Month.GenSeptember", "Month.GenOctober", "Month.GenNovember", "Month.GenDecember"
            ]
            let genFallbacks = [
                "January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November", "December"
            ]
            let monthName = trOr(genKeys[monthVal - 1], genFallbacks[monthVal - 1])
            return trOr("Date.ChatDateHeaderYear", "%1$@ %2$@, %3$@")
                .replace("%1$@", monthName)
                .replace("%2$@", "${day}")
                .replace("%3$@", "${dt.year}")
        }
        if (monthVal >= 1 && monthVal <= 12) {
            return trOr(monthKeys[monthVal - 1], monthFallbacks[monthVal - 1]).replace("%@", "${day}")
        }
        return "${monthVal}/${day}"
    }
}

/**
 * 读取文件为字节数组
 */
// ── 轻量 JSON 读取（仅解析 interop 回传的扁平 result 对象；PICK_PHOTO_ALBUM）──

/** iOS Conversation.ForwardTooltip.{SavedMessages,Chat}.{One,Many}, bold markers stripped. */
private func forwardTooltipText(many: Bool, toSaved: Bool, targetName: String): String {
    let text = if (toSaved) {
        if (many) {
            trOr("Conversation.ForwardTooltip.SavedMessages.Many", "Messages forwarded to **Saved Messages**")
        } else {
            trOr("Conversation.ForwardTooltip.SavedMessages.One", "Message forwarded to **Saved Messages**")
        }
    } else {
        let format = if (many) {
            trOr("Conversation.ForwardTooltip.Chat.Many", "Messages forwarded to **%@**")
        } else {
            trOr("Conversation.ForwardTooltip.Chat.One", "Message forwarded to **%@**")
        }
        format.replace("%@", targetName.replace("**", ""))
    }
    return text.replace("**", "")
}

private func attachFileNameOf(path: String): String {
    match (path.lastIndexOf("/")) {
        case Some(idx) => return path[(idx + 1)..path.size]
        case None => return path
    }
}

private func attachExtOf(name: String): String {
    match (name.lastIndexOf(".")) {
        case Some(idx) => return name[(idx + 1)..name.size].toAsciiLower()
        case None => return ""
    }
}

private func jsonBoolFieldPhoto(json: String, key: String): Bool {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let rest = json[(i + needle.size)..json.size]
            match (rest.indexOf("true")) {
                case Some(t) =>
                    match (rest.indexOf("false")) {
                        case Some(f) => return t < f
                        case None => return true
                    }
                case None => return false
            }
        case None => return false
    }
}

private func jsonStringFieldPhoto(json: String, key: String): String {
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let afterKey = json[(i + needle.size)..json.size]
            match (afterKey.indexOf("\"")) {
                case Some(q1) =>
                    let valStart = afterKey[(q1 + 1)..afterKey.size]
                    match (valStart.indexOf("\"")) {
                        case Some(q2) => return valStart[0..q2]
                        case None => return ""
                    }
                case None => return ""
            }
        case None => return ""
    }
}

// 解析 "paths":["a","b"] 为字符串数组（扁平字符串数组，无嵌套引号转义）。
private func jsonStringArrayFieldPhoto(json: String, key: String): ArrayList<String> {
    let result = ArrayList<String>()
    let needle = "\"${key}\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let afterKey = json[(i + needle.size)..json.size]
            match (afterKey.indexOf("[")) {
                case Some(lb) =>
                    match (afterKey.indexOf("]")) {
                        case Some(rb) =>
                            if (rb <= lb) { return result }
                            var body = afterKey[(lb + 1)..rb]
                            // 逐个提取双引号包裹的字符串项
                            while (true) {
                                match (body.indexOf("\"")) {
                                    case Some(q1) =>
                                        let tail = body[(q1 + 1)..body.size]
                                        match (tail.indexOf("\"")) {
                                            case Some(q2) =>
                                                result.add(tail[0..q2])
                                                body = tail[(q2 + 1)..tail.size]
                                            case None => return result
                                        }
                                    case None => return result
                                }
                            }
                            return result
                        case None => return result
                    }
                case None => return result
            }
        case None => return result
    }
    return result
}

func readFileBytes(filePath: String): Array<Byte> {
    try {
        let file = FileIo.open(filePath, mode: 0o0)  // 只读模式
        let stat = FileIo.stat(filePath)
        let fileSize = stat.size
        if (fileSize <= 0) {
            FileIo.close(file)
            return Array<Byte>(0, repeat: 0)
        }
        let buffer = Array<Byte>(fileSize, repeat: 0)
        let bytesRead = FileIo.read(file.fd, buffer)
        FileIo.close(file)
        Hilog.info(0, "CjTelegram", "[readFileBytes] Read ${bytesRead} bytes from ${filePath}")
        return buffer
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[readFileBytes] Error: ${e}")
        return Array<Byte>(0, repeat: 0)
    }
}

// ==================== Fix3: MP4/MOV 视频元数据解析 ====================
// 背景：HarmonyOS Cangjie 层未暴露 AVMetadataExtractor/AVPlayer.getDuration 绑定
//   （bindings/ffmpegBinding.cj probeContainerFormat 仅按扩展名返回硬编码占位尺寸）。
//   因此这里直接解析 MP4/MOV 的 box 结构提取真实 duration/宽/高：
//     moov > mvhd            → duration = durationTicks / timescale（秒）
//     moov > trak > tkhd     → width/height（16.16 定点数，取高 16 位；取面积最大的轨道）
//   非 MP4/MOV 或解析失败时返回 (0.0, 0, 0)，调用方保持原有行为（不回归）。

class Mp4Meta {
    var duration: Float64 = 0.0
    var width: Int32 = 0
    var height: Int32 = 0
}

class Mp4Range {
    var start: Int64 = -1
    var end: Int64 = 0
}

func mp4ReadU32BE(data: Array<Byte>, off: Int64): Int64 {
    if (off < 0 || off + 4 > data.size) { return 0 }
    return (Int64(data[off]) << 24) | (Int64(data[off + 1]) << 16) | (Int64(data[off + 2]) << 8) | Int64(data[off + 3])
}

func mp4ReadU64BE(data: Array<Byte>, off: Int64): Int64 {
    return (mp4ReadU32BE(data, off) << 32) | mp4ReadU32BE(data, off + 4)
}

func mp4BoxType(data: Array<Byte>, off: Int64): String {
    if (off < 0 || off + 4 > data.size) { return "" }
    var s = ""
    var k: Int64 = 0
    while (k < 4) {
        s = s + Rune(UInt32(data[off + k])).toString()
        k = k + 1
    }
    return s
}

// 在 [start, end) 内查找首个类型为 wantType 的 box，返回其 payload 区间。
func mp4FindBox(data: Array<Byte>, start: Int64, end: Int64, wantType: String): Mp4Range {
    let result = Mp4Range()
    var pos = start
    var guard: Int64 = 0
    while (pos + 8 <= end) {
        guard = guard + 1
        if (guard > 8192) { break }
        let size = mp4ReadU32BE(data, pos)
        let t = mp4BoxType(data, pos + 4)
        var headerSize: Int64 = 8
        var boxSize: Int64 = size
        if (size == 1) {
            boxSize = mp4ReadU64BE(data, pos + 8)
            headerSize = 16
        } else if (size == 0) {
            boxSize = end - pos
        }
        if (boxSize < headerSize) { break }
        var payloadEnd = pos + boxSize
        if (payloadEnd > end) { payloadEnd = end }
        if (t == wantType) {
            result.start = pos + headerSize
            result.end = payloadEnd
            return result
        }
        pos = pos + boxSize
    }
    return result
}

func extractMp4Metadata(data: Array<Byte>): Mp4Meta {
    let meta = Mp4Meta()
    let n = data.size
    if (n < 16) { return meta }
    let moov = mp4FindBox(data, 0, n, "moov")
    if (moov.start < 0) { return meta }
    let moovS = moov.start
    let moovE = moov.end

    // duration ← mvhd
    let mvhd = mp4FindBox(data, moovS, moovE, "mvhd")
    if (mvhd.start >= 0) {
        let mvhdS = mvhd.start
        let version = Int64(data[mvhdS])
        var timescale: Int64 = 0
        var durTicks: Int64 = 0
        if (version == 1) {
            // version/flags(4) + creation(8) + modification(8) + timescale(4) + duration(8)
            timescale = mp4ReadU32BE(data, mvhdS + 20)
            durTicks = mp4ReadU64BE(data, mvhdS + 24)
        } else {
            // version/flags(4) + creation(4) + modification(4) + timescale(4) + duration(4)
            timescale = mp4ReadU32BE(data, mvhdS + 12)
            durTicks = mp4ReadU32BE(data, mvhdS + 16)
        }
        if (timescale > 0) {
            meta.duration = Float64(durTicks) / Float64(timescale)
        }
    }

    // width/height ← 面积最大的 trak 的 tkhd（视频轨道；音频轨道 w/h=0）
    var pos = moovS
    var guard: Int64 = 0
    while (pos + 8 <= moovE) {
        guard = guard + 1
        if (guard > 8192) { break }
        let size = mp4ReadU32BE(data, pos)
        let t = mp4BoxType(data, pos + 4)
        var headerSize: Int64 = 8
        var boxSize: Int64 = size
        if (size == 1) {
            boxSize = mp4ReadU64BE(data, pos + 8)
            headerSize = 16
        } else if (size == 0) {
            boxSize = moovE - pos
        }
        if (boxSize < headerSize) { break }
        let pStart = pos + headerSize
        var pEnd = pos + boxSize
        if (pEnd > moovE) { pEnd = moovE }
        if (t == "trak") {
            let tkhd = mp4FindBox(data, pStart, pEnd, "tkhd")
            if (tkhd.start >= 0 && tkhd.end - tkhd.start >= 8) {
                // tkhd payload 末尾 8 字节为 width/height（16.16 定点数）
                let w = Int32(mp4ReadU32BE(data, tkhd.end - 8) >> 16)
                let h = Int32(mp4ReadU32BE(data, tkhd.end - 4) >> 16)
                if (Int64(w) * Int64(h) > Int64(meta.width) * Int64(meta.height)) {
                    meta.width = w
                    meta.height = h
                }
            }
        }
        pos = pos + boxSize
    }
    return meta
}

/**
 * Present recursive report options after the message overlay is dismissed.
 *
 * This remains a top-level function because the component macro rejects the
 * recursive callback graph required by Telegram's multi-level report flow.
 */
func showReportOptionsDialog(uiCtx: UIContext, optionTexts: Array<String>, onSubmit: (Int64) -> Unit): Unit {
    var buttons = ArrayList<AlertDialogButtonOptions>()
    var idx: Int64 = 0
    while (idx < optionTexts.size) {
        let capturedIdx = idx
        buttons.add(AlertDialogButtonOptions(
            value: optionTexts[capturedIdx],
            action: { => onSubmit(capturedIdx) }
        ))
        idx += 1
    }
    uiCtx.showAlertDialog(AlertDialogParamWithOptions(
        title: "Report",
        message: "Select a reason for reporting this message.",
        autoCancel: true,
        buttonDirection: DialogButtonDirection.Auto,
        buttons: buttons.toArray()
    ))
}

/**
 * 递归提交举报选项：命中 `onMoreOptions`（服务端多级举报分类，如 "Spam → 具体类型"）时
 * 自我递归再弹一层 `showReportOptionsDialog`。写成顶层自由函数自我递归（同 D-117 规避理由，
 * 见 showReportOptionsDialog 文档），`onToastShown` 是 ChatRoomPage 传入的 toast 展示回调
 * （最终成功时触发 "Reported" 提示，2 秒后自动隐藏，逻辑与旧版 reportDoneToast 完全一致）。
 */
func submitReportOption(uiCtx: UIContext, viewModel: ChatRoomViewModel, msgId: Int64, optionIndex: Int64, onToastShown: () -> Unit): Unit {
    viewModel.submitReport(
        msgId,
        optionIndex,
        { => onToastShown() },
        { nextTexts: Array<String> =>
            showReportOptionsDialog(uiCtx, nextTexts, { nextIdx: Int64 =>
                submitReportOption(uiCtx, viewModel, msgId, nextIdx, onToastShown)
            })
        },
        { => Hilog.info(0, "CjTelegram", "[ChatRoomPage] submitReportOption error msgId=${msgId}") }
    )
}

/**
 * 末尾一个「可见字符」占几个 Rune。
 *
 * iOS 的 deleteBackwards 删的是一个字形簇，不是一个码元。Telegram 里最常见的
 * 几种 Emoji 形态都是多码位组合，按码位删会把序列拆坏（👩‍❤️‍💋‍👨 删一次会碎成半个家庭）：
 *   ZWJ 序列      👩 + U+200D + ❤️ + U+200D + 💋 + U+200D + 👨
 *   肤色修饰      👍 + U+1F3FD
 *   变体选择符    ☺ + U+FE0F
 *   Keycap        1 + U+FE0F + U+20E3
 *   国旗          两个区域指示符 U+1F1E6..U+1F1FF
 *   旗帜标签序列  🏴 + U+E0067… + U+E007F
 */
func trailingGraphemeLength(runes: Array<Rune>): Int64 {
    let size = Int64(runes.size)
    if (size == 0) { return 0 }
    var i = size - 1
    while (i > 0) {
        let cur = UInt32(runes[i])
        let prev = UInt32(runes[i - 1])
        if (isGraphemeModifier(cur)) {
            i = i - 1
            continue
        }
        if (prev == 0x200D) {
            // 前面是 ZWJ：整段继续向前吞，落点可能又带修饰符，交给下一轮
            i = i - 2
            if (i < 0) { i = 0 }
            continue
        }
        if (isRegionalIndicator(cur) && isRegionalIndicator(prev)) {
            i = i - 1
            break
        }
        break
    }
    if (i < 0) { i = 0 }
    return size - i
}

func isGraphemeModifier(cp: UInt32): Bool {
    if (cp == 0xFE0E || cp == 0xFE0F || cp == 0x20E3 || cp == 0x200D) { return true }
    if (cp >= 0x1F3FB && cp <= 0x1F3FF) { return true }
    if (cp >= 0xE0020 && cp <= 0xE007F) { return true }
    return false
}

func isRegionalIndicator(cp: UInt32): Bool {
    return cp >= 0x1F1E6 && cp <= 0x1F1FF
}


/** `:关键词` 里允许出现的字符。 */
func isSuggestionWordChar(ch: Rune): Bool {
    let cp = UInt32(ch)
    if (cp >= 48 && cp <= 57) { return true }
    if (cp >= 65 && cp <= 90) { return true }
    if (cp >= 97 && cp <= 122) { return true }
    return cp == 95 || cp == 45
}

/** 冒号前必须是空白，否则 "http://" 这类会误触发建议条。 */
func isSuggestionBoundary(ch: Rune): Bool {
    let cp = UInt32(ch)
    return cp == 32 || cp == 10 || cp == 13 || cp == 9
}

/**
 * 系统 IME 高度监听（px）：喂给 g_lastImeHeightVp，让实体面板与系统键盘
 * 完全同尺寸。arg==0 是 IME 收起终值，必须下发。
 */
public class ChatImeHeightCallback <: Callback1Argument<UInt32> {
    private let onHeightPx: (Float64) -> Unit
    init(onHeightPx: (Float64) -> Unit) { this.onHeightPx = onHeightPx }
    public func invoke(err: ?BusinessException, arg: UInt32): Unit {
        match (err) {
            case Some(_) => return
            case None => ()
        }
        this.onHeightPx(Float64(arg))
    }
}

// ---- 预约 Video Chat 条的文案 ----
private func gcPad2(n: Int64): String { if (n < 10) { "0${n}" } else { "${n}" } }

/** 胶囊里的倒计时：<1 小时 "MM:SS"，<1 天 "H:MM:SS"，否则 "N days"；过点后显示 "Late"。 */
func groupCallCountdownText(at: Int64): String {
    if (at <= 0) { return "" }
    let now = DateTime.now().toUnixTimeStamp().toSeconds()
    let left = at - now
    if (left < 0) { return "Late" }
    if (left >= 86400) {
        let days = (left + 43200) / 86400
        return if (days == 1) { "1 day" } else { "${days} days" }
    }
    let h = left / 3600
    let m = (left % 3600) / 60
    let sec = left % 60
    return if (h > 0) { "${h}:${gcPad2(m)}:${gcPad2(sec)}" } else { "${gcPad2(m)}:${gcPad2(sec)}" }
}

/** iOS shortTimeIntervalString（NumericFormat.swift:225，非 large）："%@s" / "%@m" / "%@h" / "%@d" / "%@w" / "%@mo" / "%@y"。 */
func shortAutoremoveText(value: Int32): String {
    let v = Int64(value)
    if (v < 60) { return "${if (v < 1) { 1 } else { v }}s" }
    if (v < 3600) { return "${v / 60}m" }
    if (v < 86400) { return "${v / 3600}h" }
    if (v < 86400 * 7) { return "${v / 86400}d" }
    if (v < 86400 * 31) { return "${v / (86400 * 7)}w" }
    if (v < 86400 * 365) { return "${v / (86400 * 30)}mo" }
    return "${v / (86400 * 365)}y"
}
