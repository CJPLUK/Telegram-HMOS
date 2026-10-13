package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.base.ReuseParams
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.services.{getAppFilesDir, getThemesEngineService, getLocationResourcesService, LiveLocationTimerService, LIVE_LOCATION_INDEFINITE_PERIOD, getLiveLocationPositionService, LiveLocationPositionData, LiveLocationPositionService, triggerHaptic, getUserPhotoService, getCurrentUserId, formatCurrencyAmount, getTelegramCoreSettingsService, getWallpaperResourcesService, getStickersService}
import kit.CoreFileKit.*
import std.collection.ArrayList
import std.sync.*
import std.time.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.utils.{isSingleEmoji, containsOnlyEmoji, emojiCount, splitEmojiClusters, safeAnimateTo, parsePhoneNumber, formatPhoneNumber, chatOpenPerfBubbleAppeared}
import ohos.arkui.component_utils.ComponentUtils
import ohos_app_cangjie_entry.app.getAppState
// diag-suite_settings_appearance-TC-0413-round4.md OF-2 / RC-E: MessageDateHeader (below) reads the
// theme snapshot directly — this is an intentional exception to this file's "renderer never reads
// @StorageLink/currentPresentation(), caller feeds colour" invariant (see MessageBubble/
// MessageBubbleShape class docs), because the source date-separator (ChatMessageDateHeader.swift) is
// an independent list header that self-holds presentationData, unlike the bubble node.
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.core.storage.{BubbleForegroundColors, outgoingBubbleForegroundColors}

/** 位置气泡地图尺寸（vp）：iOS imageSize = (fitWidth, fitWidth*0.5)，fitWidth ≤ 300；本仓气泡取 260 */
let LOCATION_BUBBLE_MAP_W: Float64 = 260.0
let LOCATION_BUBBLE_MAP_H: Float64 = 130.0

/**
 * Phase Q11: 富文本片段（用于 ForEach 渲染）
 * 将消息文本按 entities 切分为带样式的片段
 */
/**
 * S2-24: mask for an unrevealed spoiler run — every non-space character becomes a shaded block
 * (U+2593), whitespace is kept so the masked run wraps like the original text.
 */
public func spoilerMaskText(text: String): String {
    let sb = StringBuilder()
    for (rune in text.toRuneArray()) {
        if (rune == r' ' || rune == r'\n' || rune == r'\t') {
            sb.append(rune.toString())
        } else {
            sb.append("\u{2593}")
        }
    }
    return sb.toString()
}

public class TextSegment <: ToString {
    public var text: String = ""
    public var isBold: Bool = false
    public var isItalic: Bool = false
    public var isCode: Bool = false
    public var isPre: Bool = false
    public var isStrike: Bool = false
    public var isUnderline: Bool = false
    public var isUrl: Bool = false
    public var isMention: Bool = false
    public var isSpoiler: Bool = false
    public var isBlockquote: Bool = false
    public var url: String = ""
    /** messageEntityCustomEmoji 的 document_id；非 0 表示这一段要画成内联表情。 */
    public var customEmojiId: Int64 = 0
    public var segIndex: Int64 = 0
    
    public init() {}
    
    public func toString(): String {
        "seg_${this.segIndex}"
    }
}

/**
 * S4-12: one run of message text while an in-chat search highlight is active.
 * isMatch runs get the iOS textHighlightColor background
 * (ChatMessageTextBubbleContentNode.updateSearchTextHighlightState → LinkHighlightingNode rects).
 */
public class SearchTextChunk {
    public var text: String = ""
    public var isMatch: Bool = false

    public init(text: String, isMatch: Bool) {
        this.text = text
        this.isMatch = isMatch
    }
}

/**
 * 消息气泡组件（Phase H 完整版 — 支持全部媒体类型 + Reactions）
 * 
 * 对应 TelegramHarmony MessageBubble.ets (946 行)
 * 对应 Telegram-iOS ChatMessageItemView (消息气泡)
 * 
 * 功能:
 * - 文本消息渲染
 * - 照片消息：缩略图 + 点击全屏
 * - 视频消息：缩略图 + 播放按钮覆盖 + 时长标签
 * - 语音消息：播放/暂停按钮 + 波形 + 进度 + 时长
 * - 文件/文档消息：文件图标 + 文件名 + 大小 + 下载按钮
 * - 贴纸消息：大号 emoji 显示
 * - GIF 消息：缩略图 + GIF 标签
 * - 位置消息：地图图标 + 坐标/地点名
 * - 联系人消息：头像缩写 + 姓名 + 电话
 * - 投票消息：问题 + 选项 + 进度条 + 票数
 * - 回复预览、转发来源、编辑标记
 * - 频道消息查看次数
 * - Reactions emoji 气泡行
 * - 长按操作菜单（快速反应栏）
 */
// ==================== 复用（对齐 iOS updateNode + setupItem）====================
//
// ForEach 的键值同时承担「身份」与「内容」双重职责：内容一变键值就变，框架便
// 「基于新的键值创建一个新的组件」（《ForEach：循环渲染》§键值生成规则），旧组件销毁、
// 新组件重建 —— 这就是发消息时最后一条气泡闪一下的根源。
// iOS 是两条通道：stableId 定身份（ChatListItem.swift:541 nodeConfiguredForParams 仅新增时建节点），
// updateNode(:572) 复用节点、setupItem(item:) 装入新数据。
//
// 仓颉的对应物是 @Reusable + aboutToReuse：组件实例进复用缓存而非销毁，
// 框架把新的构造参数放进 ReuseParams，**由组件自己取出赋值**（同 setupItem）。
//
// ⚠️ 关键约束（沙盒第 6-9 轮截屏实证，详见 docs/state_channel_design.md §4.5-4.10）：
//   依赖是按「**渲染节点读了哪些状态变量**」建立的。
//   节点读到一个会变的 @State，重绘时整个表达式重新求值，同表达式里的普通 var 也一并取到新值；
//   **一个 @State 都没读到的节点，永不重绘** —— 复用后停在上一条消息的内容。
//   ⇒ 下面 21 个参与渲染的构造参数必须是 @State，不能是普通 var（round7 F-C 前为 19；本轮新增
//     两个半径哨兵入参，见 aboutToReuse 与本类中部 overrideMainRadius/overrideAuxRadius）。
//     19 个回调闭包不参与渲染，保持普通 var 即可（.onClick 在触发时读字段，取到的就是当前值）。
@Reusable
@Component
public class MessageBubble {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // S7-111: Appearance → Text Size (PresentationData.chatFontSize) scales message text.
    // Only the font size is read here; colours stay caller-fed.
    @StorageLink["presentation"] var fontPresentation: PresentationSnapshot = currentPresentation()
    // ↓↓↓ 以下 21 个为**参与渲染**的构造参数，必须 @State（理由见上方说明）↓↓↓
    // message 被 249 处渲染表达式读取，是最主要的刷新驱动源。
    // @State 需要初值，故给 Message()（唯一调用点 ChatRoomPage.cj:1642 始终实传）。
    // 沙盒第 8 轮已证：@State 接引用类型时，**父组件就地改内容、不换引用**，
    // aboutToReuse 把同一引用赋回照样触发刷新 —— applyMediaPath 就地写 photoLocalPath 不受影响。
    @State var message: Message = Message()
    @State var groupedMessages: ArrayList<Message> = ArrayList<Message>()
    // ChatRoomPage 的播放器状态版本。iOS 由 updatedPlaybackStatusSignal 推送到节点；
    // 鸿蒙用 @Prop 保持同样的父→子更新语义，使暂停、完成、连续播放都立即重绘。
    @Prop var voicePlaybackEpoch: Int64

    /**
     * 会话类型（"user" / "chat" / "channel"）。
     *
     * iOS 的作者名头部、浏览数等都要看会话是不是群/频道
     * （ChatMessageBubbleItemNode.swift:1723 的 peerId.isGroupOrChannel）。
     * 此前 MessageBubble 完全不知道自己在什么会话里，只能按 !isSent 判断，
     * 于是私聊里对方每条消息上面都会顶一行蓝色名字。
     */
    @State var peerType: String = "user"

    // 操作回调
    public var onReply: () -> Unit = { => }
    /**
     * Swipe-to-reply (iOS ChatMessageBubbleItemNode.swipeToReplyGesture):
     * only chat pages that can set up a reply pass true; previews keep false.
     */
    public var swipeToReplyEnabled: Bool = false
    public var onEdit: () -> Unit = { => }
    public var onDelete: () -> Unit = { => }
    // Reaction 回调（切换反应）
    public var onReactionTap: (String) -> Unit = { _emoji: String => }
    // P2-116: 点击反应计数回调（查看 reactor 列表，参数为消息 ID）
    public var onReactionCountTap: (Int64) -> Unit = { _msgId: Int64 => }
    // 单个动态 Emoji 点击：由页面级控制器播放外围特效并同步给对端。
    public var onAnimatedEmojiTap: (Message, String) -> Unit = { _msg: Message, _emoji: String => }
    // 长按回调（显示快速反应栏 + 操作菜单）
    // Window-space vertical geometry used by the page-level extracted overlay.
    public var onLongPress: (Float64, Float64) -> Unit = {
        _y: Float64, _height: Float64 =>
    }
    // S3-02: iOS TapLongTapOrDoubleTapGestureRecognizer .doubleTap → quick reaction.
    public var onDoubleTap: (Message) -> Unit = { _m: Message => }
    private var lastTapDownMs: Int64 = 0
    private var lastTapDownX: Float64 = 0.0
    private var lastTapDownY: Float64 = 0.0
    // Multi-select mode owns the row gesture and disables the context recognizer.
    @State var isMultiSelectMode: Bool = false
    // S3-16: iOS ChatMessageItemView — in selection mode a tap anywhere on the row
    // (bubble, its links / media, or the empty side) toggles the message
    // (ChatControllerImpl.updateChatPresentationInterfaceState withToggledSelectedMessage).
    // The content subtree is disabled so no child control swallows the tap; the row root
    // stays enabled and resolves the tap itself from raw touch events.
    public var onSelectionTap: (Message) -> Unit = { _m: Message => }
    private var selectionPressActive: Bool = false
    private var selectionTouchStartX: Float64 = 0.0
    private var selectionTouchStartY: Float64 = 0.0
    // S4-12: in-chat search query to paint inside this bubble (iOS searchTextHighightState);
    // empty = none. Fed per entry by ChatRoomPage (MessageEntry.searchHighlight, part of the key).
    @State var searchHighlightText: String = ""
    // Hidden only after the exact snapshot is ready, providing the same
    // source-to-overlay handoff as iOS ContextControllerTakeViewInfo.
    @State var contextPreviewHidden: Bool = false
    // 图片点击回调（打开全屏查看器）
    public var onImageTap: (Message) -> Unit = { _msg: Message => }
    // 视频点击回调（打开视频播放器）
    public var onVideoTap: (Message) -> Unit = { _msg: Message => }
    /** GIF 真身缺失时点按补下载（对齐 iOS：超过自动下载尺寸上限的 GIF 点按获取）。 */
    public var onGifTap: (Message) -> Unit = { _msg: Message => }
    /**
     * GIF 的 Video 组件是否挂载。Video 挂载即触发 CreatePlayer 同步 IPC（真机
     * 抓到过 5002ms），聊天历史几十条 GIF 在普通 ForEach 下全部常驻组件树 ——
     * 无门禁时快速上划会并发创建几十个播放器，渲染服务过载闪退。
     * 门禁三条件：可见 + 260ms 稳定（快滚划过不创建）+ 拿到聊天 Video 槽（≤4 并发）。
     */
    @State var gifAnimating: Bool = false
    private var gifSettleGeneration: Int64 = 0
    private var gifHoldsVideoSlot: Bool = false
    // 语音点击回调（播放/暂停）
    public var onVoiceTap: (Message) -> Unit = { _msg: Message => }
    // 文件点击回调（下载/打开）
    public var onFileTap: (Message) -> Unit = { _msg: Message => }
    public var onInvoiceTap: (Message) -> Unit = { _msg: Message => }
    // Phase P2-3: 网页链接点击回调（打开浏览器）
    public var onWebUrlTap: (String) -> Unit = { _url: String => }
    // Webpage cards use the external browser path, matching iOS URL resolution for
    // ordinary article links while keeping entity links on the Telegram resolver.
    public var onWebPreviewTap: (String) -> Unit = { _url: String => }
    // P2-183: 位置气泡点击回调（应用内地图详情页，替代外部 Google Maps 网页）
    public var onLocationTap: (Float64, Float64, String) -> Unit = { _lat: Float64, _lng: Float64, _title: String => }
    // Phase P5-1: 投票选项点击回调（msgId, optionIndex）
    public var onVoteTap: (Int64, Int64) -> Unit = { _msgId: Int64, _optIdx: Int64 => }
    // Phase P6-4: 回复引用点击回调（跳转到原消息）
    public var onReplyTap: (Int64) -> Unit = { _replyMsgId: Int64 => }
    // P2-397: 翻译结果区语言标签（显示目标语言名称，由 ChatRoomPage 传入）
    @State var translateToLangName: String = ""

    // 图片全屏预览状态（已迁移到 ImageViewer 组件，保留兼容）
    @State var showFullImage: Bool = false
    @State var saveStatus: String = ""
    // P2-183/192: 位置消息快照路径（空=未加载/加载中；非空=file://... 路径可直接给 Image）
    @State var locationSnapshotPath: String = ""
    // S6-05：messageActionSetChatWallPaper 服务消息下方的壁纸缩略图（iOS
    // ChatMessageWallpaperBubbleContentNode 100×100 imageNode），按需从缓存/下载取得
    @State var serviceWallpaperThumb: String = ""

    // One recognizer owns text, media, stickers and service messages.
    private var mediaPressGeneration: Int64 = 0
    private var mediaPressActive: Bool = false
    private var mediaTapEligible: Bool = false
    private var lastMessageTapTimestamp: Int64 = 0
    private var suppressNextMediaTap: Bool = false
    private var mediaTouchStartX: Float64 = 0.0
    private var mediaTouchStartY: Float64 = 0.0
    // Swipe-to-reply state. Screen coordinates are used because the row
    // itself translates while the finger moves.
    @State var swipeReplyOffset: Float64 = 0.0
    private var swipeReplyActive: Bool = false
    private var swipeReplyRejected: Bool = false
    private var swipeReplyHapticPlayed: Bool = false
    private var swipeReplyStartX: Float64 = 0.0
    private var swipeReplyStartY: Float64 = 0.0

    private func contextSourceId(): String {
        return "message_context_source_" + this.message.identityKey().toString()
    }
    // P2-113: 已展开的 spoiler 段落索引（点击后从集合中移除即显示明文）
    @State var revealedSpoilers: ArrayList<Int64> = ArrayList<Int64>()

    // P2-397/P2-400: 内联翻译状态（由 ChatRoomPage 通过 prop 注入，per-message HashMap）
    // showTranslation=true → 显示翻译结果区（含 loading/error/result）
    // showOriginal=true → 显示原文（Show Original 切换回原文）
    @State var showTranslation: Bool = false
    @State var translatedText: String = ""
    @State var isTranslating: Bool = false
    @State var translateError: Bool = false
    @State var showOriginal: Bool = false
    // P2-400: Show Original 切换回调（由 ChatRoomPage 更新 bubbleShowOriginal HashMap）
    public var onShowOriginalToggle: (Bool) -> Unit = { _v: Bool => }

    // P2-395/396: 壁纸 flag + 渐变色（outgoing 气泡梯度填充 + Canvas 尾巴跟随壁纸）
    // withWallpaper=true 时 outgoing 气泡从 0x317AFF 改为 wallpaperGradientColors 中的主色调渐变填充
    // 对应 iOS ChatMessageBubbleBackdrop.setWallpaper(wallpaperBackdrop)
    @State var withWallpaper: Bool = false
    // 壁纸 4 色渐变数组（同 WallpaperBackgroundComponent.gradientColors）
    // TC-0407 F-3 起，outgoing 气泡自身的渐变端点改由 bubbleOutColor 派生（对位源侧
    // theme.chat.message.outgoing.bubble.withWallpaper.fill 是主题输出，不是壁纸自身颜色）；
    // 本字段仍作为构造参数保留（ChatRoomPage.cj 调用点仍会传入），只是不再被
    // outgoingBubblePrimaryColor()/outgoingBubbleSecondaryColor() 读取。
    @State var wallpaperGradientColors: Array<UInt32> = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]

    // TC-0407 F-3/F-6a + TC-0401 round4 RC-6: bubble fill + primary body-text colour, sourced from
    // the caller's presentation snapshot (pages/ChatRoomPage.cj / pages/AppearanceSettingsPage.cj
    // pass presentation.bubbleOutColor/bubbleInColor/textColor). This component never reads
    // @StorageLink/currentPresentation()/isDark itself — colour is only a renderer input, never a
    // second source of truth (source invariant: "renderer takes theme params, caller feeds them").
    // Defaults reproduce this file's pre-existing literals so any call site that has not yet been
    // updated to pass these renders identically to before (hard cross-feature dependency: the
    // AppearanceSettingsPage.cj call site is landed by a different feature this same round).
    //
    // ⚠️ D-143 依赖披露 / D-197（TC-0401 round6 RC-B 的组件半边，实查结论）：这六个入参保持
    // `@State`，意味着它们**只在本组件构造时**从调用点取值一次，已挂载实例此后不再回灌。
    // 这不是"漏接订阅"，是 SDK 语义：宏对 `@State` 生成的 init 形参是
    // `x!: Option<ObservedProperty<T>> = None`，赋值体是
    // `this.stateVarDecl_x_ = ObservedProperty(info, v.get())`（值拷贝，独立属性）；只有 `@Prop`
    // 走 `v.createProp(info)` 建立父→子单向同步（依据 src/reference/arkui_cangjie_wrapper/ohos/
    // arkui/state_macro_manage/cj_generate_var_decl.cj:197-218/221-249；官方文档
    // cj-macro-state「有外部传入的情况下，使用外部传入的值进行**初始化**」与 cj-macro-prop
    // 「父组件的数据源更新时…@Prop 装饰的变量将被重置」同结论）。
    // 改 `@Prop` 在本 SDK 会连带要求全部 5 个调用点显式传参（S-141：`@Prop` 声明带默认值是宏
    // 展开期硬错误），其中 components/MessageContextOverlay.cj:228 无 feature owner、
    // pages/SelectivePrivacySettingsPage.cj:868 属 set_selective_privacy，两者都在本轮 allowlist
    // 之外，故本轮维持 `@State`（与 D-184 同型的取舍）。
    // ⇒ 主题切换要抵达**已挂载**的气泡（源侧 ThemeSettingsChatPreviewItem.swift:180 的
    // `items[i].updateNode(...)` 那一跳），必须由调用方按 D-160 双相同分支挂载守卫强制销毁重建：
    // pages/AppearanceSettingsPage.cj:892/:899（set_theme_settings）与 pages/ChatRoomPage.cj:2004
    // （stick_reaction_selection_node 的既定执行路由）。见 emitted ic
    // `ic_message_bubble_theme_remount_guard`（预览块）与
    // `ic_message_bubble_theme_remount_guard_chatroom`（会话页）。
    // 冷启动/新导航进入路径不受影响（TC-0402 round7 实测
    // 新构造实例取色正确），受影响的只有"同屏切主题"这条路径。
    @State var bubbleOutColor: UInt32 = 0xFFD9FDD3
    @State var bubbleInColor: UInt32 = 0xFFFFFFFF
    @State var bubbleOutTextColor: UInt32 = 0xFF111111
    @State var bubbleInTextColor: UInt32 = 0xFF000000
    // TC-0407 round3 F-1 (diag-suite_settings_appearance-TC-0407-round3.md): themed bubble outline
    // stroke colour, same renderer-input shape as the four colours above — this component never
    // reads @StorageLink/currentPresentation()/isDark, the caller feeds the resolved colour.
    // 0xAARRGGBB; top byte 0x00 is the explicit "no outline" signal MessageBubbleShape's
    // drawBubbleCanvas() checks before touching ctx.strokeStyle (source parity: dayClassic's bubble
    // stroke is UIColor(white:0,alpha:0.2), built-in dark theme's is `.clear` —
    // DefaultDayPresentationTheme.swift:580-585 / DefaultDarkPresentationTheme.swift:528/544/566/582).
    // Default 0x00000000 (no outline) reproduces this file's pre-existing zero-stroke behaviour for
    // any call site that has not yet been updated to pass a real value (core/storage/AppTheme.cj's
    // bubbleStrokeColor field exists but is not in this feature's target_files — see
    // ic_message_bubble_stroke_color_dark_clear / ic_message_bubble_stroke_color_wiring_chatroom
    // emitted this round). Never assign this straight to a strokeStyle/fillStyle-typed property when
    // its top byte is 0 — ResourceColor.toUInt32() (ohos/base/color.cj) runs Color.alphaAdapt() on
    // every UInt32/Int64 assigned to those SDK properties, which forces a 0x00 top byte opaque
    // (D-175); the drawBubbleCanvas() guard below reads the raw field and skips the SDK call
    // entirely for that case, so alphaAdapt is never reached.
    @State var bubbleStrokeColor: UInt32 = 0x00000000

    // diag-suite_settings_appearance-TC-0400.md round4 RC-4/RC-6 (F-9/F-10): reply-block "mainColor"
    // per direction + outgoing bubble's status/accent text colour (checkmarks, timestamp). Source:
    // ChatMessageReplyInfoNode.swift:251-261 (incoming prefers the peer's authorNameColor, else the
    // theme's global accent colour) and DefaultDayPresentationTheme.swift:679/684 (outgoing bubble's
    // secondaryTextColor/accentTextColor). Neither a per-peer name-colour lookup nor a bubble-scoped
    // outgoing accentTextColor exists anywhere this component can reach — core/storage/AppTheme.cj's
    // PresentationSnapshot only has a page-wide accentColor/secondaryTextColor (AppTheme.cj:31-32),
    // not the chat.message.{incoming,outgoing}-scoped ones the source uses — so these two colours are
    // renderer-input @State params (same invariant as bubbleOutColor above), not literals.
    // ic_message_bubble_reply_accent_colors (emitted this round) asks set_theme_settings /
    // core_presentation_data to wire real values in. Defaults reproduce this file's pre-existing
    // literal (incoming 0x317AFF, this file's long-standing accent) and the day-classic source value
    // (outgoing accentTextColor 0x00A700) so unwired call sites render close to before.
    @State var replyAuthorAccentColor: UInt32 = 0x317AFF
    @State var bubbleOutAccentTextColor: UInt32 = 0x00A700

    // TC-0406 round7 F-C (diag-suite_settings_appearance-TC-0406-round7.md §六 F-C): sentinel-default
    // render inputs for the corner radii, same @State shape as the six colour inputs above (NOT
    // @Prop — a @Prop with a default value is a macro-expansion-time hard error, S-141). Sentinel -1
    // means "no override, keep reading getThemesEngineService() as before" (see getBubbleMainRadius()/
    // getBubbleAuxRadius() below); only pages/BubbleSettingsPage.cj's four preview @Builder call sites
    // pass a value >= 0. The other 4 call sites (components/MessageContextOverlay.cj,
    // pages/SelectivePrivacySettingsPage.cj, and the two unconditional ones) never pass these and
    // therefore keep the pre-existing persisted-radius behaviour unchanged.
    @State var overrideMainRadius: Int32 = -1
    @State var overrideAuxRadius: Int32 = -1

    // ic_message_bubble_forward_name_link_slot (routed for execution to this feature; ownership of
    // this file remains shell_chat_message_items per owned_source_files — see feature hand-off).
    // When true, the "Forwarded from <name>" row renders in accent colour and dispatches
    // onForwardNameTap on tap; when false (default), it keeps this file's pre-existing plain
    // rendering with no tap handler, so existing call sites that never pass these are unaffected.
    @State var forwardNameLinkEnabled: Bool = false
    public var onForwardNameTap: () -> Unit = { => }

    // Bubble and tail are drawn as one mask, matching Telegram-iOS's stretchable image generator.
    //
    // TC-0401 round7 F-1 (D-190 + D-202): the drawing context used to be an instance field right
    // here. This is the only @Reusable component in the tree (see the class banner above), so the
    // D-160 remount guard at the call sites drives recycle + aboutToReuse rather than
    // destroy + construct: this instance — and with it a `private let ctx` declared here — survives
    // in the reuse cache while the Canvas node under it is rebuilt. That is D-190's "new node
    // paired with a stale ctx object", and its documented symptom (a completely blank canvas, not a
    // stale colour) is exactly what round7 measured on device. The ctx now lives in
    // MessageBubbleShape at the bottom of this file, which carries no @Reusable, so ctx and Canvas
    // node are always constructed by the same pass. Do not move it back here.
    //
    // These two stay: they remain the measurement result of the content Column and are handed to
    // MessageBubbleShape as its canvas size. The aboutToReuse note below ("do not touch these two
    // there") continues to apply unchanged.
    @State var bubbleCanvasWidth: Float64 = 1.0
    @State var bubbleCanvasHeight: Float64 = 1.0

    // P2-187: 实时位置倒计时环计时器服务（每个 MessageBubble 实例独享）
    // 在 locationContent.onAppear 时通过 initLiveTimerService() 用消息参数初始化
    var liveTimerService: LiveLocationTimerService = LiveLocationTimerService()
    // P2-187: Canvas context for live timer ring (避免 @Component 嵌套 DSL 限制，直接内联绘制)
    private let liveTimerCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    // P2-188: 内联头像 pin 状态（避免 R-130 同包 @Component DSL 限制）
    // 对应 iOS ChatMessageLiveLocationPositionNode 的脉冲动画 + 方向箭头
    /** 内联自定义表情就绪后推进，触发重建（取图是异步的，@Builder 只能同步读缓存）。 */
    @State var inlineEmojiEpoch: Int64 = 0
    @State var livePinPulseScale: Float32 = Float32(0.0)
    @State var livePinPulseAlpha: Float64 = 1.0
    // iOS liveTextNode 每 30s 重算 "updated … ago"；倒计时环同节奏重画
    @State var liveUpdatedText: String = "updated just now"
    private var liveRefreshTicks: Int64 = 0
    var livePinAnimProgress: Float64 = 0.0
    var livePinTimer: Option<Timer> = None<Timer>
    // P2-188: Canvas context for heading arrow in live location pin
    private let livePinArrowCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    // ==================== 辅助方法（不能在 build/@Builder 中使用 let）====================
    
    /**
     * Phase Q11: 将消息文本按实体切分为样式化片段
     * 
     * 算法: 遍历 textEntityList (按 offset 排序)，生成交替的 plain/styled 段。
     * 例如 "Hello **world** test" → [plain:"Hello ", bold:"world", plain:" test"]
     */
    private func getTextSegments(): Array<TextSegment> {
        let content = this.message.content
        let entities = this.message.textEntityList
        
        if (content.size == 0) { return Array<TextSegment>(0, {_i: Int64 => TextSegment()}) }
        if (entities.size == 0) {
            // 无实体 — 返回单段纯文本
            let seg = TextSegment()
            seg.text = content
            seg.segIndex = 0
            return Array<TextSegment>(1, {_i: Int64 => seg})
        }
        
        let result = ArrayList<TextSegment>()
        var segIdx: Int64 = 0
        
        // 按 offset 排序（实体通常已排序，但保险起见）
        // 简单冒泡排序（实体数通常很少）
        let sorted = ArrayList<TextEntityData>()
        for (e in entities) { sorted.add(e) }
        for (i in 0..Int64(sorted.size)) {
            for (j in 0..Int64(sorted.size) - 1 - i) {
                if (sorted[j].offset > sorted[j + 1].offset) {
                    let tmp = sorted[j]
                    sorted[j] = sorted[j + 1]
                    sorted[j + 1] = tmp
                }
            }
        }
        
        let contentRunes = content.toRuneArray()
        let contentLen = Int32(contentRunes.size)
        
        // P5-10: Support nested/overlapping entities by collecting all breakpoints
        // then applying all active entities to each segment
        let breakpoints = ArrayList<Int32>()
        breakpoints.add(0)
        breakpoints.add(contentLen)
        for (entity in sorted) {
            let eOffset = entity.offset
            let eEnd = if (eOffset + entity.length > contentLen) { contentLen } else { eOffset + entity.length }
            if (eOffset >= 0 && eOffset <= contentLen) { breakpoints.add(eOffset) }
            if (eEnd >= 0 && eEnd <= contentLen) { breakpoints.add(eEnd) }
        }
        // Deduplicate and sort breakpoints
        let uniqueBp = ArrayList<Int32>()
        for (bp in breakpoints) {
            var found = false
            for (u in uniqueBp) { if (u == bp) { found = true; break } }
            if (!found) { uniqueBp.add(bp) }
        }
        for (i in 0..Int64(uniqueBp.size)) {
            for (j in 0..Int64(uniqueBp.size) - 1 - i) {
                if (uniqueBp[j] > uniqueBp[j + 1]) {
                    let tmp = uniqueBp[j]; uniqueBp[j] = uniqueBp[j + 1]; uniqueBp[j + 1] = tmp
                }
            }
        }
        // Generate segments between adjacent breakpoints, applying all overlapping entities
        var bpi: Int64 = 0
        while (bpi + 1 < Int64(uniqueBp.size)) {
            let segStart = uniqueBp[bpi]
            let segEnd = uniqueBp[bpi + 1]
            if (segStart >= segEnd) { bpi += 1; continue }
            var segText = ""
            for (ri in Int64(segStart)..Int64(segEnd)) {
                segText += contentRunes[ri].toString()
            }
            let seg = TextSegment()
            seg.text = segText
            seg.segIndex = segIdx
            segIdx += 1
            // Apply all overlapping entities
            for (entity in sorted) {
                let eOffset = entity.offset
                let eEnd = if (eOffset + entity.length > contentLen) { contentLen } else { eOffset + entity.length }
                if (eOffset <= segStart && eEnd >= segEnd) {
                    let t = entity.entityType
                    if (t == "bold") { seg.isBold = true }
                    if (t == "italic") { seg.isItalic = true }
                    if (t == "code") { seg.isCode = true }
                    if (t == "pre") { seg.isPre = true; seg.isCode = true }
                    if (t == "strike") { seg.isStrike = true }
                    if (t == "underline") { seg.isUnderline = true }
                    if (t == "textUrl") { seg.isUrl = true; seg.url = entity.url }
                    if (t == "url") { seg.isUrl = true; seg.url = segText }
                    if (t == "mention") { seg.isMention = true; seg.url = segText }
                    if (t == "mentionName") { seg.isMention = true; seg.url = entity.url }
                    if (t == "email") { seg.isUrl = true; seg.url = "mailto:" + segText }
                    if (t == "customEmoji") { seg.customEmojiId = entity.customEmojiDocumentId }
                    if (t == "spoiler") { seg.isSpoiler = true }
                    if (t == "blockquote") { seg.isBlockquote = true }
                }
            }
            result.add(seg)
            bpi += 1
        }
        
        return result.toArray()
    }
    
    /**
     * Phase Q11: 判断消息是否有富文本实体需要渲染
     */
    private func hasRichTextEntities(): Bool {
        return this.message.textEntityList.size > 0
    }

    @Builder
    func buildInlineCustomEmoji(seg: TextSegment) {
        if (inlineCustomEmojiPath(seg.customEmojiId).size > 0) {
            ImageSpan(inlineCustomEmojiPath(seg.customEmojiId))
                .width(20)
                .height(20)
                .objectFit(ImageFit.Contain)
                .verticalAlign(ImageSpanAlignment.Center)
        } else {
            ImageSpan(inlineCustomEmojiFrame(seg.customEmojiId))
                .width(20)
                .height(20)
                .objectFit(ImageFit.Contain)
                .verticalAlign(ImageSpanAlignment.Center)
        }
    }

    /** 正文里出现的每个自定义表情都预取一次；就绪后推进 epoch 触发重建。 */
    private func prefetchInlineCustomEmoji(): Unit {
        for (entity in this.message.textEntityList) {
            if (entity.entityType != "customEmoji") { continue }
            if (entity.customEmojiDocumentId == 0) { continue }
            requestInlineCustomEmoji(entity.customEmojiDocumentId, { =>
                spawn(UIThread) {
                    =>
                    this.inlineEmojiEpoch = this.inlineEmojiEpoch + 1
                }
            })
        }
    }

    private func isAnimatedEmojiMessage(): Bool {
        return getStickersService().isLargeEmojiEnabled() &&
            this.message.messageType == "text" &&
            this.message.textEntityList.size == 0 &&
            isSingleEmoji(this.message.content)
    }

    /**
     * 2~3 个 emoji 的纯表情消息 —— iOS 同样按大表情渲染。
     *
     * iOS 的判据是 messageIsEligibleForLargeEmoji：整条文本都是 emoji 且无实体
     * （ChatMessageItemCommon.swift:242-250），并不限于单个；只有 emojiString.count == 1
     * 时才走动画表情，其余用 messageEmojiFont（Font.regular(53)）画大号文字
     * （ChatMessageStickerItemNode.swift:458-463）。
     * 我们此前只认单个 emoji，发两三个就退化成普通小字文本。
     */
    private func isLargeEmojiMessage(): Bool {
        return getStickersService().isLargeEmojiEnabled() &&
            this.message.messageType == "text" &&
            this.message.textEntityList.size == 0 &&
            !isSingleEmoji(this.message.content) &&
            containsOnlyEmoji(this.message.content)
    }

    /** 群聊 / 频道 —— 对应 iOS peerId.isGroupOrChannel。 */
    private func isGroupOrChannel(): Bool {
        return this.peerType == "chat" || this.peerType == "channel"
    }

    /**
     * 是否为该入向消息保留左侧头像位。
     *
     * iOS 在群/频道的入向消息左侧挂一个 34pt 的 ChatMessageAvatarHeader
     * （ChatMessageItemImpl.swift:422-468），并把头像**贴在同一作者聚簇的底部**
     * （ChatMessageDateHeader.swift:922-924 的 stick direction）。
     * 我们此前整个消息行都没有头像列。
     *
     * senderId == 0 的情形（广播频道的帖子没有具体发送者）不占位，避免整行左移。
     */
    private func showsPeerAvatar(): Bool {
        return !this.message.isSent && this.isGroupOrChannel() && this.message.senderId != 0
    }

    /**
     * 时间戳+状态是否走「浮层」而非气泡底栏。
     *
     * iOS 按节点类型分流：纯媒体走 .Image*（暗色 scrim 压在图上），
     * 贴纸/大表情走 .Free*（service 配色胶囊，见 freeDateAndStatusOverlay），
     * 两者都不使用气泡底栏。此前贴纸与大表情虽然被当作无气泡渲染，
     * 却仍落在底栏分支上 —— 底栏那套配色是给绿色气泡背景配的
     * （时间 #4C7B43、白勾 0.6 透明），铺在聊天壁纸上等于看不见，
     * 表现就是「表情不显示时间、动画贴纸不显示时间和已读标识」。
     */
    private func usesFloatingDateAndStatus(): Bool {
        return this.isBubblelessMedia() ||
            this.message.messageType == "sticker" ||
            this.isAnimatedEmojiMessage() ||
            this.isLargeEmojiMessage()
    }

    /** 无气泡背景、直接铺在壁纸上的内容（贴纸 / 单个动画表情 / 2~3 个大表情）。 */
    /**
     * 大表情的字号 —— 照抄 iOS fontSizeForEmojiString
     * （ChatMessageAnimatedStickerItemNode.swift:3325-3362）：基准 94，按簇数逐档缩小，
     * 10 个及以上一律 ×0.21。iOS 那边取的是 max(每行簇数, 行数)，我们的大表情消息
     * 不含换行与空格（containsOnlyEmoji 会拒掉），所以直接就是簇数。
     */
    private func largeEmojiFontSize(): Float64 {
        let multiplier = match (emojiCount(this.message.content)) {
            case 1 => 1.0
            case 2 => 0.84
            case 3 => 0.69
            case 4 => 0.53
            case 5 => 0.46
            case 6 => 0.38
            case 7 => 0.32
            case 8 => 0.27
            case 9 => 0.24
            case _ => 0.21
        }
        return Float64(Int64(94.0 * multiplier))
    }

    /**
     * 素材边长。表情包素材本体只占画布约 75%，按 1.19 倍字号渲染时本体正好落在
     * 0.9 倍字号上 —— 与 iOS 上 Apple 字形的本体大小一致（78pt 字号实测本体 71pt）。
     */
    private func largeEmojiDisplaySize(): Float64 {
        return this.largeEmojiFontSize() * 1.19
    }

    /** 行内步进：iOS 上 Apple 表情字形的推进约为字号的 1.08 倍（78pt 实测 84pt） */
    private func largeEmojiAdvance(): Float64 {
        return this.largeEmojiFontSize() * 1.081
    }

    /**
     * 表情块的宽度，必须显式算出来。
     *
     * Flex 默认撑满父宽，Column 跟着变成整行宽，右对齐的时间胶囊就会甩到屏幕右边，
     * 而 iOS 是把它贴在表情块右缘内缩 4 的位置。这里按步进和每行个数把块宽算准，
     * 换行位置与 iOS 的 maximumContentWidth 对齐（气泡最大内容宽度）。
     */
    private func largeEmojiMaxRowWidth(): Float64 {
        return 300.0
    }

    private func largeEmojiBlockWidth(): Float64 {
        let advance = this.largeEmojiAdvance()
        var perLine = Int64(this.largeEmojiMaxRowWidth() / advance)
        if (perLine < 1) { perLine = 1 }
        var count = emojiCount(this.message.content)
        if (count > perLine) { count = perLine }
        return Float64(count) * advance
    }

    private func isStickerLikeContent(): Bool {
        return this.message.messageType == "sticker" ||
            this.isAnimatedEmojiMessage() ||
            this.isLargeEmojiMessage()
    }

    /**
     * 纯媒体（图片/视频/GIF）且无 caption —— iOS 下不绘制气泡背景、图片自身即圆角容器、
     * 反应下沉到气泡下方、时间戳 overlay 到图右下带暗色 scrim。带 caption 时恢复气泡。
     *
     * 对齐 iOS ChatMessageBubbleItemNode：媒体内容节点声明 hidesBackground=.emptyWallpaper
     * (ChatMessageMediaBubbleContentNode.swift:430)，无文本 caption 节点(.never,:228)覆盖时
     * backgroundType 置 .none(:3856) → 无气泡；且 needReactions 保持 true → 反应走外部
     * ChatMessageReactionButtonsNode 渲染在 backgroundFrame.maxY+4(:5202)。带 caption 时
     * 末节点是文本气泡 → needReactions=false(:367) → 反应回到气泡内状态行、气泡背景恢复。
     */
    private func isBubblelessMedia(): Bool {
        let t = this.message.messageType
        // 圆形视频在 iOS 始终由 ChatMessageInstantVideoItemNode 独立渲染，
        // 不存在外层普通消息气泡。
        if (t == "video_note") { return true }
        if (t != "photo" && t != "video" && t != "gif") { return false }
        let hasCaption = this.message.content.size > 0 && this.message.content != this.message.mediaDescription
        return !hasCaption
    }

    /**
     * P2-113: 判断 spoiler 是否已展开（通过 segIndex 查找）
     */
    private func isSpoilerRevealed(segIndex: Int64): Bool {
        for (idx in this.revealedSpoilers) {
            if (idx == segIndex) { return true }
        }
        return false
    }

    /**
     * P2-113: 切换 spoiler 展开状态
     */
    private func toggleSpoiler(segIndex: Int64): Unit {
        if (this.isSpoilerRevealed(segIndex)) {
            let next = ArrayList<Int64>()
            for (idx in this.revealedSpoilers) {
                if (idx != segIndex) { next.add(idx) }
            }
            this.revealedSpoilers = next
        } else {
            let next = ArrayList<Int64>()
            for (idx in this.revealedSpoilers) { next.add(idx) }
            next.add(segIndex)
            this.revealedSpoilers = next
        }
    }

    /**
     * 判断当前语音消息是否正在播放
     */
    // P7C-1: 判断是否为动画贴纸 (TGS/Lottie)
    private func isTgsSticker(): Bool {
        return this.message.documentMimeType.contains("tgs") || this.message.documentMimeType.contains("lottie")
    }

    // Telegram video stickers are VP9 WebM documents carrying both
    // documentAttributeSticker and documentAttributeVideo. They are stickers,
    // not generic images, and must be rendered by the video pipeline.
    private func isVideoSticker(): Bool {
        return this.message.messageType == "sticker" &&
            (this.message.documentMimeType.contains("webm") ||
             this.message.documentFileName.toAsciiLower().endsWith(".webm") ||
             this.message.documentLocalPath.toAsciiLower().endsWith(".webm"))
    }

    private func isVoicePlaying(_epoch: Int64): Bool {
        let playerMgr = getVoicePlayerManager()
        let playerState = playerMgr.getStateForMessage(this.message.id)
        return match (playerState) {
            case Loading => true
            case Playing => true
            case _ => false
        }
    }
    
    /**
     * 获取语音消息显示时间（播放进度或总时长）
     */
    private func getVoiceDisplayTime(_epoch: Int64): Int32 {
        // iOS ChatMessageInteractiveFileNode: stringForDuration(duration, position:)
        // shows duration - position while this voice is the current item, so the
        // label counts down as it plays and returns to the full length when idle.
        let playerMgr = getVoicePlayerManager()
        match (playerMgr.getStateForMessage(this.message.id)) {
            case Idle => return this.message.audioDuration
            case _ => ()
        }
        let durationSec = playerMgr.getDurationMsForMessage(this.message.id, this.message.audioDuration) / 1000
        let positionSec = playerMgr.getProgressMsForMessage(this.message.id) / 1000
        let remaining = durationSec - positionSec
        return Int32(if (remaining > 0) { remaining } else { 0 })
    }

    /**
     * Phase Q2: 获取波形条高度数组（20 个条, 值范围 4-24）
     * 
     * Telegram waveform 是 5-bit 编码 (每个采样 0-31, 打包存储)。
     * 此方法解码并归一化为 20 条显示条。
     * 如果没有真实波形数据，使用消息 ID 生成伪随机波形。
     */
    private func getWaveformBars(): Array<Int64> {
        let waveform = this.message.audioWaveform
        if (waveform.size == 0) {
            // 无波形数据 → 使用消息 ID 生成伪随机
            return Array<Int64>(20, { i: Int64 =>
                (this.message.id * 7 + i * 13 + 3) % 20 + 4
            })
        }

        // 解码 5-bit packed waveform → 采样点数组
        let totalSamples = Int64(waveform.size) * 8 / 5
        let samples = ArrayList<Int64>()
        var bitPos: Int64 = 0
        while (bitPos + 5 <= Int64(waveform.size) * 8 && samples.size < totalSamples) {
            let byteIdx = bitPos / 8
            let bitOff = bitPos % 8
            // 读取跨字节的 5 bits
            let b0 = Int64(waveform[byteIdx]) & 0xFF
            let b1 = if (byteIdx + 1 < Int64(waveform.size)) { Int64(waveform[byteIdx + 1]) & 0xFF } else { 0 }
            let combined = (b0 | (b1 << 8)) >> bitOff
            let sample = combined & 0x1F  // 5 bits = 0..31
            samples.add(sample)
            bitPos += 5
        }

        let sampleCount = samples.size
        if (sampleCount == 0) {
            return Array<Int64>(20, { i: Int64 =>
                (this.message.id * 7 + i * 13 + 3) % 20 + 4
            })
        }

        // 归一化到 20 条, 高度范围 4..24
        let immSamples = samples
        return Array<Int64>(20, { i: Int64 =>
            let sIdx = i * sampleCount / 20
            let val = if (sIdx < immSamples.size) { immSamples[sIdx] } else { 0 }
            // 归一化: 0..31 → 4..24
            val * 20 / 31 + 4
        })
    }

    /**
     * Phase Q2: 获取语音播放进度比例 (0.0 ~ 1.0)
     */
    private func getVoiceProgress(_epoch: Int64): Float64 {
        // Millisecond position against the player-reported duration: whole-second
        // progress only moved the fill once per second (a 2s note jumped once).
        let playerMgr = getVoicePlayerManager()
        let progressMs = playerMgr.getProgressMsForMessage(this.message.id)
        let durationMs = playerMgr.getDurationMsForMessage(this.message.id, this.message.audioDuration)
        if (durationMs <= 0 || progressMs <= 0) { return 0.0 }
        let ratio = Float64(progressMs) / Float64(durationMs)
        return if (ratio > 1.0) { 1.0 } else { ratio }
    }

    /**
     * Phase Q2: 获取已播放的波形条数量（用于高亮显示已播放部分）
     */
    private func getPlayedBarCount(_epoch: Int64): Int64 {
        let progress = this.getVoiceProgress(_epoch)
        return Int64(progress * 20.0 + 0.5)
    }

    // ==================== 媒体内容构建器 ====================
    
    /**
     * Phase Q7: 计算照片显示宽度（保持纵横比，约束在 240x320 内）
     * 注意：使用两个独立函数而非 tuple 返回，因为 @Builder 内不能用 let
     */
    private func getPhotoDisplayWidth(): Float64 {
        let maxW: Int32 = 240
        let maxH: Int32 = 320
        let pw = this.message.photoWidth
        let ph = this.message.photoHeight
        if (pw <= 0 || ph <= 0) {
            return Float64(maxW)
        }
        var dw = maxW
        var dh = ph * maxW / pw
        if (dh > maxH) {
            dh = maxH
            dw = pw * maxH / ph
            if (dw > maxW) { dw = maxW }
        }
        if (dw < 80) { dw = 80 }
        return Float64(dw)
    }

    private func getPhotoDisplayHeight(): Float64 {
        let maxW: Int32 = 240
        let maxH: Int32 = 320
        let pw = this.message.photoWidth
        let ph = this.message.photoHeight
        if (pw <= 0 || ph <= 0) {
            return 160.0
        }
        var dh = ph * maxW / pw
        if (dh > maxH) { dh = maxH }
        if (dh < 60) { dh = 60 }
        return Float64(dh)
    }

    private func hasGroupedMedia(): Bool {
        return this.groupedMessages.size > 1
    }

    private func getGroupedPhotoWidth(): Float64 {
        if (this.groupedMessages.size == 2) { return 139.5 }
        if (this.groupedMessages.size == 3) { return 92.67 }
        return 69.25
    }

    /**
     * Phase Q7: 构建照片消息内容（增强版 — 自适应比例 + 模糊预览占位）
     */
    @Builder
    func photoContent(isSent: Bool) {
        if (this.hasGroupedMedia()) {
            Stack(alignContent: Alignment.BottomEnd) {
                Row(space: 1.vp) {
                    ForEach(this.groupedMessages.toArray(), itemGenerator: { groupedMessage: Message, _idx: Int64 =>
                        if (groupedMessage.photoLocalPath.size > 0) {
                            Image(groupedMessage.photoLocalPath)
                                .width(this.getGroupedPhotoWidth())
                                .height(180)
                                .objectFit(ImageFit.Cover)
                                .onClick({ _evt => this.handleMediaTap(groupedMessage) })
                        } else {
                            Column {}
                                .width(this.getGroupedPhotoWidth())
                                .height(180)
                                .backgroundColor(0xFFE5E5EA)
                        }
                    }, keyGenerator: { groupedMessage: Message, idx: Int64 =>
                        // Message 未实现 ToString，缺省 key 只有下标：气泡复用给另一组同样张数的相册时
                        // 不重建，缩略图与 onClick 捕获的 groupedMessage 都停在上一组（点 A 开 B）。
                        "${groupedMessage.id}_${idx}_${groupedMessage.photoLocalPath}"
                    })
                }
                .width(280)
                .height(180)
                if (this.isBubblelessMedia()) {
                    mediaTimestampOverlay(isSent)
                }
            }
            .width(280)
            .height(180)
            .borderRadius(12)
            .clip(true)
            .margin(top: 2)
        } else if (this.message.photoLocalPath.size > 0) {
            // 已下载：用实际图片显示，按真实比例。iOS 纯图片满铺无外边距、自身圆角即容器边界，
            // 时间戳 overlay 到右下带 scrim；带 caption 时无 overlay、走气泡底栏。
            Stack(alignContent: Alignment.BottomEnd) {
                Image(this.message.photoLocalPath)
                    .width(this.getPhotoDisplayWidth())
                    .height(this.getPhotoDisplayHeight())
                    .objectFit(ImageFit.Cover)
                if (this.isBubblelessMedia()) {
                    mediaTimestampOverlay(isSent)
                }
            }
            .borderRadius(12)
            .clip(true)
            .margin(top: 2)
            // Match iOS' media node: one stable recognizer owner resolves a
            // short tap as preview and a hold as the message context menu.
            .onClick({ _evt => this.handleMediaTap(this.message) })
        } else if (this.message.photoDownloadState != 0) {
            // S7-93: 自动下载被 Data and Storage → Auto-Download 设置拦下（1）或用户点按下载中（2）。
            // iOS ChatMessageInteractiveMediaNode：automaticDownload == .none 时媒体上显示下载箭头，
            // 点按才拉取；拉取中显示进度环。
            Column {
                Column {
                    if (this.message.photoDownloadState == 2) {
                        LoadingProgress()
                            .width(32)
                            .height(32)
                            .color(0xFFFFFF)
                    } else {
                        Image(@r(app.media.chatroom_ic_download))
                            .width(26)
                            .height(26)
                            .fillColor(0xFFFFFF)
                    }
                }
                .width(48)
                .height(48)
                .borderRadius(24)
                .backgroundColor(0x80000000)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .width(this.getPhotoDisplayWidth())
            .height(this.getPhotoDisplayHeight())
            .backgroundColor(if (isSent) { 0x2873D4 } else { 0xE0E0E0 })
            .borderRadius(12)
            .margin(top: 2)
            .onClick({ _evt => this.handleMediaTap(this.message) })
        } else {
            // 加载中占位符：使用真实比例
            // 资源保真修复：真实矢量图标（Chat/Context Menu/Image.imageset/image_24.pdf 转 SVG）替代 emoji 字形
            Column {
                Image(@r(app.media.chatroom_ic_photo))
                    .width(28)
                    .height(28)
                    .fillColor(if (isSent) { 0xFFFFFF } else { 0x666666 })
                    .opacity(0.7)
                    .margin(bottom: 4)
                Text(if (this.message.strippedThumb.size > 0) { "Loading..." } else { "Loading photo..." })
                    .fontSize(12)
                    .fontColor(if (isSent) { 0xFFFFFF } else { 0x666666 })
                    .opacity(0.7)
                // 如果有尺寸信息，显示分辨率
                if (this.message.photoWidth > 0) {
                    Text("${this.message.photoWidth}×${this.message.photoHeight}")
                        .fontSize(10)
                        .fontColor(if (isSent) { 0xFFFFFF } else { 0x999999 })
                        .opacity(0.5)
                        .margin(top: 2)
                }
            }
            .width(this.getPhotoDisplayWidth())
            .height(this.getPhotoDisplayHeight())
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(if (isSent) { 0x2873D4 } else { 0xE0E0E0 })
            .borderRadius(12)
            .margin(top: 2)
        }
    }
    
    /**
     * 构建视频消息内容
     */
    @Builder
    func videoContent(isSent: Bool) {
        if (this.message.documentLocalPath.size > 0) {
            // 有缩略图
            Stack {
                Image(this.message.documentLocalPath)
                    .width(200)
                    .constraintSize(maxWidth: 240, maxHeight: 200)
                    .borderRadius(8)
                    .objectFit(ImageFit.Cover)
                // 播放按钮覆盖层
                Column {
                    Text("▶")
                        .fontSize(36)
                        .fontColor(0xFFFFFF)
                }
                .width(56)
                .height(56)
                .backgroundColor(0x60000000)
                .borderRadius(28)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                // iOS 普通视频：时长置左上，消息时间置右下。
                Row {
                    Text(if (this.message.videoDuration > 0) { formatDurationSec(this.message.videoDuration) } else { this.message.mediaDescription })
                        .fontSize(11)
                        .fontColor(0xFFFFFF)
                        .padding(left: 6, right: 6, top: 2, bottom: 2)
                        .backgroundColor(0x80000000)
                        .borderRadius(4)
                }
                .position(x: 8, y: 8)
                // 时间戳 overlay（纯视频无 caption 时，置右下带 scrim）
                if (this.isBubblelessMedia()) {
                    Stack(alignContent: Alignment.BottomEnd) {
                        mediaTimestampOverlay(isSent)
                    }
                    .width(200)
                    .height(200)
                }
            }
            .width(200)
            .borderRadius(12)
            .clip(true)
            .margin(top: 2)
            .onClick({ evt =>
                this.onVideoTap(this.message)
            })
        } else {
            // 无缩略图占位
            Row {
                Column {
                    Text("▶")
                        .fontSize(32)
                        .fontColor(if (isSent) { 0xFFFFFF } else { 0x333333 })
                    Text(if (this.message.videoDuration > 0) { formatDurationSec(this.message.videoDuration) } else { this.message.mediaDescription })
                        .fontSize(12)
                        .fontColor(if (isSent) { 0xFFFFFF } else { 0x666666 })
                        .margin(top: 4)
                    if (this.message.documentSize > 0) {
                        Text(formatFileSize(this.message.documentSize))
                            .fontSize(11)
                            .fontColor(if (isSent) { 0xFFFFFF } else { 0x999999 })
                            .opacity(0.7)
                    }
                }
                .alignItems(HorizontalAlign.Center)
            }
            .width(200)
            .height(120)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(if (isSent) { 0x2060B0 } else { 0xD0D0D0 })
            .borderRadius(8)
            .margin(left: 4, right: 4, top: 6)
            .onClick({ evt =>
                this.onVideoTap(this.message)
            })
        }
    }
    
    /**
     * Phase P6-11: 构建圆形视频消息 (Video Note) 内容
     * 
     * Telegram 的视频消息显示为圆形，类似语音消息但带视频
     */
    @Builder
    func videoNoteContent(isSent: Bool) {
        Column {
            if (this.message.documentLocalPath.size > 0) {
                // 有缩略图 → 圆形显示
                Stack {
                    Image(this.message.documentLocalPath)
                        .width(200)
                        .height(200)
                        .borderRadius(100)
                        .objectFit(ImageFit.Cover)
                    // 播放按钮覆盖层
                    Column {
                        Text("▶")
                            .fontSize(32)
                            .fontColor(0xFFFFFF)
                    }
                    .width(48)
                    .height(48)
                    .backgroundColor(0x60000000)
                    .borderRadius(24)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    // 圆形视频保持内容内时长，同时把消息时间/状态压在右下。
                    Stack(alignContent: Alignment.Bottom) {
                        Text(if (this.message.videoDuration > 0) { formatDurationSec(this.message.videoDuration) } else { "0:00" })
                            .fontSize(11)
                            .fontColor(0xFFFFFF)
                            .padding(left: 6, right: 6, top: 2, bottom: 2)
                            .backgroundColor(0x80000000)
                            .borderRadius(8)
                    }
                    .width(200)
                    .height(188)
                    Stack(alignContent: Alignment.BottomEnd) {
                        mediaTimestampOverlay(isSent)
                    }
                    .width(200)
                    .height(200)
                }
                .width(200)
                .height(200)
                .borderRadius(100)
                .clip(true)
                .onClick({ evt =>
                    this.onVideoTap(this.message)
                })
            } else {
                // 无缩略图 → 圆形占位
                Stack {
                    Column {
                        Text("▶")
                            .fontSize(36)
                            .fontColor(0xFFFFFF)
                        Text(if (this.message.videoDuration > 0) { formatDurationSec(this.message.videoDuration) } else { "Video Note" })
                            .fontSize(12)
                            .fontColor(0xFFFFFF)
                            .margin(top: 4)
                    }
                    .alignItems(HorizontalAlign.Center)
                    Stack(alignContent: Alignment.BottomEnd) {
                        mediaTimestampOverlay(isSent)
                    }
                    .width(200)
                    .height(200)
                }
                .width(200)
                .height(200)
                .backgroundColor(if (isSent) { 0x2060B0 } else { 0xA0A0A0 })
                .borderRadius(100)
                .alignContent(Alignment.Center)
                .onClick({ evt =>
                    this.onVideoTap(this.message)
                })
            }
        }
        .alignItems(if (isSent) { HorizontalAlign.End } else { HorizontalAlign.Start })
        .width(100.percent)
        .margin(top: 6)
    }

    /**
     * 语音/音频播放-暂停按钮（真实矢量图标，替代 Unicode 字形）
     *
     * diag-suite_settings_appearance-TC-0417-round4.md C2：`Text("▶"/"⏸")` 在鸿蒙系统字体下按
     * emoji-presentation 渲染，`.fontColor()` 对 emoji 字形无效，颜色恒为系统配色、不随主题变化。
     * 改为矢量资源 + `.fillColor()`，还原源侧 SemanticStatusNodeIconContext.swift:42-84 的机制
     * （矢量路径填充，颜色随 foregroundColor/主题走）。
     * 几何: 播放态取 15×18（源侧 :54，offset x=1.5，源侧 :53）；暂停态取 15×16（源侧 :56，offset=0）；
     * `diameter ≥ 40` 时不缩放（源侧 :62-66 的 `diameter < 40` 缩放分支本处不触发）。
     * 图标资源按状态切换 → 组件级 if/else（D-133：`@r()` 不作为值级 if/else 分支返回值使用）。
     * `marginRight` 作为形参而非调用点链式 `.margin()`：本文件 `voiceContent(isSent)` /
     * `audioContent(isSent)` / `documentContent(isSent)` 三个既有同类带参 `@Builder func` 均以
     * 裸调用（不带 `this.`、调用点不链式修饰）作为完整语句使用（D-115 附近约定），本函数照抄该形状。
     */
    @Builder
    func mediaStatusPlayPauseIcon(isSent: Bool, diameter: Float64, cornerRadius: Float64, marginRight: Float64) {
        Column {
            if (this.isVoicePlaying(this.voicePlaybackEpoch)) {
                Image(@r(app.media.chatroom_ic_semanticpause))
                    .width(15.0)
                    .height(16.0)
                    .fillColor(if (isSent) { this.outFg().mediaControlInnerBackgroundColor } else { 0x317AFF })
            } else {
                Image(@r(app.media.chatroom_ic_semanticplay))
                    .width(15.0)
                    .height(18.0)
                    .fillColor(if (isSent) { this.outFg().mediaControlInnerBackgroundColor } else { 0x317AFF })
                    .offset(x: 1.5, y: 0.0)
            }
        }
        .width(diameter)
        .height(diameter)
        .borderRadius(cornerRadius)
        // 发出方向对位源侧 statusNode：实底 mediaActiveControlColor + 镂空字形
        // （ChatMessageInteractiveFileNode.swift:1790-1796）。
        .backgroundColor(if (isSent) { this.outFg().mediaActiveControlColor } else { this.withAlpha(this.replyBlockMainColor(isSent), 0x1A) })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onTouch({ evt =>
            if (evt.eventType == TouchType.Down) {
                getVoicePlayerManager().preload(this.message.id, this.message.documentLocalPath)
            }
        })
        .onClick({ evt =>
            this.onVoiceTap(this.message)
        })
        .margin(right: marginRight)
    }

    /**
     * 构建语音消息内容（Phase Q2: 真实波形 + 进度高亮）
     *
     * 对应 TelegramHarmony MessageBubble.ets VoiceContent builder
     *
     * 渲染: 播放按钮 | 20条波形条(已播放部分高亮) | 时长
     */
    @Builder
    func voiceContent(isSent: Bool) {
        Row {
            // 播放/暂停按钮 — 真实矢量图标（C2 修复），44vp 直径圆形，颜色随主题走
            mediaStatusPlayPauseIcon(isSent, 44.0, 22.0, 8.0)
            
            Column {
                // Phase Q2: 波形条 — 使用真实波形数据（20 条, 已播放部分高亮）
                Row {
                    ForEach(this.getWaveformBars(), itemGenerator: { height: Int64, idx: Int64 =>
                        Column {}
                            .width(3)
                            .height(height)
                            .backgroundColor(
                                if (isSent) {
                                    // 源侧 waveform：前景 mediaActiveControlColor、底 mediaInactiveControlColor
                                    // （ChatMessageInteractiveFileNode.swift:1301-1321）。
                                    if (idx < this.getPlayedBarCount(this.voicePlaybackEpoch)) { this.outFg().mediaActiveControlColor } else { this.outFg().mediaInactiveControlColor }
                                } else {
                                    if (idx < this.getPlayedBarCount(this.voicePlaybackEpoch)) { 0x317AFF } else { 0xB0CBEF }
                                }
                            )
                            .opacity(if (isSent || idx < this.getPlayedBarCount(this.voicePlaybackEpoch)) { 1.0 } else { 0.5 })
                            .borderRadius(2)
                            .margin(left: if (idx > 0) { 2 } else { 0 })
                    })
                }
                .height(24)
                .alignItems(VerticalAlign.Center)
                
                // 时长 / 进度
                Text(formatDurationSec(this.getVoiceDisplayTime(this.voicePlaybackEpoch)))
                    .fontSize(11)
                    .fontColor(if (isSent) { this.outFg().fileDurationColor } else { 0x999999 })
                    .opacity(if (isSent) { 1.0 } else { 0.7 })
                    .margin(top: 2)
            }
            // iOS 的 fileTap 覆盖整块语音内容，waveform 单独承担 scrubbing。鸿蒙侧把
            // 右侧波形 + 时长作为一个命中区：波形行定位，时长行切换播放/暂停。
            .onTouch({ evt =>
                    if (evt.eventType == TouchType.Up && evt.touches.size > 0) {
                        let x = evt.touches[0].x
                        let y = evt.touches[0].y
                        if (y <= 24.0) {
                            var ratio = x / 98.0
                            Hilog.info(0, "CjTelegram", "[VoiceSeek] x=${x}vp ratio=${ratio}")
                            if (ratio < 0.0) { ratio = 0.0 }
                            if (ratio > 1.0) { ratio = 1.0 }
                            let playerMgr = getVoicePlayerManager()
                            if (playerMgr.currentMessageId == this.message.id) {
                                playerMgr.seek(Int32(ratio * Float64(this.message.audioDuration)))
                            } else {
                                this.onVoiceTap(this.message)
                            }
                        } else {
                            this.onVoiceTap(this.message)
                        }
                    }
                })
        }
        .padding(left: 12, right: 12, top: 8, bottom: 4)
    }

    /**
     * Phase Q2: 构建音频消息内容（音乐/音频文件 — 非语音）
     * 
     * 显示: 播放按钮 | 标题+演奏者 | 时长
     * 区别于 voice: audio 显示标题/演奏者，voice 显示波形
     */
    @Builder
    func audioContent(isSent: Bool) {
        Row {
            // 播放/暂停按钮 — 真实矢量图标（C2 修复，同型第二处，源侧同一 statusNode）
            mediaStatusPlayPauseIcon(isSent, 44.0, 8.0, 10.0)
            
            Column {
                // 标题：iOS ChatMessageInteractiveFileNode:704 title ?? fileName ?? "Unknown Track"（S2-97）
                Text(if (this.message.audioTitle.size > 0) {
                    this.message.audioTitle
                } else if (this.message.documentFileName.size > 0) {
                    this.message.documentFileName
                } else { "Unknown Track" })
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(if (isSent) { this.outFg().fileTitleColor } else { 0x333333 })
                    .maxLines(1)
                
                // 演奏者 + 时长
                Row {
                    if (this.message.audioPerformer.size > 0) {
                        Text(this.message.audioPerformer)
                            .fontSize(12)
                            .fontColor(if (isSent) { this.outFg().fileDescriptionColor } else { 0x999999 })
                            .opacity(if (isSent) { 1.0 } else { 0.7 })
                            .maxLines(1)
                        
                        Text(" · ")
                            .fontSize(12)
                            .fontColor(if (isSent) { this.outFg().fileDescriptionColor } else { 0x999999 })
                            .opacity(if (isSent) { 1.0 } else { 0.5 })
                    }
                    
                    Text(formatDurationSec(this.getVoiceDisplayTime(this.voicePlaybackEpoch)))
                        .fontSize(12)
                        .fontColor(if (isSent) { this.outFg().fileDurationColor } else { 0x999999 })
                        .opacity(if (isSent) { 1.0 } else { 0.7 })
                    if (this.message.documentSize > 0) {
                        Text(" · ${formatFileSize(this.message.documentSize)}")
                            .fontSize(12)
                            .fontColor(if (isSent) { this.outFg().fileDescriptionColor } else { 0x999999 })
                            .opacity(if (isSent) { 1.0 } else { 0.7 })
                    }
                }
                .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
        }
        .padding(left: 12, right: 12, top: 8, bottom: 4)
    }
    
    /**
     * 构建文件/文档消息内容
     */
    @Builder
    func documentContent(isSent: Bool) {
        if (this.message.documentMimeType.startsWith("image/") &&
            (this.message.documentThumbnailPath.size > 0 || this.message.documentLocalPath.size > 0)) {
            Stack(alignContent: Alignment.BottomStart) {
                Image(if (this.message.documentLocalPath.size > 0) {
                    this.message.documentLocalPath
                } else {
                    this.message.documentThumbnailPath
                })
                    .width(280)
                    .height(180)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(8)
                Text(this.message.documentFileName)
                    .fontSize(11)
                    .fontColor(0xFFFFFFFF)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                    .backgroundColor(0x66000000)
                    .padding(left: 7, right: 7, top: 3, bottom: 3)
                    .margin(left: 6, bottom: 6)
            }
            .width(280)
            .height(180)
            .onClick({ _evt => this.onFileTap(this.message) })
        } else {
            Row {
            // 文件图标
            // 资源保真修复：真实矢量图标（Chat/Message/RadialProgressIconDocument.imageset/ic_ch_file.pdf 转 SVG）替代 emoji 字形
            Column {
                Image(@r(app.media.chatroom_ic_doc))
                    .width(24)
                    .height(24)
                    .fillColor(if (isSent) { this.outFg().mediaControlInnerBackgroundColor } else { 0x317AFF })
            }
            .width(44)
            .height(44)
            // 发出方向对位源侧文件 statusNode：实底 mediaActiveControlColor + 镂空字形
            // （ChatMessageInteractiveFileNode.swift:1790-1796）。
            .backgroundColor(if (isSent) { this.outFg().mediaActiveControlColor } else { this.withAlpha(this.replyBlockMainColor(isSent), 0x1A) })
            .borderRadius(8)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 10)

            Column {
                Text(if (this.message.documentFileName.size > 0) { this.message.documentFileName } else { "File" })
                    .fontSize(14)
                    .fontColor(if (isSent) { this.outFg().fileTitleColor } else { 0x000000 })
                    .maxLines(1)
                if (this.message.documentSize > 0) {
                    Text(formatFileSize(this.message.documentSize))
                        .fontSize(11)
                        .fontColor(if (isSent) { this.outFg().fileDescriptionColor } else { 0x999999 })
                        .opacity(if (isSent) { 1.0 } else { 0.7 })
                        .margin(top: 2)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // 状态图标：下载中 / 已下载（可打开）/ 未下载
            if (this.message.isFileDownloading) {
                // 下载进行中 — 显示加载动画
                LoadingProgress()
                    .width(28)
                    .height(28)
                    .color(if (isSent) { this.outFg().mediaActiveControlColor } else { 0x317AFF })
            } else if (this.message.documentLocalPath.size > 0) {
                // 已下载 — 显示打开图标
                // 资源保真修复：真实矢量图标（Chat/Message/FileCloudFetched.imageset/phone.pdf 转 SVG）替代 emoji 字形
                Image(@r(app.media.chatroom_ic_downloaded))
                    .width(18)
                    .height(18)
                    .fillColor(if (isSent) { this.outFg().mediaActiveControlColor } else { 0x317AFF })
                    .padding(7)
                    .backgroundColor(this.withAlpha(this.replyBlockMainColor(isSent), 0x1A))
                    .borderRadius(16)
            } else if (this.message.documentId != 0) {
                // 未下载 — 显示下载按钮
                // 资源保真修复：真实矢量图标（Chat/Message/FileCloudFetch.imageset/cloud.pdf 转 SVG）替代 emoji 字形
                Image(@r(app.media.chatroom_ic_download))
                    .width(18)
                    .height(18)
                    .fillColor(if (isSent) { this.outFg().mediaActiveControlColor } else { 0x317AFF })
                    .padding(7)
                    .backgroundColor(this.withAlpha(this.replyBlockMainColor(isSent), 0x1A))
                    .borderRadius(16)
            }
            }
            .padding(left: 12, right: 12, top: 8)
            .onClick({ _evt => this.onFileTap(this.message) })
        }
    }
    
    /**
     * Phase Q3: 构建贴纸消息内容
     * 
     * 对应 TelegramHarmony MessageBubble.ets StickerContent
     * 
     * 仅显示已下载且可渲染的贴纸资源；资源未就绪时保持透明。
     */
    /**
     * Phase P2-1 + P7C-1: 贴纸内容渲染
     * 静态贴纸：显示已下载图片
     * 动画贴纸：显示服务端缩略图 + 脉冲动画效果
     * 未下载：透明占位，禁止显示 alt emoji / 默认贴纸 fallback
     */
    @Builder
    func stickerContent(isSent: Bool) {
        Column {
            // iOS 把 dateAndStatusNode 直接加在贴纸节点上、锚右下角，
            // 贴纸没有气泡底栏可用（ChatMessageAnimatedStickerItemNode.swift:243/1722）。
            Stack(alignContent: Alignment.BottomEnd) {
                Column {
                    if (this.message.documentLocalPath.size > 0) {
                        if (this.isTgsSticker()) {
                            // 动画贴纸 — 通过 rlottie 桥（libentry.so tg_lottie_*）将已下载的
                            // .tgs 逐帧光栅化为真实帧序列循环播放（替代旧的缩略图+脉冲降级）
                            AnimatedStickerComponent(
                                documentId: this.message.documentId,
                                localPath: this.message.documentLocalPath,
                                displaySize: 160.0,
                                placeholderPath: this.message.documentThumbnailPath
                            )
                        } else if (this.isVideoSticker()) {
                            AnimatedStickerComponent(
                                documentId: this.message.documentId,
                                localPath: this.message.documentLocalPath,
                                displaySize: 160.0,
                                isVideoSticker: true,
                                videoDuration: this.message.videoDuration,
                                placeholderPath: this.message.documentThumbnailPath
                            )
                        } else {
                            Image(this.message.documentLocalPath)
                                .width(160)
                                .height(160)
                                .objectFit(ImageFit.Contain)
                        }
                    } else if (this.message.documentThumbnailPath.size > 0) {
                        // This is the exact representation attached to the same
                        // Telegram document, not stickerAlt/system Emoji fallback.
                        Image(this.message.documentThumbnailPath)
                            .width(160)
                            .height(160)
                            .objectFit(ImageFit.Contain)
                    } else {
                        Column {}
                            .width(160)
                            .height(160)
                    }
                }
                .width(160)
                .height(160)
                freeDateAndStatusOverlay(isSent)
            }
            .width(160)
            .height(160)
        }
        .padding(left: 8, right: 8, top: 4)
    }
    
    /**
     * Phase P2-2: GIF 消息内容 — 下载后 Video 自动循环播放 / Image 静帧
     * Telegram GIF 实际是 mp4 视频，下载后用 Video 组件 autoPlay + loop + muted
     */
    @Builder
    func gifContent(isSent: Bool) {
        Stack(alignContent: Alignment.TopStart) {
            // 层 1：缩略图垫底。iOS 的媒体气泡永远先出模糊缩略图
            //（ChatMessageInteractiveMediaNode 的 imageNode），真身好了盖在上面，
            // 中间不闪灰块。
            if (this.message.documentThumbnailPath.size > 0) {
                Image(this.message.documentThumbnailPath)
                    .width(this.gifMediaWidth())
                    .height(this.gifMediaHeight())
                    .objectFit(ImageFit.Cover)
            } else if (!(this.gifReady() && this.gifAnimating)) {
                Column {
                    Text(trSource("GIF"))
                        .fontSize(24)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Bold)
                }
                .width(this.gifMediaWidth())
                .height(this.gifMediaHeight())
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(if (isSent) { 0x2060B0 } else { 0xD0D0D0 })
            }
            // 层 2：真身。Telegram 的 GIF 实为无声 mp4 → Video 循环播放；
            // 真 .gif 文件 → Image 自带动图播放。
            //
            // documentLocalPath 到这里**只可能是真身**：缩略图从前会被写进这个
            // 字段（jpg 直接喂 Video → 黑框），已在 ChatRoomViewModel 的
            // assignMediaPath("docThumb") 处堵死。
            if (this.message.documentLocalPath.size > 0 && this.gifAnimating) {
                if (this.message.documentMimeType.contains("mp4") || this.message.documentMimeType.contains("video")) {
                    Video(src: this.message.documentLocalPath)
                        .width(this.gifMediaWidth())
                        .height(this.gifMediaHeight())
                        .autoPlay(true)
                        .loop(true)
                        .muted(true)
                        .controls(false)
                        .objectFit(ImageFit.Cover)
                } else {
                    Image(this.message.documentLocalPath)
                        .width(this.gifMediaWidth())
                        .height(this.gifMediaHeight())
                        .objectFit(ImageFit.Cover)
                }
            } else if (this.message.isFileDownloading) {
                Column {
                    LoadingProgress()
                        .width(32)
                        .height(32)
                        .color(0xFFFFFF)
                }
                .width(this.gifMediaWidth())
                .height(this.gifMediaHeight())
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(0x30000000)
            }
            // 层 3：GIF 角标。iOS 放在媒体**内部** (6,6)
            //（ChatMessageInteractiveMediaNode.swift:3025 badgeNode.frame origin (inset, 6)），
            // 开始播放后随播放淡出（:633 alpha = 1 - factor）——所以真身就绪后不再画。
            // 此前角标 .position(x:8,y:8) 挂在一个被 100% 宽子项撑开的 Stack 上，
            // 实测画到了气泡左侧的墙纸上。现在 Stack 尺寸=媒体尺寸，角标必然在媒体内。
            if (!(this.gifReady() && this.gifAnimating)) {
                Text(trSource("GIF"))
                    .fontSize(11)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Bold)
                    .padding(left: 6, right: 6, top: 2, bottom: 2)
                    .backgroundColor(0x80000000)
                    .borderRadius(4)
                    .position(x: 6, y: 6)
            }
            // 层 4：时间戳（纯 GIF 无 caption 时，媒体内右下带 scrim，与照片一致）
            if (this.isBubblelessMedia()) {
                Row {
                    mediaTimestampOverlay(isSent)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(VerticalAlign.Bottom)
            }
        }
        .width(this.gifMediaWidth())
        .height(this.gifMediaHeight())
        .borderRadius(12)
        .clip(true)
        .margin(top: 2)
        .onVisibleAreaChange([0.01], { isVisible: Bool, _ratio: Float64 =>
            this.handleGifVisibility(isVisible)
        })
        .onDisAppear({ => this.stopGifPlayback() })
        .onClick({ _evt =>
            // 真身未到（自动下载被尺寸上限或开关拦下）→ 点按补下载，对齐 iOS 的
            // tap-to-fetch。真身已在时点按不做事（iOS 点开 GIF 进全屏，那是后话）。
            if (!this.gifReady() && !this.message.isFileDownloading) {
                this.onGifTap(this.message)
            } else if (this.gifReady() && !this.gifAnimating && !getTelegramCoreSettingsService().getPsAutoplayGif()) {
                // S7-153: 自动播放关闭时，点按开始播放（iOS 不自动播放的 GIF 由点按触发播放）。
                if (getChatVideoPlaybackLimiter().acquire()) {
                    this.gifHoldsVideoSlot = true
                    this.gifAnimating = true
                }
            }
        })
    }

    /** 真身（mp4/gif 文件）已就绪。 */
    private func gifReady(): Bool {
        return this.message.documentLocalPath.size > 0
    }

    /**
     * GIF 媒体显示尺寸：按真实宽高比装进 240×240（iOS 的媒体尺寸由
     * dimensions.fitted(constrainedSize) 推导，不是定宽）。此前定宽 200 +
     * ImageFit.Contain，竖版视频左右全是黑边，和「Video 喂了 jpg」叠在一起
     * 整个气泡就是一块黑。
     */
    private func gifMediaWidth(): Float64 {
        let w = Float64(this.message.videoWidth)
        let h = Float64(this.message.videoHeight)
        if (w <= 0.0 || h <= 0.0) { return 200.0 }
        let scale = if (240.0 / w < 240.0 / h) { 240.0 / w } else { 240.0 / h }
        return w * scale
    }

    private func gifMediaHeight(): Float64 {
        let w = Float64(this.message.videoWidth)
        let h = Float64(this.message.videoHeight)
        if (w <= 0.0 || h <= 0.0) { return 150.0 }
        let scale = if (240.0 / w < 240.0 / h) { 240.0 / w } else { 240.0 / h }
        return h * scale
    }

    /**
     * GIF 气泡的可见性门禁（GifGridCell 同款三件套：settle + 槽位 + 立即停）。
     * iOS 对位：ChatMessageInteractiveMediaNode 只在 visibility != none 时持有
     * UniversalVideoNode，滚出即弃 —— 我们这版 ArkUI 组件销毁信号不可靠，
     * 用 onVisibleAreaChange 承担同一职责。
     */
    private func handleGifVisibility(isVisible: Bool): Unit {
        if (isVisible) {
            this.gifSettleGeneration = this.gifSettleGeneration + 1
            let token = this.gifSettleGeneration
            let _ = spawn {
                sleep(Duration.millisecond * 260)
                launch {
                    // S7-153: 省电 → Autoplay GIFs 关闭时不自动播放（iOS
                    // ChatMessageMediaBubbleContentNode.swift:156/182 automaticPlayback 仅在
                    // energyUsageSettings.autoplayGif 为真时置位），点按才播放。
                    if (token == this.gifSettleGeneration && !this.gifAnimating && getTelegramCoreSettingsService().getPsAutoplayGif()) {
                        if (getChatVideoPlaybackLimiter().acquire()) {
                            this.gifHoldsVideoSlot = true
                            this.gifAnimating = true
                        }
                    }
                }
            }
        } else {
            this.gifSettleGeneration = this.gifSettleGeneration + 1
            this.stopGifPlayback()
        }
    }

    private func stopGifPlayback(): Unit {
        if (this.gifAnimating) { this.gifAnimating = false }
        if (this.gifHoldsVideoSlot) {
            this.gifHoldsVideoSlot = false
            getChatVideoPlaybackLimiter().release()
        }
    }

    /**
     * Phase P2-3: 网页预览卡片 — 渲染 title/description + 点击跳转浏览器
     * 
     * 渲染: 竖线标记 | 站点名 + 标题 + 描述 + URL 链接文字
     * 点击 → onWebUrlTap 回调 → ChatRoomPage 通过 Want 拉起浏览器
     */
    @Builder
    func webPreviewContent(isSent: Bool) {
        Row {
            // 左侧蓝色竖线
            Column {}
                .width(3)
                .height(this.webPreviewLineHeight())
                .backgroundColor(if (isSent) { 0xB0D4FF } else { 0x317AFF })
                .borderRadius(2)
                .margin(right: 8)

            Column {
                // 站点名
                if (this.message.webPageSiteName.size > 0) {
                    Text(this.message.webPageSiteName)
                        .fontSize(12)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFF2481CC)
                        .maxLines(1)
                }
                // 标题
                if (this.message.webPageTitle.size > 0) {
                    Text(this.message.webPageTitle)
                        .fontSize(14)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFF111111)
                        .maxLines(2)
                        .margin(top: 2)
                }
                // 描述
                if (this.message.webPageDescription.size > 0) {
                    Text(this.message.webPageDescription)
                        .fontSize(13)
                        .fontColor(0xFF333333)
                        .maxLines(3)
                        .margin(top: 2)
                }
                // P7B-1: 网页预览缩略图
                if (this.message.webPagePhotoLocalPath.size > 0) {
                    Image(this.message.webPagePhotoLocalPath)
                        .width(264)
                        .height(this.webPreviewPhotoHeight())
                        .borderRadius(6)
                        .objectFit(ImageFit.Contain)
                        .margin(top: 6)
                }
            }
            .width(264)
            .alignItems(HorizontalAlign.Start)
        }
        .padding(left: 12, right: 12, top: 6, bottom: 4)
        .onClick({ evt =>
            if (this.message.webPageUrl.size > 0) {
                this.onWebPreviewTap(this.message.webPageUrl)
            }
        })
    }

    /** iOS ChatMessageInvoiceBubbleContentNode + keyboardButtonBuy action row. */
    @Builder
    func invoiceContent(isSent: Bool) {
        Column {
            if (this.message.invoiceTitle.size > 0) {
                Text(this.message.invoiceTitle)
                    .fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                    .maxLines(2)
            }
            if (this.message.invoiceCurrency != "XTR") {
                Text(formatCurrencyAmount(this.message.invoiceTotalAmount, this.message.invoiceCurrency) + " " + trSource("Invoice"))
                    .fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                    .margin(top: 4)
            }
            if (this.message.invoiceDescription.size > 0) {
                Text(this.message.invoiceDescription)
                    .fontSize(15)
                    .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                    .maxLines(5).margin(top: 4)
            }
            if (this.message.invoicePaymentButtonTitle.size > 0) {
                Button(this.message.invoicePaymentButtonTitle)
                    .width(100.percent).height(42)
                    .fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor(if (isSent) { 0xFFFFFFFF } else { 0xFF2481CC })
                    .backgroundColor(if (isSent) { 0x223178FF } else { 0x112481CC })
                    .borderRadius(8).margin(top: 8)
                    .onClick({ _ => this.onInvoiceTap(this.message) })
            }
        }
        .width(270).alignItems(HorizontalAlign.Start)
        .padding(left: 12, right: 12, top: 10, bottom: 8)
    }

    private func webPreviewPhotoHeight(): Int64 {
        if (this.message.webPagePhotoWidth <= 0 || this.message.webPagePhotoHeight <= 0) {
            return 140
        }
        let scaled = 264 * Int64(this.message.webPagePhotoHeight) / Int64(this.message.webPagePhotoWidth)
        if (scaled < 96) { return 96 }
        if (scaled > 210) { return 210 }
        return scaled
    }

    private func webPreviewLineHeight(): Int64 {
        var height: Int64 = 0
        if (this.message.webPageSiteName.size > 0) { height += 18 }
        if (this.message.webPageTitle.size > 0) {
            height += if (this.message.webPageTitle.size > 42) { 38 } else { 20 }
        }
        if (this.message.webPageDescription.size > 0) {
            height += if (this.message.webPageDescription.size > 80) { 54 } else { 36 }
        }
        if (this.message.webPagePhotoLocalPath.size > 0) {
            height += this.webPreviewPhotoHeight() + 6
        }
        return height
    }

    /**
     * P2-183/192: 构建位置消息内容 — 真实 OSM 静态地图快照卡片
     *
     * Gap 修复:
     *   原: 假彩色占位块 + "View on Map" → 外部 Google Maps 网页
     *   现: 真快照 (fetchMapSnapshot → OSM HTTP + 缓存) + 点击 → 应用内 LocationDetailPage
     *
     * 快照加载链 (P2-192):
     *   .onAppear → loadLocationSnapshot → spawn { getLocationResourcesService().fetchMapSnapshot }
     *               → launch { this.locationSnapshotPath = path }
     *               → Image(this.locationSnapshotPath) 自动刷新
     *
     * 点击链 (P2-183):
     *   "查看地图" .onClick → onLocationTap(lat, lng, title)
     *     → ChatRoomPage: pageStack.pushPathByName("LocationDetailPage", "lat|lng|title")
     *       → LocationDetailPage 应用内显示快照 + 地址 + 导航按钮
     *
     * 实时位置 (LOC-5) 保持外部 Web (地图应用内实时追踪，不在详情页实现)
     */
    @Builder
    func locationContent(isSent: Bool) {
        Column {
            // 地图卡片主体
            Stack {
                // P2-192: 真实快照图片（优先）；无快照时回退占位
                if (this.locationSnapshotPath.size > 0) {
                    Image(this.locationSnapshotPath)
                        .width(LOCATION_BUBBLE_MAP_W)
                        .height(LOCATION_BUBBLE_MAP_H)
                        .objectFit(ImageFit.Cover)
                } else {
                    // 占位背景（快照加载前）
                    Column {}
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(if (isSent) { 0x2873D4 } else { 0xC8D8E8 })
                    // 装饰性网格线条（模拟地图纹理）
                    Column {
                        Divider().color(if (isSent) { 0x3380DD } else { 0xD0DDE8 }).strokeWidth(1).opacity(0.5)
                        Blank().height(28)
                        Divider().color(if (isSent) { 0x3380DD } else { 0xD0DDE8 }).strokeWidth(1).opacity(0.3)
                        Blank().height(28)
                        Divider().color(if (isSent) { 0x3380DD } else { 0xD0DDE8 }).strokeWidth(1).opacity(0.5)
                        Blank().height(28)
                        Divider().color(if (isSent) { 0x3380DD } else { 0xD0DDE8 }).strokeWidth(1).opacity(0.3)
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .padding(top: 10)
                }

                // P2-188 gap fix: 中心位置标记
                // - 实时位置: 内联头像 pin + 脉冲圈 + heading 箭头（对应 LiveLocationPositionComponent）
                // - 静态位置: 保留 📍 emoji
                if (this.message.isLiveLocation) {
                    // P2-188: 内联 live avatar pin (R-130: 同包不能 DSL 实例化 @Component)
                    Stack() {
                        // 层 1: 脉冲圈（蓝色扩散圆，3s 周期）
                        Column {}
                            .width(60)
                            .height(60)
                            .borderRadius(30)
                            .backgroundColor(0x450088FF)
                            .scale(x: this.livePinPulseScale, y: this.livePinPulseScale)
                            .opacity(this.livePinPulseAlpha)
                            .position(x: 1, y: 34)

                        // 层 2: 方向箭头（仅在有 heading 时显示）
                        if (this.livePinHasHeading()) {
                            Canvas(this.livePinArrowCtx)
                                .width(70)
                                .height(70)
                                .rotate(angle: this.getLivePinHeadingDeg())
                                .position(x: -4, y: 29)
                                .onReady({ =>
                                    this.drawLivePinArrow(this.livePinArrowCtx)
                                })
                        }

                        // 层 3: pin 背景（蓝色圆头 + 三角尖端）
                        Stack() {
                            Column {}
                                .width(62)
                                .height(62)
                                .borderRadius(31)
                                .backgroundColor(0xFF2196F3)
                                .position(x: 0, y: 0)
                            Column {}
                                .width(14)
                                .height(14)
                                .backgroundColor(0xFF2196F3)
                                .rotate(angle: 45.0)
                                .position(x: 24, y: 56)
                        }
                        .width(62)
                        .height(74)

                        // 层 4: 头像（iOS LiveLocationPositionNode.avatarNode：真实头像，无则首字母占位）
                        if (this.livePinAvatarPath().size > 0) {
                            Image(this.livePinAvatarPath())
                                .width(42)
                                .height(42)
                                .borderRadius(21)
                                .objectFit(ImageFit.Cover)
                                .position(x: 10, y: 9)
                        } else {
                            Column {
                                Text(this.getLivePinPlaceholder())
                                    .fontSize(18)
                                    .fontColor(0xFFFFFFFF)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(42)
                            .height(42)
                            .borderRadius(21)
                            .backgroundColor(0xFF5C6BC0)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .position(x: 10, y: 9)
                        }
                    }
                    .width(62)
                    .height(74)
                    // iOS pinNode.frame.y = imageH*0.5 - 10 - pinH/2：居中后再上移 10
                    .margin(bottom: 20)
                } else {
                    // iOS LiveLocationPositionNode .location 模式：accent 色 62×74 大头针 + 44×44 图标圆
                    Stack() {
                        Column {}
                            .width(62)
                            .height(62)
                            .borderRadius(31)
                            .backgroundColor(0xFF007AFF)
                            .position(x: 0, y: 0)
                        Column {}
                            .width(14)
                            .height(14)
                            .backgroundColor(0xFF007AFF)
                            .rotate(angle: 45.0)
                            .position(x: 24, y: 56)
                        Column {
                            Image(@r(app.media.loc_ic_maprow))
                                .width(24)
                                .height(24)
                                .fillColor(0xFF007AFF)
                        }
                        .width(44)
                        .height(44)
                        .borderRadius(22)
                        .backgroundColor(0xFFFFFFFF)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .position(x: 9, y: 9)
                    }
                    .width(62)
                    .height(74)
                    .margin(bottom: 20)
                }

            }
            .width(LOCATION_BUBBLE_MAP_W)
            .height(LOCATION_BUBBLE_MAP_H)
            .borderRadius(12)
            .clip(true)
            .margin(left: 4, right: 4, top: 6)
            .onClick({ _evt =>
                // iOS：任何位置消息点击 → openMessage → LocationViewController
                this.onLocationTap(this.message.locationLat, this.message.locationLng, this.locationTapTitle())
            })
            .onAppear({ =>
                this.loadLocationSnapshotIfNeeded()
                // P2-187: initialize timer service with message's timestamp + period
                if (this.message.isLiveLocation) {
                    this.initLiveTimerService()
                    // P2-188: start inline pulse animation for live avatar pin
                    this.startLivePinAnimation()
                }
            })

            // 对位 iOS ChatMessageMapBubbleContentNode（live 分支）：
            //   titleNode  "Live Location"  medium 16   at (imageMinX+7, imageMaxY+6)
            //   liveTextNode "updated … ago" regular 14 at (imageMinX+7, +titleH)，宽 imageW-14-40
            //   liveTimerNode 28×28 环       at (imageMaxX-10-28, imageMaxY+11)
            // 过期（activeLiveBroadcastingTimeout == nil）后三者全部隐藏，只剩地图。
            if (this.message.isLiveLocation && this.liveLocationActive()) {
                Stack(alignContent: Alignment.TopStart) {
                    Column {
                        Text(trSource("Live Location"))
                            .fontSize(16)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.liveTitleColor(isSent))
                            .maxLines(1)
                        Text(this.liveUpdatedText)
                            .fontSize(14)
                            .fontColor(this.liveSecondaryColor(isSent))
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                            .height(18)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .padding(left: 7, right: 54)
                    Stack() {
                        Canvas(this.liveTimerCtx)
                            .width(28.0)
                            .height(28.0)
                            .onReady({ =>
                                this.drawLiveTimerRing(this.liveTimerCtx, 28.0, isSent)
                            })
                    }
                    .width(28.0)
                    .height(28.0)
                    .position(x: LOCATION_BUBBLE_MAP_W - 10.0 - 28.0, y: 5)
                }
                .width(LOCATION_BUBBLE_MAP_W)
                .margin(left: 4, right: 4, top: 6, bottom: 4)
                .onClick({ _evt =>
                    this.onLocationTap(this.message.locationLat, this.message.locationLng, "Live Location")
                })
            } else if (!this.message.isLiveLocation && this.message.venueTitle.size > 0) {
                // iOS venue：title medium14 + address regular14，位于 (imageMinX+7, imageMaxY+6)
                Column {
                    Text(this.message.venueTitle)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFF000000)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                    if (this.message.venueAddress.size > 0) {
                        Text(this.message.venueAddress)
                            .fontSize(14)
                            .fontColor(this.liveSecondaryColor(isSent))
                            .maxLines(2)
                            .textOverflow(TextOverflow.Ellipsis)
                    }
                }
                .width(LOCATION_BUBBLE_MAP_W)
                .alignItems(HorizontalAlign.Start)
                .padding(left: 7, right: 7)
                .margin(left: 4, right: 4, top: 6, bottom: 4)
                .onClick({ _evt =>
                    this.onLocationTap(this.message.locationLat, this.message.locationLng, this.locationTapTitle())
                })
            }
        }
    }

    /**
     * Phase P5-13: 获取位置显示文本（坐标或地址）
     */
    private func getLocationDisplayText(): String {
        if (this.message.mediaDescription.size > 0 && this.message.mediaDescription != "[Location]") {
            return this.message.mediaDescription
        }
        if (this.message.locationLat != 0.0 || this.message.locationLng != 0.0) {
            return "${this.message.locationLat}, ${this.message.locationLng}"
        }
        return "Location"
    }

    /**
     * Phase LOC-5: 获取实时位置持续时间文本
     */
    private func getLiveDurationText(): String {
        let period = this.message.liveLocationPeriod
        if (period == 900) { return "15 min" }
        if (period == 3600) { return "1 hour" }
        if (period == 28800) { return "8 hours" }
        if (period > 3600) {
            let hours = period / 3600
            return "${hours} hours"
        }
        if (period > 60) {
            let mins = period / 60
            return "${mins} min"
        }
        return "Live Location"
    }

    /**
     * P2-187: 初始化实时位置倒计时环计时器服务
     *
     * 对应 iOS ChatMessageMapBubbleContentNode.liveTimerNode.update(
     *   beginTimestamp: Double(item.message.timestamp),
     *   timeout: activeLiveBroadcastingTimeout == liveLocationIndefinitePeriod ? -1.0 : Double(activeLiveBroadcastingTimeout)
     * )
     *
     * rawTimestamp: 消息的 Unix 时间戳（秒），即 liveLocation 开始时刻
     * liveLocationPeriod: 分享时长（秒）；INDEFINITE → -1.0 timeout（无限期）
     */
    private func initLiveTimerService(): Unit {
        let beginTs = Float64(this.message.rawTimestamp)
        let timeout: Float64
        if (this.message.liveLocationPeriod == LIVE_LOCATION_INDEFINITE_PERIOD) {
            timeout = -1.0
        } else if (this.message.liveLocationPeriod > 0) {
            timeout = Float64(this.message.liveLocationPeriod)
        } else {
            timeout = 900.0
        }
        this.liveTimerService.update(beginTs, timeout)
        Hilog.info(0, "CjTelegram", "[MessageBubble] initLiveTimerService: begin=${beginTs} timeout=${timeout}")
    }

    // P2-187: 辅助——获取计时器标签（避免在 @Builder 中使用 let）
    private func getLiveTimerLabel(): String {
        this.liveTimerService.getTimerState().label
    }

    // P2-187: 辅助——获取计时器进度 [0.0,1.0]
    private func getLiveTimerProgress(): Float64 {
        this.liveTimerService.getTimerState().progress
    }

    // P2-187: 辅助——绘制倒计时环到 Canvas context
    /**
     * 对位 iOS ChatMessageLiveLocationTimerNode.draw：
     *   底 = accent 40% 透明的 1.5pt 圆环；进度 = accent 实线弧（从 12 点顺时针，长度 = 剩余比例）；
     *   文字 = 剩余分钟数（≥1h 显示 "Nh"，无限期 "∞"），round bold 13 / 11。
     */
    private func drawLiveTimerRing(c2d: CanvasRenderingContext2D, ringSize: Float64, isSent: Bool): Unit {
        let cx = ringSize / 2.0
        let cy = ringSize / 2.0
        let lineW = 1.5
        let pi = 3.14159265358979
        let accent = this.liveAccentColor(isSent)
        let radius = (ringSize - lineW) / 2.0

        c2d.clearRect(0.0, 0.0, ringSize, ringSize)
        c2d.strokeStyle = Int64(accent)
        c2d.lineWidth = lineW
        c2d.globalAlpha = 0.4
        c2d.beginPath()
        c2d.arc(cx, cy, radius, 0.0, 2.0 * pi, counterclockwise: false)
        c2d.stroke()
        c2d.globalAlpha = 1.0

        let state = this.liveTimerService.getTimerState()
        if (!state.isInfinite) {
            let remaining = 1.0 - state.progress
            let startAngle = -pi / 2.0
            let endAngle = startAngle + remaining * 2.0 * pi
            c2d.lineCap = "round"
            c2d.beginPath()
            c2d.arc(cx, cy, radius, startAngle, endAngle, counterclockwise: false)
            c2d.stroke()
        }

        let label = if (state.isInfinite) { "∞" } else { state.label }
        let fontSize = if (label.size > 2) { 11.0 } else { 13.0 }
        c2d.font = "bold ${fontSize}px sans-serif"
        c2d.fillStyle = Int64(this.liveSecondaryColor(isSent))
        c2d.textAlign = "center"
        c2d.textBaseline = "middle"
        c2d.fillText(label, cx, cy)
    }

    // ---- iOS 实时位置文案/取色 ----

    /** iOS activeLiveBroadcastingTimeout != nil：无限期或 timestamp + period > now */
    private func liveLocationActive(): Bool {
        if (this.message.liveLocationPeriod == LIVE_LOCATION_INDEFINITE_PERIOD) { return true }
        if (this.message.liveLocationPeriod <= 0) { return false }
        let now = Int64(this.liveTimerService.getCurrentUnixSeconds())
        return this.message.rawTimestamp + Int64(this.message.liveLocationPeriod) > now
    }

    private func locationTapTitle(): String {
        if (this.message.venueTitle.size > 0) { return this.message.venueTitle }
        if (this.message.isLiveLocation) { return "Live Location" }
        return "Location"
    }

    /** iOS stringForRelativeLiveLocationTimestamp：取 EditedMessageAttribute.date，无则消息时间。 */
    private func computeLiveUpdatedText(): String {
        let now = Int64(this.liveTimerService.getCurrentUnixSeconds())
        let base = if (this.message.editDate > 0) { this.message.editDate } else { this.message.rawTimestamp }
        let diff = now - base
        if (diff < 60) { return "updated just now" }
        if (diff < 3600) {
            let m = diff / 60
            return if (m == 1) { "updated 1 minute ago" } else { "updated ${m} minutes ago" }
        }
        if (diff < 86400) {
            let h = diff / 3600
            return if (h == 1) { "updated 1 hour ago" } else { "updated ${h} hours ago" }
        }
        let d = diff / 86400
        return if (d == 1) { "updated 1 day ago" } else { "updated ${d} days ago" }
    }

    /** iOS theme.chat.message.incoming/outgoing.accentControlColor（day theme） */
    private func liveAccentColor(isSent: Bool): UInt32 {
        return if (isSent) { 0xFF00A700 } else { 0xFF007AFF }
    }

    private func liveSecondaryColor(isSent: Bool): UInt32 {
        return if (isSent) { 0xFF008C09 } else { 0xFF8E8E93 }
    }

    private func liveTitleColor(isSent: Bool): UInt32 {
        return 0xFF000000
    }

    // ==================== P2-188: 内联头像 pin — 替代孤儿 LiveLocationPositionComponent ====================

    /**
     * P2-188 gap fix: 启动头像 pin 脉冲动画
     *
     * 对应 LiveLocationPositionComponent.startPulseAnimation():
     * 每 60ms 触发一帧，3s 一轮（50 帧），写 livePinPulseScale/Alpha/@State
     */
    private func startLivePinAnimation(): Unit {
        if (this.livePinTimer.isSome()) { return }
        this.livePinTimer = Some(Timer.repeat(
            Duration.millisecond * 60,
            Duration.millisecond * 60,
            { =>
                if (getAppState().isInForeground()) { this.livePinAnimStep() }
            },
            style: CatchupStyle.Skip
        ))
    }

    private func stopLivePinAnimation(): Unit {
        match (this.livePinTimer) {
            case Some(t) =>
                t.cancel()
                this.livePinTimer = None<Timer>
            case None => ()
        }
    }

    /**
     * 每帧更新脉冲动画参数（等价 LiveLocationPositionComponent.animateStep）
     * R-69: @State 写操作在 launch{} 内
     */
    private func livePinAnimStep(): Unit {
        this.liveRefreshTicks = this.liveRefreshTicks + 1
        if (this.liveRefreshTicks % 500 == 1) {
            let text = this.computeLiveUpdatedText()
            let sent = this.message.isSent
            launch {
                this.liveUpdatedText = text
                try { this.drawLiveTimerRing(this.liveTimerCtx, 28.0, sent) } catch (_: Exception) {}
            }
        }
        this.livePinAnimProgress = this.livePinAnimProgress + 0.02
        if (this.livePinAnimProgress > 1.0) {
            this.livePinAnimProgress = 0.0
        }
        let p = this.livePinAnimProgress
        let scaleF64: Float64
        let alpha: Float64
        if (p < 0.49) {
            scaleF64 = p / 0.49 * 0.72
            alpha = 1.0 - (p / 0.49) * 0.8
        } else if (p < 0.88) {
            let t2 = (p - 0.49) / 0.39
            scaleF64 = 0.72 + t2 * 0.28
            alpha = 0.2 - t2 * 0.2
        } else {
            scaleF64 = 1.0
            alpha = 0.0
        }
        let scaleF32 = Float32(scaleF64)
        launch {
            this.livePinPulseScale = scaleF32
            this.livePinPulseAlpha = alpha
        }
    }

    /**
     * P2-188: 绘制方向箭头扇形（等价 LiveLocationPositionComponent.drawArrow）
     * 对应 iOS: UImageView + CGAffineTransform.makeRotation(heading)
     */
    private func drawLivePinArrow(c2d: CanvasRenderingContext2D): Unit {
        let w = 70.0
        let cx = w / 2.0
        let cy = w / 2.0
        let r = w / 2.0
        let innerR = 5.0
        let pi = 3.14159265358979323846
        let startAngle = pi / 2.0 + pi / 8.0
        let endAngle = pi / 2.0 - pi / 8.0
        c2d.beginPath()
        c2d.moveTo(cx, cy)
        c2d.arc(cx, cy, r, startAngle, endAngle, counterclockwise: true)
        c2d.closePath()
        c2d.fillStyle = 0x7F0088FF
        c2d.fill()
        c2d.beginPath()
        c2d.arc(cx, cy, innerR, 0.0, 2.0 * pi, counterclockwise: false)
        c2d.fillStyle = 0xFF000000
        c2d.globalAlpha = 0.0
        c2d.fill()
        c2d.globalAlpha = 1.0
    }

    /**
     * P2-188: 从 Message.locationHeading 获取方向角（度），用于 Canvas rotate
     * 对应 iOS effectiveHeading → CGAffineTransform.makeRotation(heading)
     * @return (hasHeading, angleDeg)
     */
    private func getLivePinHeadingDeg(): Float32 {
        let h = this.message.locationHeading
        if (h >= 0) { return Float32(h) }
        return Float32(0.0)
    }

    private func livePinHasHeading(): Bool {
        this.message.locationHeading >= 0
    }

    /** pin 内头像路径：发送者头像；自己发的实时位置 senderId 可能为 0，回退到当前账号头像。 */
    private func livePinAvatarPath(): String {
        var uid = this.message.senderId
        if (uid <= 0 || this.message.isSent) { uid = getCurrentUserId() }
        if (uid <= 0) { return "" }
        return getUserPhotoService().getUserPhotoPath(uid)
    }

    private func getLivePinPlaceholder(): String {
        getLiveLocationPositionService().getAvatarPlaceholder(this.message.senderName)
    }

    /**
     * P2-192: 加载位置快照（首次出现时触发）
     * 从 LocationResourcesService.fetchMapSnapshot 拉取 OSM 静态地图（含本地缓存）
     */
    private func loadLocationSnapshotIfNeeded(): Unit {
        if (this.locationSnapshotPath.size > 0) { return }
        let lat = this.message.locationLat
        let lng = this.message.locationLng
        if (lat == 0.0 && lng == 0.0) { return }
        let _ = spawn {
            let svc = getLocationResourcesService()
            let r = svc.fetchMapSnapshot(lat, lng, Int32(LOCATION_BUBBLE_MAP_W * 2.0), Int32(LOCATION_BUBBLE_MAP_H * 2.0), zoom: 16)
            if (r.success) {
                let p = r.localPath
                launch { this.locationSnapshotPath = p }
            }
        }
    }

    /**
     * Phase P5-13: 构建地图 URL（供系统浏览器打开）
     */
    private func getLocationMapUrl(): String {
        let lat = this.message.locationLat
        let lng = this.message.locationLng
        if (lat != 0.0 || lng != 0.0) {
            return "https://maps.google.com/?q=${lat},${lng}"
        }
        return "https://maps.google.com/"
    }
    
    /**
     * 构建联系人消息内容
     */
    @Builder
    func contactContent(isSent: Bool) {
        Row {
            // 联系人头像占位
            // 资源保真修复：真实矢量图标（Chat/Context Menu/User.imageset/ic_lt_user.pdf 转 SVG）替代 emoji 字形
            Column {
                Image(@r(app.media.chatroom_ic_avatar))
                    .width(20)
                    .height(20)
                    .fillColor(0xFFFFFF)
            }
            .width(44)
            .height(44)
            .backgroundColor(if (isSent) { 0x2873D4 } else { 0x007AFF })
            .borderRadius(22)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 10)
            
            Column {
                // 联系人名称（iOS ChatMessageContactBubbleContentNode: displayName）
                // W3 S2-96：配色对位 ChatMessageContactBubbleContentNode.swift:130-150/220-221 ——
                // 标题 titleString 取 mainColor（outgoing 恒为 messageTheme.accentTextColor；incoming
                // 为 peer nameColor 或 accentTextColor），正文 textString 取 messageTheme.primaryTextColor。
                // 此前发出方向写死白色，压在 dayClassic 浅绿发出气泡（0xE1FFC7 系）上几乎不可读。
                Text(this.contactCardName())
                    .fontSize(15)
                    .fontColor(this.replyBlockMainColor(isSent))
                    .fontWeight(FontWeight.Medium)
                // S2-96: 电话号码（iOS formatPhoneNumber(contact.phoneNumber)）
                if (this.message.contactPhone.size > 0) {
                    Text(this.contactCardPhone())
                        .fontSize(13)
                        .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                        .margin(top: 2)
                } else if (this.message.content.size > 0 && this.message.content != this.message.mediaDescription) {
                    Text(this.message.content)
                        .fontSize(13)
                        .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                        .margin(top: 2)
                }
            }
            .alignItems(HorizontalAlign.Start)
        }
        .padding(left: 12, right: 12, top: 8)
    }
    
    /** S2-96: name shown on a contact card; falls back to the legacy "[Contact: …]" description. */
    private func contactCardName(): String {
        if (this.message.contactDisplayName.size > 0) { return this.message.contactDisplayName }
        let desc = this.message.mediaDescription
        if (desc.startsWith("[Contact: ") && desc.endsWith("]") && desc.size > 11) {
            return desc[10..(desc.size - 1)].trimAscii()
        }
        return if (desc.size > 0) { desc } else { "Contact" }
    }

    /** S2-96: iOS formatPhoneNumber — "+86 176 2150 5331" style, raw "+<digits>" when unparsable. */
    private func contactCardPhone(): String {
        var raw = this.message.contactPhone
        if (raw.size == 0) { return "" }
        if (!raw.startsWith("+")) { raw = "+" + raw }
        let parsed = parsePhoneNumber(raw)
        if (parsed.countryCode.size > 0 && parsed.nationalNumber.size > 0) {
            return formatPhoneNumber(parsed.countryCode, parsed.nationalNumber)
        }
        return raw
    }

    /**
     * 构建投票消息内容
     */
    /**
     * Phase Q8: 获取投票选项索引数组（供 ForEach 使用）
     */
    private func getPollOptionIndices(): Array<Int64> {
        return Array<Int64>(Int64(this.message.pollOptions.size), { i: Int64 => i })
    }

    /**
     * Phase Q8: 获取选项的百分比文字
     */
    private func getPollOptionPercentage(optIndex: Int64): String {
        if (optIndex < 0 || optIndex >= Int64(this.message.pollOptions.size)) { return "" }
        let opt = this.message.pollOptions[optIndex]
        if (this.message.pollTotalVoters == 0) { return "" }
        return "${opt.percentage}%"
    }

    /**
     * Phase Q8: 获取选项的投票人数文字
     */
    private func getPollOptionVotersText(optIndex: Int64): String {
        if (optIndex < 0 || optIndex >= Int64(this.message.pollOptions.size)) { return "" }
        let opt = this.message.pollOptions[optIndex]
        if (opt.voters == 0) { return "" }
        return "${opt.voters}"
    }

    /**
     * Phase Q8: 获取选项是否被当前用户选中
     */
    private func isPollOptionChosen(optIndex: Int64): Bool {
        if (optIndex < 0 || optIndex >= Int64(this.message.pollOptions.size)) { return false }
        return this.message.pollOptions[optIndex].chosen
    }

    /**
     * Phase Q8: 获取选项是否为正确答案
     */
    private func isPollOptionCorrect(optIndex: Int64): Bool {
        if (optIndex < 0 || optIndex >= Int64(this.message.pollOptions.size)) { return false }
        return this.message.pollOptions[optIndex].correct
    }

    /**
     * Phase Q8: 获取选项进度条宽度（百分比对应的像素宽度，最大 180）
     */
    private func getPollOptionBarWidth(optIndex: Int64): Float64 {
        if (optIndex < 0 || optIndex >= Int64(this.message.pollOptions.size)) { return 0.0 }
        let pct = this.message.pollOptions[optIndex].percentage
        return Float64(pct) * 180.0 / 100.0
    }

    /**
     * Phase Q8: 构建投票消息内容（增强版 — 显示选项+结果+百分比）
     */
    @Builder
    func pollContent(isSent: Bool) {
        Column {
            // 投票图标 + 类型标签
            Row {
                Text("📊")
                    .fontSize(18)
                    .margin(right: 8)
                Text(if (this.message.pollQuiz) { "Quiz" } else { "Poll" })
                    .fontSize(11)
                    .fontColor(if (isSent) { 0xFFFFFF } else { 0x999999 })
                    .fontWeight(FontWeight.Medium)
                if (this.message.pollClosed) {
                    Text(" · Closed")
                        .fontSize(11)
                        .fontColor(if (isSent) { 0xFFFFFF } else { 0x999999 })
                        .opacity(0.7)
                }
            }
            .padding(left: 12, right: 12, top: 6)
            
            // 问题
            if (this.message.pollQuestion.size > 0) {
                Text(this.message.pollQuestion)
                    .fontSize(15)
                    .fontColor(if (isSent) { 0xFFFFFF } else { 0x000000 })
                    .fontWeight(FontWeight.Bold)
                    .padding(left: 12, right: 12, top: 4)
            }
            
            // 投票选项列表
            ForEach(this.getPollOptionIndices(), itemGenerator: { idx: Int64, _i: Int64 =>
                pollOptionRow(idx, isSent)
            })
            
            // 底部：总票数
            if (this.message.pollTotalVoters > 0) {
                Text("${this.message.pollTotalVoters} votes")
                    .fontSize(11)
                    .fontColor(if (isSent) { 0xFFFFFF } else { 0x999999 })
                    .opacity(0.7)
                    .padding(left: 12, right: 12, top: 4, bottom: 2)
            }

            // Quiz 解析答案提示
            if (this.message.pollQuiz && this.message.pollSolution.size > 0) {
                Text("💡 ${this.message.pollSolution}")
                    .fontSize(12)
                    .fontColor(if (isSent) { 0xFFFFFF } else { 0x317AFF })
                    .opacity(0.8)
                    .padding(left: 12, right: 12, top: 2)
            }
        }
    }

    /**
     * Phase Q8: 单个投票选项行
     */
    @Builder
    func pollOptionRow(optIndex: Int64, isSent: Bool) {
        Column {
            Row {
                // 选中标记
                // 资源保真修复：真实矢量图标（Chat/Context Menu/Check.imageset/ic_menucheck.pdf 转 SVG）替代 emoji 字形
                if (this.isPollOptionChosen(optIndex)) {
                    Image(@r(app.media.chatroom_ic_poll_check))
                        .width(12)
                        .height(12)
                        .fillColor(if (isSent) { 0xFFFFFF } else { 0x317AFF })
                        .margin(right: 6)
                }
                // 正确答案标记（quiz 模式）
                if (this.message.pollQuiz && this.isPollOptionCorrect(optIndex)) {
                    Image(@r(app.media.chatroom_ic_poll_check))
                        .width(12)
                        .height(12)
                        .fillColor(0x34C759)
                        .margin(right: 6)
                }
                // 选项文字
                if (optIndex < Int64(this.message.pollOptions.size)) {
                    Text(this.message.pollOptions[optIndex].text)
                        .fontSize(14)
                        .fontColor(if (isSent) { 0xFFFFFF } else { 0x000000 })
                }
                Blank()
                // 百分比
                Text(this.getPollOptionPercentage(optIndex))
                    .fontSize(13)
                    .fontColor(if (isSent) { 0xFFFFFF } else { 0x317AFF })
                    .fontWeight(FontWeight.Medium)
            }
            .width(100.percent)
            
            // 进度条
            if (this.message.pollTotalVoters > 0) {
                Row {}
                    .width(this.getPollOptionBarWidth(optIndex))
                    .height(3)
                    .backgroundColor(if (this.isPollOptionChosen(optIndex)) { 0x317AFF } else { if (isSent) { 0xFFFFFF } else { 0xCCCCCC } })
                    .opacity(if (this.isPollOptionChosen(optIndex)) { 1.0 } else { 0.4 })
                    .borderRadius(1.5)
                    .margin(top: 2)
            }
        }
        .padding(left: 12, right: 12, top: 6)
        .onClick({ evt =>
            this.handlePollVote(optIndex)
        })
    }

    private func handlePollVote(optIndex: Int64): Unit {
        if (this.message.pollClosed) { return }
        if (optIndex < 0 || optIndex >= Int64(this.message.pollOptions.size)) { return }
        let alreadyVoted = this.isPollOptionChosen(optIndex)
        if (alreadyVoted && !this.message.pollMultipleChoice) { return }
        this.onVoteTap(this.message.id, optIndex)
    }

    // ==================== S4-12: 聊天内搜索命中高亮 ====================

    /** True while an in-chat search query is set for this bubble and the text contains it. */
    private func searchHighlightActive(): Bool {
        if (this.searchHighlightText.size == 0 || this.message.content.size == 0) { return false }
        return this.message.content.toAsciiLower().contains(this.searchHighlightText.toAsciiLower())
    }

    /**
     * Split the message text into runs for searchHighlightedTextContent. Runs break at every
     * match boundary and (outside a match) after whitespace, so the wrapping Flex can wrap
     * between words while each matched run keeps its own background. Matching is
     * case-insensitive on ASCII (toAsciiLower keeps byte offsets), so slices stay on UTF-8
     * boundaries.
     */
    private func getSearchHighlightChunks(): ArrayList<SearchTextChunk> {
        let result = ArrayList<SearchTextChunk>()
        let content = this.message.content
        let query = this.searchHighlightText.toAsciiLower()
        if (query.size == 0) {
            result.add(SearchTextChunk(content, false))
            return result
        }
        let lower = content.toAsciiLower()
        // match ranges [start, end) in byte offsets
        let starts = ArrayList<Int64>()
        var from: Int64 = 0
        while (from <= lower.size - query.size) {
            match (lower.indexOf(query, from)) {
                case Some(pos) =>
                    starts.add(pos)
                    from = pos + query.size
                case None => break
            }
        }
        let bytes = content.toArray()
        var chunkStart: Int64 = 0
        var matchIdx: Int64 = 0
        var i: Int64 = 0
        while (i < bytes.size) {
            if (matchIdx < starts.size && i == starts[matchIdx]) {
                if (i > chunkStart) { result.add(SearchTextChunk(content[chunkStart..i], false)) }
                let end = i + query.size
                result.add(SearchTextChunk(content[i..end], true))
                chunkStart = end
                i = end
                matchIdx += 1
                continue
            }
            let b = bytes[i]
            if (b == 0x20 || b == 0x0A) {
                result.add(SearchTextChunk(content[chunkStart..(i + 1)], false))
                chunkStart = i + 1
            }
            i += 1
        }
        if (chunkStart < bytes.size) { result.add(SearchTextChunk(content[chunkStart..bytes.size], false)) }
        return result
    }

    /**
     * iOS ChatMessageTextBubbleContentNode.updateSearchTextHighlightState: every occurrence of
     * the search query inside a result message is backed by a textHighlightColor rect
     * (DefaultDayPresentationTheme.swift:628 0xffe438). Span has no background in this SDK, so
     * the text is laid out as wrapping Text runs and the matched runs carry the background.
     */
    @Builder
    func searchHighlightedTextContent(isSent: Bool) {
        Flex(wrap: FlexWrap.Wrap) {
            ForEach(this.getSearchHighlightChunks(), itemGenerator: { chunk: SearchTextChunk, _idx: Int64 =>
                Text(chunk.text)
                    .fontSize(this.chatFont(15))
                    .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                    // W4 S4-12：非命中段必须是 Color.Transparent。本 SDK 对首字节为 0 的数值颜色
                    // 字面量强制补 alpha=FF（ItemListComponents.cj D-144），0x00000000 落成不透明黑，
                    // 命中气泡里 kiwi 以外的文字整段被黑块盖住；iOS 只给匹配 rect 上色，其余不画。
                    .backgroundColor(if (chunk.isMatch) { 0xFFFFE438 } else { Color.Transparent })
                    .borderRadius(3)
            }, keyGenerator: { chunk: SearchTextChunk, idx: Int64 =>
                "${idx}_${chunk.isMatch}_${chunk.text}"
            })
        }
        .padding(left: 10, right: 10, top: 7)
    }

    // ==================== Phase Q11: 富文本渲染 ====================
    
    /**
     * Phase Q11 + P2-113: 使用 Text + ForEach(Span) 渲染富文本实体
     *
     * 支持: 粗体、斜体、代码、删除线、下划线、链接(onClick)、
     *       mention(onClick)、spoiler(点击展开)、blockquote(背景色模拟)
     *
     * CangjieUI Text 支持 Span 子组件，Span 支持 onClick（通用事件）。
     */
    @Builder
    func richTextContent(isSent: Bool) {
        Column {
            Text() {
                ForEach(this.getTextSegments(), itemGenerator: { seg: TextSegment, _idx: Int64 =>
                    if (seg.customEmojiId != 0 && hasInlineCustomEmoji(seg.customEmojiId)) {
                        // iOS EmojiTextAttachmentView：自定义表情画进文本流本身，
                        // 而不是退化成 alt 字符
                        this.buildInlineCustomEmoji(seg)
                    } else if (seg.isSpoiler && !this.isSpoilerRevealed(seg.segIndex)) {
                        // S2-24 / iOS InvisibleInkDustNode: the hidden run is masked in place (one
                        // shaded glyph per character, spaces kept) so the covered text keeps its
                        // extent and stays unreadable; Span has no backgroundColor and no dust
                        // overlay can be anchored to a Span, so the mask is drawn with glyphs.
                        // Tap to reveal (toggleSpoiler).
                        Span(spoilerMaskText(seg.text))
                            .fontSize(this.chatFont(15))
                            .fontColor(if (isSent) { 0xFF7FA8D8 } else { 0xFF9A9AA0 })
                            .onClick({ _evt =>
                                this.toggleSpoiler(seg.segIndex)
                            })
                    } else if (seg.isUrl) {
                        Span(seg.text)
                            .fontSize(if (seg.isCode || seg.isPre) { this.chatFont(14) } else { this.chatFont(16) })
                            .fontColor(0xFF2481CC)
                            .fontWeight(if (seg.isBold) { FontWeight.Bold } else { FontWeight.Normal })
                            .fontStyle(if (seg.isItalic) { FontStyle.Italic } else { FontStyle.Normal })
                            .decoration(decorationType: TextDecorationType.Underline)
                            .onClick({ _evt =>
                                if (seg.url.size > 0) {
                                    this.onWebUrlTap(seg.url)
                                }
                            })
                    } else if (seg.isMention) {
                        Span(seg.text)
                            .fontSize(this.chatFont(16))
                            .fontColor(0xFF2481CC)
                            .fontWeight(FontWeight.Medium)
                            .onClick({ _evt =>
                                if (seg.url.size > 0) {
                                    if (seg.url.startsWith("@")) {
                                        let domain = seg.url[1..]
                                        this.onWebUrlTap("tg://resolve?domain=${domain}")
                                    } else {
                                        this.onWebUrlTap(seg.url)
                                    }
                                }
                            })
                    } else {
                        Span(seg.text)
                            .fontSize(if (seg.isCode || seg.isPre) { this.chatFont(14) } else { this.chatFont(15) })
                            .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                            .fontWeight(if (seg.isBold) { FontWeight.Bold } else { FontWeight.Normal })
                            .fontStyle(if (seg.isItalic) { FontStyle.Italic } else { FontStyle.Normal })
                            .decoration(decorationType: if (seg.isStrike) { TextDecorationType.LineThrough } else if (seg.isUnderline) { TextDecorationType.Underline } else { TextDecorationType.None })
                    }
                }, keyGenerator: { seg: TextSegment, idx: Int64 =>
                    this.textSegmentKey(seg, idx)
                })
            }
        }
        .padding(left: 12, right: 12, top: 8)
    }

    /**
     * 富文本段的 ForEach key 必须带上本条消息与段内容。
     *
     * 缺省 key 是 `idx_` + TextSegment.toString()（= "seg_<segIndex>"），与内容无关。
     * 本组件是 @Reusable：LazyForEach 把气泡复用给另一条消息时，只要两条消息的段数相同，
     * key 全部不变，ForEach 不重建 Span，气泡就停在上一条消息的正文（R3 C7：
     * Kevin O'Leary 帖子的气泡——反应/浏览量/时间都已换新——仍画着 BlackRock 帖子的正文，
     * 用户长按"看到的"BlackRock，菜单与转发却是气泡实际绑定的 Kevin O'Leary）。
     * 对齐 iOS ChatMessageTextBubbleContentNode：每次 asyncLayout 按当前 item.message
     * 重新生成 attributedText，节点复用不保留旧正文。
     */
    /** S7-111: message text sizes scale with the chat font size (16 = default/base). */
    private func chatFont(base: Int64): Int64 {
        let size = Int64(this.fontPresentation.chatFontSize)
        if (size <= 0) { return base }
        return (base * size + 8) / 16
    }

    private func textSegmentKey(seg: TextSegment, idx: Int64): String {
        let style = "${seg.isBold}${seg.isItalic}${seg.isCode}${seg.isPre}${seg.isStrike}${seg.isUnderline}" +
            "${seg.isUrl}${seg.isMention}${seg.isSpoiler}${seg.isBlockquote}"
        let revealed = seg.isSpoiler && this.isSpoilerRevealed(seg.segIndex)
        let emojiReady = seg.customEmojiId != 0 && hasInlineCustomEmoji(seg.customEmojiId)
        return "${this.message.id}_${idx}_${style}_${revealed}_${seg.customEmojiId}_${emojiReady}_${seg.url}_${this.fontPresentation.chatFontSize}_${seg.text}"
    }
    
    // ==================== P2-400: 内联翻译结果区（iOS 式内联进气泡，非独立全屏）====================

    /**
     * P2-400: 内联翻译结果构建器
     * 在原消息气泡下方追加翻译区块：
     *   - "Translating..." loading 行
     *   - 翻译错误提示
     *   - 译文文本（译文语言标签 + 内容）
     *   - Show Original / Show Translation 切换行
     *
     * 对应 iOS ChatTranslation inline bubble 渲染（在 ChatMessageBubbleItemNode 下方追加区块）
     */
    @Builder
    func inlineTranslationContent(isSent: Bool) {
        if (this.showTranslation) {
            // 分隔线
            Divider()
                .strokeWidth(1)
                .color(if (isSent) { 0x4499DD } else { 0xD8D8D8 })
                .width(100.percent)
                .margin(top: 4)

            Column {
                if (this.isTranslating) {
                    Row {
                        LoadingProgress()
                            .width(16)
                            .height(16)
                            .color(if (isSent) { 0xFFFFFF } else { 0x317AFF })
                        Text(" Translating...")
                            .fontSize(13)
                            .fontColor(if (isSent) { 0xFFFFFF } else { 0x8E8E93 })
                            .opacity(0.8)
                    }
                    .padding(left: 12, right: 12, top: 6, bottom: 4)
                } else if (this.translateError) {
                    Text("Translation failed. Tap Translate in menu to retry.")
                        .fontSize(13)
                        .fontColor(if (isSent) { 0xFFCCCC } else { 0xFF3B30 })
                        .padding(left: 12, right: 12, top: 6, bottom: 4)
                } else if (!this.showOriginal && this.translatedText.size > 0) {
                    // 译文标签（对应 iOS 内联翻译区域的语言标签）
                    Text(if (this.translateToLangName.size > 0) { this.translateToLangName } else { "Translation" })
                        .fontSize(11)
                        .fontColor(if (isSent) { 0xCCE8FF } else { 0x0088CC })
                        .padding(left: 12, right: 12, top: 6, bottom: 2)
                    // 译文内容
                    Text(this.translatedText)
                        .fontSize(16)
                        .fontColor(if (isSent) { 0xFFFFFF } else { 0x000000 })
                        .padding(left: 12, right: 12, bottom: 4)
                        .width(100.percent)
                        .lineHeight(22)
                    // Show Original 切换行（对应 iOS "Show Original" button）
                    Text(trSource("Show Original"))
                        .fontSize(13)
                        .fontColor(if (isSent) { 0xCCE8FF } else { 0x0088CC })
                        .padding(left: 12, right: 12, bottom: 6)
                        .onClick({ evt =>
                            this.onShowOriginalToggle(true)
                        })
                } else if (this.showOriginal) {
                    // 显示原文时（Show Translation 切换回）
                    Text("Show Translation")
                        .fontSize(13)
                        .fontColor(if (isSent) { 0xCCE8FF } else { 0x0088CC })
                        .padding(left: 12, right: 12, top: 6, bottom: 6)
                        .onClick({ evt =>
                            this.onShowOriginalToggle(false)
                        })
                }
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Start)
        }
    }

    // ==================== 主消息内容构建（供发送/接收共用）====================

    // ==================== P2-113: Service Message (centered gray pill) ====================

    /**
     * P2-113: 获取 service 消息展示文本
     * 优先用 serviceText（真实动作文本），fallback 到 content（genericHandler）
     */
    private func getServiceDisplayText(): String {
        if (this.message.serviceText.size > 0) { return this.message.serviceText }
        if (this.message.content.size > 0) { return this.message.content }
        return "Service message"
    }

    /**
     * P2-113: service/action 消息居中灰色胶囊渲染
     *
     * 对应 iOS: ChatMessageActionItemNode (居中灰色文本)
     *
     * 格式: 姓名 + 动作文本，居中显示，灰色圆角背景
     */
    @Builder
    func serviceMessageContent() {
        Column {
            Text(this.buildServiceText())
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .padding(left: 12, right: 12, top: 4, bottom: 4)
                .backgroundColor(0xB0B0B0)
                .borderRadius(12)
                .textAlign(TextAlign.Center)
            // S6-05：壁纸服务消息（iOS ChatMessageWallpaperBubbleContentNode）：文案下方 100×100 壁纸缩略图
            if (this.serviceWallpaperThumb.size > 0) {
                Image(this.serviceWallpaperThumb)
                    .width(100)
                    .height(100)
                    .borderRadius(12)
                    .objectFit(ImageFit.Cover)
                    .margin(top: 6)
            }
        }
        .width(100.percent)
        .alignItems(HorizontalAlign.Center)
        .padding(top: 4, bottom: 4)
    }

    private func buildServiceText(): String {
        let actionText = this.getServiceDisplayText()
        if (this.message.senderName.size > 0) {
            return "${this.message.senderName} ${actionText}"
        }
        return actionText
    }

    // ==================== P2-113: Unsupported message fallback ====================

    /**
     * P2-113: 未知/受限消息 fallback 气泡
     * 对应 iOS: unsupported / restricted message 显示 "This message is not supported..."
     */
    @Builder
    func unsupportedContent(isSent: Bool) {
        Row {
            Text("This message is not supported in this version of the app.")
                .fontSize(14)
                .fontColor(if (isSent) { 0xFFFFFF } else { 0x8E8E93 })
                .fontStyle(FontStyle.Italic)
                .opacity(0.8)
                .padding(left: 12, right: 12, top: 8, bottom: 4)
        }
    }

    // ==================== Phase T3: Call Message (centered card) ====================
    
    private func getCallIcon(): String {
        if (this.message.callReason == "missed") { return "📵" }
        if (this.message.isSent) { return "📱" }
        return "📱"
    }
    
    private func getCallColor(): Int64 {
        if (this.message.callReason == "missed") { return 0xFF3B30 }
        return 0x34C759
    }
    
    private func getCallLabel(): String {
        if (this.message.callReason == "missed") { return "Missed Call" }
        if (this.message.callReason == "busy") { return "Busy" }
        if (this.message.callReason == "disconnect") { return "Disconnected" }
        if (this.message.isSent) { return "Outgoing Call" }
        return "Incoming Call"
    }
    
    private func getCallDurationText(): String {
        if (this.message.callDuration <= 0) { return "" }
        let mins = Int64(this.message.callDuration / 60)
        let secs = Int64(this.message.callDuration % 60)
        let secStr = if (secs < 10) { "0${secs}" } else { "${secs}" }
        return "${mins}:${secStr}"
    }
    
    @Builder
    func callMessageContent() {
        Row {
            // Call icon
            Text(this.getCallIcon())
                .fontSize(18)
                .margin(right: 8)
            
            Column {
                // Call type label
                Text(this.getCallLabel())
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.getCallColor())
                
                // Duration + time
                Row {
                    if (this.getCallDurationText().size > 0) {
                        Text(this.getCallDurationText())
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .margin(right: 6)
                    }
                    Text(this.message.time)
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                }
                .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
        }
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .backgroundColor(0xF0F0F0)
        .borderRadius(16)
    }
    
    /**
     * diag-suite_settings_appearance-TC-0400.md round4 F-9: 回复预览块的 mainColor，按方向取
     * 不同来源（见 replyAuthorAccentColor / bubbleOutAccentTextColor 的类字段文档）。
     * 提成 private func 而非 @Builder 内 let——S-005/D-116 禁止 build()/@Builder 内声明局部变量。
     *
     * diag-suite_settings_appearance-TC-0401-round5.md F-P2c: 报告点名 voiceContent /
     * audioContent / documentContent 三个 @Builder 里五处播放/图标圆底的
     * `if (isSent) { 0x2873D4 } else { 0xE8F0FE }` 字面量（旧缺陷/新指纹，round4 F-6a 未覆盖）。
     * 这五处与回复块同源同形（同一对字面量、同一 mainColor@10%alpha 语义——对位源侧
     * ChatMessageReplyInfoNode.swift:254-261 mainColor + MessageInlineBlockBackgroundView.swift:
     * 30-46/73 backgroundAlpha 0.1），复用本函数而非另开 `@Prop quoteMainColor`：新增
     * `@Prop` 会强制 `components/MessageContextOverlay.cj` / `pages/SelectivePrivacySettingsPage.cj`
     * / `pages/AppearanceSettingsPage.cj` 三个不在本 feature allowlist 内的调用点全部改签名
     * （本 SDK `@Prop` 无默认值，S-141）。TC-0401 round6 复核后该判断不变：跨 allowlist 的级联仍在，
     * 六个入参维持 `@State`，主题回灌改由调用方的 D-160 挂载守卫承担（见类字段区的依赖披露）。
     */
    private func replyBlockMainColor(isSent: Bool): UInt32 {
        if (isSent) {
            return this.bubbleOutAccentTextColor
        }
        return this.replyAuthorAccentColor
    }

    /**
     * diag-suite_settings_appearance-TC-0400.md round6 F-1（TC-0402 round7 同根因）：回复块左侧
     * 竖色条的高度必须由**回复文本内容**推导，不能用 `.height(100.percent)`。百分比在祖先链
     * 无任一级声明确定高度时会回落到"父级可用高度"（滚动视口剩余高度），于是色条撑高 Row、
     * Row 撑高整张预览卡（实测色条 1561px vs 兄弟文本列 118px，约 13.2 倍）。
     *
     * 对位源侧：竖条不是独立布局节点——`MessageInlineBlockBackgroundView.swift:43-44` 把
     * lineWidth=3.0 的左条画进模板图的 size.height 全高，模板图再拉伸到
     * `ChatMessageReplyInfoNode.swift:901/922` 里由 titleLayout/textLayout 实测推导出的
     * `realSize → backgroundFrame`。即源侧"竖条高 = 块高 = 文本高"两条不变量恒成立。
     *
     * 常量来源（不是按表现反推的阈值）：两个 Text 都是 `.fontSize(11)`、replyToText 带
     * `.maxLines(1)`、replyToSenderName 单行 ⇒ 各占 1 行；round6 layout 实测这对 Text 各 45px、
     * 密度 3.5 ⇒ 每行 12.86vp，取整 13。尾部 +8 是兄弟 Column 自带的 `.padding(top: 4, bottom: 4)`
     * （源侧 backgroundFrame 同样含该内边距）。⇒ 有作者名 34vp（= 实测 118px ÷ 3.5）、无作者名 21vp。
     *
     * 形态对位：`webPreviewLineHeight()`（:1238）是同文件、同"左竖条 + 右文本列"版式、同"逐项
     * 累加行高"写法的既有正例，其调用点 :1176 `.height(this.webPreviewLineHeight())` 与本函数同型。
     */
    private func replyBlockLineHeight(): Int64 {
        var height: Int64 = 13
        if (this.message.replyToSenderName.size > 0) {
            height += 13
        }
        return height + 8
    }

    /**
     * 把 0-255 的 alpha 字节叠到一个不透明 0xRRGGBB 颜色上，产出 0xAARRGGBB。
     * D-175：顶字节为 0 会被 SDK 的 alphaAdapt 强制改写成 0xFF（强制不透明），
     * 所以 alpha 必须传非零值；本文件调用点（F-9 的 10%/28%，F-P2c 的五处 10%）都满足。
     */
    private func withAlpha(color: UInt32, alpha: UInt32): UInt32 {
        return (alpha << 24) | (color & 0x00FFFFFF)
    }

    /**
     * R1 C5/D5/D7：发出气泡内的次要前景色（edited/时间/状态勾、文件名/大小、文件图标、播放键、
     * 波形、时长）统一取主题色表 core/storage/AppTheme.cj#outgoingBubbleForegroundColors()，
     * 按本气泡实际填充色选表（对位源侧 chat.message.outgoing 的 secondaryTextColor /
     * fileTitleColor / fileDescriptionColor / fileDurationColor / mediaActiveControlColor /
     * mediaInactiveControlColor / pendingActivityColor 与 outgoingCheckColor）。此前这些位置写死
     * 白色，只在深色填充上可读，浅绿填充上对比度约 1.1:1。
     */
    private func outFg(): BubbleForegroundColors {
        return outgoingBubbleForegroundColors(this.bubbleOutColor)
    }

    @Builder
    func messageContent(isSent: Bool) {
        // 转发信息
        // ic_message_bubble_forward_name_link_slot: forwardNameLinkEnabled gates both the tap
        // handler and (per the contract's "accent color" requirement) is expressed with the same
        // if(isSent){white}else{accent-blue} literal this file already uses for every other
        // interactive/accent element (reply sender name, mentions, etc.) — the disabled branch is
        // this file's untouched pre-existing literal, so default-false call sites are unaffected.
        // C7（R1）：对位 iOS ChatMessageForwardInfoNode.asyncLayout —— 标题行
        // "Forwarded from"（Chat.MessageForwardInfo.MessageHeader，常规字重）+ 来源名一行
        // （peerString，medium 字重），字号 floor(17 × 14/17) = 14；颜色取主题
        // incoming/outgoing accentTextColor（与回复块同源的 replyBlockMainColor），不写死白色。
        if (this.message.forwardFromName.size > 0) {
            Column {
                Text(trSource("Forwarded from"))
                    .fontSize(14)
                    .fontColor(this.replyBlockMainColor(isSent))
                if (this.forwardNameLinkEnabled) {
                    Text(this.message.forwardFromName)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.replyBlockMainColor(isSent))
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .onClick({ _evt => this.onForwardNameTap() })
                } else {
                    Text(this.message.forwardFromName)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.replyBlockMainColor(isSent))
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                }
            }
            .alignItems(HorizontalAlign.Start)
            .padding(left: 12, right: 12, top: 6)
        }
        
        // 回复预览
        // diag-suite_settings_appearance-TC-0400.md round4 RC-4/F-9（回归：round2 曾修好，round3
        // F-1 换渲染器后丢失）：左侧竖色条 + 标题左对齐 + 底色/竖条/标题统一取 mainColor，
        // 不再是整块写死字面量。对位源侧 MessageInlineBlockBackgroundView.swift:12-13/38/43-44/73
        // （radius 4.0、左侧 lineWidth 3.0、整块 mainColor@0.1 打底、左侧再叠 mainColor@0.28）与
        // ChatMessageReplyInfoNode.swift:251-261（mainColor 取 peer authorNameColor，回落全局 accent）。
        if (this.message.replyToMsgId > 0) {
            Row {
                // 左侧竖色条（源侧 lineWidth=3.0），与文本列等高
                // TC-0400 round6 F-1：高度由内容推导（replyBlockLineHeight），不用 100.percent
                Column {}
                    .width(3)
                    .height(this.replyBlockLineHeight())
                    .backgroundColor(this.withAlpha(this.replyBlockMainColor(isSent), 0x47))
                Column {
                    if (this.message.replyToSenderName.size > 0) {
                        Text(this.message.replyToSenderName)
                            .fontSize(11)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(this.replyBlockMainColor(isSent))
                    }
                    Text(if (this.message.replyToText.size > 0) { this.message.replyToText } else { "..." })
                        .fontSize(11)
                        .fontColor(if (isSent) { 0xFFFFFF } else { 0x666666 })
                        .opacity(if (isSent) { 0.8 } else { 1.0 })
                        .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .padding(left: 8, right: 8, top: 4, bottom: 4)
            }
            .alignItems(VerticalAlign.Top)
            .margin(left: 12, right: 12, top: 6)
            .backgroundColor(this.withAlpha(this.replyBlockMainColor(isSent), 0x1A))
            .borderRadius(4)
            .onClick({ evt =>
                // Phase P6-4: 点击回复引用 → 跳转到原消息
                this.onReplyTap(this.message.replyToMsgId)
            })
        }
        
        // 发送者名称 —— 仅群/频道的入向消息、且为聚簇首条时显示。
        // 对齐 iOS displayAuthorInfo = !mergedTop.merged && incoming && peerId.isGroupOrChannel
        // （ChatMessageBubbleItemNode.swift:1686/1692）。此前漏了会话类型这一项，
        // 私聊里对方每条消息上面都会多顶一行名字。
        // 颜色也改为按 peer 派生（iOS authorNameColor 用同一套 7 色板），不再固定蓝。
        if (!isSent && this.isGroupOrChannel() && this.message.senderName.size > 0 &&
            (this.message.isFirstInGroup || this.message.isSingleMessage)) {
            Row {
                Text(this.message.senderName)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(avatarPaletteColor(avatarColorIndex(this.message.senderId)))
                    .maxLines(1)
                if (this.message.senderRole.size > 0) {
                    Text(this.message.senderRole)
                        .fontSize(11)
                        .fontColor(0x7A7A7A)
                        .maxLines(1)
                        .margin(left: 8)
                }
            }
            .padding(left: 12, right: 12, top: 6)
        }
        
        // ==================== 媒体内容路由 ====================
        if (this.message.messageType == "photo") {
            photoContent(isSent)
        }
        if (this.message.messageType == "video") {
            videoContent(isSent)
        }
        if (this.message.messageType == "video_note") {
            videoNoteContent(isSent)
        }
        if (this.message.messageType == "voice") {
            voiceContent(isSent)
        }
        if (this.message.messageType == "audio") {
            audioContent(isSent)
        }
        if (this.message.messageType == "document") {
            documentContent(isSent)
        }
        if (this.message.messageType == "sticker") {
            stickerContent(isSent)
        }
        if (this.message.messageType == "gif") {
            gifContent(isSent)
        }
        if (this.message.messageType == "location") {
            locationContent(isSent)
        }
        if (this.message.messageType == "contact") {
            contactContent(isSent)
        }
        if (this.message.messageType == "poll") {
            pollContent(isSent)
        }
        if (this.message.messageType == "invoice") {
            invoiceContent(isSent)
        }
        
        // P2-113: 未知/不受支持的媒体类型
        // 对应 iOS: unsupported message → show "This message is not supported in this version"
        if (this.message.messageType != "text" && this.message.messageType != "photo" && this.message.messageType != "video" && this.message.messageType != "video_note" && this.message.messageType != "voice" && this.message.messageType != "audio" && this.message.messageType != "document" && this.message.messageType != "sticker" && this.message.messageType != "gif" && this.message.messageType != "location" && this.message.messageType != "contact" && this.message.messageType != "poll" && this.message.messageType != "invoice" && this.message.messageType != "webpage" && this.message.messageType != "phone_call" && this.message.messageType != "service") {
            if (this.message.mediaDescription.size > 0) {
                // Known but unsupported: show media description
                Text(this.message.mediaDescription)
                    .fontSize(14)
                    .fontColor(if (isSent) { 0xFFFFFF } else { 0x317AFF })
                    .opacity(0.9)
                    .padding(left: 12, right: 12, top: 8)
            } else if (this.message.content.size == 0) {
                // Truly unknown with no content: show unsupported notice
                unsupportedContent(isSent)
            }
        }
        
        // 消息文本（照片消息带文字说明时也显示）
        // Phase Q11: 富文本渲染 — 有实体时用 Text+Span，否则纯文本
        if (this.message.content.size > 0 && this.message.content != this.message.mediaDescription && this.message.messageType != "contact") {
            if (this.isAnimatedEmojiMessage()) {
                // 大表情同样走 ChatMessageAnimatedStickerItemNode，时间+状态是挂在
                // 动画节点右下角的独立胶囊，而不是气泡底栏。
                Stack(alignContent: Alignment.BottomEnd) {
                    if (this.message.status == "sending") {
                        // Do not mount the loader until sendMessage releases the
                        // shared MTProto client. The send worker preloads Lottie
                        // frames before publishing the final sent-state bubble.
                        // A transparent fixed-size placeholder is intentional:
                        // showing Text(content) here flashes the system Emoji glyph
                        // before the server acknowledgement and Lottie preload.
                        Column {}
                            .width(112)
                            .height(112)
                    } else {
                        // iOS ChatMessageAnimatedStickerItemNode uses one
                        // TapLongTapOrDoubleTapGestureRecognizer for both replay and
                        // context-menu opening. Keep both branches on the animation
                        // component's stable root Stack as well, instead of splitting
                        // click and long press across a child/ancestor hit-test chain.
                        AnimatedEmojiComponent(
                            emoji: this.message.content,
                            displaySize: 112.0,
                            onTap: { emoji: String =>
                                this.onAnimatedEmojiTap(this.message, emoji)
                            },
                            // The message-row recognizer owns context presentation for every
                            // content type; nested native menus would race the page overlay.
                            menuEnabled: false
                        )
                    }
                    freeDateAndStatusOverlay(isSent)
                }
                .width(112)
                .height(112)
            } else if (this.isLargeEmojiMessage()) {
                // 2~3 个 emoji：iOS 不走动画节点，把 emojiFile 置空、只留一行大号文字
                // （ChatMessageAnimatedStickerItemNode.swift:503-523 / :1073），字号由
                // fontSizeForEmojiString 给：2 个 78、3 个 64。
                //
                // 那行文字在 iOS 上就是 Apple 的表情字形，鸿蒙的系统字形跟它差得很远。
                // 系统里没有、也不能内置 Apple 表情字体，所以逐个簇改用 Telegram 自带
                // 动画表情包的素材（美术风格本就对齐 Apple），并停在第一帧保持 iOS 的静态观感。
                // 时间胶囊挂在整块**下方**、右缘内缩 4，而不是像贴纸那样压在内容上：
                // iOS 给这条路径留了 imageTopPadding 16 / imageBottomPadding 20（:1049-1052），
                // 胶囊落在 imageFrame.maxY - 高 - 4 + 20（:1722）。
                Column {
                    // 那行文字的换行宽度是 maximumContentWidth（气泡最大宽度减去各层
                    // 内边距，:1071），行数不限（maximumNumberOfLines: 0）。
                    Flex(wrap: FlexWrap.Wrap) {
                        ForEach(
                            splitEmojiClusters(this.message.content),
                            itemGenerator: { cluster: String, _idx: Int64 =>
                                LargeEmojiGlyph(
                                    emoji: cluster,
                                    displaySize: this.largeEmojiDisplaySize(),
                                    advanceWidth: this.largeEmojiAdvance(),
                                    fallbackFontSize: this.largeEmojiFontSize()
                                )
                            }
                        )
                    }
                    .width(this.largeEmojiBlockWidth())
                    freeDateAndStatusOverlay(isSent)
                }
                .alignItems(HorizontalAlign.End)
                .padding(left: 4, right: 4, top: 16, bottom: 4)
            } else if (this.searchHighlightActive()) {
                searchHighlightedTextContent(isSent)
            } else if (this.hasRichTextEntities()) {
                richTextContent(isSent)
            } else {
                Text(this.message.content)
                    .fontSize(this.chatFont(15))
                    .fontColor(if (isSent) { this.bubbleOutTextColor } else { this.bubbleInTextColor })
                    .padding(left: 10, right: 10, top: 7)
            }
        }

        // Phase Q5: 网页预览（在消息文本之后、底部之前）
        if (this.message.webPageTitle.size > 0 || this.message.webPageDescription.size > 0) {
            webPreviewContent(isSent)
        }

        // iOS: 文本/带caption媒体的反应在气泡内（文本节点自带 statusNode），位于 caption 之后、
        // metadata 之前；纯媒体（isBubblelessMedia）的反应改由 build() 在气泡下方独立渲染，故此处门控。
        if (!this.isBubblelessMedia() && !this.message.reactions.isEmpty()) {
            ForEach(this.reactionSubtreeKeys(), itemGenerator: { _reactionVersion: String, _reactionVersionIndex: Int64 =>
                MessageReactions(
                    reactions: this.message.reactions,
                    isSent: isSent,
                    messageId: this.message.id,
                    onReactionTap: { emoji: String =>
                        this.onReactionTap(emoji)
                    },
                    onReactionCountTap: { msgId: Int64 =>
                        this.onReactionCountTap(msgId)
                    },
                    onAddReaction: { =>
                        this.requestContextOverlay()
                    }
                )
            }, keyGenerator: { reactionVersion: String, _reactionVersionKeyIndex: Int64 =>
                reactionVersion
            })
        }
        
        // 底部信息栏
        //
        // iOS 里**每条气泡都带自己的时间+状态**：合并（mergedTop/mergedBottom）只决定
        // 圆角、间距与作者头部，不影响 dateAndStatusNode 的显隐 —— 显隐由内容块是否为
        // 气泡内最后一块决定（ChatMessageTextBubbleContentNode.swift:314-351，
        // 单条文本消息只有一个内容块，恒为最后一块 → 恒显示）。
        // 此前这里按 isLastInGroup/isSingleMessage 门控，导致连发多条时只有最后一条有时间。
        //
        // 分流：纯媒体走图上暗色 scrim（mediaTimestampOverlay），
        // 贴纸/大表情走 service 配色胶囊（freeDateAndStatusOverlay），两者都不走此底栏。
        if (!this.usesFloatingDateAndStatus()) {
            Row {
                if (this.message.isEdited) {
                    // 源侧 "edited" 与时间同一串、同一 dateColor（outgoing.secondaryTextColor，
                    // ChatMessageDateAndStatusNode.swift:428-429）。
                    Text(trSource("edited"))
                        .fontSize(11)
                        .fontColor(if (isSent) { this.outFg().secondaryTextColor } else { 0x999999 })
                        .margin(right: 4)
                }
                // 浏览数只在频道语境有意义 —— iOS 的 impressionCount 来自频道帖子的
                // views 属性，普通群/私聊不带。此前对所有入向消息都画，群聊里会凭空多出计数。
                if (this.peerType == "channel" && this.message.views > 0) {
                    Text("◉ ${this.compactViewCount()} ")
                        .fontSize(11)
                        .fontColor(0x999999)
                }
                // diag-suite_settings_appearance-TC-0400.md round4 RC-6/F-10: 时间戳与状态勾
                // 必须同源取主题色，不再各自写死近似字面量（R1 C5 起取 outFg() 色表）。
                // R1 C5：源侧 .BubbleOutgoing 的 dateColor 是 outgoing.secondaryTextColor
                // （ChatMessageDateAndStatusNode.swift:428-429），与 "edited" 同色。
                Text(this.message.time)
                    .fontSize(11)
                    .fontColor(if (isSent) { this.outFg().secondaryTextColor } else { 0x999999 })
                // P2-118: 发送状态图标 — 对应 iOS 三态:
                //   sending → 时钟图标(用省略号占位)
                //   sent(已发未读) → 灰色单勾（真实矢量，还原 iOS generateCheckImage 的程序化勾形路径）
                //   read(对方已读) → 蓝色双勾（两个单勾图标水平重叠偏移，还原 iOS checkSentNode+checkReadNode 叠加绘制方式）
                // 资源保真修复：真实矢量图标（还原 PresentationThemeEssentialGraphics.swift generateCheckImage
                // 的精确 drawSvgPath 坐标：M0,4 L2.95157047,6.95157047 C... L9.5,0）替代 emoji 字形
                // iOS .Failed 时 statusWidth = 0：胶囊内不画任何图标，
                // 重发入口是气泡外的 ChatMessageDeliveryFailedNode（见 deliveryFailedIndicator）。
                if (isSent && this.message.status != "failed") {
                    if (this.message.status == "sending") {
                        // iOS .Sending 画的是时钟（clockBubbleOutgoingFrameImage /
                        // clockFreeFrameImage，ChatMessageDateAndStatusNode.swift:606-638），
                        // 此前用 " ..." 文本占位。
                        // 源侧 clockBubbleOutgoing* 取 outgoing.pendingActivityColor。
                        Image(@r(app.media.loc_ic_clock))
                            .width(11)
                            .height(11)
                            .fillColor(this.outFg().pendingActivityColor)
                            .margin(left: 4)
                    } else if (this.message.status == "read") {
                        // Stack + position 还原 iOS checkSentNode/checkReadNode 水平偏移叠加绘制（D-Stack 层叠布局定位法，本文件既有 position(x,y) 先例）
                        // RC-6/F-10: 已读双勾取源侧 outgoingCheckColor（outFg().checkColor）
                        Stack() {
                            Image(@r(app.media.chatroom_ic_check))
                                .width(11)
                                .height(9)
                                .fillColor(this.outFg().checkColor)
                                .position(x: 0, y: 0)
                            Image(@r(app.media.chatroom_ic_check))
                                .width(11)
                                .height(9)
                                .fillColor(this.outFg().checkColor)
                                .position(x: 4, y: 0)
                        }
                        .width(15)
                        .height(9)
                        .margin(left: 4)
                    } else {
                        // "sent" — 单勾，灰色（已发未读）
                        // 源侧 chatOutgoingFullCheck 取 outgoingCheckColor。
                        Image(@r(app.media.chatroom_ic_check))
                            .width(11)
                            .height(9)
                            .fillColor(this.outFg().checkColor)
                            .margin(left: 4)
                    }
                }
            }
            .padding(left: 12, right: 12, top: 2, bottom: 8)
            .justifyContent(FlexAlign.End)
        }
        
        // P2-400: 内联翻译结果区（iOS 式内联进气泡，非独立全屏页）
        inlineTranslationContent(isSent)

    }
    
    // ==================== Phase P6-3: 分组辅助方法 ====================

    /**
     * P2-340: 从 ThemesEngineService 读取主角半径（用户设置值，默认 16vp）。
     * round7 F-C: overrideMainRadius 哨兵（-1 = 无覆盖）>= 0 时优先用它，否则维持原有的
     * service 读取——这是唯一的行为分叉点，其余调用点（allowlist 内外）零改动。
     */
    private func getBubbleMainRadius(): Int64 {
        if (this.overrideMainRadius >= 0) {
            return Int64(this.overrideMainRadius)
        }
        return Int64(getThemesEngineService().getBubbleMainRadius())
    }

    /**
     * P2-340: 从 ThemesEngineService 读取辅助角半径（分组内侧，默认 8vp）
     * 合并角关闭时，内侧角与主角半径相同（不缩小）。
     * round7 F-C: 同上，overrideAuxRadius 哨兵 >= 0 时优先用它；mergeCorners 本身仍只读持久层
     * （不属于本轮入参化范围）。
     */
    private func getBubbleAuxRadius(): Int64 {
        let svc = getThemesEngineService()
        // TC-0407 F-2: mirrors PresentationThemeEssentialGraphics.swift:271
        // (mergeBubbleCorners && maxCornerRadius >= 10.0) ? auxiliaryRadius : mainRadius. Below the
        // 10vp main-radius threshold the source always uses the main radius for the inner corner
        // regardless of the merge-corners setting; this gate is currently a no-op only because
        // BubbleSettingsPage.commit() happens to clamp aux <= main, and must land in the same batch
        // as any change that derives aux independently (e.g. main/2), or C2 tail corners regress.
        // Gate unchanged (mergeCorners && main >= 10); only the main-radius value it reads now goes
        // through getBubbleMainRadius() so the gate itself respects the sentinel override too.
        let mainR = this.getBubbleMainRadius()
        if (!svc.getBubbleMergeCorners() || mainR < 10) {
            return mainR
        }
        if (this.overrideAuxRadius >= 0) {
            return Int64(this.overrideAuxRadius)
        }
        return Int64(svc.getBubbleAuxRadius())
    }

    // round7 F-C (D-125 镜像字段模式，参见 dev_pattern.md D-125"修复策略")：mainRadius/auxRadius
    // 传给 MessageBubbleShape 时必须是裸 @State 字段读取才能建立父→子活通道；getBubbleMainRadius()/
    // getBubbleAuxRadius() 是函数调用，通道对它们不成立。这两个 Float64 镜像字段就是"declare the
    // field itself as Float64"那句要的字段：每次 build() 经由 refreshRenderRadii() 的零高度探针
    // 刷新一次，随后在两个 MessageBubbleShape 调用点以 this.renderMainRadius / this.renderAuxRadius
    // 裸字段形式传入。
    @State var renderMainRadius: Float64 = 16.0
    @State var renderAuxRadius: Float64 = 8.0

    // TC-0407 round2 F-1：同一 D-125 镜像字段模式扩到 hasTail 与四个分组标志。这五项此前以
    // this.hasBubbleTail() 函数调用 / this.message.<字段> 嵌套字段访问的形式传给
    // MessageBubbleShape，两种写法都不建立父→子活通道；MessageBubble 是全仓唯一的
    // @Reusable 组件，子节点（MessageBubbleShape）不随复用整体重新求值，于是这五项在复用后
    // 停留在上一条消息的取值上，与 mainRadius/auxRadius 在 round7 F-C 之前的病灶同源。
    @State var shapeHasTail: Bool = false
    @State var shapeIsMiddleInGroup: Bool = false
    @State var shapeIsFirstInGroup: Bool = false
    @State var shapeIsLastInGroup: Bool = false
    @State var shapeIsSingleMessage: Bool = false

    // R3 C3：日期胶囊文字同样必须走裸 @State 镜像。此前以
    // `MessageDateHeader(dateText: this.message.dateSeparatorText)` 嵌套字段形式传给子组件
    // 的 @Prop，与上面五项同病：不建立父→子活通道，复用后胶囊停留在**上一条消息**的日期上。
    // 首屏 local-first 的旧缓存行（6 月 / 9 月）进复用池后被今天的消息复用，于是
    // 「Today」下面冒出「June 24」、再往上「September 14」「June 19」——列表本身按
    // (timestamp, namespace, id) 有序，乱的是胶囊文字。iOS ChatMessageDateHeader 每个
    // 日期头节点由它所在的 item 现算（ChatMessageDateHeader.swift），不存在跨条目残留。
    @State var dateHeaderText: String = ""

    /**
     * 零高度探针消费的返回值：把当前半径（含哨兵覆盖）、尾巴与四个分组标志
     * 一并镜像进裸 @State 字段（D-125 正例同型）。两个调用点各自的零高度 Text 探针
     * 共用这一个函数，与半径此前的做法一致——同一轮 build() 里只需要在
     * MessageBubbleShape 构造之前跑一次。
     */
    private func refreshRenderRadii(): String {
        this.renderMainRadius = Float64(this.getBubbleMainRadius())
        this.renderAuxRadius = Float64(this.getBubbleAuxRadius())
        this.shapeHasTail = this.hasBubbleTail()
        this.shapeIsMiddleInGroup = this.message.isMiddleInGroup
        this.shapeIsFirstInGroup = this.message.isFirstInGroup
        this.shapeIsLastInGroup = this.message.isLastInGroup
        this.shapeIsSingleMessage = this.message.isSingleMessage
        return ""
    }

    /** Telegram-iOS MessageBubbleImageNeighbors 的逐角半径映射。 */
    private func getBubbleBorderRadiuses(isSent: Bool): BorderRadiuses {
        let mainR = Float64(this.getBubbleMainRadius())
        let auxR  = Float64(this.getBubbleAuxRadius())

        if (this.message.isSingleMessage) {
            return BorderRadiuses(topLeft: mainR, topRight: mainR, bottomLeft: mainR, bottomRight: mainR)
        }
        if (this.message.isMiddleInGroup) {
            if (isSent) {
                return BorderRadiuses(topLeft: mainR, topRight: auxR, bottomLeft: mainR, bottomRight: auxR)
            } else {
                return BorderRadiuses(topLeft: auxR, topRight: mainR, bottomLeft: auxR, bottomRight: mainR)
            }
        }
        if (this.message.isFirstInGroup) {
            // first: 顶部两角大，底部仅"对面"角大（尾部方向角缩小）
            if (isSent) {
                // outgoing: 尾巴在右→ bottomRight 小
                return BorderRadiuses(topLeft: mainR, topRight: mainR, bottomLeft: mainR, bottomRight: auxR)
            } else {
                // incoming: 尾巴在左→ bottomLeft 小
                return BorderRadiuses(topLeft: mainR, topRight: mainR, bottomLeft: auxR, bottomRight: mainR)
            }
        }
        // .bottom: 靠消息边的上角缩小，底部恢复主半径并绘制尾巴。
        if (isSent) {
            return BorderRadiuses(topLeft: mainR, topRight: auxR, bottomLeft: mainR, bottomRight: mainR)
        } else {
            return BorderRadiuses(topLeft: auxR, topRight: mainR, bottomLeft: mainR, bottomRight: mainR)
        }
    }

    private func hasBubbleTail(): Bool {
        // iOS：气泡带 reactions 时把 bottomNodeMergeStatus 强制成 .Left/.Right
        // （ChatMessageBubbleItemNode.swift:2310-2315），而尾巴只在
        // .None(.Incoming/.Outgoing) 时画（:3300-3321）—— 即有反应就没有尾巴。
        // 反应画在气泡内时才适用；纯媒体的反应在气泡外独立行，不影响尾巴。
        if (!this.usesFloatingDateAndStatus() && !this.message.reactions.isEmpty()) {
            return false
        }
        return this.message.isLastInGroup || this.message.isSingleMessage
    }

    /**
     * 纯媒体消息的反应行 —— 渲染在气泡（图片）下方，对齐 iOS 外部 ChatMessageReactionButtonsNode
     * （backgroundFrame.maxY+4）。发送态右对齐、接收态左对齐由 MessageReactions 内部按 isSent 处理。
     */
    @Builder
    func reactionsRow(isSent: Bool) {
        if (!this.message.reactions.isEmpty()) {
            ForEach(this.reactionSubtreeKeys(), itemGenerator: { _reactionVersion: String, _reactionVersionIndex: Int64 =>
                MessageReactions(
                    reactions: this.message.reactions,
                    isSent: isSent,
                    messageId: this.message.id,
                    onReactionTap: { emoji: String =>
                        this.onReactionTap(emoji)
                    },
                    onReactionCountTap: { msgId: Int64 =>
                        this.onReactionCountTap(msgId)
                    },
                    onAddReaction: { =>
                        this.requestContextOverlay()
                    }
                )
            }, keyGenerator: { reactionVersion: String, _reactionVersionKeyIndex: Int64 =>
                reactionVersion
            })
        }
    }

    /**
     * 纯媒体消息的时间戳浮层 —— overlay 到图片右下角，暗色半透明圆角 scrim + 白字。
     * 对齐 iOS 媒体节点 dateAndStatusNode 的 .ImageIncoming/.ImageOutgoing 类型
     * （ChatMessageDateAndStatusNode.swift:449-473 暗色 scrim 药丸 + 高对比白字）。
     */
    @Builder
    func mediaTimestampOverlay(isSent: Bool) {
        Row {
            if (this.message.isEdited) {
                Text(trSource("edited"))
                    .fontSize(11)
                    .fontColor(0xFFFFFF)
                    .opacity(0.9)
                    .margin(right: 4)
            }
            Text(this.message.time)
                .fontSize(11)
                .fontColor(0xFFFFFF)
            if (isSent && this.message.status != "failed") {
                if (this.message.status == "sending") {
                    Image(@r(app.media.loc_ic_clock))
                        .width(11)
                        .height(11)
                        .fillColor(0xFFFFFF)
                        .opacity(0.7)
                        .margin(left: 4)
                } else if (this.message.status == "read") {
                    Stack() {
                        Image(@r(app.media.chatroom_ic_check))
                            .width(11)
                            .height(9)
                            .fillColor(0xFFFFFF)
                            .position(x: 0, y: 0)
                        Image(@r(app.media.chatroom_ic_check))
                            .width(11)
                            .height(9)
                            .fillColor(0xFFFFFF)
                            .position(x: 4, y: 0)
                    }
                    .width(15)
                    .height(9)
                    .margin(left: 4)
                } else {
                    Image(@r(app.media.chatroom_ic_check))
                        .width(11)
                        .height(9)
                        .fillColor(0xFFFFFF)
                        .opacity(0.9)
                        .margin(left: 4)
                }
            }
        }
        .padding(left: 6, right: 6, top: 3, bottom: 3)
        .backgroundColor(0x59000000)
        .borderRadius(10)
        .margin(right: 8, bottom: 8)
    }

    /**
     * 发送失败指示器 —— 对应 iOS ChatMessageDeliveryFailedNode
     * （ChatMessageBubbleItemNode.swift:3901-3918）。
     *
     * iOS 把它画在**气泡外侧**、并为此加宽布局内缩（:1953-1958），
     * 同时让状态胶囊里不再出现任何图标（statusWidth = 0，:682-688）。
     * 我们此前是在胶囊里塞一个红色 "!"，既不显眼也没有操作入口。
     * 点击走消息上下文菜单（删除/重发在那里）。
     */
    @Builder
    func deliveryFailedIndicator() {
        Stack(alignContent: Alignment.Center) {
            Text("!")
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFFFFFF)
        }
        .width(22)
        .height(22)
        .backgroundColor(0xFFFF3B30)
        .borderRadius(11)
        .margin(right: 6)
        .onClick({ _evt =>
            this.requestContextOverlay()
        })
    }

    /**
     * 贴纸 / 动画表情的时间+状态浮层 —— 对应 iOS ChatMessageDateAndStatusNode 的
     * .FreeIncoming / .FreeOutgoing 形态（ChatMessageAnimatedStickerItemNode.swift:1115-1125）。
     *
     * 与 mediaTimestampOverlay（图片/视频用的暗色 scrim，对应 iOS .Image* 形态）不同：
     * 贴纸没有底图可压暗，iOS 用的是 service-message 配色的毛玻璃胶囊
     * （selectDateFillStaticColor：内置壁纸下 #748391 @45%，文字取 serviceColor.primaryText 白）。
     * 尺寸取自 ChatMessageDateAndStatusNode.swift:710 的 backgroundInsets(2,7,2,7)
     * 与 :548 的字号 floor(17 * 11/17) = 11，圆角为 height/2（:1079 胶囊）。
     */
    @Builder
    func freeDateAndStatusOverlay(isSent: Bool) {
        Row {
            if (this.message.isEdited) {
                Text(trSource("edited"))
                    .fontSize(11)
                    .fontColor(0xFFFFFF)
                    .opacity(0.9)
                    .margin(right: 4)
            }
            Text(this.message.time)
                .fontSize(11)
                .fontColor(0xFFFFFF)
            if (isSent && this.message.status != "failed") {
                if (this.message.status == "sending") {
                    Image(@r(app.media.loc_ic_clock))
                        .width(11)
                        .height(11)
                        .fillColor(0xFFFFFF)
                        .opacity(0.7)
                        .margin(left: 4)
                } else if (this.message.status == "read") {
                    // iOS checkSentNode + checkReadNode 水平错开叠加（checkOffset = floor(17*6/17)）
                    Stack() {
                        Image(@r(app.media.chatroom_ic_check))
                            .width(11)
                            .height(9)
                            .fillColor(0xFFFFFF)
                            .position(x: 0, y: 0)
                        Image(@r(app.media.chatroom_ic_check))
                            .width(11)
                            .height(9)
                            .fillColor(0xFFFFFF)
                            .position(x: 4, y: 0)
                    }
                    .width(15)
                    .height(9)
                    .margin(left: 4)
                } else {
                    Image(@r(app.media.chatroom_ic_check))
                        .width(11)
                        .height(9)
                        .fillColor(0xFFFFFF)
                        .opacity(0.9)
                        .margin(left: 4)
                }
            }
        }
        .padding(left: 7, right: 7, top: 2, bottom: 2)
        .backgroundColor(0x73748391)
        .borderRadius(10)
        // iOS 把胶囊锚在贴纸帧右下各内缩 4pt（ChatMessageAnimatedStickerItemNode.swift:1722）
        .margin(right: 4, bottom: 4)
    }

    private func compactViewCount(): String {
        let views = this.message.views
        if (views >= 1000000) {
            let tenths = (views + 50000) / 100000
            return "${tenths / 10}.${tenths % 10}M"
        }
        if (views >= 1000) {
            let tenths = (views + 50) / 100
            return "${tenths / 10}.${tenths % 10}K"
        }
        return "${views}"
    }

    /**
     * 根据分组位置返回消息上方间距
     * - 同组内消息: 1vp（极小间距）
     * - 不同组/首条: 4vp（正常间距）
     * - 有日期分隔线: 0vp（日期线自带间距）
     */
    private func getGroupTopPadding(): Int64 {
        if (this.message.showDateSeparator) { return 0 }
        if (this.message.isFirstInGroup || this.message.isSingleMessage) { return 4 }
        return 1
    }
    
    private func getGroupBottomPadding(): Int64 {
        if (this.message.isLastInGroup || this.message.isSingleMessage) { return 4 }
        return 1
    }

    /**
     * Reaction 子树的内容版本。
     *
     * iOS 保持 ChatMessageItemView / reactionButtonsNode 身份稳定，并在每次
     * updateNode 的 apply 阶段把最新 ReactionsMessageAttribute 装入已有节点。
     * 当前仓颉 SDK 对嵌套组件的 ArrayList<ReactionData> 构造参数不会可靠地
     * 原位同步，因此用单元素 ForEach 把内容变化限定为只替换 reaction 子树；
     * 外层 MessageBubble 的 stableId 和复用实例保持不变。
     */
    private func reactionSubtreeKeys(): Array<String> {
        var key = this.message.id.toString()
        for (reaction in this.message.reactions) {
            key = key + "|" + reaction.emoji + ":" + reaction.count.toString() +
                ":" + reaction.isSelected.toString()
            for (peerId in reaction.peerIds) { key = key + ":p" + peerId.toString() }
            for (path in reaction.peerAvatarPaths) { key = key + ":a" + path }
            for (initials in reaction.peerInitialsList) { key = key + ":i" + initials }
        }
        return [key]
    }
    
    // ==================== 主 build ====================
    
    /**
     * 复用装载 —— 对齐 iOS ChatListItemNode.setupItem(item:)（ChatListItem.swift:572 updateNode 内调用）。
     *
     * 框架只把新的构造参数放进 params，**必须由组件自己取出赋值**
     * （《自定义组件生命周期》：「将组件的构造参数传递给 aboutToReuse」）。
     * 签名以本机 SDK 为准：`protected open func aboutToReuse(params: ReuseParams)`，
     * `ReuseParams` 只有 `init(arr)` 与 `get<T>(key): ?T`（文档写的 prop size / contains 本 SDK 没有）。
     *
     * ⚠️ 41 个构造参数**一个都不能漏**（round7 F-C 前为 38；本轮新增 overrideMainRadius/
     * overrideAuxRadius 两个半径哨兵入参）：漏掉回调闭包，复用后的气泡点"删除"会作用到
     * **另一条消息** —— 静默且比闪严重得多。下面按声明顺序逐条对应，改字段时同步改这里。
     */
    protected override func aboutToAppear(): Unit {
        chatOpenPerfBubbleAppeared(this.message.id)
        this.dateHeaderText = this.message.dateSeparatorText
        this.prefetchInlineCustomEmoji()
        this.resolveServiceWallpaperThumb()
    }

    /**
     * S6-05：壁纸服务消息的缩略图。先查 WallpaperResourcesService 的 "m" 缩略图缓存
     * （同一份 key：deriveWallpaperThumbCacheKey(id, access_hash)），未命中则按 slug
     * account.getWallPaper → downloadWallpaperThumb，回到 UI 线程填入 @State。
     */
    private func resolveServiceWallpaperThumb(): Unit {
        if (this.message.messageType != "service" || this.message.serviceWallpaperSlug.size == 0) {
            this.serviceWallpaperThumb = ""
            return
        }
        let resSvc = getWallpaperResourcesService()
        let cached = resSvc.getCachedLocalPathNonEmpty(
            resSvc.deriveWallpaperThumbCacheKey(this.message.serviceWallpaperId, this.message.serviceWallpaperAccessHash))
        if (cached.size > 0) {
            this.serviceWallpaperThumb = if (cached.startsWith("file://")) { cached } else { "file://" + cached }
            return
        }
        let slug = this.message.serviceWallpaperSlug
        let msgId = this.message.id
        spawn {
            try {
                let item = resSvc.getWallPaper(slug)
                let uri = resSvc.downloadWallpaperThumb(item)
                launch {
                    if (uri.size > 0 && this.message.id == msgId) {
                        this.serviceWallpaperThumb = if (uri.startsWith("file://")) { uri } else { "file://" + uri }
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[MessageBubble] service wallpaper thumb error: ${e}")
            }
        }
    }

    protected override func aboutToReuse(params: ReuseParams) {
        // ① 先清掉上一条消息遗留的交互态，避免串到新消息。
        //    放在 aboutToReuse 而非 aboutToRecycle：回收过程中写 @State 的行为未经实测验证，
        //    此处等效且更安全（组件在缓存里不渲染，早清晚清没有区别）。
        //    ⚠️ 动画字段 livePinPulseScale/Alpha 由定时器驱动，不清。
        this.showFullImage = false
        this.saveStatus = ""
        this.locationSnapshotPath = ""
        this.serviceWallpaperThumb = ""
        this.resolveServiceWallpaperThumb()
        this.revealedSpoilers = ArrayList<Int64>()
        this.mediaPressGeneration = 0
        this.mediaPressActive = false
        this.mediaTapEligible = false
        this.lastMessageTapTimestamp = 0
        this.suppressNextMediaTap = false
        this.mediaTouchStartX = 0.0
        this.mediaTouchStartY = 0.0
        this.swipeReplyOffset = 0.0
        this.swipeReplyActive = false
        this.swipeReplyRejected = false
        this.swipeReplyHapticPlayed = false

        // ⚠️ bubbleCanvasWidth / bubbleCanvasHeight **不要在这里动**（既不清零也不还原初值）。
        //
        // 它们的测量源已改为「内容 Column」而非 Stack（见 build() 里两处
        // `★ 测量源必须是内容` 的说明），因此：
        //   · 复用后内容尺寸变了 → 内容 Column 的 onAreaChange 触发 → 自动写回新尺寸
        //   · 复用后内容尺寸没变 → 不触发，而此时**旧值恰好就是正确值**
        // 两种情况都不需要人工干预。
        //
        // 曾经两次在此处翻车，方向相反，根因同一个（当时测量源还是 Stack，构成反馈环）：
        //   · 保留旧值 H1 → Canvas 撑住 Stack → 尺寸不变 → 不触发 → 正文上方留白
        //   · 还原成 1.0 → Canvas 缩到 1×1，但内容尺寸没变 → Stack 尺寸仍不变 → 不触发
        //     → 卡在 1×1 → **发消息时气泡整个消失**
        // 《组件区域变化事件》原文：「仅会响应由布局变化所导致的组件大小、位置发生变化时的回调」
        // —— 尺寸不变就不回调，所以只要 Canvas 参与 Stack 测量，两个方向都会锁死。
        // 修的是结构（把测量源换成纯内容），不是在这里挑一个"更好的初值"。

        // ② 21 个参与渲染的参数（@State，赋值即触发订阅了它们的节点重绘）
        match (params.get<Message>("message"))                  { case Some(v) => this.message = v;                 case None => () }
        match (params.get<String>("peerType"))                 { case Some(v) => this.peerType = v;                case None => () }
        match (params.get<Int64>("voicePlaybackEpoch"))         { case Some(v) => this.voicePlaybackEpoch = v;      case None => () }
        // TC-0407 round2 F-1: reset the MessageBubbleShape input mirrors (hasTail + the four
        // group flags) right after message is reassigned, so the very first build() round after
        // recycle already reflects the new message rather than waiting for the next
        // refreshRenderRadii() probe to overwrite whatever the previous message left behind.
        this.shapeHasTail = this.hasBubbleTail()
        this.shapeIsMiddleInGroup = this.message.isMiddleInGroup
        this.shapeIsFirstInGroup = this.message.isFirstInGroup
        this.shapeIsLastInGroup = this.message.isLastInGroup
        this.shapeIsSingleMessage = this.message.isSingleMessage
        this.dateHeaderText = this.message.dateSeparatorText
        match (params.get<ArrayList<Message>>("groupedMessages")){ case Some(v) => this.groupedMessages = v;         case None => () }
        match (params.get<Bool>("isMultiSelectMode"))           { case Some(v) => this.isMultiSelectMode = v;       case None => () }
        // S4-12: absent at the call sites that never search (thread / preview screens) → keep default.
        match (params.get<String>("searchHighlightText"))       { case Some(v) => this.searchHighlightText = v;     case None => this.searchHighlightText = "" }
        match (params.get<Bool>("contextPreviewHidden"))        { case Some(v) => this.contextPreviewHidden = v;    case None => () }
        match (params.get<String>("translateToLangName"))       { case Some(v) => this.translateToLangName = v;     case None => () }
        match (params.get<Bool>("showTranslation"))             { case Some(v) => this.showTranslation = v;         case None => () }
        match (params.get<String>("translatedText"))            { case Some(v) => this.translatedText = v;          case None => () }
        match (params.get<Bool>("isTranslating"))               { case Some(v) => this.isTranslating = v;           case None => () }
        match (params.get<Bool>("translateError"))              { case Some(v) => this.translateError = v;          case None => () }
        match (params.get<Bool>("showOriginal"))                { case Some(v) => this.showOriginal = v;            case None => () }
        match (params.get<Bool>("withWallpaper"))               { case Some(v) => this.withWallpaper = v;           case None => () }
        match (params.get<Array<UInt32>>("wallpaperGradientColors")) { case Some(v) => this.wallpaperGradientColors = v; case None => () }
        match (params.get<UInt32>("bubbleOutColor"))            { case Some(v) => this.bubbleOutColor = v;          case None => () }
        match (params.get<UInt32>("bubbleInColor"))             { case Some(v) => this.bubbleInColor = v;           case None => () }
        // TC-0407 round3 F-1: same restore shape as the other renderer-input colours above.
        match (params.get<UInt32>("bubbleStrokeColor"))         { case Some(v) => this.bubbleStrokeColor = v;       case None => () }
        match (params.get<UInt32>("bubbleOutTextColor"))        { case Some(v) => this.bubbleOutTextColor = v;      case None => () }
        match (params.get<UInt32>("bubbleInTextColor"))         { case Some(v) => this.bubbleInTextColor = v;       case None => () }
        match (params.get<UInt32>("replyAuthorAccentColor"))    { case Some(v) => this.replyAuthorAccentColor = v;  case None => () }
        match (params.get<UInt32>("bubbleOutAccentTextColor"))  { case Some(v) => this.bubbleOutAccentTextColor = v; case None => () }
        // round7 F-C: sentinel radius overrides. Absent at the 4 call sites outside
        // pages/BubbleSettingsPage.cj (they never pass these keys), so params.get returns None there
        // and the field keeps whatever it already had (-1 default on cold construct, or the last
        // override value on recycle within the same preview block) — no behaviour change for them.
        match (params.get<Int32>("overrideMainRadius"))         { case Some(v) => this.overrideMainRadius = v;      case None => () }
        match (params.get<Int32>("overrideAuxRadius"))          { case Some(v) => this.overrideAuxRadius = v;       case None => () }
        match (params.get<Bool>("forwardNameLinkEnabled"))      { case Some(v) => this.forwardNameLinkEnabled = v;  case None => () }

        // ③ 17 个回调闭包（普通 var 即可，不参与渲染；但**必须重新装上**，
        //    它们捕获了具体那条消息 —— 漏一个就会作用到错误的消息上）
        match (params.get<() -> Unit>("onReply"))               { case Some(v) => this.onReply = v;                 case None => () }
        match (params.get<Bool>("swipeToReplyEnabled"))         { case Some(v) => this.swipeToReplyEnabled = v;     case None => () }
        match (params.get<() -> Unit>("onEdit"))                { case Some(v) => this.onEdit = v;                  case None => () }
        match (params.get<() -> Unit>("onDelete"))              { case Some(v) => this.onDelete = v;                case None => () }
        match (params.get<(String) -> Unit>("onReactionTap"))   { case Some(v) => this.onReactionTap = v;           case None => () }
        match (params.get<(Int64) -> Unit>("onReactionCountTap")){ case Some(v) => this.onReactionCountTap = v;     case None => () }
        match (params.get<(Message, String) -> Unit>("onAnimatedEmojiTap")) {
            case Some(v) => this.onAnimatedEmojiTap = v
            case None => ()
        }
        match (params.get<(Message) -> Unit>("onDoubleTap")) {
            case Some(v) => this.onDoubleTap = v
            case None => ()
        }
        match (params.get<(Float64, Float64) -> Unit>("onLongPress")) {
            case Some(v) => this.onLongPress = v
            case None => ()
        }
        match (params.get<(Message) -> Unit>("onImageTap"))     { case Some(v) => this.onImageTap = v;              case None => () }
        match (params.get<(Message) -> Unit>("onVideoTap"))     { case Some(v) => this.onVideoTap = v;              case None => () }
        match (params.get<(Message) -> Unit>("onGifTap"))       { case Some(v) => this.onGifTap = v;                case None => () }
        match (params.get<(Message) -> Unit>("onVoiceTap"))     { case Some(v) => this.onVoiceTap = v;              case None => () }
        match (params.get<(Message) -> Unit>("onFileTap"))      { case Some(v) => this.onFileTap = v;               case None => () }
        match (params.get<(String) -> Unit>("onWebUrlTap"))     { case Some(v) => this.onWebUrlTap = v;             case None => () }
        match (params.get<(String) -> Unit>("onWebPreviewTap")) { case Some(v) => this.onWebPreviewTap = v;         case None => () }
        match (params.get<(Float64, Float64, String) -> Unit>("onLocationTap")) { case Some(v) => this.onLocationTap = v; case None => () }
        match (params.get<(Int64, Int64) -> Unit>("onVoteTap")) { case Some(v) => this.onVoteTap = v;               case None => () }
        match (params.get<(Int64) -> Unit>("onReplyTap"))       { case Some(v) => this.onReplyTap = v;              case None => () }
        match (params.get<(Bool) -> Unit>("onShowOriginalToggle")) { case Some(v) => this.onShowOriginalToggle = v; case None => () }
        match (params.get<() -> Unit>("onForwardNameTap"))      { case Some(v) => this.onForwardNameTap = v;        case None => () }
        // ⚠️ 必须放在 message 已经换成新消息之后：放在开头的清理段里会去预取上一条的表情
        this.prefetchInlineCustomEmoji()
    }

    /**
     * 进复用缓存 —— 只停掉跟"上一条消息"绑定的定时器，**不碰任何 @State**。
     * 实时位置的脉冲动画若不停，会为一条已不在屏上的消息持续走帧。
     */
    protected override func aboutToRecycle() {
        this.stopLivePinAnimation()
    }

    public func build() {
        Column {
            // Phase P6-3: 日期分隔线
            // diag-suite_settings_appearance-TC-0413-round4.md OF-2/F-2: 拆成独立组件
            // MessageDateHeader（文件末尾），随主题快照的 freeformBubbleColor 重着色，
            // 不再是不读任何主题量的字面量。geometry 原样搬进新组件，一个数值不改。
            if (this.message.showDateSeparator) {
                MessageDateHeader(dateText: this.dateHeaderText)
            }
            
            // Swipe-to-reply host: the row slides left and the reply badge is
            // attached to its trailing edge (iOS ChatMessageSwipeToReplyNode).
            Stack(alignContent: Alignment.End) {
            Row {
                if (this.message.messageType == "service") {
                    // ==================== P2-113: service/action 消息（居中灰色胶囊）====================
                    serviceMessageContent()
                } else if (this.message.isCallMessage) {
                    // ==================== Phase T3: 通话消息（居中显示）====================
                    Row {
                        callMessageContent()
                    }
                    .width(100.percent)
                    .justifyContent(FlexAlign.Center)
                } else if (this.message.isSent) {
                    // ==================== 发送的消息（右对齐）====================
                    // P2-395/396: 壁纸时改用 linearGradient 背景（跟随壁纸渐变色）
                    Row {
                        if (this.message.status == "failed") {
                            deliveryFailedIndicator()
                        }
                        if (this.isStickerLikeContent()) {
                            Column {
                                messageContent(true)
                            }
                            .alignItems(HorizontalAlign.End)
                            .constraintSize(maxWidth: 86.percent)
                        } else if (this.isBubblelessMedia()) {
                            // iOS: 纯媒体无气泡背景，图片自身即圆角容器；反应在图下方独立行（气泡外）
                            Column {
                                Column {
                                    messageContent(true)
                                }
                                .alignItems(HorizontalAlign.End)
                                reactionsRow(true)
                            }
                            .alignItems(HorizontalAlign.End)
                            .constraintSize(maxWidth: 86.percent)
                        } else {
                            Stack(alignContent: Alignment.BottomEnd) {
                                // TC-0401 round7 F-1: the bubble fill/tail mask moved into
                                // MessageBubbleShape (bottom of this file). Two things had to change
                                // at once and both live in that class: its CanvasRenderingContext2D
                                // now shares the Canvas node's lifetime (D-190 — this component is
                                // @Reusable, so a ctx declared here outlives the node it is bound to),
                                // and a fill-colour change is now a repaint trigger in its own right
                                // (D-202 — the preview block's fixture bubbles keep byte-identical
                                // bounds across every theme state, so neither .onAreaChange ever
                                // fires and .onReady alone never re-ran).
                                //
                                // The wrapper Stack reproduces the raw Canvas node's box exactly —
                                // same explicit size, same .position(0, 0) out-of-flow placement — so
                                // this Stack keeps measuring from the content Column alone and the
                                // geometry is unchanged. The built-in modifiers must stay on this
                                // plain Stack: chaining them directly onto a custom @Component
                                // instantiation is a macro-expansion error (syntax_error.md, the
                                // ArchiveInfoContent case).
                                //
                                // fillColor / canvasW / canvasH / withWallpaper / mainRadius /
                                // auxRadius / hasTail / isMiddleInGroup / isFirstInGroup /
                                // isLastInGroup / isSingleMessage are all passed as bare
                                // `this.<field>` reads on purpose (D-125): those are the inputs that
                                // must reach an already-mounted instance, and the macro only wires a
                                // live parent->child channel for literal bare field reads.
                                // mainRadius/auxRadius/hasTail/the four group flags all source from
                                // mirror fields (renderMainRadius/renderAuxRadius from round7 F-C;
                                // shapeHasTail/shapeIsMiddleInGroup/shapeIsFirstInGroup/
                                // shapeIsLastInGroup/shapeIsSingleMessage from TC-0407 round2 F-1),
                                // kept fresh once per build() by the same zero-height probe below —
                                // same technique this file already uses for repaintIfChanged() inside
                                // MessageBubbleShape.build() itself.
                                Stack {
                                    Text(this.refreshRenderRadii()).height(0).fontSize(0)
                                    MessageBubbleShape(
                                        fillColor: this.bubbleOutColor,
                                        strokeColor: this.bubbleStrokeColor,
                                        canvasW: this.bubbleCanvasWidth,
                                        canvasH: this.bubbleCanvasHeight,
                                        withWallpaper: this.withWallpaper,
                                        isSent: true,
                                        hasTail: this.shapeHasTail,
                                        mainRadius: this.renderMainRadius,
                                        auxRadius: this.renderAuxRadius,
                                        isMiddleInGroup: this.shapeIsMiddleInGroup,
                                        isFirstInGroup: this.shapeIsFirstInGroup,
                                        isLastInGroup: this.shapeIsLastInGroup,
                                        isSingleMessage: this.shapeIsSingleMessage
                                    )
                                }
                                .width(this.bubbleCanvasWidth)
                                .height(this.bubbleCanvasHeight)
                                .position(x: 0.0, y: 0.0)
                                // ★ 测量源必须是**内容**，不能是 Stack —— 见下方 onAreaChange 说明。
                                // 外层 Column 只包一个子元素，尺寸 = 内容 + margin，与 Canvas 无关。
                                Column {
                                    Column {
                                        messageContent(true)
                                    }
                                    .alignItems(HorizontalAlign.End)
                                    .margin(right: if (this.hasBubbleTail()) { 6 } else { 0 })
                                }
                                .onAreaChange({ _: Area, newArea: Area =>
                                    this.bubbleCanvasWidth = newArea.width.value
                                    this.bubbleCanvasHeight = newArea.height.value
                                })
                            }
                            .constraintSize(maxWidth: 86.percent)
                            .translate(x: if (this.hasBubbleTail()) { 6.0 } else { 0.0 })
                            .shadow(radius: if (getThemesEngineService().getBubbleShadowEnabled()) { 4.0 } else { 0.0 }, color: Color(0x33000000))
                        }
                    }
                    .width(100.percent)
                    .justifyContent(FlexAlign.End)
                } else {
                    // ==================== 接收的消息（左对齐，灰色）====================
                    Row {
                        if (this.showsPeerAvatar()) {
                            // 头像只画在聚簇底部那条上，其余条目留等宽占位保持左缘对齐 ——
                            // 对齐 iOS：avatar header 在同一作者聚簇里只出现一次且贴底。
                            Column {
                                if (this.message.isLastInGroup || this.message.isSingleMessage) {
                                    Avatar(
                                        avatarUrl: getUserPhotoService().getUserPhotoPath(this.message.senderId),
                                        displayName: this.message.senderName,
                                        avatarSize: 34,
                                        peerId: this.message.senderId
                                    )
                                }
                            }
                            .width(34)
                            .margin(right: 6)
                        }
                        if (this.isStickerLikeContent()) {
                            Column {
                                messageContent(false)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .constraintSize(maxWidth: 86.percent)
                        } else if (this.isBubblelessMedia()) {
                            // iOS: 纯媒体无气泡背景，图片自身即圆角容器；反应在图下方独立行（气泡外）
                            Column {
                                Column {
                                    messageContent(false)
                                }
                                .alignItems(HorizontalAlign.Start)
                                reactionsRow(false)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .constraintSize(maxWidth: 86.percent)
                        } else {
                            Stack(alignContent: Alignment.BottomStart) {
                                // TC-0401 round7 F-1: the bubble fill/tail mask moved into
                                // MessageBubbleShape (bottom of this file). Two things had to change
                                // at once and both live in that class: its CanvasRenderingContext2D
                                // now shares the Canvas node's lifetime (D-190 — this component is
                                // @Reusable, so a ctx declared here outlives the node it is bound to),
                                // and a fill-colour change is now a repaint trigger in its own right
                                // (D-202 — the preview block's fixture bubbles keep byte-identical
                                // bounds across every theme state, so neither .onAreaChange ever
                                // fires and .onReady alone never re-ran).
                                //
                                // The wrapper Stack reproduces the raw Canvas node's box exactly —
                                // same explicit size, same .position(0, 0) out-of-flow placement — so
                                // this Stack keeps measuring from the content Column alone and the
                                // geometry is unchanged. The built-in modifiers must stay on this
                                // plain Stack: chaining them directly onto a custom @Component
                                // instantiation is a macro-expansion error (syntax_error.md, the
                                // ArchiveInfoContent case).
                                //
                                // fillColor / canvasW / canvasH / withWallpaper / mainRadius /
                                // auxRadius / hasTail / isMiddleInGroup / isFirstInGroup /
                                // isLastInGroup / isSingleMessage are all passed as bare
                                // `this.<field>` reads on purpose (D-125): those are the inputs that
                                // must reach an already-mounted instance, and the macro only wires a
                                // live parent->child channel for literal bare field reads.
                                // mainRadius/auxRadius/hasTail/the four group flags all source from
                                // mirror fields (renderMainRadius/renderAuxRadius from round7 F-C;
                                // shapeHasTail/shapeIsMiddleInGroup/shapeIsFirstInGroup/
                                // shapeIsLastInGroup/shapeIsSingleMessage from TC-0407 round2 F-1),
                                // kept fresh once per build() by the same zero-height probe below —
                                // same technique this file already uses for repaintIfChanged() inside
                                // MessageBubbleShape.build() itself.
                                Stack {
                                    Text(this.refreshRenderRadii()).height(0).fontSize(0)
                                    MessageBubbleShape(
                                        fillColor: this.bubbleInColor,
                                        strokeColor: this.bubbleStrokeColor,
                                        canvasW: this.bubbleCanvasWidth,
                                        canvasH: this.bubbleCanvasHeight,
                                        withWallpaper: this.withWallpaper,
                                        isSent: false,
                                        hasTail: this.shapeHasTail,
                                        mainRadius: this.renderMainRadius,
                                        auxRadius: this.renderAuxRadius,
                                        isMiddleInGroup: this.shapeIsMiddleInGroup,
                                        isFirstInGroup: this.shapeIsFirstInGroup,
                                        isLastInGroup: this.shapeIsLastInGroup,
                                        isSingleMessage: this.shapeIsSingleMessage
                                    )
                                }
                                .width(this.bubbleCanvasWidth)
                                .height(this.bubbleCanvasHeight)
                                .position(x: 0.0, y: 0.0)
                                // ★ 同发送分支：测量源是内容，不是 Stack。
                                Column {
                                    Column {
                                        messageContent(false)
                                    }
                                    .alignItems(HorizontalAlign.Start)
                                    .margin(left: if (this.hasBubbleTail()) { 6 } else { 0 })
                                }
                                .onAreaChange({ _: Area, newArea: Area =>
                                    this.bubbleCanvasWidth = newArea.width.value
                                    this.bubbleCanvasHeight = newArea.height.value
                                })
                            }
                            .constraintSize(maxWidth: 86.percent)
                            .translate(x: if (this.hasBubbleTail()) { -6.0 } else { 0.0 })
                            .shadow(radius: if (getThemesEngineService().getBubbleShadowEnabled()) { 4.0 } else { 0.0 }, color: Color(0x33000000))
                        }
                    }
                    .width(100.percent)
                    .justifyContent(FlexAlign.Start)
                    // 头像贴气泡底缘（iOS 的 header stick 到聚簇底部）
                    .alignItems(VerticalAlign.Bottom)
                }
            }
            .width(100.percent)
            .padding(left: 8, right: 8)
            .id(this.contextSourceId())
            .opacity(if (this.contextPreviewHidden) { 0.0 } else { 1.0 })
            .translate(x: this.swipeReplyOffset)

            if (this.swipeReplyOffset < 0.0) {
                Stack {
                    Image(@r(app.media.chatroom_ic_reply))
                        .width(18)
                        .height(18)
                        .fillColor(0xFFFFFFFF)
                }
                .width(33)
                .height(33)
                .borderRadius(16.5)
                .backgroundColor(0x66000000)
                .opacity(this.swipeReplyProgress())
                .scale(
                    x: Float32(0.4 + 0.6 * this.swipeReplyProgress()),
                    y: Float32(0.4 + 0.6 * this.swipeReplyProgress()),
                    z: Float32(1.0)
                )
                // iOS: node.position.x = bounds.width + offset + 33/2 inside the
                // shifted bounds (offset -24 incoming, +10 outgoing), so the
                // badge enters from the trailing edge together with the row.
                .translate(x: this.swipeReplyBadgeBaseX() + this.swipeReplyOffset)
            }
            }
            .width(100.percent)
            // S3-16: selection mode disables every control inside the row (links, media,
            // buttons, reply quote …) so none of them can swallow the tap; the row root
            // below stays enabled and turns the tap into onSelectionTap.
            .enabled(!this.isMultiSelectMode)
        }
        .width(100.percent)
        .padding(top: this.getGroupTopPadding(), bottom: this.getGroupBottomPadding())
        // Keep recognition on the rendered message row. The page overlay owns
        // presentation, expansion and dismissal; no native context menu is mounted.
        .onTouch({ evt => this.handleMessageContextTouch(evt) })
    }

    /** Resolve the exact rendered row in window coordinates before presentation. */
    private func requestContextOverlay(): Unit {
        let sourceId = this.contextSourceId()
        try {
            let rectangle = ComponentUtils.getRectangleById(sourceId)
            // ComponentUtils reports physical px, while ArkUI position/size
            // numbers are vp. Passing px through made the page think an
            // on-screen message was far below the viewport and clamp it to
            // the top. Convert the complete rectangle at the boundary.
            let uiContext = this.getUIContext()
            let y = match (uiContext.px2vp(rectangle.windowOffset.y.px)) {
                case Some(value) => value.value
                case None => rectangle.windowOffset.y
            }
            let height = match (uiContext.px2vp(rectangle.size.height.px)) {
                case Some(value) => value.value
                case None => rectangle.size.height
            }
            this.onLongPress(y, height)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[MessageBubble] context geometry failed id=${sourceId}: ${e}")
        }
    }

    /** iOS swipeToReplyGesture: swipeOffset 45 incoming, 60 outgoing. */
    private func swipeReplyThreshold(): Float64 {
        return if (this.message.isSent) { 60.0 } else { 45.0 }
    }

    private func swipeReplyProgress(): Float64 {
        let p = (0.0 - this.swipeReplyOffset) / this.swipeReplyThreshold()
        return if (p > 1.0) { 1.0 } else if (p < 0.0) { 0.0 } else { p }
    }

    private func swipeReplyBadgeBaseX(): Float64 {
        // Stack is end-aligned: the badge's trailing edge starts at the row
        // edge; shift by iOS offset + badge width.
        let offset = if (this.message.isSent) { 10.0 } else { -24.0 }
        return offset + 33.0
    }

    /** iOS shouldBegin + canSetupReply subset available on this model. */
    private func canSwipeToReply(): Bool {
        if (!this.swipeToReplyEnabled || this.isMultiSelectMode) { return false }
        if (this.message.id <= 0) { return false }
        if (this.message.messageType == "service") { return false }
        if (this.message.isSent && (this.message.status == "failed" || this.message.status == "sending")) {
            return false
        }
        return true
    }

    /** iOS rubberBandingOffset(offset:bandingStart:) with range 100, coefficient 0.4. */
    private func swipeReplyRubberBand(distance: Float64): Float64 {
        let bandingStart = this.swipeReplyThreshold()
        if (distance < bandingStart) { return distance }
        let banded = distance - bandingStart
        let range = 100.0
        return bandingStart + (1.0 - (1.0 / ((banded * 0.4 / range) + 1.0))) * range
    }

    private func finishSwipeReply(ended: Bool, screenX: Float64): Unit {
        let wasActive = this.swipeReplyActive
        this.swipeReplyActive = false
        this.swipeReplyRejected = false
        if (!wasActive) { return }
        let translation = screenX - this.swipeReplyStartX
        if (ended && translation < 0.0 - this.swipeReplyThreshold()) {
            this.onReply()
        }
        let uiContext = this.getUIContext()
        safeAnimateTo({ => uiContext }, AnimateParam(duration: 300, curve: Curve.Friction), { =>
            this.swipeReplyOffset = 0.0
        })
    }

    /** Returns true while the horizontal swipe owns the touch sequence. */
    private func handleSwipeReplyTouch(evt: TouchEvent): Bool {
        if (evt.touches.size == 0 && evt.changedTouches.size == 0) { return this.swipeReplyActive }
        let point = if (evt.changedTouches.size > 0) { evt.changedTouches[0] } else { evt.touches[0] }
        match (evt.eventType) {
            case TouchType.Down =>
                this.swipeReplyActive = false
                this.swipeReplyRejected = !this.canSwipeToReply()
                this.swipeReplyHapticPlayed = false
                this.swipeReplyStartX = point.screenX
                this.swipeReplyStartY = point.screenY
                return false
            case TouchType.Move =>
                if (this.swipeReplyRejected) { return false }
                let dx = point.screenX - this.swipeReplyStartX
                let dy = point.screenY - this.swipeReplyStartY
                if (!this.swipeReplyActive) {
                    let ady = if (dy < 0.0) { 0.0 - dy } else { dy }
                    if (ady > 10.0 && ady > (0.0 - dx)) {
                        // Vertical scroll wins; this sequence is not a swipe.
                        this.swipeReplyRejected = true
                        return false
                    }
                    if (dx < -10.0 && (0.0 - dx) > ady * 1.5) {
                        this.swipeReplyActive = true
                    } else {
                        return false
                    }
                }
                var translation = 0.0
                if (dx < 0.0) {
                    translation = 0.0 - this.swipeReplyRubberBand(0.0 - dx)
                    if (translation < -180.0) { translation = -180.0 }
                }
                this.swipeReplyOffset = translation
                if (!this.swipeReplyHapticPlayed && (0.0 - translation) >= this.swipeReplyThreshold()) {
                    this.swipeReplyHapticPlayed = true
                    triggerHaptic("impact", "heavy")
                }
                return true
            case TouchType.Up =>
                let owned = this.swipeReplyActive
                this.finishSwipeReply(true, point.screenX)
                return owned
            case TouchType.Cancel =>
                let owned = this.swipeReplyActive
                this.finishSwipeReply(false, point.screenX)
                return owned
            case _ => return false
        }
    }

    /** One 300 ms recognizer owner for text, media, stickers and service messages. */
    private func handleMessageContextTouch(evt: TouchEvent): Unit {
        if (this.handleSwipeReplyTouch(evt)) {
            // A horizontal reply swipe cancels the pending long press and
            // must not turn into a media tap on release.
            if (this.mediaPressActive) {
                this.mediaPressActive = false
                this.mediaPressGeneration += 1
            }
            return
        }
        if (this.isMultiSelectMode) {
            this.handleSelectionTouch(evt)
            return
        }
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0) {
                    this.mediaTouchStartX = evt.touches[0].x
                    this.mediaTouchStartY = evt.touches[0].y
                }
                // S3-02: second finger-down within 350 ms and ~30 px of the previous
                // one is a double tap (iOS doubleTapGesture → sendDefaultReaction).
                let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                let ddx = this.mediaTouchStartX - this.lastTapDownX
                let ddy = this.mediaTouchStartY - this.lastTapDownY
                if (this.lastTapDownMs > 0 && nowMs - this.lastTapDownMs < 350 && ddx * ddx + ddy * ddy < 900.0) {
                    this.lastTapDownMs = 0
                    this.mediaPressActive = false
                    this.mediaPressGeneration += 1
                    this.suppressNextMediaTap = true
                    Hilog.info(0, "CjTelegram", "[MessageBubble] double tap msgId=${this.message.id}")
                    this.onDoubleTap(this.message)
                    return
                }
                this.lastTapDownMs = nowMs
                this.lastTapDownX = this.mediaTouchStartX
                this.lastTapDownY = this.mediaTouchStartY
                this.mediaPressActive = true
                this.mediaTapEligible = true
                this.mediaPressGeneration += 1
                let generation = this.mediaPressGeneration
                spawn {
                    sleep(Duration.millisecond * 300)
                    launch {
                        if (this.mediaPressActive && generation == this.mediaPressGeneration) {
                            this.mediaPressActive = false
                            this.mediaTapEligible = false
                            this.suppressNextMediaTap = true
                            triggerHaptic("impact", "light")
                            this.requestContextOverlay()
                        }
                    }
                }
            case TouchType.Move =>
                if (this.mediaPressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.mediaTouchStartX
                    let dy = evt.touches[0].y - this.mediaTouchStartY
                    if (dx * dx + dy * dy > 64.0) {
                        this.mediaPressActive = false
                        this.mediaTapEligible = false
                        this.mediaPressGeneration += 1
                    }
                }
            case TouchType.Up =>
                if (this.mediaTapEligible) {
                    let elapsed = evt.timestamp - this.lastMessageTapTimestamp
                    if (this.lastMessageTapTimestamp > 0 && elapsed > 0 && elapsed <= 400_000_000) {
                        let reaction = getStickersService().readLocalStringSetting("quick_reaction", "❤️")
                        this.lastMessageTapTimestamp = 0
                        this.suppressNextMediaTap = true
                        if (!reaction.isEmpty()) { this.onReactionTap(reaction) }
                    } else {
                        this.lastMessageTapTimestamp = evt.timestamp
                    }
                }
                this.mediaPressActive = false
                this.mediaTapEligible = false
                this.mediaPressGeneration += 1
            case TouchType.Cancel =>
                this.mediaPressActive = false
                this.mediaTapEligible = false
                this.mediaPressGeneration += 1
            case _ => ()
        }
    }

    /**
     * S3-16: selection-mode tap on the row (iOS ChatMessageItemView: the whole row is one
     * tap target while selecting). Raw touch events reach the row root even though the
     * content subtree is disabled; a finger that travelled more than ~8 vp is a scroll,
     * not a toggle. The circle on the page side has its own onClick and is outside this row.
     */
    private func handleSelectionTouch(evt: TouchEvent): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0) {
                    this.selectionTouchStartX = evt.touches[0].x
                    this.selectionTouchStartY = evt.touches[0].y
                }
                this.selectionPressActive = true
            case TouchType.Move =>
                if (this.selectionPressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.selectionTouchStartX
                    let dy = evt.touches[0].y - this.selectionTouchStartY
                    if (dx * dx + dy * dy > 64.0) {
                        this.selectionPressActive = false
                    }
                }
            case TouchType.Up =>
                let wasPending = this.selectionPressActive
                this.selectionPressActive = false
                if (wasPending) {
                    Hilog.info(0, "CjTelegram", "[MessageBubble] selection tap msgId=${this.message.id}")
                    this.onSelectionTap(this.message)
                }
            case TouchType.Cancel =>
                this.selectionPressActive = false
            case _ => ()
        }
    }

    private func handleMediaTap(target: Message): Unit {
        if (this.suppressNextMediaTap) {
            this.suppressNextMediaTap = false
            return
        }
        this.onImageTap(target)
    }
}

/**
 * 格式化文件大小为可读字符串
 */
func formatFileSize(bytes: Int64): String {
    if (bytes < 1024) {
        return "${bytes} B"
    } else if (bytes < 1048576) {
        let kb = bytes / 1024
        return "${kb} KB"
    } else if (bytes < 1073741824) {
        let mb = bytes / 1048576
        let remainder = (bytes % 1048576) / 104858  // 一位小数
        return "${mb}.${remainder} MB"
    } else {
        let gb = bytes / 1073741824
        return "${gb} GB"
    }
}

/**
 * 格式化时长（秒 → M:SS）
 */
func formatDurationSec(seconds: Int32): String {
    let mins = seconds / 60
    let secs = seconds % 60
    let sStr = if (secs < 10) { "0${secs}" } else { "${secs}" }
    return "${mins}:${sStr}"
}

/** 气泡尾巴补丁块宽/高（vp）：覆盖 [体侧边-16.5, 体侧边+18] × [底-17, 底]。 */
let BUBBLE_TAIL_PATCH_W: Float64 = 34.5
let BUBBLE_TAIL_PATCH_H: Float64 = 17.0

/** 1 物理像素对应的 vp（UIScreenPixel 等价物），不依赖任何组件实例。 */
private func onePixelInVp(): Float64 {
    try {
        let density = Float64(getDefaultDisplaySync().densityPixels)
        if (density > 0.0) { return 1.0 / density }
    } catch (e: Exception) {}
    return 0.5
}

/**
 * TC-0401 round7 F-1 —— 气泡填充 / 尾巴遮罩的绘制器，从 MessageBubble 拆出。
 *
 * 拆出的两个理由（缺一都修不好 TC-0401 S4_b2 / TC-0402 的"预览气泡填充整个丢失"）：
 *
 * 1. **D-190：ctx 必须与它的 Canvas 节点同生命周期。** MessageBubble 是全仓唯一的 @Reusable
 *    组件（见该类头部注释），所以调用点的 D-160 双相同分支挂载守卫驱动的是
 *    「回收 + aboutToReuse」而不是「销毁 + 构造」：MessageBubble 实例连同声明在它身上的
 *    `private let ctx` 一起活在复用池里，而它下面的 Canvas 节点被重建 —— 正是 D-190 记录的
 *    「新节点配旧 ctx 对象」非原生配对。D-190 写明的症状是"完全空白"而不是"停在旧颜色"，
 *    round7 在设备上量到的正是空白。本类**不带 @Reusable**，每次冷挂载都全新构造，
 *    ctx 与 Canvas 节点由同一次构造产出。
 *
 * 2. **填充色变化此前完全没有重绘通道。** 搬迁前 drawBubbleCanvas() 只由 Canvas 的 .onReady 与
 *    .onAreaChange 两个几何事件触发；预览块喂的是两条固定 fixture 消息，三个主题态下实测
 *    bounds 逐字相同 ⇒ 两个 onAreaChange 都不回调，只剩不保证重复触发的 .onReady。于是
 *    aboutToReuse 确实把六个主题色喂进来了（round7 的像素证据：文字色两个方向都跟着变），
 *    却没有任何东西把新颜色画出去。下面的 repaintIfChanged() 把「填充色变了」本身变成一条
 *    重绘信号 —— 对位源侧 ChatMessageBubbleImages 随主题重新生成模板图那一跳
 *    （ThemeSettingsChatPreviewItem.swift:172/:178-190 updateNode → apply）。这不是特判、
 *    不是兜底门控：颜色变必然重出图，是源侧的结构性保证。
 *
 * 本轮**刻意不做**的事（round7 诊断的边界条件）：
 *   · 不给本类加 @Reusable —— 每次冷挂载全新构造正是 D-190 修法的要点；
 *   · 不在本类读 @StorageLink / currentPresentation() / isDark，也不新造明暗色表 ——
 *     "渲染器不读全局、由调用方喂色"是源侧不变量，与 MessageBubble 六个主题入参同一条；
 *   · 不动任何几何常量、路径顺序、两次 globalCompositeOperation 切换，以及 tail 的
 *     fullTailCorner 14.0 门槛：下面的 drawBubbleCanvas 是原样搬来的函数体，只把它读的
 *     宿主字段换成本类自己的入参；
 *   · 不回退调用点的 D-160 挂载守卫（它已被证明有效），也不把 MessageBubble 的六个主题入参
 *     改成 @Prop（S-141 级联会波及 allowlist 外文件，且改了也修不好本缺陷 —— Canvas 仍旧
 *     没有"颜色变了就重画"的通道）。
 */
@Component
class MessageBubbleShape {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // D-125：fillColor / canvasW / canvasH / withWallpaper 在两个调用点都以裸 `this.<字段>` 形式
    // 传入。宏只为字面裸字段引用建立父→子活通道，写成 if/else 值级表达式或函数调用返回值会让
    // 通道失效（D-188 把前者明确归入 D-125 同一大类）—— 这四个正是必须抵达已挂载实例的入参。
    // 其余几个是几何入参，取值来源与搬迁前逐字相同（同样是函数调用 / 嵌套字段），因此响应性
    // 与搬迁前完全一致：它们随本节点整体重新求值而刷新，而本节点的重新求值由上面四个裸字段驱动。
    @Prop var fillColor: UInt32
    // TC-0407 round3 F-1: themed outline stroke colour, same D-125 bare-field passing convention as
    // fillColor above (both call sites pass `this.bubbleStrokeColor`). Top byte 0x00 means "no
    // outline for this theme" — drawBubbleCanvas() below checks it and skips the whole stroke pass,
    // never assigning a 0x00-top-byte value to ctx.strokeStyle (see bubbleStrokeColor's field doc on
    // MessageBubble for why that assignment must never happen, D-175).
    @Prop var strokeColor: UInt32
    @Prop var canvasW: Float64
    @Prop var canvasH: Float64
    @Prop var withWallpaper: Bool
    @Prop var isSent: Bool
    @Prop var hasTail: Bool
    @Prop var mainRadius: Float64
    @Prop var auxRadius: Float64
    @Prop var isMiddleInGroup: Bool
    @Prop var isFirstInGroup: Bool
    @Prop var isLastInGroup: Bool
    @Prop var isSingleMessage: Bool

    // D-190 的落点：声明在这里，与下面 build() 里那个 Canvas 节点由同一次构造产出。
    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(
        RenderingContextSettings(antialias: true)
    )

    // 普通 var，**刻意不是 @State**：它们只做重绘去重，不被任何渲染表达式读取。若声明成 @State，
    // 写它们会触发新的 build() 轮次，与下面的零高度探针构成回路。
    private var paintedFill: UInt32 = 0
    // TC-0407 round3 F-1: 13th dedup key, same shape as paintedFill above — the outline colour is
    // its own independent renderer input (drawBubbleCanvas() reads this.strokeColor separately from
    // this.fillColor), so a fill-only theme switch that happens to leave strokeColor unchanged must
    // still be distinguishable from a strokeColor-only change (e.g. dark<->light toggling the top
    // byte while fillColor is mid-transition). Folding it into paintedFill's comparison would miss
    // that case.
    private var paintedStrokeColor: UInt32 = 0
    private var paintedW: Float64 = 0.0
    private var paintedH: Float64 = 0.0
    // round7 F-C: 半径此前不在去重键里，滑杆改半径时这两个 @Prop 即使已经被父组件推入新值，
    // 也从未触发重绘——这正是 RC-C 的核心缺口。加入去重键 + 记账字段后，半径变化本身成为一条
    // 重绘信号，对位源侧 ThemeSettingsChatPreviewItem.swift:180 "参数变了就重出图" 那一跳。
    private var paintedMainRadius: Float64 = 0.0
    private var paintedAuxRadius: Float64 = 0.0
    // TC-0407 round2 F-1: 去重键此前只覆盖 5/12 项入参，另外 7 项即使真的被父组件推入新值也
    // 不触发重绘——这正是 RC-1 的核心缺口（复用后画布带着上一条消息的 hasTail / 四个分组
    // 标志 / isSent / withWallpaper 继续存在，直到 fillColor/canvasW/canvasH/mainRadius/
    // auxRadius 五项之一恰好也变了才会连带重画）。扩到全部 12 项，drawBubbleCanvas() 读到的
    // 每一个入参都参与去重判定。
    private var paintedWithWallpaper: Bool = false
    private var paintedIsSent: Bool = false
    private var paintedHasTail: Bool = false
    private var paintedIsMiddleInGroup: Bool = false
    private var paintedIsFirstInGroup: Bool = false
    private var paintedIsLastInGroup: Bool = false
    private var paintedIsSingleMessage: Bool = false

    /** 无条件重绘并记账。onReady 走这条：那一刻探针可能已经记过账但画布还没挂上。 */
    private func paintBubble(width: Float64, height: Float64): Unit {
        this.paintedFill = this.fillColor
        this.paintedStrokeColor = this.strokeColor
        this.paintedW = width
        this.paintedH = height
        this.paintedMainRadius = this.mainRadius
        this.paintedAuxRadius = this.auxRadius
        this.paintedWithWallpaper = this.withWallpaper
        this.paintedIsSent = this.isSent
        this.paintedHasTail = this.hasTail
        this.paintedIsMiddleInGroup = this.isMiddleInGroup
        this.paintedIsFirstInGroup = this.isFirstInGroup
        this.paintedIsLastInGroup = this.isLastInGroup
        this.paintedIsSingleMessage = this.isSingleMessage
        // 已销毁实例上的迟到回调：Canvas 上下文/组件句柄可能已失效，绘制异常只能吞掉，
        // 不能让它冒到 FFI 回调边界（那里没有 catch，等于 abort）。
        try {
            this.drawTailPatch(this.isSent)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[MessageBubbleShape] paintBubble skipped: ${e}")
        }
    }

    /**
     * drawTailPatch() 读到的入参中，任一项相对"上次真正画出去的那一份"有变化时重绘一次。返回值被
     * 零高度 Text 消费 —— D-116 不允许在 build() 体内写裸语句，这是让一个普通函数每轮 build() 都被
     * 执行的既定写法（D-125 正例同型）。
     */
    private func repaintIfChanged(): String {
        if (this.fillColor != this.paintedFill || this.strokeColor != this.paintedStrokeColor ||
            this.canvasW != this.paintedW ||
            this.canvasH != this.paintedH || this.mainRadius != this.paintedMainRadius ||
            this.auxRadius != this.paintedAuxRadius ||
            this.withWallpaper != this.paintedWithWallpaper ||
            this.isSent != this.paintedIsSent ||
            this.hasTail != this.paintedHasTail ||
            this.isMiddleInGroup != this.paintedIsMiddleInGroup ||
            this.isFirstInGroup != this.paintedIsFirstInGroup ||
            this.isLastInGroup != this.paintedIsLastInGroup ||
            this.isSingleMessage != this.paintedIsSingleMessage) {
            this.paintBubble(this.canvasW, this.canvasH)
        }
        return ""
    }

    // ==================== 几何（与 iOS ChatMessageBubbleImages.swift 同一套常量） ====================

    private func bodyLeft(): Float64 {
        return if (!this.isSent && this.hasTail) { 6.0 } else { 0.0 }
    }

    private func bodyWidth(): Float64 {
        let w = if (this.hasTail) { this.canvasW - 6.0 } else { this.canvasW }
        return if (w > 0.0) { w } else { 0.0 }
    }

    /** 四角半径：middle/first/last 分组用 aux 半径替换体侧边的两角（与原 Canvas 版逐字同逻辑）。 */
    private func cornerRadius(topSide: Bool, bodySide: Bool): Float64 {
        let mainR = this.mainRadius
        let auxR = this.auxRadius
        if (!bodySide) { return mainR }
        if (this.isMiddleInGroup) { return auxR }
        if (this.isFirstInGroup && !this.isSingleMessage) { return if (topSide) { mainR } else { auxR } }
        if (this.isLastInGroup && !this.isSingleMessage) { return if (topSide) { auxR } else { mainR } }
        return mainR
    }

    private func radiusTopLeft(): Float64 { return this.cornerRadius(true, !this.isSent) }
    private func radiusTopRight(): Float64 { return this.cornerRadius(true, this.isSent) }
    private func radiusBottomLeft(): Float64 { return this.cornerRadius(false, !this.isSent) }
    private func radiusBottomRight(): Float64 { return this.cornerRadius(false, this.isSent) }

    private func hasStroke(): Bool {
        return ((this.strokeColor >> 24) & 0xFFu32) != 0u32
    }

    /** 源侧 borderWidth = UIScreenPixel + innerExtension(0.25)；无描边主题返回 0。 */
    private func strokeWidthVp(): Float64 {
        if (!this.hasStroke()) { return 0.0 }
        return onePixelInVp() + 0.25
    }

    private func strokeColorForBorder(): UInt32 {
        // .border 的颜色在 width=0 时不参与绘制；描边色顶字节 0 的主题不会走到这里被画出。
        return if (this.hasStroke()) { this.strokeColor } else { 0x00000000 }
    }

    private func tailPatchX(): Float64 {
        if (this.isSent) { return this.canvasW - 6.0 - 16.5 }
        return 6.0 - 18.0
    }

    private func tailPatchY(): Float64 {
        return this.canvasH - BUBBLE_TAIL_PATCH_H
    }

    /**
     * 气泡 = 普通节点主体 + 尾巴小 Canvas。
     *
     * 2026-09-15 真机 RENDER_MEMORY_OVER_ERROR（GPU 2.1GB）根因：此前整个气泡是一张与气泡同尺寸的
     * Canvas 离屏面，长消息 300×900vp 按 3.25 倍密度一张 ≈11MB，疯狂上拉一页 60 条就是 660MB，
     * GPU 释放跟不上分配。iOS（ChatMessageBubbleImages.swift）把气泡画成一张很小的可拉伸图
     * （cap insets），GPU 开销与尺寸无关；这里的等价物是主体走 backgroundColor + 四角 borderRadius
     * + border（无离屏面），Canvas 只画尾巴那 34.5×17vp 的补丁块（≈25KB），绘制原语与原版逐字相同。
     * 外层 Stack 裁剪保持与原 Canvas 一致的可见范围（尾巴超出气泡框的 12vp 原本就被画布裁掉）。
     */
    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            // 零高度探针必须排在 Canvas 之前（同一 build() 内按出现顺序求值），这样
            // "颜色/尺寸变了就重画" 与 .onReady 是两条互不依赖的通道，任一条成立即可出图。
            Text(this.repaintIfChanged()).height(0).fontSize(0)
            // 描边用 borderWidth/borderColor 而不是 border(width:color:)：后者的 radius 形参
            // 缺省即按 0 落地，会把随后/此前设的四角 borderRadius 覆盖成直角（真机实锤：气泡变方）。
            Column {}
                .width(this.bodyWidth())
                .height(this.canvasH)
                .backgroundColor(this.fillColor)
                .borderWidth(this.strokeWidthVp())
                .borderColor(this.strokeColorForBorder())
                .borderRadius(
                    topLeft: this.radiusTopLeft(),
                    topRight: this.radiusTopRight(),
                    bottomLeft: this.radiusBottomLeft(),
                    bottomRight: this.radiusBottomRight()
                )
                .position(x: this.bodyLeft(), y: 0.0)
            if (this.hasTail) {
                Canvas(this.ctx)
                    .width(BUBBLE_TAIL_PATCH_W)
                    .height(BUBBLE_TAIL_PATCH_H)
                    .position(x: this.tailPatchX(), y: this.tailPatchY())
                    .onReady({ =>
                        this.paintBubble(this.canvasW, this.canvasH)
                    })
            }
        }
        .width(this.canvasW)
        .height(this.canvasH)
        .clip(true)
    }

    /**
     * 尾巴补丁块（补丁局部坐标，原点 = 全局 (体侧边∓16.5/18, 底-17)）。
     * Direct port of Telegram-iOS ChatMessageBubbleImages.swift 的尾巴段：角补方块、
     * 下半椭圆水滴尾、outline、再用 destination-out 椭圆挖出弧形。主体圆角矩形已由
     * build() 里的普通节点承担，这里不再画。
     *
     * 坐标换算：sent 时全局 bodyRight ↔ 局部 16.5，height ↔ 局部 17；
     *           received 时全局 bodyLeft ↔ 局部 18，height ↔ 局部 17。
     */
    private func drawTailPatch(isSent: Bool): Unit {
        if (!this.hasTail) { return }
        let ctx = this.ctx
        let w = BUBBLE_TAIL_PATCH_W
        let h = BUBBLE_TAIL_PATCH_H
        let mainR = this.mainRadius
        ctx.clearRect(0.0, 0.0, w, h)
        ctx.globalCompositeOperation = "source-over"
        ctx.fillStyle = this.fillColor

        // TC-0407 F-1 / TC-0406 C2: minRadiusForFullTailCorner = 14.0（源 :29）。
        let fullTailCorner = mainR >= 14.0
        if (isSent) {
            let bodyRight = 16.5
            if (fullTailCorner) {
                ctx.beginPath()
                ctx.moveTo(bodyRight - 9.0, h - 8.5)
                ctx.quadraticCurveTo(bodyRight - 9.0, h, bodyRight + 4.5, h)
                ctx.quadraticCurveTo(bodyRight + 18.0, h, bodyRight + 18.0, h - 8.5)
                ctx.closePath()
                ctx.fill()
            } else {
                ctx.fillRect(bodyRight - 9.0 - 2.0, h - 8.5, 27.0 + 2.0, 8.5)
            }
            ctx.fillRect(bodyRight - 16.5, h - 17.0, 16.5, 9.0)
        } else {
            let bodyLeft = 18.0
            if (fullTailCorner) {
                ctx.beginPath()
                ctx.moveTo(bodyLeft + 9.0, h - 8.5)
                ctx.quadraticCurveTo(bodyLeft + 9.0, h, bodyLeft - 4.5, h)
                ctx.quadraticCurveTo(bodyLeft - 18.0, h, bodyLeft - 18.0, h - 8.5)
                ctx.closePath()
                ctx.fill()
            } else {
                ctx.fillRect(bodyLeft - 18.0, h - 8.5, 27.0 + 2.0, 8.5)
            }
            ctx.fillRect(bodyLeft, h - 17.0, 16.5, 9.0)
        }

        // TC-0407 round3 F-1: tail outline（源 :309-318，不 closePath）。
        if (this.hasStroke()) {
            ctx.strokeStyle = this.strokeColor
            ctx.lineWidth = this.strokeWidthVp()
            if (fullTailCorner) {
                ctx.beginPath()
                if (isSent) {
                    ctx.moveTo(16.5 - 9.0, h - 8.5)
                    ctx.quadraticCurveTo(16.5 - 9.0, h, 16.5 + 4.5, h)
                    ctx.quadraticCurveTo(16.5 + 18.0, h, 16.5 + 18.0, h - 8.5)
                } else {
                    ctx.moveTo(18.0 + 9.0, h - 8.5)
                    ctx.quadraticCurveTo(18.0 + 9.0, h, 18.0 - 4.5, h)
                    ctx.quadraticCurveTo(18.0 - 18.0, h, 18.0 - 18.0, h - 8.5)
                }
                ctx.stroke()
            } else {
                ctx.beginPath()
                if (isSent) {
                    ctx.moveTo(16.5 - 9.0 - 2.0, h)
                    ctx.lineTo(16.5 - 9.0, h)
                    ctx.lineTo(16.5 + 18.0, h)
                } else {
                    ctx.moveTo(18.0 + 11.0, h)
                    ctx.lineTo(18.0 + 9.0, h)
                    ctx.lineTo(18.0 - 18.0, h)
                }
                ctx.stroke()
            }
        }

        ctx.globalCompositeOperation = "destination-out"
        ctx.beginPath()
        if (isSent) {
            ctx.ellipse(16.5 + 11.5, h - 8.5, 11.5, 10.5, 0.0, 0.0, 6.283185307179586, counterclockwise: false)
        } else {
            ctx.ellipse(18.0 - 11.5, h - 8.5, 11.5, 10.5, 0.0, 0.0, 6.283185307179586, counterclockwise: false)
        }
        ctx.fill()
        ctx.globalCompositeOperation = "source-over"
    }

    /**
     * TC-0407 F-3: outgoing 气泡壁纸分支渐变端点。源侧 theme.chat.message.outgoing.bubble.
     * withWallpaper.fill 是主题的输出，不是壁纸自身的颜色 —— 之前从 wallpaperGradientColors 取值
     * 是职责错位（气泡色与所选壁纸的渐变耦合，与主题脱钩）。两端改由呈现快照喂入的
     * bubbleOutColor 派生；快照目前只暴露单一 outgoing 气泡色，没有第二个"次色"维度，
     * 两端同值即退化为纯色填充，不在本文件内新造一张明暗/次色表。
     *
     * TC-0401 round7 F-1：两个函数随绘制体一起搬进本类，取色来源逐字不变 —— outgoing 分支的
     * fillColor 由调用点传 `this.bubbleOutColor`（发送分支唯一取值），故 `this.fillColor` 与搬迁前
     * 的 `this.bubbleOutColor` 是同一个值。不借本轮改动这两个函数的取色来源（TC-0407 F-3 既定结论）。
     */
    private func outgoingBubblePrimaryColor(): UInt32 {
        return this.fillColor
    }

    /**
     * TC-0407 F-3: 见 outgoingBubblePrimaryColor() 说明。
     */
    private func outgoingBubbleSecondaryColor(): UInt32 {
        return this.fillColor
    }
}

/**
 * diag-suite_settings_appearance-TC-0413-round4.md OF-2/RC-E（与 TC-0401 round7/round8 F-2 同一条
 * 处方，供给侧已落地，本轮只补消费侧）：会话日期分隔胶囊（"August 19"）。
 *
 * 源侧 ChatMessageDateHeader 是**独立于气泡节点的 list header**，自持 presentationData，并在主题变化时
 * 用 selectDateFillStaticColor(theme:wallpaper:) 重设底色（ChatMessageDateHeader.swift:202/:308/:337）。
 * 因此它读全局主题快照是**对位行为**——与 MessageBubble/MessageBubbleShape 类文档「渲染器不读全局、由
 * 调用方喂色」那条不变量不冲突：那条约束的对象是气泡节点本身，日期头在源侧从来就不是气泡节点。
 *
 * 底色取值：PresentationSnapshot.freeformBubbleColor（core/storage/AppTheme.cj:97，TC-0401 round8 F-2
 * 供给侧已落地，doc comment 明确标注"consumed by shell_chat_message_items's date-separator header"），
 * 对位源侧 chat.message.freeform.with{With,Without}Wallpaper.fill——浅色 0xE5E5EA / 深色 0x1F1F1F，
 * 与实测深浅两态诉求一致。不是按 0xB0B0B0 的观感去挑近似字段：这是该字面量在快照里语义对位的字段，
 * 由更早一轮的处方（TC-0401 round8 F-2）专门为这个消费点开出。
 *
 * 文字色保持字面量 0xFFFFFF——源侧 bubbleVariableColor(dateTextColor,...) 在本仓已实现的两个主题
 * （dayClassic / night）下都解到白，不构成可见差异，处方要求不得为此自造明暗表。
 *
 * `:2457 serviceMessageContent()` 的同型字面量本轮**仍不动**，但这里以前写的"它对应
 * `theme.chat.serviceMessage.components.with*.fill`"这条映射**已被订正为错误**
 * （diag-suite_settings_appearance-TC-0407.md round4 复核，逐一读过源侧调用点）：该 token 在源侧
 * 只有 4 个消费点（PresentationThemeEssentialGraphics.swift:601/612/613/614），全部是构造独立位图
 * 资源（chatServiceBubbleFillImage / chatFreeformContentAdditionalInfoBackgroundImage /
 * chatEmptyItemBackgroundImage / chatLoadingIndicatorBackgroundImage），没有一个是本组件对应的
 * service/action 消息灰色胶囊背景——不要再拿这条映射当作"两处硬接会撞车"的理由。字面量在本轮
 * 保持不动纯粹是因为本批处方范围只是气泡描边（TC-0407 F-1），未覆盖这处胶囊的真实取色路径；它
 * 对应的源侧字段仍待另一批查清后再迁移，不要凭空猜一个字段名填进来。
 */
@Component
class MessageDateHeader {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @Prop var dateText: String
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    func build() {
        Row {
            Text(this.dateText)
                .fontSize(12)
                .fontColor(0xFFFFFF)
                .padding(left: 12, right: 12, top: 4, bottom: 4)
                .backgroundColor(this.presentation.freeformBubbleColor)
                .borderRadius(10)
        }
        .width(100.percent)
        .justifyContent(FlexAlign.Center)
        .padding(top: 12, bottom: 8)
    }
}
