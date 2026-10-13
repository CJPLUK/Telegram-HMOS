package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.i18n.System as I18nSystem
import ohos_app_cangjie_entry.services.{
    getEmojiRecentService, EmojiRecentService,
    getStickersService, getEntityKeyboardStore, showToast, getCurrentUserId,
    getUndoToastService, seedCustomEmojiDocuments, prefetchCustomEmojiDocuments,
    prefetchEmojiPackMedia, saveFeaturedEmojiDetailsCache, loadFeaturedEmojiDetailsCache,
    EmojiKeywordEntry, EmojiKeyboardSnapshot,
    StickerItem, StickerPackInfo, StickerPackDetail, EmojiGroupInfo
,
    setKeyboardGridScrolling, isKeyboardGridScrolling, getAppFilesDir,
    ensureStickerLocalFile, requestAnimationCacheBuild, loadStickerStaticFrame,
    CHAIN_TRACE_LOGS}
import ohos_app_cangjie_entry.bindings.setEmojiGridProviders
import ohos_app_cangjie_entry.interop.callArk
import ohos_app_cangjie_entry.router.routerPush
import std.collection.{ArrayList, HashMap, HashSet}
import std.sync.*
import std.time.*
import std.convert.*
/** ArkTS 表情网格占位块 id（OverlayGeometry 主动重量用） */
let EMOJI_GRID_SLOT_ID = "cj_emoji_grid_slot"


/** SearchBar 内部 TextInput 的 id，供 FocusControl.requestFocus 定位。 */
public let EMOJI_SEARCH_INPUT_ID: String = "emoji_panel_search_input"

/** 行表分组 key：负数为固定分组，100+ 为 8 个静态分类，正数（非 10x）为自定义表情包 id。 */
let EMOJI_GROUP_RECENT: Int64 = -1
let EMOJI_GROUP_SEARCH_CUSTOM: Int64 = -2
let EMOJI_GROUP_SEARCH_STATIC: Int64 = -3
let EMOJI_GROUP_TRENDING: Int64 = -4
/**
 * iOS 的静态 Emoji 是**一个** group（groupId "static"）+ 8 个 subgroupId，
 * 面板上只有一个 "EMOJI" 标题。此前这里做成了 8 个独立分组、8 个标题，
 * 是还原度上的错误，lldb 读 iOS 图层树时才确认（只有 3 个 GroupHeaderLayer）。
 */
let EMOJI_GROUP_STATIC: Int64 = 100

/**
 * EmojiPicker — Emoji 表情选择器组件（P2-372 完整版）
 *
 * iOS 对应: EmojiPaneNode (submodules/ChatListUI/Sources/EmojiPaneNode.swift)
 *
 * 功能：
 *   1. emoji 搜索框 — 按关键词筛选当前分类的 emoji
 *   2. recent 真持久 — 通过 EmojiRecentService + Preferences 持久化，非硬编码
 *   3. 分类动态 — sticky 分类头 + 侧边索引（8 个分类）
 *   4. premium/custom-emoji 入口 — Premium 标志位，UI 占位
 *
 * 仓颉规则遵守：
 *   - S-005: build() 内无 let/var（提取到 private func）
 *   - R-107: @Builder 和 ForEach 内无 let/var
 *   - S-001: @State 写在 launch{} 内（远程调用回调路径）
 *   - R-112: enum public + operator==
 *
 * 调用链:
 *   EmojiPicker → EmojiRecentService.getRecentEmojis() (Preferences 持久化)
 *   EmojiPicker → EmojiRecentService.recordUsed(emoji) (spawn 异步写)
 */
/** Phase1：表情网格交给 ArkTS 覆盖层（ImageAnimator 帧动画，系统驱动零逐帧开销）。 */
let USE_ARKTS_EMOJI_GRID: Bool = true

func jsonEscape(v: String): String {
    var out = ""
    for (ch in v.runes()) {
        if (ch == r'"') { out = out + "\\\"" }
        else if (ch == r'\\') { out = out + "\\\\" }
        else { out = out + "${ch}" }
    }
    return out
}

func optLenVp(v: ?Length): Float64 {
    match (v) {
        case Some(l) => l.value
        case None => 0.0
    }
}

@Component
public class EmojiPicker {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    /** 内容区高度（vp）：由宿主按真实 IME 高度注入（总高 - 页签行 - 手势带）。 */
    var contentHeightVp: Float64 = 287.0
    // ===== 外部回调 =====
    var peerType: String = ""
    var peerId: Int64 = 0
    var onSelectEmoji: (String) -> Unit = { _emoji: String => }
    var onSelectCustomEmoji: (StickerItem) -> Unit = { _emoji: StickerItem => }
    var onClose: () -> Unit = { => }
    /** 搜索框聚焦态回报宿主：宿主据此切换 IME 共存的紧凑面板（iOS 复刻）。 */
    var onSearchActiveChanged: (Bool) -> Unit = { _active: Bool => }
    var initialContentOffset: Float64 = 0.0
    var onContentOffsetChanged: (Float64) -> Unit = { _value: Float64 => }

    // ===== 内部状态 =====
    @State var selectedCategory: Int64 = 0
    @State var searchText: String = ""
    @State var recentEmojis: Array<String> = Array<String>(0, repeat: "")
    @State var recentCustomEmojis: Array<StickerItem> =
        Array<StickerItem>(0, repeat: StickerItem())
    @State var emojiKeywords: Array<EmojiKeywordEntry> =
        Array<EmojiKeywordEntry>(0, repeat: EmojiKeywordEntry())
    @State var isLoadingRecent: Bool = false
    @State var installedEmojiPacks: Array<StickerPackInfo> =
        Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    @State var installedEmojiDetails: Array<StickerPackDetail> =
        Array<StickerPackDetail>(0, repeat: StickerPackDetail())
    @State var featuredEmojiPacks: Array<StickerPackInfo> =
        Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    @State var emojiSearchCategories: Array<EmojiGroupInfo> =
        Array<EmojiGroupInfo>(0, repeat: EmojiGroupInfo())
    @State var selectedCustomPackId: Int64 = 0
    @State var selectedSearchCategoryId: Int64 = 0
    @State var installingEmojiPackId: Int64 = 0
    @State var hasPeerSpecificEmojiPack: Bool = false
    @State var peerSpecificEmojiPack: StickerPackDetail = StickerPackDetail()
    @State var customSearchItems: Array<StickerItem> =
        Array<StickerItem>(0, repeat: StickerItem())
    @State var customAnimationEpoch: Int64 = 0
    /**
     * 自定义表情的 RPC 还在飞。用来区分「还没搜完」和「确实没有」——
     * iOS 的 EmojiSearchStatusComponent 也是这两态分开
     *（search / progress / results），空态提示只在后者出现。
     */
    @State var searchInFlight: Bool = false
    /**
     * 搜索图标是否处于「返回箭头」态。必须是裸 @State：SearchBar 的 backArrow 是
     * @Prop，调用点传表达式时父组件 build() 虽会重算，但按本工程 D-125 约定统一
     * 传裸字段，避免再踩一次「值没推下去」。
     */
    @State var searchShowsBack: Bool = false
    /** iOS dismissedTrendingEmojiPacks 的本地等价；关掉后当次会话内不再出现。 */
    @State var showTrendingEmoji: Bool = true
    /** 搜索胶囊被点开后才挂真正的输入框（iOS 同样是点开才展开输入态）。 */
    @State var searchInputActive: Bool = false
    /** iOS 对自定义表情同样支持长按 peek 预览；此前只有静态 emoji 有肤色长按。 */
    @State var showEmojiPreview: Bool = false
    @State var previewEmojiItem: StickerItem = StickerItem()
    private var emojiPressActive: Bool = false
    private var emojiPressGeneration: Int64 = 0
    private var suppressNextCustomTap: Bool = false
    /** iOS premiumToastCounter：决定这一次弹哪条文案（逢偶数推 Saved Messages）。 */
    private var premiumToastCounter: Int64 = 0
    @State var variantPopupVisible: Bool = false
    @State var variantEmoji: String = ""
    @State var variantOptions: Array<String> = Array<String>(0, repeat: "")
    private var variantPressActive: Bool = false
    private var variantPressGeneration: Int64 = 0
    private var variantTouchX: Float64 = 0.0
    private var variantTouchY: Float64 = 0.0
    private var suppressNextEmojiTap: Bool = false
    private var emojiSnapshotListenerId: Int64 = -1
    private var emojiLifecycleGeneration: Int64 = 0
    private var customSearchGeneration: Int64 = 0
    private var customAnimationTimer: Option<Timer> = None
    /**
     * iOS 记住每个 emoji 上次选过的肤色并直接以该肤色呈现。
     * 用普通字段 + 变更后 rebuildRows 触发重建，避免 HashMap 当 @State 的刷新语义不确定。
     */
    private var skinTones: HashMap<String, String> = HashMap<String, String>()
    /** 已展开的折叠分组（iOS expandedGroupIds）。 */
    private var expandedGroups: ArrayList<Int64> = ArrayList<Int64>()
    /** 已经发过 getStickerSet 的精选包，避免滚动时反复请求。 */
    private let contentScroller: Scroller = Scroller()
    /**
     * 顶部包导航自己的 Scroller。iOS 在 activeContentItemId 变化时会把高亮项
     * 滚进可视区（EntityKeyboardTopPanelComponent.swift:2156）；没有它的话，
     * 内容滚到远处的包，导航高亮就停在屏幕外，用户看不到自己在哪一组。
     */
    private let topPanelScroller: Scroller = Scroller()
    // 唯一布局真相，见 EntityKeyboardLayout.cj（iOS ItemLayout 移植）。
    // 静态目录有 1519 枚 Emoji，全量 ForEach 会一次性建出 1519 个 Text 节点，
    // 是此前面板卡顿/闪退的主因；改为 List + LazyForEach 只建可见行。
    private let rowSource: KeyboardRowSource = KeyboardRowSource()
    // isEmbedded 行（trending）的独立数据源——那一行必须虚拟化，见 KeyboardCellSource。
    private let embeddedSource: KeyboardCellSource = KeyboardCellSource()
    private var contentWidth: Float64 = 360.0

    protected override func aboutToAppear(): Unit {
        this.panelAlive = true
        if (USE_ARKTS_EMOJI_GRID) {
            registerOverlayRemeasure("emojiGrid", { => this.remeasureGridSlot() })
        }
        this.panelStreamEpoch = getKeyboardFrameClock().bumpKeyboardEpoch()
        if (this.emojiSnapshotListenerId >= 0) {
            getEntityKeyboardStore().unsubscribeEmojiSnapshot(this.emojiSnapshotListenerId)
            this.emojiSnapshotListenerId = -1
        }
        this.emojiLifecycleGeneration = this.emojiLifecycleGeneration + 1
        let lifecycle = this.emojiLifecycleGeneration
        // 心跳必须在代际推进**之后**启动：此前挂在 aboutToAppear 开头，
        // 捕获的旧代际被本函数随后的 +1 立刻作废，首拍守卫即失败退出 ——
        // 真机整段滚动只有 1 次 drive、精选区一遍冻屏的根因。
        this.startCellDriveHeartbeat(lifecycle)
        if (USE_ARKTS_EMOJI_GRID) {
            setEmojiGridProviders(
                Some({ => this.cachedRowsJson }),
                Some({ payload: String =>
                    launch {
                        if (this.emojiLifecycleGeneration == lifecycle) {
                            this.handleArkGridEvent(payload)
                        }
                    }
                }))
        }
        let store = getEntityKeyboardStore()
        store.actualizeEmojiKeyboard()
        this.applyEmojiSnapshot(store.currentEmojiSnapshot())
        this.emojiSnapshotListenerId = store.subscribeEmojiSnapshot({ snapshot: EmojiKeyboardSnapshot =>
            launch {
                if (this.emojiLifecycleGeneration == lifecycle) {
                    this.applyEmojiSnapshot(snapshot)
                }
            }
        })
        this.loadRecentEmojis()
        this.loadRecentCustomEmojis()
        this.loadEmojiKeywords()
        this.loadSkinTones()
        this.loadTrendingDismissed()
        let restoreOffset = this.initialContentOffset
        if (restoreOffset > 0.0) {
            let _ = spawn {
                sleep(Duration.millisecond * 16)
                launch {
                    this.contentScroller.scrollTo(
                        xOffset: 0.0, yOffset: restoreOffset, animation: false)
                }
            }
        }
    }

    protected override func aboutToDisappear(): Unit {
        this.panelAlive = false
        if (USE_ARKTS_EMOJI_GRID) {
            unregisterOverlayRemeasure("emojiGrid")
            this.pushArkGridUpdate(false)
            setEmojiGridProviders(None, None)
        }
        this.compositorOn = false
        this.canvasModel.active = false
        // 收割**本代**播放流（R-146：格子收不到销毁回调，不收割就是僵尸；
        // 只割自己这一代——重建面板时旧实例的 disappear 晚于新实例挂载）。
        getKeyboardFrameClock().stopKeyboardStreams(this.panelStreamEpoch)
        this.emojiLifecycleGeneration = this.emojiLifecycleGeneration + 1
        this.customSearchGeneration = this.customSearchGeneration + 1
        if (this.emojiSnapshotListenerId >= 0) {
            getEntityKeyboardStore().unsubscribeEmojiSnapshot(this.emojiSnapshotListenerId)
            this.emojiSnapshotListenerId = -1
        }
        this.stopCustomEmojiAnimationClock()
    }

    // ===== 数据加载 =====

    private func loadRecentEmojis() {
        this.isLoadingRecent = true
        let _ = spawn {
            let svc = getEmojiRecentService()
            let recent = svc.getRecentEmojis()
            launch {
                this.isLoadingRecent = false
                let tmp: Array<String> = recent
                this.recentEmojis = tmp
                this.rebuildRows()
            }
        }
    }

    private func loadRecentCustomEmojis(): Unit {
        let lifecycle = this.emojiLifecycleGeneration
        let _ = spawn {
            let values = getEmojiRecentService().getRecentCustomEmoji()
            launch {
                if (this.emojiLifecycleGeneration == lifecycle) {
                    this.recentCustomEmojis = values
                    this.rebuildRows()
                    if (!values.isEmpty()) { this.startCustomEmojiAnimationClock() }
                }
            }
        }
    }

    private func loadSkinTones(): Unit {
        let lifecycle = this.emojiLifecycleGeneration
        let _ = spawn {
            let values = getEmojiRecentService().getSkinTones()
            launch {
                if (this.emojiLifecycleGeneration == lifecycle) {
                    this.skinTones = values
                    this.rebuildRows()
                }
            }
        }
    }

    private func loadTrendingDismissed(): Unit {
        let lifecycle = this.emojiLifecycleGeneration
        let _ = spawn {
            let dismissed = getEmojiRecentService().isTrendingDismissed()
            launch {
                if (this.emojiLifecycleGeneration == lifecycle && dismissed) {
                    this.showTrendingEmoji = false
                    this.rebuildRows()
                }
            }
        }
    }

    /** 有记录过肤色就用记录的那个字形，否则用基础字形。 */
    private func displayEmoji(base: String): String {
        if (this.skinTones.contains(base)) { return this.skinTones[base] }
        return base
    }

    private var featuredDetailPrefetchStarted: Bool = false
    // ---- 拉模式中央驱动（iOS 可见性驱动的对位，见 KeyboardCellRegistry 注释）----
    private var visibleFirstRow: Int64 = 0
    private var visibleLastRow: Int64 = 0
    private var cellDriveGeneration: Int64 = 0
    // ---- XComponent 原生合成器（emoji_grid_compositor.cpp）----
    // 网格 List 的全局区域（px），onAreaChange 维护；合成器视口/格子坐标由此换算。
    /** 已交给 Canvas 合成器的 doc（其格子被透明帧挖洞）。 */
    private let compositorDocs: HashSet<Int64> = HashSet<Int64>()
    private let canvasModel: EmojiGridCanvasModel = EmojiGridCanvasModel()
    @State var compositorOn: Bool = false
    /** 格子重生代际：行键的盐。跳转/孤儿检测时 +1 并重载行表，强制 ArkUI
     *  重建可见格子（重建 → aboutToAppear → 重新订阅），闭合瞬时跳转下
     *  复用格子零回调、零订阅、永不自愈的洞（真机 60s 实锤）。 */
    private var cellRebirthGeneration: Int64 = 0
    private var lastRebirthAtMs: Int64 = 0
    /** 连续孤儿超标的 drive 计数：重生是重炮（整窗行重建=一次可见闪烁），
     *  只在连续 3 拍确认后才放，且至少间隔 10s —— 此前 3s 循环触发
     *  就是「表情框频繁闪烁」的直接来源。 */
    private var orphanStreak: Int64 = 0
    /** 瞬时跳转后 currentOffset 陈旧、且 rebuildRows 会让行下标漂移
     *（真机对账实锤：记下标的强制窗在明细到达后驱动的是漂移前的影子行）。
     *  记**分组 key**，每次驱动现算下标；真实滚动事件解除。 */
    /** 最近一次 onScrollIndex 的时间与「事件行-前缀行」校准偏差。
     *  前缀和几何与真实渲染存在累计漂移（真机：rawY 同值下事件 224 vs
     *  前缀 210，越深越歪）；事件新鲜时以事件为准并校准偏差，
     *  事件静默期用 前缀行+偏差 兜底。 */
    private var lastScrollEventAtMs: Int64 = 0
    private var rowBias: Int64 = 0
    private var gridGlobalXPx: Float64 = 0.0
    private var gridGlobalYPx: Float64 = 0.0
    private var gridWidthPx: Float64 = 0.0
    private var gridHeightPx: Float64 = 0.0

    /** Canvas 合成器活跃时网格转透明（帧从垫底 Canvas 透出）。 */
    private func gridBackgroundColor(): Color {
        if (this.compositorOn) { return Color.Transparent }
        return Color(0xFFF1F3F5)
    }

    private func vp2pxF(v: Float64): Float64 {
        match (this.getUIContext().vp2px(v.vp)) {
            case Some(l) => l.value
            case None => v * 3.0
        }
    }

    /**
     * 把当前视口内、播放池已出帧的自定义表情格子交给 Canvas 合成器：
     * 覆盖件每 33ms 用池的 lastFrames 单次重绘全部格子（一次提交替代
     * N 次组件更新）。未出帧的 doc 留在逐格路径上，出帧后下一次 drive 接管。
     * 坐标为网格 Stack 局部 vp（Canvas 垫在 List 之下同一 Stack 内）。
     */
    private func pushCompositorFrame(): Unit {
        let rows = this.rowSource.currentRows()
        var scrollY = 0.0
        let cur = this.contentScroller.currentOffset()
        if (cur.isSome()) { scrollY = cur.getOrThrow().yOffset }
        let listHVp = this.contentHeightVp
        let pool = getKeyboardDocPlayback()
        let cells = ArrayList<EmojiGridCanvasCell>()
        var rowTop = 0.0
        var index: Int64 = 0
        while (index < Int64(rows.size)) {
            let row = rows[index]
            if (rowTop > scrollY + listHVp) { break }
            if (row.kind == KEYBOARD_ROW_ITEMS && !row.embedded &&
                rowTop + row.height > scrollY) {
                let glyph = row.glyphSize()
                let pad = (row.itemSize - glyph) / 2.0
                var col: Int64 = 0
                for (cell in row.cells) {
                    if (cell.item.documentId != 0 && cell.item.isCustomEmoji &&
                        pool.lastFrameFor(cell.item.documentId).isSome()) {
                        let xVp = row.sideInset + Float64(col) * (row.itemSize + row.horizontalSpacing) + pad
                        let yVp = rowTop - scrollY + pad
                        cells.add(EmojiGridCanvasCell(cell.item.documentId, xVp, yVp, glyph))
                    }
                    col = col + 1
                }
            }
            rowTop = rowTop + row.height
            index = index + 1
        }
        // Canvas 合成器停用：Canvas 与 XComponent 在本混合管线同属
        // 「悬浮不透明独立层」（整块盖在面板上、未画区域黑屏、z 序无关，
        // 真机三轮实锤），布局内嵌入均不可行。帧上屏回归逐格路径 ——
        // 解码侧已根治（op=1 修补 + seen 防毒化 + LRU 像素预算），
        // 负载分档（>56 流 20fps）兜住 UI 线程。
        this.canvasModel.cells = ArrayList<EmojiGridCanvasCell>()
        this.canvasModel.active = false
        this.compositorOn = false
        Hilog.info(0, "CjTelegram",
            "[Compositor] canvas cells=${cells.size} delegated=${this.compositorDocs.size}")
        this.compositorDocs.clear()
        getKeyboardDocPlayback().setCanvasDelegated(ArrayList<Int64>())
    }

    // ==================== ArkTS 网格桥（Phase1） ====================

    /** UI 线程预生成的行表 JSON 快照：provider 在 JS 线程被调，
     *  绝不能跨线程碰 rowSource/组件状态（S-001），只读这份不可变字符串。 */
    private var cachedRowsJson: String = ""

    /** 全量行表 → JSON（ArkTS 覆盖层拉取）。docId 用字符串（JS i64 精度）。
     *  纯数据入参 + StringBuilder：此前用组件方法在 UI 线程逐段 `+` 拼 195KB，
     *  O(n²) 拷贝直接把 UI 线程冻 3 秒被看门狗击杀（THREAD_BLOCK_3S 真机实锤）。
     *  现在 rebuildRows 抓快照后丢后台线程构建。 */
    private static func buildRowsJson(
        rows: Array<KeyboardRow>, filesDir: String, premium: Bool): String {
        let sb = StringBuilder()
        sb.append("{\"rows\":[")
        var ri: Int64 = 0
        while (ri < Int64(rows.size)) {
            let row = rows[ri]
            if (ri > 0) { sb.append(",") }
            sb.append("{\"kind\":${row.kind},\"key\":\"${jsonEscape(row.key)}\",")
            sb.append("\"group\":\"${row.groupKey}\",\"title\":\"${jsonEscape(row.title)}\",")
            sb.append("\"sub\":\"${jsonEscape(row.subtitle)}\",\"badge\":\"${jsonEscape(row.badge)}\",")
            sb.append("\"clear\":\"${jsonEscape(row.clearAction)}\",")
            sb.append("\"locked\":${row.actionLocked},\"embedded\":${row.embedded},")
            sb.append("\"h\":${row.height},\"item\":${row.itemSize},\"hsp\":${row.horizontalSpacing},")
            sb.append("\"inset\":${row.sideInset},\"cells\":[")
            var ci: Int64 = 0
            for (cell in row.cells) {
                if (ci > 0) { sb.append(",") }
                let doc = cell.item.documentId
                var cache = ""
                var stat = ""
                if (doc != 0 && !filesDir.isEmpty()) {
                    // 路径无条件下发（不做存在性探测）：文件缺失时 ArkTS 侧
                    // 打开失败会发 need|doc 请求补建，随后按路径重试升格 ——
                    // 存在性探测既慢（每次全量重建 300+ 次 access），又会把
                    // 「构建完成后升格」永久卡死在下一次 rebuildRows。
                    cache = filesDir + "/anim_cache/doc${doc}@84.acv3"
                    stat = filesDir + "/static_frames/doc${doc}@84#representative.bgra"
                }
                let locked = doc != 0 && cell.item.isCustomEmoji &&
                    !cell.item.isFreeEmoji && !premium
                sb.append("{\"doc\":\"${doc}\",\"tint\":${cell.item.supportsTextColor},\"e\":\"${jsonEscape(cell.emoji)}\",")
                sb.append("\"x\":\"${jsonEscape(cell.expandLabel)}\",")
                sb.append("\"lock\":${locked},")
                sb.append("\"cache\":\"${jsonEscape(cache)}\",\"static\":\"${jsonEscape(stat)}\"}")
                ci = ci + 1
            }
            sb.append("]}")
            ri = ri + 1
        }
        sb.append("]}")
        return sb.toString()
    }

    /** ArkTS 事件（管道分隔避免 JSON 解析）："cell|docId|emoji" / "button|group" /
     *  "expand|group" / "top|group"。JS 线程进来，launch 回 UI。 */
    private func handleArkGridEvent(payload: String): Unit {
        let parts = payload.split("|")
        if (parts.size == 0) { return }
        let kind = parts[0]
        if (kind == "cell" && parts.size >= 3) {
            let docId = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            let emoji = parts[2]
            if (docId != 0) {
                var found = StickerItem()
                for (row in this.rowSource.currentRows()) {
                    for (cell in row.cells) {
                        if (cell.item.documentId == docId) { found = cell.item }
                    }
                }
                if (found.documentId != 0) { this.selectCustomEmoji(found) }
            } else if (emoji.size > 0) {
                this.onSelectEmoji(emoji)
            }
        } else if (kind == "button" && parts.size >= 2) {
            let group = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            if (!this.hasPremiumHere()) {
                routerPush("PremiumDemoPage", "animatedEmoji")
            } else if (group != 0) {
                this.installEmojiPackById(group)
            }
        } else if (kind == "expand" && parts.size >= 2) {
            let group = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            if (group != 0) { this.expandGroup(group) }
        } else if (kind == "clear" && parts.size >= 2) {
            this.handleHeaderClear(parts[1])
        } else if (kind == "need" && parts.size >= 2) {
            // ArkTS 格子打不开 .acv3：下载源文件并紧急排队构建帧缓存。
            // ArkTS 侧随后按路径退避重试，文件落盘即自动升格为动画。
            let docId = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let lastMs = this.arkNeedRequested.get(docId) ?? 0
            if (docId != 0 && nowMs - lastMs > 20_000) {
                this.arkNeedRequested[docId] = nowMs
                if (CHAIN_TRACE_LOGS) {
                    Hilog.info(0, "CjTelegram", "[ChainTrace] need-recv emoji doc=${docId}")
                }
                var found = StickerItem()
                for (row in this.rowSource.currentRows()) {
                    for (cell in row.cells) {
                        if (cell.item.documentId == docId) { found = cell.item }
                    }
                }
                if (found.documentId != 0) {
                    let item = found
                    // 走有界调度器的插队道，绝不裸 spawn：整页 ~100 个 need 同时
                    // 开下载会把串行 MTProto 队列塞死几分钟，后续 searchCustomEmoji
                    // RPC 排不上号 ——「第二次点分类没反应」的根因。插队道让最新
                    // 可见格先服务，滚走的旧任务沉底。
                    let _ = getKeyboardMediaScheduler().submitUrgent {
                        let path = ensureStickerLocalFile(item)
                        if (path.size > 0) {
                            let video = item.mimeType.contains("webm")
                            // 先解一张代表帧落盘（亚秒级）：ArkTS 格子的退避重试
                            // 立刻能捡到静帧上屏 —— 搜索结果 doc 从未见过，
                            // 只排全量构建的话串行队列要按分钟计，页面整片 🔒
                            //（「custom emoji 页面加载特别慢」的根因）。
                            requestAnimationCacheBuild(
                                item.documentId, path, video, 84, urgent: true)
                            // 静帧渲染移出 urgent 道（渲染闸会被 live 流卡住，见贴纸面板同注）
                            let _ = getKeyboardMediaScheduler().submit {
                                let _ = loadStickerStaticFrame(
                                    item.documentId, path, video, 84, representative: true)
                            }
                        }
                    }
                }
            }
        } else if (kind == "top" && parts.size >= 2) {
            let group = (try { Int64.parse(parts[1]) } catch (_: Exception) { 0 })
            if (group > 0) {
                if (this.selectedCustomPackId != group) {
                    this.selectedCustomPackId = group
                    this.revealPackInTopPanel(group)
                }
            } else {
                if (this.selectedCustomPackId != 0) { this.selectedCustomPackId = 0 }
            }
        }
    }

    /** 数据代际：只在行表 JSON 真变了才 +1（ArkTS @Watch gen → 整表 reload，
     *  跳转/几何推送不能背这个开销）。 */
    private var arkGridGeneration: Int64 = 0
    /** 导航跳转转发：sr=目标行，ss=跳转序号（ArkTS 侧 @Watch ss 执行一次）。 */
    private var arkScrollRow: Int64 = -1
    private var arkScrollSeq: Int64 = 0
    /** 行表 JSON 后台构建在飞：此时跳转不能抢先推送 —— ArkTS 还持着旧表，
     *  新表行号会落空（从搜索态 23 行切分类跳 700 行表：scrollToIndex 越界
     *  静默 no-op，「点其他类别不跳转」的根因）。跳转参数挂在 sr/ss 上，
     *  由构建完成的那次推送捎带，ArkTS 先 reload 后执行。 */
    private var arkRowsPushInFlight: Bool = false

    /** 跳转统一入口：数据推送在飞就搭车，否则立即推。 */
    private func forwardArkJump(row: Int64): Unit {
        this.arkScrollRow = row
        this.arkScrollSeq = this.arkScrollSeq + 1
        if (!this.arkRowsPushInFlight) { this.pushArkGridUpdate(true) }
    }
    /** 已请求补建 .acv3 的 doc（进程内去重；builder 自带队列级去重）。 */
    /** need 补建限频（doc → 上次受理 ms），同贴纸面板：不永久去重。 */
    private let arkNeedRequested: HashMap<Int64, Int64> = HashMap<Int64, Int64>()

    /** 同 StickerKeyboardPanel.panelAlive：关闭后迟到的异步推送不得复活覆盖层。 */
    private var panelAlive: Bool = false

    /**
     * 主动按当前布局重量占位块并推送（OverlayGeometry 通道）。
     * onAreaChange 在“键盘收起、面板整体下移”时不会再触发，这里补上。
     */
    private func remeasureGridSlot(): Unit {
        if (!USE_ARKTS_EMOJI_GRID || !this.panelAlive) { return }
        match (measureOverlaySlot(EMOJI_GRID_SLOT_ID)) {
            case Some(r) =>
                let changed = r.x != this.gridGlobalXPx || r.y != this.gridGlobalYPx ||
                    r.w != this.gridWidthPx || r.h != this.gridHeightPx
                this.gridGlobalXPx = r.x
                this.gridGlobalYPx = r.y
                this.gridWidthPx = r.w
                this.gridHeightPx = r.h
                if (changed) { this.pushArkGridUpdate(true) }
            case None => ()
        }
    }

    private func pushArkGridUpdate(visible: Bool): Unit {
        if (!USE_ARKTS_EMOJI_GRID) { return }
        let show = visible && this.panelAlive
        let payload = "{\"visible\":${show},\"x\":${Int64(this.gridGlobalXPx)}," +
            "\"y\":${Int64(this.gridGlobalYPx)},\"w\":${Int64(this.gridWidthPx)}," +
            "\"h\":${Int64(this.gridHeightPx)},\"gen\":${this.arkGridGeneration}," +
            "\"sr\":${this.arkScrollRow},\"ss\":${this.arkScrollSeq}}"
        Hilog.info(0, "CjTelegram", "[ArkGrid] push ${payload}")
        callArk("emojiGrid.update", payload)
    }

    private func deactivateCanvasCompositor(): Unit {
        if (!this.compositorOn) { return }
        this.compositorOn = false
        this.canvasModel.active = false
        getKeyboardDocPlayback().setCanvasDelegated(ArrayList<Int64>())
        let restoreList = ArrayList<Int64>()
        for (d in this.compositorDocs) { restoreList.add(d) }
        getKeyboardDocPlayback().restoreDocs(restoreList)
        this.compositorDocs.clear()
    }

    private func rebirthVisibleCells(reason: String): Unit {
        let now = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (now - this.lastRebirthAtMs < 10000) { return }
        this.lastRebirthAtMs = now
        this.cellRebirthGeneration = this.cellRebirthGeneration + 1
        Hilog.info(0, "CjTelegram",
            "[EmojiPicker] cell rebirth gen=${this.cellRebirthGeneration} reason=${reason}")
        // 同一行表重载：LazyForEach 重估 keyGenerator，含盐键变化 → 可见行重建。
        this.rowSource.setRows(this.rowSource.currentRows())
        this.scheduleCellDrive()
    }

    /** 滚动/重建后 600ms 稳定期集中驱动一次（新事件重置计时）。 */
    private func scheduleCellDrive(): Unit {
        this.cellDriveGeneration = this.cellDriveGeneration + 1
        let token = this.cellDriveGeneration
        let _ = spawn {
            sleep(Duration.millisecond * 300)
            launch {
                if (this.cellDriveGeneration == token) { this.driveVisibleCells() }
            }
        }
    }

    /**
     * 驱动心跳：面板存活期每 1.2s 无条件对账一次可见集。
     * 本版本 ArkUI 的回调（onScrollIndex / onScrollStop / 可见性 / 生命周期）
     * 没有一个在全部场景可靠（真机取证：二遍滚动 onScrollIndex 全程静默），
     * 事件只作加速器，心跳才是正确性来源。集合不变时 drive 是纯 set 对账，
     * 开销可忽略。
     */
    private func startCellDriveHeartbeat(lifecycle: Int64): Unit {
        let _ = spawn {
            while (true) {
                sleep(Duration.millisecond * 1200)
                var alive = true
                launch {
                    if (this.emojiLifecycleGeneration == lifecycle) {
                        this.driveVisibleCells()
                    }
                }
                // 面板销毁后（代际前进）下一轮退出：读值在 launch 里做过即可，
                // 这里再补一层退出检查避免永生协程。
                if (this.emojiLifecycleGeneration != lifecycle) { alive = false }
                if (!alive) { break }
            }
        }
    }

    /**
     * 由 Scroller 实测偏移反算首个可见行 —— onScrollIndex 在本版本 ArkUI
     * 不可靠（真机实锤有整段滚动全程静默），事件值只当缓存，驱动时以
     * currentOffset 为准重算。行表自带每行高度，前缀和即得。
     */
    private func firstRowAtOffset(rows: Array<KeyboardRow>): Int64 {
        // 「强制窗」两版（记下标/记 groupKey）均被真机对账否决：
        // scrollToIndex 在懒列表上落点有偏差（目标 210 实落 224），
        // 而 currentOffset 与 onScrollIndex 事件一致且正确 —— 纯偏移即真相。
        if (rows.isEmpty()) { return 0 }
        let current = this.contentScroller.currentOffset()
        if (current.isNone()) { return this.visibleFirstRow }
        let target = current.getOrThrow().yOffset
        if (target <= 0.0) { return 0 }
        var acc = 0.0
        var index: Int64 = 0
        while (index < Int64(rows.size)) {
            acc = acc + rows[index].height
            if (acc > target) { return index }
            index = index + 1
        }
        return Int64(rows.size) - 1
    }

    private func driveVisibleCells(): Unit {
        // 滚动中不对账：起停在飞驰而过的行上churn出的解码积压，会让停稳后的
        // 真可见格 3 秒内都出不了帧（真机：drive 全对但落点冻屏、导航掉速）。
        // 停稳后心跳 ≤1.2s 必然补驱。
        if (isKeyboardGridScrolling()) { return }
        let visible = ArrayList<Int64>()
        let seenDocs = HashSet<Int64>()
        let rows = this.rowSource.currentRows()
        // 空行表是合法瞬态（分类搜索请求在飞、快照重建间隙）：此时
        // firstRowAtOffset 会算出 size-1 = -1，后续下标直接越界杀进程
        //（真机实锤：点搜索分类 chip 300ms 后 IndexOutOfBounds 闪退）。
        if (rows.isEmpty()) { return }
        // 事件窗（onScrollIndex，有时整段静默）与偏移窗（currentOffset 反算，
        // List 顶部若有行表外内容会整窗漂移）都不完全可信 —— 各驱各的窗，
        // 集合按 doc 去重：多驱动几行只是多几条流，漏驱动才是冻屏。
        //（教训：跨窗 min/max 再封顶会在事件窗陈旧为 0 时把整窗钉死在顶部。）
        let prefixRow = this.firstRowAtOffset(rows)
        var offsetRow = prefixRow
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (nowMs - this.lastScrollEventAtMs < 2000) {
            offsetRow = this.visibleFirstRow
            this.rowBias = this.visibleFirstRow - prefixRow
        } else {
            offsetRow = prefixRow + this.rowBias
        }
        // 两个分支都夹：行表刚缩短时事件值可能越界
        if (offsetRow < 0) { offsetRow = 0 }
        if (offsetRow >= Int64(rows.size)) { offsetRow = Int64(rows.size) - 1 }
        // 导航条封面**先**入集合：起播按插入序消费，iOS 的
        // 顶栏是永动区，不排在网格后面。
        // 导航条封面：条会自动滚到**活跃包**附近（iOS EntityKeyboardTopPanel
        // 同步高亮），屏上可见的是活跃位 ±8 —— 驱动这一窗而非列表开头
        //（开头 cap16 版真机实锤：条上画的全是深处封面，一个都没驱动，全静止）。
        let navPacks = ArrayList<StickerPackInfo>()
        for (pack in this.installedEmojiPacks) { navPacks.add(pack) }
        for (pack in this.featuredNavigationEmojiPacks()) { navPacks.add(pack) }
        // 活跃包直接取偏移窗首行的 groupKey（行表即真相）；
        // selectedCustomPackId 走事件更新，静默滚动时滞后半屏。
        var activePackId: Int64 = this.selectedCustomPackId
        if (offsetRow >= 0 && offsetRow < Int64(rows.size) && rows[offsetRow].groupKey > 0) {
            activePackId = rows[offsetRow].groupKey
        }
        var activeIndex: Int64 = 0
        if (activePackId != 0) {
            var scan: Int64 = 0
            while (scan < navPacks.size) {
                if (navPacks[scan].id == activePackId) {
                    activeIndex = scan
                    break
                }
                scan = scan + 1
            }
        }
        var navFrom = activeIndex - 8
        if (navFrom < 0) { navFrom = 0 }
        var navTo = navFrom + 16
        if (navTo > navPacks.size) { navTo = navPacks.size }
        var navAt = navFrom
        while (navAt < navTo) {
            let cover = this.customPackCoverId(navPacks[navAt])
            if (cover != 0 && seenDocs.add(cover)) { visible.add(cover) }
            navAt = navAt + 1
        }
        // 只用偏移窗：currentOffset 反算经真机漏斗验证与事件值一致（off≈ev），
        // 而并入事件窗会把需求集推过播放槽上限（146>96，startwait=50，
        // 可见格反而拿不到槽 —— 一遍冻屏的直接原因）。offsetRow 已在上方算出。
        let starts = ArrayList<Int64>()
        starts.add(offsetRow)
        // ArkTS 网格接管后（Phase1），网格帧由 ImageAnimator 播放，
        // 仓颉播放池只需供导航条封面 —— 双管线齐跑是「非常卡」的直接来源。
        if (!USE_ARKTS_EMOJI_GRID) {
            for (startRow in starts) {
                var index = startRow
                var lastRow = startRow + 7
                if (lastRow >= Int64(rows.size)) { lastRow = Int64(rows.size) - 1 }
                while (index <= lastRow && index >= 0) {
                    for (cell in rows[index].cells) {
                        if (cell.item.documentId != 0 && seenDocs.add(cell.item.documentId)) {
                            visible.add(cell.item.documentId)
                        }
                    }
                    index = index + 1
                }
            }
        }
        var gridSample = ""
        var gs: Int64 = 0
        var scanRow = offsetRow
        while (scanRow < Int64(rows.size) && gs < 3) {
            if (rows[scanRow].kind == KEYBOARD_ROW_ITEMS && !rows[scanRow].embedded) {
                for (cell in rows[scanRow].cells) {
                    if (gs >= 3) { break }
                    if (cell.item.documentId != 0) {
                        gridSample = gridSample + "${cell.item.documentId},"
                        gs = gs + 1
                    }
                }
            }
            scanRow = scanRow + 1
        }
        var rawOffset = -1.0
        let curOff = this.contentScroller.currentOffset()
        if (curOff.isSome()) { rawOffset = curOff.getOrThrow().yOffset }
        Hilog.info(0, "CjTelegram",
            "[EmojiDrive] off=${offsetRow} rawY=${Int64(rawOffset)} ev=${this.visibleFirstRow} rows=${rows.size} total=${visible.size} gridSample=${gridSample}")
        let pool = getKeyboardDocPlayback()
        pool.driveVisible(visible)
        // 孤儿自愈（最后防线）：连续 3 拍大量流在跑却无人订阅才重生。
        if (pool.lastOrphanCount > 8) {
            this.orphanStreak = this.orphanStreak + 1
            if (this.orphanStreak >= 3) {
                this.orphanStreak = 0
                this.rebirthVisibleCells("orphans=${pool.lastOrphanCount}")
            }
        } else {
            this.orphanStreak = 0
        }
        this.pushCompositorFrame()
    }
    /** 本面板实例的键盘流代际（挂载时领取）。 */
    private var panelStreamEpoch: Int64 = 0

    /**
     * 精选包明细的**一次性**后台预取 —— 与被删掉的 ensurePackDetailLoaded 的
     * 本质区别：不由滚动触发、每会话只跑一轮、串行拉取后陆续落 store。
     * 行表的格子级稳定 key 保证陆续到达的明细不会拆毁已在播的格子。
     * 目的：featured 响应里多数包只带 5 个封面，凑不齐 iOS 的三行折叠。
     */
    private func prefetchFeaturedEmojiDetails(): Unit {
        if (this.featuredDetailPrefetchStarted) { return }
        if (this.featuredEmojiPacks.isEmpty()) { return }
        this.featuredDetailPrefetchStarted = true
        let targets = ArrayList<StickerPackInfo>()
        for (pack in this.featuredEmojiPacks) {
            if (Int64(pack.topItems.size) >= 24) { continue }
            if (this.emojiDetailCellsFor(pack.id).size > 0) { continue }
            targets.add(pack)
        }
        if (targets.size == 0) { return }
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let raster = this.featuredCellRaster()
        let allPacks = ArrayList<StickerPackInfo>()
        for (pack in this.featuredEmojiPacks) { allPacks.add(pack) }
        let _ = spawn {
            // 阶段〇：磁盘缓存直出（iOS Postbox 的对位）。命中的包零 RPC；
            // 冷启动面板结构立即完整。
            let cachedDetails = loadFeaturedEmojiDetailsCache()
            let haveIds = HashSet<Int64>()
            for (detail in cachedDetails) { let _ = haveIds.add(detail.info.id) }
            if (!cachedDetails.isEmpty()) {
                store.publishEmojiPackDetails(accountToken, cachedDetails)
            }
            // 阶段一：只对缓存没有的包发 RPC，拉完一次性批量发布 —— 一包一发
            // 会让订阅方每 1-2 秒 rebuildRows 一次、持续几分钟（静止卡顿 +
            // 导航格子反复拆毁冻死的根源，见 publishEmojiPackDetails 注释）。
            let fetchedDetails = ArrayList<StickerPackDetail>()
            for (pack in targets) {
                if (haveIds.contains(pack.id)) { continue }
                let detail = getStickersService().getStickerSet(pack.id, pack.accessHash)
                if (detail.success) { fetchedDetails.add(detail) }
            }
            if (!fetchedDetails.isEmpty()) {
                store.publishEmojiPackDetails(accountToken, fetchedDetails)
                for (detail in fetchedDetails) { cachedDetails.add(detail) }
                saveFeaturedEmojiDetailsCache(cachedDetails)
            }
            // 阶段二：媒体 + AnimationCache 预取覆盖**全部**精选包 —— 不能只覆盖
            // 本轮新拉明细的（明细自上个会话就持久化的包会被跳过，真机实测
            // 只有屏上兜底请求在建缓存，一轮只出 6 个文件）。
            // 先回 UI 线程取数（@State），再交给**单条**后台协程按包串行处理，
            // 避免每包各起 6 条下载道的并发爆炸。
            launch {
                let batches = ArrayList<StickerPackDetail>()
                for (pack in allPacks) {
                    let cells = this.emojiDetailCellsFor(pack.id)
                    let items = ArrayList<StickerItem>()
                    if (cells.size > 0) {
                        for (cell in cells) {
                            if (items.size >= 24) { break }
                            if (cell.item.documentId != 0) { items.add(cell.item) }
                        }
                    } else {
                        for (item in pack.topItems) {
                            if (items.size >= 24) { break }
                            if (item.documentId != 0 && item.isCustomEmoji) { items.add(item) }
                        }
                    }
                    if (items.size == 0) { continue }
                    let detail = StickerPackDetail()
                    detail.success = true
                    for (item in items) { detail.stickers.add(item) }
                    batches.add(detail)
                }
                let _ = spawn {
                    for (detail in batches) {
                        prefetchEmojiPackMedia(detail, raster)
                    }
                }
            }
        }
    }

    /**
     * 网格标准光栅 = 84（CustomEmojiImage.rasterSize() 的同一常数）。
     * 此前按 contentWidth 推导：预取跑在首帧布局前拿默认 360 → 72，
     * 格子在真实宽度下是 84 —— 缓存键全体错配、缓存 100% 失效。
     */
    private func featuredCellRaster(): Int32 {
        return 84
    }

    private func applyEmojiSnapshot(snapshot: EmojiKeyboardSnapshot): Unit {
        this.installedEmojiPacks = snapshot.installedPacks
        this.installedEmojiDetails = snapshot.installedDetails
        this.featuredEmojiPacks = snapshot.featuredPacks
        this.emojiSearchCategories = snapshot.searchCategories
        match (getEntityKeyboardStore().currentPeerEmojiPack(this.peerType, this.peerId)) {
            case Some(detail) =>
                this.peerSpecificEmojiPack = detail
                this.hasPeerSpecificEmojiPack = true
            case None => this.hasPeerSpecificEmojiPack = false
        }
        // 快照到达去抖聚合（贴纸侧同款风暴治理）；首次立即建避免空窗。
        if (this.rowSource.currentRows().isEmpty()) {
            this.rebuildRows()
        } else {
            this.scheduleEmojiRowsRebuild()
        }
        this.prefetchFeaturedEmojiDetails()
    }

    /** 快照驱动重建的 400ms 尾沿去抖（用户直接动作仍走同步 rebuildRows）。 */
    private var emojiRowsRebuildGeneration: Int64 = 0

    private func scheduleEmojiRowsRebuild(): Unit {
        this.emojiRowsRebuildGeneration = this.emojiRowsRebuildGeneration + 1
        let token = this.emojiRowsRebuildGeneration
        let _ = spawn {
            sleep(Duration.millisecond * 400)
            launch {
                if (this.emojiRowsRebuildGeneration == token) { this.rebuildRows() }
            }
        }
    }

    // ===== 行表（唯一布局真相） =====

    private func makeGroup(key: Int64, title: String, cells: Array<KeyboardCell>): KeyboardGroup {
        let group = KeyboardGroup()
        group.key = key
        group.title = title
        group.cells = cells
        return group
    }

    /** 静态目录：8 个分类拼成一个分组，记录每个分类的起始下标作为 subgroup。 */
    private func staticEmojiGroup(): KeyboardGroup {
        let group = KeyboardGroup()
        group.key = EMOJI_GROUP_STATIC
        group.title = "EMOJI"
        let cells = ArrayList<KeyboardCell>()
        let starts = ArrayList<Int64>()
        var index: Int64 = 0
        while (index < 8) {
            starts.add(cells.size)
            for (cell in cachedEmojiCells(EMOJI_GROUP_STATIC + index, getCategoryEmojis(index))) {
                cells.add(cell)
            }
            index = index + 1
        }
        group.cells = cells.toArray()
        group.subgroupStarts = starts.toArray()
        return group
    }

    /** iOS featuredTop：未安装的精选表情包封面，排在内容最前，可关闭。 */
    /**
     * TRENDING EMOJI 一行 8 格，与 iOS 的 featuredTop 组一致。
     *
     * 数量取决于有多少 featured 包能拿出封面。此前只有 3 格：featured 列表里大量是
     * stickerSetNoCovered#77b15d1c（无 cover document），封面只能从 set 自己的
     * thumb_document_id 取，而那个字段在解析时被读掉就扔了。修在
     * StickersService.parseStickerSetInfo + parseFeaturedStickersResponseFull。
     */
    private func trendingCells(): Array<KeyboardCell> {
        let cells = ArrayList<KeyboardCell>()
        // 不截断：iOS 遍历全部 featuredPacks（EmojiPagerContentSignals.swift:275 起），
        // 靠 isEmbedded 的横向滚动看完。此前截在 8 个，99 个包里 91 个够不着。
        for (pack in this.featuredEmojiPacks) {
            if (this.isEmojiPackInstalled(pack.id)) { continue }
            if (pack.cover.documentId == 0) { continue }
            cells.add(documentCell(pack.cover))
        }
        return cells.toArray()
    }

    private func documentCells(values: Array<StickerItem>): Array<KeyboardCell> {
        let cells = ArrayList<KeyboardCell>()
        for (value in values) {
            cells.add(documentCell(value))
        }
        return cells.toArray()
    }

    /** recent 组同时包含自定义表情与静态 Emoji，与 iOS 的 recent 组一致。 */
    private func recentCells(): Array<KeyboardCell> {
        let cells = ArrayList<KeyboardCell>()
        for (value in this.recentCustomEmojis) {
            cells.add(documentCell(value))
        }
        for (value in this.recentEmojis) {
            cells.add(emojiCell(value))
        }
        return cells.toArray()
    }

    private func searchResultCells(): Array<KeyboardCell> {
        let cells = ArrayList<KeyboardCell>()
        for (value in this.searchAllEmojis(this.searchText)) {
            cells.add(emojiCell(value))
        }
        return cells.toArray()
    }

    /**
     * 搜索态：**静态 Emoji 结果在前**，自定义表情结果在后。
     *
     * iOS 搜 "cat" 直接在搜索栏下方给出 🐱😿😻😸😹😾😺🐈🐈‍⬛。我们原本把 CUSTOM EMOJI
     * 排在前面，这个账号的自定义结果全是 premium 锁定——32 个挂锁把真正有用的静态结果
     * 推到屏外，要下滑四次才看得到。
     *
     * 这与早先 EmojiSuggestionStrip 的那次是同一个错（自定义候选排前面，把静态候选挤到
     * 屏外 9200px）。当时只修了建议条，面板内搜索漏了——**同一类缺陷要在所有出现的地方
     * 一起改**，不能只修当时手上那一处。
     */
    private func searchGroups(): ArrayList<KeyboardGroup> {
        let groups = ArrayList<KeyboardGroup>()
        if (!this.searchText.isEmpty()) {
            groups.add(this.makeGroup(EMOJI_GROUP_SEARCH_STATIC, "SEARCH RESULTS",
                this.searchResultCells()))
        }
        if (!this.customSearchItems.isEmpty()) {
            groups.add(this.makeGroup(EMOJI_GROUP_SEARCH_CUSTOM, "CUSTOM EMOJI",
                this.documentCells(this.customSearchItems)))
        }
        return groups
    }

    /**
     * 常规态：与 iOS emojiInputData 一致的单条连续列表
     * —— recent → peerSpecific → static（8 个分类）→ 已安装自定义表情包。
     * 点分类/包 tab 只做 scroll-to-group，不再整块换页。
     */
    /**
     * 分组顺序与 iOS emojiInputData 一致：
     * featuredTop(TRENDING) → recent → peerSpecific → static → 已安装表情包。
     */
    private func normalGroups(): ArrayList<KeyboardGroup> {
        let groups = ArrayList<KeyboardGroup>()
        if (this.showTrendingEmoji) {
            let trending = this.makeGroup(EMOJI_GROUP_TRENDING, "TRENDING EMOJI",
                this.trendingCells())
            trending.clearAction = "trending"
            trending.isEmbedded = true
            groups.add(trending)
        }
        let recent = this.makeGroup(EMOJI_GROUP_RECENT, "RECENTLY USED", this.recentCells())
        recent.clearAction = "recent"
        // ⚠️ 不折叠。此前这里写 5，注释还声称「iOS 就是 5」——**那个 5 是我从
        // 背景图标选择器分支（EmojiPagerContentSignals.swift:1160，
        // `case .backgroundIcon`）读来的**。聊天键盘的最近使用组在同文件 1262 行，
        // `Emoji_FrequentlyUsed`（文案就是 "Recently Used"），collapsedLineCount 是 **nil**。
        // 折叠成 5 行意味着最近使用超过 40 个就被收进 "+N"，而 iOS 全部展示。
        //
        // 教训：同一个字段在不同 subject 分支里取值不同，抄之前要先确认自己读的是
        // 哪一条路径——聊天键盘的判据是 hasRecentEmoji 那一支。
        groups.add(recent)

        if (this.peerSpecificEmojiPackVisible()) {
            let peerGroup = this.makeGroup(
                this.peerSpecificEmojiPack.info.id,
                this.peerSpecificEmojiPack.info.title,
                this.documentCells(this.peerSpecificEmojiPack.stickers.toArray()))
            // iOS EmojiPagerContentSignals.swift:1310 —— 群组专属表情包的分组头带
            // Emoji.GroupEmoji = "GROUP EMOJI" 角标，用来和普通已装包区分开。
            peerGroup.badge = "GROUP EMOJI"
            groups.add(peerGroup)
        }

        groups.add(this.staticEmojiGroup())

        for (detail in this.installedEmojiDetails) {
            if (!this.isEmojiPackInstalled(detail.info.id)) { continue }
            let group = this.makeGroup(detail.info.id, detail.info.title,
                this.documentCells(detail.stickers.toArray()))
            // iOS 对「已装但账号无 Premium」的包同样给锁定形态
            //（EmojiPagerContentComponent.swift:3241 的 isPremiumLocked && !isFeatured
            // 分支：分组边框 + 整宽 Unlock 按钮 + collapsedLineCount=3）。
            // 此前已装包走普通分组（全量铺开、无按钮），与精选包形态割裂 ——
            // Effect Emoji / Meme Emoji / FlowersFont 三个包就是这么冒出来的。
            if (!this.hasPremiumHere()) {
                group.bottomActionLocked = true
                group.bottomActionTitle = "Unlock ${detail.info.title}"
                group.collapsedLineCount = 3
            }
            groups.add(group)
        }
        for (group in this.featuredEmojiGroups()) { groups.add(group) }
        return groups
    }

    private func emojiDetailCellsFor(packId: Int64): Array<KeyboardCell> {
        for (detail in this.installedEmojiDetails) {
            if (detail.info.id == packId) {
                return this.documentCells(detail.stickers.toArray())
            }
        }
        return Array<KeyboardCell>(0, { _ => KeyboardCell() })
    }

    /**
     * iOS 把未安装的精选表情包作为内容流最后的分组，isFeatured 头 + Add 按钮，
     * 且 collapsedLineCount = 3（超过三行收成末位的 "+N"）。
     * 此前这些包只在顶部导航里出现，点了才换页显示。
     */
    private func featuredEmojiGroups(): ArrayList<KeyboardGroup> {
        let groups = ArrayList<KeyboardGroup>()
        for (pack in this.featuredEmojiPacks) {
            if (this.isEmojiPackInstalled(pack.id)) { continue }
            // **只用 featured 响应自带的 topItems**（stickerSetFullCovered 携带
            // 全部文档）。iOS 的键盘精选组就是这个数据形态：不拉明细、不重建，
            // collapsedLineCount=3 折叠 + "+N" 展开，明细只属于包预览页。
            // 旧链路（滚动中 ensurePackDetailLoaded 逐包拉全量 → 每次返回
            // rebuildRows）是本面板卡顿和格子冻结的主要来源，已整段删除。
            // 过滤掉元数据残缺的项（如旧缓存里的合成封面）：它们渲染出来就是
            // 无锁标、点不动的幽灵格子。
            // 明细已被一次性预取（prefetchFeaturedEmojiDetails）落进 store 的就用
            // 全量（渲染仍被 collapsedLineCount=3 折叠成三行 + "+N"）；没到的先用
            // topItems（多数包只带 5 个封面，这正是「每个主题只有 5 个」的原因 ——
            // iOS 能显示三行是因为它的 featured 明细在 Postbox 里是全的）。
            var cells = this.emojiDetailCellsFor(pack.id)
            if (cells.size == 0) {
                let realItems = ArrayList<StickerItem>()
                for (item in pack.topItems) {
                    if (item.documentId != 0 && item.isCustomEmoji) { realItems.add(item) }
                }
                if (realItems.size == 0) { continue }
                cells = this.documentCells(realItems.toArray())
            }
            let group = KeyboardGroup()
            group.key = pack.id
            group.title = pack.title
            group.subtitle = "${pack.count} emoji"
            // iOS 的 **emoji** 面板不在分组头放小 Add，而是在分组末尾放一条整宽按钮
            //（EmojiPagerContentComponent.swift:3337）。实测是紫蓝渐变的
            // 「Unlock Love Icons 🔒」横跨整个分组宽度。贴纸面板才是头部小按钮。
            // 锁定判据要和格子上的锁图标一致，否则会出现「满屏 🔒 但按钮写 Add」。
            // pack.featuredIsPremium 是 featured 响应的**整体**标志，不反映单个包，
            // 所以改成看这个包自己的内容：首个格子锁着就算整包锁定
            //（与 isPremiumLocked(item) 同一套规则）。
            // 锁定判据用**账号能力**，不用格子内容。
            //
            // 试过两版基于内容的判据，都错：
            //   「首个格子锁着」——"Effect Emoji" 的首个表情恰好免费、其余全锁；
            //   「多数格子锁着」——分组常常是用**一个封面占位**建的（明细还没到），
            //     日志实测 58 次构建里 cells=1，而封面往往就是免费的那个。
            // 两者都会得到「满屏 🔒 但按钮写 Add」。
            // pack.featuredIsPremium 也不行：那是 featured 响应的整体标志，不区分单包。
            //
            // 领域规则更可靠：没有 Premium 的账号**根本不能使用自定义表情**，
            // 所以 emoji 面板里的精选包对非 Premium 用户一律是 Unlock。
            let locked = !this.hasPremiumHere()
            group.bottomActionLocked = locked
            group.bottomActionTitle = if (locked) {
                "Unlock ${pack.title}"
            } else {
                "Add ${pack.title}"
            }
            // iOS 的 **emoji** 面板精选组没有 60vp 大头行（那是贴纸面板的形态），
            // 就是普通灰色组名、标题左侧带 🔒（用户对照 iOS 实锤）。
            group.collapsedLineCount = 3
            group.cells = cells
            groups.add(group)
        }
        return groups
    }

    private func currentGroups(): ArrayList<KeyboardGroup> {
        if (!this.searchText.isEmpty() || this.selectedSearchCategoryId != 0) {
            return this.searchGroups()
        }
        return this.normalGroups()
    }

    /** 有查询词、查询已结束、且一条结果都没有。 */
    private func searchNoResults(): Bool {
        if (this.searchText.isEmpty()) { return false }
        if (this.searchInFlight) { return false }
        return this.rowSource.totalCount() == 0
    }

    @Builder
    func buildEmptySearchResults() {
        Column {
            Text(trSource("No emoji found"))
                .fontSize(15)
                .fontColor(0x8E8E93)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    private func rebuildRows(): Unit {
        if (this.contentWidth <= 0.0) { return }
        let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let metrics = emojiKeyboardMetrics(this.contentWidth)
        let rows = buildKeyboardRowsExpanded(
            this.currentGroups(), metrics, metrics, this.expandedGroups.toArray())
        this.rowSource.setRows(rows)
        this.embeddedSource.setCells(embeddedRowCells(rows))
        if (USE_ARKTS_EMOJI_GRID) {
            let snapshot = rows
            let filesDir = getAppFilesDir()
            let premium = this.hasPremiumHere()
            this.arkRowsPushInFlight = true
            let _ = spawn {
                let json = buildRowsJson(snapshot, filesDir, premium)
                launch {
                    // hash 门控：内容没变不 bump gen（gen 变化 = ArkTS 整表
                    // reload；贴纸侧同款，见 StickerKeyboardPanel.rebuildRows）。
                    if (json != this.cachedRowsJson) {
                        // [GenDiff] 诊断：内容抖动时打印首个分歧字节的上下文
                        //（曾定位 recent 首格在锁定 custom emoji 与 🔥 间乒乓、
                        // 912KB JSON 每 ~200ms 交替 reload 的成因）。挂总开关。
                        if (CHAIN_TRACE_LOGS && !this.cachedRowsJson.isEmpty()) {
                            let a = this.cachedRowsJson.toArray()
                            let b = json.toArray()
                            var i: Int64 = 0
                            let n = if (Int64(a.size) < Int64(b.size)) { Int64(a.size) } else { Int64(b.size) }
                            while (i < n && a[i] == b[i]) { i = i + 1 }
                            var lo = i - 80
                            if (lo < 0) { lo = 0 }
                            var hiA = i + 80
                            if (hiA > Int64(a.size)) { hiA = Int64(a.size) }
                            var hiB = i + 80
                            if (hiB > Int64(b.size)) { hiB = Int64(b.size) }
                            let ctxA = (try { String.fromUtf8(a[lo..hiA]) } catch (_: Exception) { "?" })
                            let ctxB = (try { String.fromUtf8(b[lo..hiB]) } catch (_: Exception) { "?" })
                            Hilog.info(0, "CjTelegram",
                                "[GenDiff] emoji at=${i} lenA=${a.size} lenB=${b.size} A=${ctxA} || B=${ctxB}")
                        }
                        this.cachedRowsJson = json
                        this.arkGridGeneration = this.arkGridGeneration + 1
                    }
                    this.arkRowsPushInFlight = false
                    this.pushArkGridUpdate(true)
                }
            }
        } else {
            this.pushArkGridUpdate(true)
        }
        // 行数据里的 StickerItem 本来就带完整元数据，直接种进 doc 缓存；
        // 只带 id 的（最近使用）攒一批发**一次** RPC。不做这两步时，每个
        // CustomEmojiImage 各自 resolve，single-flight 排成串行 RPC 队列，
        // 面板冷启动要 ~4s 才填满（见 seedCustomEmojiDocuments 注释）。
        let seedItems = ArrayList<StickerItem>()
        let prefetchIds = ArrayList<Int64>()
        for (row in rows) {
            for (cell in row.cells) {
                if (cell.item.documentId == 0) { continue }
                if (cell.item.mimeType.size > 0 && cell.item.accessHash != 0) {
                    seedItems.add(cell.item)
                } else {
                    prefetchIds.add(cell.item.documentId)
                }
            }
        }
        let _ = spawn {
            seedCustomEmojiDocuments(seedItems)
            prefetchCustomEmojiDocuments(prefetchIds)
        }
        Hilog.info(0, "CjTelegram",
            "[EmojiPickerPerf] rebuildRows rows=${rows.size} perRow=${metrics.itemsPerRow} " +
            "size=${metrics.itemSize} seed=${seedItems.size} prefetch=${prefetchIds.size} " +
            "elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
        this.scheduleCellDrive()
    }

    /**
     * onAreaChange 在布局阶段回调，直接 setRows 会在同一帧内触发 LazyForEach
     * 重载。推迟一帧再重建，避免在布局中途改数据源。
     */
    private func updateContentWidth(width: Float64): Unit {
        if (width <= 0.0 || this.contentWidth == width) { return }
        this.contentWidth = width
        let _ = spawn {
            sleep(Duration.millisecond * 16)
            launch { this.rebuildRows() }
        }
    }

    /** trending 封面 → 所属精选包的分组（含 Unlock/Add 底按钮）。 */
    private func openFeaturedPackForTrending(item: StickerItem): Unit {
        var packId: Int64 = 0
        for (pack in this.featuredEmojiPacks) {
            if (this.customPackCoverId(pack) == item.documentId) { packId = pack.id; break }
            for (top in pack.topItems) {
                if (top.documentId == item.documentId) { packId = pack.id; break }
            }
            if (packId != 0) { break }
        }
        if (packId == 0) { return }
        this.scrollToGroup(packId)
    }

    private func scrollToGroup(key: Int64): Unit {
        let index = keyboardRowIndexForGroup(this.rowSource.currentRows(), key)
        if (USE_ARKTS_EMOJI_GRID) {
            // 真正显示的是 ArkTS List：仓颉 contentScroller 只滚隐藏占位，
            // 必须把跳转转发过去（导航栏跳转失效的根因）。
            Hilog.info(0, "CjTelegram",
                "[ArkGrid] jump group=${key} row=${index} rows=${this.rowSource.currentRows().size} inflight=${this.arkRowsPushInFlight}")
            if (index >= 0) { this.forwardArkJump(index) }
            return
        }
        if (index >= 0) {
            // iOS 的导航跳转是瞬时定位：smooth 平滑滚过几百行会把沿途行
            // 全部实例化 + 驱动窗连环起停，一路掉帧（「跳转很卡」的主因）。
            this.contentScroller.scrollToIndex(
                Int32(index), smooth: false, align: ScrollAlign.Start)
            // （不再强制窗：见 firstRowAtOffset 注释）
            // 瞬时跳转的落点格子多为无回调复用（订阅全丢），350ms 后重生一轮。
            let _ = spawn {
                sleep(Duration.millisecond * 350)
                launch { this.rebirthVisibleCells("nav-jump") }
            }
        }
    }

    /** 底部 tab 的高亮跟随首个可见行所属分组，取代按像素反推分类。 */
    private func updateSelectionForRow(index: Int64): Unit {
        let rows = this.rowSource.currentRows()
        if (index < 0 || index >= Int64(rows.size)) { return }
        let key = rows[index].groupKey
        if (key == EMOJI_GROUP_STATIC) {
            if (this.selectedCustomPackId != 0) { this.selectedCustomPackId = 0 }
            let sub = rows[index].subgroup
            if (sub >= 0 && this.selectedCategory != sub) { this.selectedCategory = sub }
            return
        }
        if (key > 0) {
            if (this.selectedCustomPackId != key) {
                this.selectedCustomPackId = key
                this.revealPackInTopPanel(key)
            }
        }
    }

    /** 顶部导航里所有包封面的排列顺序，与 buildTopPanel 的 ForEach 顺序一致。 */
    private func topPanelPackIds(): Array<Int64> {
        let ids = ArrayList<Int64>()
        for (pack in this.installedEmojiPacks) { ids.add(pack.id) }
        if (this.peerSpecificEmojiPackVisible()) { ids.add(this.peerSpecificEmojiPack.info.id) }
        for (pack in this.featuredNavigationEmojiPacks()) { ids.add(pack.id) }
        return ids.toArray()
    }

    /** 把 packId 对应的封面滚到导航条中间。封面等宽，位置可以直接算出来。 */
    private func revealPackInTopPanel(packId: Int64): Unit {
        let ids = this.topPanelPackIds()
        var index: Int64 = -1
        var i: Int64 = 0
        while (i < Int64(ids.size)) {
            if (ids[i] == packId) { index = i; break }
            i = i + 1
        }
        if (index < 0) { return }
        let itemX = this.searchCategoryStripWidth() + Float64(index) * KEYBOARD_TOP_PANEL_TAB_WIDTH
        let viewport = if (this.contentWidth > 0.0) { this.contentWidth } else { 360.0 }
        var target = itemX - viewport / 2.0 + KEYBOARD_TOP_PANEL_TAB_WIDTH / 2.0
        if (target < 0.0) { target = 0.0 }
        this.topPanelScroller.scrollTo(xOffset: target, yOffset: 0.0, animation: true)
    }

    // ensurePackDetailLoaded 已删除：iOS 的键盘不为精选组拉明细
    //（数据形态见 featuredEmojiGroups 注释）；滚动触发的逐包全量 RPC 与
    // 随之而来的行表重建，正是「精选区卡顿 + 格子集体冻结」的根源。


    // iOS recent 组带 isClearable（清空最近使用），EmojiRecentService 目前没有
    // 对应的清除接口，留到后续批次一起补。

    private func handleEmojiSelect(emoji: String) {
        // Persist recent
        let e = emoji
        let _ = spawn {
            let svc = getEmojiRecentService()
            svc.recordUsed(e)
        }
        this.onSelectEmoji(emoji)
    }

    private func handleEmojiTap(emoji: String): Unit {
        if (this.suppressNextEmojiTap) {
            this.suppressNextEmojiTap = false
            return
        }
        this.handleEmojiSelect(emoji)
    }

    /** 单一 recognizer 同时处理点击和 350ms 长按，行为与 iOS EmojiPagerItemLayer 一致。 */
    private func handleEmojiTouch(event: TouchEvent, emoji: String): Unit {
        match (event.eventType) {
            case TouchType.Down =>
                let variants = getIOSStaticEmojiVariants(emoji)
                if (variants.size <= 1) { return }
                if (event.touches.size > 0) {
                    this.variantTouchX = event.touches[0].x
                    this.variantTouchY = event.touches[0].y
                }
                this.variantPressActive = true
                this.variantPressGeneration = this.variantPressGeneration + 1
                let generation = this.variantPressGeneration
                let pressedEmoji = emoji
                let values = variants
                let _ = spawn {
                    sleep(Duration.millisecond * 350)
                    launch {
                        if (this.variantPressActive &&
                            this.variantPressGeneration == generation) {
                            this.variantPressActive = false
                            this.suppressNextEmojiTap = true
                            this.variantEmoji = pressedEmoji
                            this.variantOptions = values
                            this.variantPopupVisible = true
                        }
                    }
                }
            case TouchType.Move =>
                if (this.variantPressActive && event.touches.size > 0) {
                    let dx = event.touches[0].x - this.variantTouchX
                    let dy = event.touches[0].y - this.variantTouchY
                    if (dx * dx + dy * dy > 100.0) {
                        this.variantPressActive = false
                        this.variantPressGeneration = this.variantPressGeneration + 1
                    }
                }
            case TouchType.Up =>
                this.variantPressActive = false
                this.variantPressGeneration = this.variantPressGeneration + 1
            case TouchType.Cancel =>
                this.variantPressActive = false
                this.variantPressGeneration = this.variantPressGeneration + 1
            case _ => ()
        }
    }

    private func dismissVariantPopup(): Unit {
        this.variantPopupVisible = false
        this.suppressNextEmojiTap = false
    }

    private func selectEmojiVariant(emoji: String): Unit {
        this.variantPopupVisible = false
        this.suppressNextEmojiTap = false
        // iOS 记住这一次的肤色选择，之后该 emoji 直接以此肤色呈现
        let base = this.variantEmoji
        this.skinTones[base] = emoji
        getEmojiRecentService().recordSkinTone(base, emoji)
        this.rebuildRows()
        this.handleEmojiSelect(emoji)
    }

    /**
     * iOS 先回放 ItemCache 的关键词索引，再由 managedSynchronizeEmojiKeywords 增量更新。
     * 磁盘结果用于首帧，网络同步不阻塞面板打开。
     */
    private func loadEmojiKeywords(): Unit {
        let language = currentEmojiSearchLanguage()
        let _ = spawn {
            let service = getStickersService()
            let cached = service.getCachedEmojiKeywords(language)
            let cachedCombined = ArrayList<EmojiKeywordEntry>()
            if (cached.success) {
                for (entry in cached.keywords) { cachedCombined.add(entry) }
            }
            if (!language.startsWith("en")) {
                let englishCached = service.getCachedEmojiKeywords("en")
                if (englishCached.success) {
                    for (entry in englishCached.keywords) { cachedCombined.add(entry) }
                }
            }
            if (!cachedCombined.isEmpty()) {
                let cachedKeywords = cachedCombined.toArray()
                launch { this.emojiKeywords = cachedKeywords }
            }
            let synchronizedKeywords = service.synchronizeEmojiKeywords(language)
            let actualCombined = ArrayList<EmojiKeywordEntry>()
            if (synchronizedKeywords.success) {
                for (entry in synchronizedKeywords.keywords) { actualCombined.add(entry) }
            }
            if (!language.startsWith("en")) {
                let englishActual = service.synchronizeEmojiKeywords("en")
                if (englishActual.success) {
                    for (entry in englishActual.keywords) { actualCombined.add(entry) }
                }
            }
            if (!actualCombined.isEmpty()) {
                let values = actualCombined.toArray()
                launch { this.emojiKeywords = values }
            }
        }
    }

    // ===== 辅助方法 =====

    private func currentEmojisForDisplay(): Array<String> {
        let q = this.searchText
        if (q.size > 0) {
            return this.searchAllEmojis(q)
        }
        return getCategoryEmojis(this.selectedCategory)
    }

    /** Telegram 关键词索引搜索全部静态分组，并保持目录顺序、去除重复结果。 */
    private func searchAllEmojis(query: String): Array<String> {
        let normalized = query.toAsciiLower()
        let result = ArrayList<String>()
        for (emoji in allIOSStaticEmojis()) {
            if (emoji.contains(query)) { addUniqueEmoji(result, emoji) }
        }
        for (entry in this.emojiKeywords) {
            if (!entry.isDeleted && entry.keyword.toAsciiLower().contains(normalized)) {
                for (emoji in entry.emoticons) { addUniqueEmoji(result, emoji) }
            }
        }
        return result.toArray()
    }

    private func onSearchChanged(value: String): Unit {
        this.searchText = value
        this.selectedCustomPackId = 0
        this.selectedSearchCategoryId = 0
        this.customSearchGeneration = this.customSearchGeneration + 1
        let generation = this.customSearchGeneration
        if (value.isEmpty()) {
            this.customSearchItems = Array<StickerItem>(0, repeat: StickerItem())
            this.searchInFlight = false
            this.searchShowsBack = false
            this.stopCustomEmojiAnimationClock()
            this.rebuildRows()
            return
        }
        let query = this.customEmojiSearchQuery(value)
        if (query.isEmpty()) {
            this.customSearchItems = Array<StickerItem>(0, repeat: StickerItem())
            this.searchInFlight = false
            this.searchShowsBack = true
            this.rebuildRows()
            return
        }
        this.searchInFlight = true
        this.searchShowsBack = false
        // 静态结果先出（本地关键词索引），自定义表情结果随 RPC 回来再并进行表。
        this.rebuildRows()
        let _ = spawn {
            sleep(Duration.millisecond * 180)
            if (this.customSearchGeneration != generation) { return }
            let result = getStickersService().searchCustomEmoji(query)
            let items = result.documents.toArray()
            launch {
                if (this.customSearchGeneration == generation) {
                    this.searchInFlight = false
                    this.searchShowsBack = true
                    this.customSearchItems = items
                    this.rebuildRows()
                    if (!items.isEmpty()) { this.startCustomEmojiAnimationClock() }
                }
            }
        }
    }

    /**
     * messages.searchCustomEmoji 接收的是 emoticon 串而不是自然语言。iOS 先通过
     * EmojiKeywords 把本地化文本转成 emoji identifiers，再拼接给远端；直接把
     * “happy” 发给 RPC 会稳定得到空结果。
     */
    private func customEmojiSearchQuery(value: String): String {
        var result = ""
        let normalized = value.toAsciiLower()
        if (value.size > 0 && this.searchAllEmojis(value).size > 0) {
            for (emoji in this.searchAllEmojis(value)) {
                if (result.size < 128) { result = result + emoji }
            }
        }
        if (result.isEmpty()) {
            for (entry in this.emojiKeywords) {
                if (!entry.isDeleted && entry.keyword.toAsciiLower().contains(normalized)) {
                    for (emoji in entry.emoticons) {
                        if (result.size < 128 && !result.contains(emoji)) {
                            result = result + emoji
                        }
                    }
                }
            }
        }
        return result
    }

    private func selectSearchCategory(group: EmojiGroupInfo): Unit {
        this.searchText = ""
        this.selectedCustomPackId = 0
        this.selectedSearchCategoryId = group.iconEmojiId
        this.customSearchGeneration = this.customSearchGeneration + 1
        let generation = this.customSearchGeneration
        // 立即清掉上一分类的结果：切换分类的首次重建原来还挂着旧分类内容，
        // 新结果又被压着到不了 —— 页面看起来「点了没反应」。清空 = 即时反馈。
        this.customSearchItems = Array<StickerItem>(0, repeat: StickerItem())
        var query = ""
        for (identifier in group.emoticons) { query = query + identifier }
        if (group.isPremium && query.isEmpty()) {
            for (detail in this.installedEmojiDetails) {
                for (item in detail.stickers) {
                    if (!item.isFreeEmoji && query.size < 128) {
                        query = query + item.altEmoji
                    }
                }
            }
        }
        if (query.isEmpty()) {
            this.customSearchItems = Array<StickerItem>(0, repeat: StickerItem())
            this.rebuildRows()
            return
        }
        this.rebuildRows()
        let requestQuery = query
        let _ = spawn {
            let result = getStickersService().searchCustomEmoji(requestQuery)
            let items = result.documents.toArray()
            launch {
                if (this.customSearchGeneration == generation) {
                    this.customSearchItems = items
                    this.rebuildRows()
                    if (!items.isEmpty()) { this.startCustomEmojiAnimationClock() }
                }
            }
        }
    }

    private func selectedCustomEmojiItems(): Array<StickerItem> {
        if (this.hasPeerSpecificEmojiPack &&
            this.peerSpecificEmojiPack.info.id == this.selectedCustomPackId) {
            return this.peerSpecificEmojiPack.stickers.toArray()
        }
        for (detail in this.installedEmojiDetails) {
            if (detail.info.id == this.selectedCustomPackId) {
                return detail.stickers.toArray()
            }
        }
        return Array<StickerItem>(0, repeat: StickerItem())
    }

    private func customPackTitle(): String {
        if (this.hasPeerSpecificEmojiPack &&
            this.peerSpecificEmojiPack.info.id == this.selectedCustomPackId) {
            return this.peerSpecificEmojiPack.info.title
        }
        for (pack in this.installedEmojiPacks) {
            if (pack.id == this.selectedCustomPackId) { return pack.title }
        }
        for (pack in this.featuredEmojiPacks) {
            if (pack.id == this.selectedCustomPackId) { return pack.title }
        }
        return "Custom Emoji"
    }

    /** 顶部面板里能真正显示的未安装精选包：必须拿得出封面。 */
    private func featuredNavigationEmojiPacks(): Array<StickerPackInfo> {
        let result = ArrayList<StickerPackInfo>()
        for (pack in this.featuredEmojiPacks) {
            if (this.isEmojiPackInstalled(pack.id)) { continue }
            if (this.customPackCoverId(pack) == 0) { continue }
            result.add(pack)
        }
        return result.toArray()
    }

    private func customPackCoverId(pack: StickerPackInfo): Int64 {
        // 封面优先级：**第一个彩色内容项** > cover 文档 > 兜底。
        //
        // 真机排查「导航栏一排灰色爱心/考拉/南瓜」的结论：那些灰图是
        // thumb_document_id 兜底出来的 —— Telegram 的 set 缩略图**设计上就是
        // 单色轮廓**（text_color 模板），tint 后必然灰。iOS 顶部面板显示的是
        // 包内第一个彩色表情，所以同一个包 iOS 彩色、我们灰色。
        // topItems / 明细现在都是全量数据（预取链），直接取第一个非模板项。
        for (item in pack.topItems) {
            if (item.documentId != 0 && !item.supportsTextColor && item.isCustomEmoji) {
                return item.documentId
            }
        }
        for (detail in this.installedEmojiDetails) {
            if (detail.info.id == pack.id) {
                for (item in detail.stickers) {
                    if (item.documentId != 0 && !item.supportsTextColor) {
                        return item.documentId
                    }
                }
            }
        }
        if (pack.cover.documentId != 0) { return pack.cover.documentId }
        if (this.hasPeerSpecificEmojiPack && this.peerSpecificEmojiPack.info.id == pack.id &&
            !this.peerSpecificEmojiPack.stickers.isEmpty()) {
            return this.peerSpecificEmojiPack.stickers[0].documentId
        }
        return 0
    }

    /**
     * 与 iOS 一致：点包 tab 只是把同一条连续列表滚到该包，不再整块换页。
     * 包明细尚未落库时先发起 getStickerSet，快照回来后 applyEmojiSnapshot
     * 会重建行表，届时再滚过去。
     */
    private func selectCustomPack(pack: StickerPackInfo): Unit {
        this.selectedCustomPackId = pack.id
        this.startCustomEmojiAnimationClock()
        if (!this.searchText.isEmpty() || this.selectedSearchCategoryId != 0) {
            this.searchText = ""
            this.selectedSearchCategoryId = 0
            this.customSearchItems = Array<StickerItem>(0, repeat: StickerItem())
            this.rebuildRows()
        }
        if (keyboardRowIndexForGroup(this.rowSource.currentRows(), pack.id) >= 0) {
            this.scrollToGroup(pack.id)
            return
        }
        let requested = pack
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let _ = spawn {
            let detail = getStickersService().getStickerSet(requested.id, requested.accessHash)
            if (detail.success) { store.publishEmojiPackDetail(token, detail) }
            launch {
                if (detail.success) {
                    this.applyEmojiSnapshot(store.currentEmojiSnapshot())
                    this.scrollToGroup(requested.id)
                }
            }
        }
    }

    private func peerSpecificEmojiPackVisible(): Bool {
        if (!this.hasPeerSpecificEmojiPack || this.peerSpecificEmojiPack.stickers.isEmpty()) {
            return false
        }
        return !this.isEmojiPackInstalled(this.peerSpecificEmojiPack.info.id)
    }

    private func canInstallSelectedEmojiPack(): Bool {
        if (this.isEmojiPackInstalled(this.selectedCustomPackId)) { return false }
        for (pack in this.featuredEmojiPacks) {
            if (pack.id == this.selectedCustomPackId) { return true }
        }
        return false
    }

    /**
     * iOS `hasPremium(premiumIfSavedMessages: true)`：在「收藏夹」（和自己的会话）里
     * 即便没有会员也允许使用 premium 自定义表情——那条消息只发给自己。
     */
    private func hasPremiumHere(): Bool {
        if (isCurrentUserPremium()) { return true }
        return this.peerType == "user" && this.peerId == getCurrentUserId()
    }

    private func isPremiumLocked(item: StickerItem): Bool {
        return item.isCustomEmoji && !item.isFreeEmoji && !this.hasPremiumHere()
    }

    private func selectCustomEmoji(item: StickerItem): Unit {
        Hilog.info(0, "CjTelegram", "[EmojiTap] docId=${item.documentId} isCustom=${item.isCustomEmoji} free=${item.isFreeEmoji} locked=${this.isPremiumLocked(item)} altLen=${item.altEmoji.size}")
        if (this.isPremiumLocked(item)) {
            // iOS ChatEntityKeyboardInputNode.swift:729 弹的是 UndoOverlay：
            // 一条带动作按钮的覆盖层，按钮点进 PremiumDemoScreen(.animatedEmoji)。
            //
            // 用 UndoToast 而不是系统 toast：系统 toast 没有按钮，而且走独立系统
            // 窗口——截图拍不到、可访问性树里也没有，等于不可测。
            //
            // 文案取自 Localizable.strings 原文（此前那句 "…to use this emoji"
            // 是自造的）。iOS 还会逢偶数改推「去 Saved Messages 免费试」，
            // 但那条的动作是跳进与自己的会话，我们还没有这个入口——
            // iOS 自己在 chatPeerId == nil 时也把这条关掉（:741），
            // 我们照同一个形状关着，等 Saved Messages 入口做出来再打开。
            getUndoToastService().showUndo(
                "Subscribe to Telegram Premium to unlock premium emoji.",
                actionText: "More",
                durationMs: 5000,
                onUndo: { => routerPush("PremiumDemoPage", "animatedEmoji") }
            )
            return
        }
        this.prependRecentCustomEmoji(item)
        getEmojiRecentService().recordCustomEmojiUsed(item.documentId)
        this.onSelectCustomEmoji(item)
    }

    private func installSelectedEmojiPack(): Unit {
        if (this.selectedCustomPackId == 0 ||
            this.installingEmojiPackId == this.selectedCustomPackId) { return }
        var selected = StickerPackInfo()
        for (pack in this.featuredEmojiPacks) {
            if (pack.id == this.selectedCustomPackId) { selected = pack }
        }
        if (selected.id == 0 || this.isEmojiPackInstalled(selected.id)) { return }
        this.installingEmojiPackId = selected.id
        let packId = selected.id
        let accessHash = selected.accessHash
        let lifecycle = this.emojiLifecycleGeneration
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let previous = store.currentEmojiSnapshot()
        let optimisticVersion = store.optimisticallyInstallEmojiPack(
            accountToken, selected, this.selectedCustomEmojiItems())
        let _ = spawn {
            let result = getStickersService().installStickerSet(packId, accessHash)
            if (result.success) {
                let packs = getStickersService().getEmojiStickers().packs.toArray()
                store.publishEmojiInstalledPacks(accountToken, packs)
                let detail = getStickersService().getStickerSet(packId, accessHash)
                if (detail.success) { store.publishEmojiPackDetail(accountToken, detail) }
            } else {
                let _ = store.restoreEmojiSnapshotIfVersion(
                    accountToken, previous, optimisticVersion)
            }
            launch {
                if (this.emojiLifecycleGeneration == lifecycle &&
                    this.installingEmojiPackId == packId) {
                    this.installingEmojiPackId = 0
                }
            }
        }
    }

    private func prependRecentCustomEmoji(item: StickerItem): Unit {
        let values = ArrayList<StickerItem>()
        values.add(item)
        for (existing in this.recentCustomEmojis) {
            if (existing.documentId != item.documentId && values.size < 32) {
                values.add(existing)
            }
        }
        this.recentCustomEmojis = values.toArray()
        this.rebuildRows()
    }

    /**
     * 曾经这里有一个 34ms 的全局时钟：递增 customAnimationEpoch，让每个
     * CustomEmojiImage 按 `epoch % frameCount` 取帧。两个问题——所有格子被绑在
     * 同一个帧号上（长短动画互相拖累），以及为了能按帧号取图，必须先把整支动画
     * 预光栅进内存（384px × 全帧 ≈ 上百 MB，正是闪退的来源）。
     *
     * 现在每个格子各自持有流式解码器，按素材自身的 frameDurationMs 推进，
     * 并发由 KeyboardPlaybackLimiter 限额。epoch 只保留「父级是否要求播放」
     * 这一层语义（>= 0 即播），不再需要时钟。
     */
    private func startCustomEmojiAnimationClock(): Unit {}

    private func stopCustomEmojiAnimationClock(): Unit {}

    /**
     * 分类 tab 不再换页：与 iOS 一样只把同一条连续列表滚到该分组。
     * 搜索态需要先退出，行表才会切回常规分组。
     */
    private func selectStaticCategory(index: Int64): Unit {
        this.selectedCategory = index
        this.selectedCustomPackId = 0
        if (!this.searchText.isEmpty() || this.selectedSearchCategoryId != 0) {
            this.searchText = ""
            this.selectedSearchCategoryId = 0
            this.customSearchItems = Array<StickerItem>(0, repeat: StickerItem())
            this.rebuildRows()
        }
        if (!this.recentCustomEmojis.isEmpty()) {
            this.startCustomEmojiAnimationClock()
        } else {
            this.stopCustomEmojiAnimationClock()
        }
        let row = keyboardRowIndexForSubgroup(
            this.rowSource.currentRows(), EMOJI_GROUP_STATIC, index)
        if (row >= 0) {
            if (USE_ARKTS_EMOJI_GRID) {
                // 网格在 ArkTS 侧：分类跳转同样必须转发（见 scrollToGroup）
                this.forwardArkJump(row)
            } else {
                this.contentScroller.scrollToIndex(
                    Int32(row), smooth: true, align: ScrollAlign.Start)
            }
        }
    }

    // ===== Build =====

    public func build() {
        Stack(alignContent: Alignment.Center) {
        Column {
            // ==================== 顶部面板（48pt）====================
            // lldb 从运行中的 iOS 量到：EntityKeyboardTopContainerPanelComponent
            // = 402x48，内部 TopPanel = 402x40（y 偏移 8），图标 24x24，
            // x 依次 14 / 50 / 86 —— 即左起 14、间距 36。
            // 此前这条导航在面板底部，与 iOS 上下颠倒。
            // 搜索输入态隐藏导航条（iOS：搜索时只剩搜索行 + 结果区，
            // 紧凑面板高度预算也只给这两块）。
            if (!this.searchInputActive) {
                this.buildTopPanel()
            }

            // ==================== 搜索行（54pt）====================
            // iOS EmojiSearchHeaderView = (0, 49; 402x54)：搜索框与分类图标同一行。
            if (this.searchInputActive) {
                this.buildActiveSearchRow()
            } else {
                this.buildSearchRow()
            }

            // ==================== 主内容区 ====================
            // iOS 只为可见窗口建 layer（ItemLayout.visibleItems(for:)）。这里等价物
            // 是 List + LazyForEach：1519 枚静态 Emoji 只会materialize 屏幕内的几行。
            // 置顶安装栏已移除：featured 组的列表内 60vp 头行（标题+副题+Add）
            // 已承担同一职责，两条同时出现就是重复标题+双 Add（用户实锤反馈）。
            // iOS EmptySearchResultsView：搜不到时给一句居中的
            // EmojiSearch.SearchEmojiEmptyResult = "No emoji found"。
            // 我们此前是**一片空白**——用户分不清是没结果还是卡住了。
            if (this.searchNoResults()) {
                this.buildEmptySearchResults()
            }
            if (USE_ARKTS_EMOJI_GRID) {
                // 网格由 ArkTS 覆盖层渲染（壳层 Stack 顶部，见 EmojiGridPanel.ets）；
                // 这里保留等高占位维持面板布局，并向壳层供几何。
                // layoutWeight 而非整块 contentHeightVp：本 Column 上方还有
                // 导航 48 + 搜索行 54，写死总高会让占位符（连同按它定位的
                // ArkTS 覆盖层）向下溢出 102vp —— 溢出段不受面板裁剪，正好
                // 把面板下方的 GIFs/Stickers/Emoji 页签行整个盖住（真机实锤：
                // 「gif 和 sticker 按钮不显示了」）。旧仓颉 List 就是 weight(1)。
                Column {}
                    .width(100.percent)
                    .layoutWeight(1)
                    .id(EMOJI_GRID_SLOT_ID)
                    .onAreaChange({ _: Area, newArea: Area =>
                        this.gridGlobalXPx = this.vp2pxF(optLenVp(newArea.globalPosition.x))
                        this.gridGlobalYPx = this.vp2pxF(optLenVp(newArea.globalPosition.y))
                        this.gridWidthPx = this.vp2pxF(newArea.width.value)
                        this.gridHeightPx = this.vp2pxF(newArea.height.value)
                        this.pushArkGridUpdate(true)
                    })
            } else {
            List(space: 0, scroller: this.contentScroller) {
                LazyForEach(this.rowSource,
                    itemGenerator: { row: KeyboardRow, _index: Int64 =>
                        ListItem {
                            this.buildKeyboardRow(row)
                        }
                    },
                    keyGenerator: { row: KeyboardRow, _index: Int64 =>
                        if (row.groupKey > 0) {
                            "${row.key}#g${this.cellRebirthGeneration}"
                        } else {
                            row.key
                        }
                    })
            }
            .layoutWeight(1)
            .width(100.percent)
            // iOS 给内容区留 containerInsets.bottom（EmojiPagerContentComponent.swift:971）。
            // 没有它时**最后一个分组的底部按钮会被裁掉一半**——滚到列表末尾，
            // 紫色渐变条露出来但文字标签在可视区之下，连可访问性树里都查不到。
            // 实测：Face Emoji 包会裁，Application Emoji 包（内容更短）凑巧不裁——
            // 又是一个「换个数据就露馅」的问题。
            .padding(bottom: 12)
            .cachedCount(2)
            .scrollBar(BarState.Off)
            .onAreaChange({ _: Area, newArea: Area =>
                this.gridGlobalXPx = this.vp2pxF(optLenVp(newArea.globalPosition.x))
                this.gridGlobalYPx = this.vp2pxF(optLenVp(newArea.globalPosition.y))
                this.gridWidthPx = this.vp2pxF(newArea.width.value)
                this.gridHeightPx = this.vp2pxF(newArea.height.value)
                this.pushArkGridUpdate(true)
            })
            .onDidScroll({ _offset: Float64, _state: ScrollState =>
                // 滚动闸（僵尸断源，见 AnimatedEmojiService.setKeyboardGridScrolling）
                setKeyboardGridScrolling(true)
                // Canvas 合成器退位（宏禁 if 内 for-in，逻辑收进方法）。
                this.deactivateCanvasCompositor()
            })
            .onScrollStop({ => setKeyboardGridScrolling(false) })
            .onScrollIndex({ first: Int32, last: Int32, _center: Int32 =>
                this.visibleFirstRow = Int64(first)
                this.visibleLastRow = Int64(last)
                this.lastScrollEventAtMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                this.scheduleCellDrive()
                this.updateSelectionForRow(Int64(first))
            })
            .onScrollStop({ => this.publishContentOffset() })
            // Canvas 合成器垫底：本包装器的 Stack 首子在上（真机实锤：
            // 放首位时 Canvas 盖住整个 List），故挂在 List 之后=垫底。
            if (this.compositorOn) {
                EmojiGridCanvasOverlay(model: this.canvasModel)
            }
            }
        }
        .width(100.percent)
        .height(this.contentHeightVp)
        .backgroundColor(this.gridBackgroundColor())
        // 布局宽度是 metrics 的唯一输入（iOS 用 availableSize.width）。
        .onAreaChange({ _: Area, newArea: Area =>
            this.updateContentWidth(newArea.width.value)
        })

        if (this.variantPopupVisible) {
            this.buildEmojiVariantOverlay()
        }

        if (this.showEmojiPreview) {
            StickerPreviewOverlay(
                sticker: this.previewEmojiItem,
                isFavorite: false,
                onSend: { item: StickerItem =>
                    this.showEmojiPreview = false
                    this.selectCustomEmoji(item)
                },
                onSendSilently: { item: StickerItem =>
                    this.showEmojiPreview = false
                    this.selectCustomEmoji(item)
                },
                onFavorite: { _item: StickerItem, _remove: Bool => this.showEmojiPreview = false },
                onViewPack: { item: StickerItem =>
                    this.showEmojiPreview = false
                    this.scrollToGroup(item.packId)
                },
                onClose: { => this.showEmojiPreview = false }
            )
        }
        }
        .width(100.percent)
        .height(this.contentHeightVp)
    }

    /** iOS 顶部面板：8 个静态分类图标 + 已装包封面 + 未装的精选包封面。 */
    @Builder
    func buildTopPanel() {
        Scroll(this.topPanelScroller) {
            Row {
                this.buildStaticCategoryPill()
                ForEach(this.installedEmojiPacks,
                    itemGenerator: { pack: StickerPackInfo, _index: Int64 =>
                        this.buildCustomPackTab(pack)
                    }, keyGenerator: { pack: StickerPackInfo, _index: Int64 =>
                        // 稳定键：行表/快照重建时导航格子原地复用，不拆播放流。
                        "navi_${pack.id}"
                    })
                if (this.peerSpecificEmojiPackVisible()) {
                    this.buildCustomPackTab(this.peerSpecificEmojiPack.info)
                }
                // 取不到封面的包直接不占位。此前会渲染一个「+」占位符，等于用一个
                // 空按钮挤掉一个真封面的位置——贴纸面板的 featuredNavigationPacks()
                // 一直是这么过滤的，emoji 侧漏了。
                ForEach(this.featuredNavigationEmojiPacks(),
                    itemGenerator: { pack: StickerPackInfo, _index: Int64 =>
                        this.buildFeaturedEmojiPackTab(pack)
                    }, keyGenerator: { pack: StickerPackInfo, _index: Int64 =>
                        "navf_${pack.id}"
                    })
            }
            .padding(left: 2, right: 2)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(48)
        .width(100.percent)
        .padding(top: 8)
    }

    /**
     * iOS EmojiSearchHeaderView（0, 49; 402x54）：**一个**灰色胶囊里装着
     * 放大镜 + Search 文案 + 一排搜索分类图标，而不是「搜索框一行、图标另一行」。
     * 点击胶囊才展开成真正的输入态。
     */
    @Builder
    func buildSearchRow() {
        Row {
            Row {
                Text("\u{1F50D}")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .margin(left: 10, right: 4)
                if (this.searchText.isEmpty()) {
                    Text(trSource("Search"))
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                } else {
                    Text(this.searchText)
                        .fontSize(15)
                        .fontColor(0x1C1C1E)
                        .maxLines(1)
                }
                Blank()
                Scroll {
                    Row {
                        ForEach(this.emojiSearchCategories,
                            itemGenerator: { group: EmojiGroupInfo, _index: Int64 =>
                                this.buildSearchCategory(group)
                            })
                    }
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width(this.searchCategoryStripWidth())
            }
            .width(100.percent)
            .height(36)
            .borderRadius(18)
            .backgroundColor(0x0F767680)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt => this.openSearchInput() })
        }
        .width(100.percent)
        .height(54)
        .padding(left: 12, right: 12)
        .alignItems(VerticalAlign.Center)
    }

    /** 胶囊里留给分类图标的宽度：搜索有内容时收窄，给文本让位。 */
    private func searchCategoryStripWidth(): Float64 {
        if (this.searchText.isEmpty()) { return 218.0 }
        return 96.0
    }

    /** 点胶囊进入输入态；焦点由 buildActiveSearchRow 的 onAppear 请求。 */
    private func openSearchInput(): Unit {
        this.searchInputActive = true
        // 先报宿主再等 IME：IME 高度回调到达时紧凑态开关必须已就位，
        // 否则会走互斥分支把整个面板关掉。
        this.onSearchActiveChanged(true)
    }

    @Builder
    func buildActiveSearchRow() {
        Row {
            Column {
                // iOS 的搜索图标是三态（EmojiSearchHeaderView.swift:460）：
                //   空闲 🔍 / 搜索中转圈 / 出结果后变返回箭头，点箭头退出搜索。
                // SearchBar 本来就有 loading 转圈，只是这里一直没把 searchInFlight 传进去；
                // 箭头态是新加的 backArrow。
                SearchBar(
                    text: this.searchText,
                    hint: trSource("Search"),
                    onChange: { value: String => this.onSearchChanged(value) },
                    onCancel: { =>
                        this.searchInputActive = false
                        this.onSearchActiveChanged(false)
                        this.onSearchChanged("")
                    },
                    loading: this.searchInFlight,
                    backArrow: this.searchShowsBack,
                    onBackArrow: { =>
                        this.searchInputActive = false
                        this.onSearchActiveChanged(false)
                        this.onSearchChanged("")
                    },
                    inputId: EMOJI_SEARCH_INPUT_ID
                )
            }
            .layoutWeight(1)
            // iOS 进入搜索态后分类图标条**保留**（实测截图：
            // 「🔍 |Search ♡ 👍 👎 🎉 ☺ ☹ Cancel」并排在同一行）。
            // 此前我们换成全宽 SearchBar 后整条图标消失，搜索态下少了一整个入口。
            Scroll {
                Row {
                    ForEach(this.emojiSearchCategories,
                        itemGenerator: { group: EmojiGroupInfo, _index: Int64 =>
                            this.buildSearchCategory(group)
                        })
                }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width(this.activeSearchCategoryWidth())
            .margin(left: 4)
        }
        .width(100.percent)
        .height(54)
        .padding(left: 8, right: 8)
        .alignItems(VerticalAlign.Center)
        // 点一次就能打字，与 iOS 一致。此前 openSearchInput() 只把胶囊换成 SearchBar，
        // 不请求焦点，软键盘不起——**必须再点第二次**才能输入。
        // 焦点挂在 onAppear 而不是 openSearchInput() 里：SearchBar 是被
        // searchInputActive 这次状态变化创建出来的，设状态的那一刻它还不存在。
        .onAppear({ => FocusControl.requestFocus(EMOJI_SEARCH_INPUT_ID) })
    }

    /** 搜索态下留给分类图标的宽度：有查询词时收窄给文本让位（与非激活态同规则）。 */
    private func activeSearchCategoryWidth(): Float64 {
        if (this.searchText.isEmpty()) { return 150.0 }
        return 76.0
    }

    @Builder
    func buildSearchCategory(group: EmojiGroupInfo) {
        Column {
            CustomEmojiImage(
                documentId: group.iconEmojiId,
                size: 24.0,
                placeholder: "",
                templateMode: true,
                animationEpoch: -1
            )
        }
        .width(38)
        .height(38)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(if (this.selectedSearchCategoryId == group.iconEmojiId) {
            0x26317AFF
        } else { Color.Transparent })
        .borderRadius(19)
        .onClick({ _event => this.selectSearchCategory(group) })
    }

    private func publishContentOffset(): Unit {
        let current = this.contentScroller.currentOffset()
        if (current.isSome()) {
            this.onContentOffsetChanged(current.getOrThrow().yOffset)
        }
    }

    /** 已安装包没有 Add 入口；只有 featured 包被选中时才顶出这条安装栏。 */
    @Builder
    func buildInstallBar() {
        Row {
            Text(this.customPackTitle())
                .fontSize(12)
                .fontColor(0x8E8E93)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
            Text(if (this.installingEmojiPackId == this.selectedCustomPackId) {
                "Installing…"
            } else { "Add" })
                .fontSize(12)
                .fontColor(0xFF007AFF)
                .padding(left: 10, right: 10, top: 4, bottom: 4)
                .backgroundColor(0x14007AFF)
                .borderRadius(12)
                .onClick({ _event => this.installSelectedEmojiPack() })
        }
        .width(100.percent)
        .height(30)
        .padding(left: 12, right: 8)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildKeyboardRow(row: KeyboardRow) {
        if (row.kind == KEYBOARD_ROW_HEADER) {
            this.buildRowHeader(row)
        } else if (row.kind == KEYBOARD_ROW_GROUP_BUTTON) {
            this.buildGroupActionButton(row)
        } else {
            this.buildRowItems(row)
        }
    }

    /**
     * iOS GroupHeaderLayer：标题居中、大写、次级灰，frame = (16, y; width-32, 24)。
     * 分组头高度里已经含了 verticalGroupSpacing（首组除外），所以文字底对齐。
     */
    @Builder
    func buildRowHeader(row: KeyboardRow) {
        if (row.actionTitle.size > 0) {
            this.buildFeaturedHeader(row)
        } else {
            this.buildPlainHeader(row)
        }
    }

    /** iOS itemFeaturedHeaderHeight = 60：左标题 + 副标题，右侧 Add。 */
    @Builder
    func buildFeaturedHeader(row: KeyboardRow) {
        Row {
            Column {
                Text(row.title)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x1C1C1E)
                    .maxLines(1)
                Text(row.subtitle)
                    .fontSize(12)
                    .fontColor(0x8E8E93)
                    .margin(top: 2)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Button(if (this.installingEmojiPackId == row.groupKey) { "Adding…" } else { "Add" })
                .height(28)
                .fontSize(13)
                .fontColor(0xFFFFFF)
                .backgroundColor(0x317AFF)
                .borderRadius(14)
                .padding(left: 14, right: 14)
                .onClick({ _evt => this.installEmojiPackById(row.groupKey) })
        }
        .width(100.percent)
        .height(row.height)
        .padding(left: KEYBOARD_HEADER_INSET, right: KEYBOARD_HEADER_INSET, bottom: 6)
        .alignItems(VerticalAlign.Bottom)
    }

    @Builder
    func buildPlainHeader(row: KeyboardRow) {
        Row {
            Blank().width(28)
            Blank()
            if (row.actionLocked) {
                // iOS：锁定分组的组名左侧一枚小锁（灰）。
                Text("\u{1F512}")
                    .fontSize(11)
                    .margin(right: 4)
                    .opacity(0.55)
            }
            Text(row.title)
                .fontSize(12)
                .fontColor(0x8E8E93)
                .fontWeight(FontWeight.Medium)
            // iOS GroupHeaderLayer 的 badge：标题右侧 4pt，semibold 11，高 16，全圆角。
            // 只有群组专属表情包用得到（"GROUP EMOJI"）。
            if (row.badge.size > 0) {
                Text(row.badge)
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFFFFFFFF)
                    .height(16)
                    .padding(left: 4, right: 4)
                    .borderRadius(8)
                    .backgroundColor(0xA88E8E93)
                    .margin(left: 4)
            }
            Blank()
            if (row.clearAction.size > 0) {
                Text("×")
                    .fontSize(22)
                    .fontColor(0xA1A7AD)
                    .width(28)
                    .height(24)
                    .textAlign(TextAlign.Center)
                    .onClick({ _evt => this.handleHeaderClear(row.clearAction) })
            } else {
                Blank().width(28)
            }
        }
        .width(100.percent)
        .height(row.height)
        .padding(left: KEYBOARD_HEADER_INSET, right: KEYBOARD_HEADER_INSET)
        .alignItems(VerticalAlign.Bottom)
    }

    private func handleHeaderClear(action: String): Unit {
        if (action == "trending") {
            this.showTrendingEmoji = false
            this.rebuildRows()
            getEmojiRecentService().setTrendingDismissed(true)
            return
        }
        if (action == "recent") { this.confirmClearRecent() }
    }

    /** iOS recent 组 isClearable：先弹 destructive 确认，再清。 */
    private func confirmClearRecent(): Unit {
        let cancelButton = AlertDialogButtonOptions(value: "Cancel", action: { => () })
        let clearButton = AlertDialogButtonOptions(
            value: "Clear",
            fontColor: 0xFFFF3B30,
            action: { => this.clearRecentEmoji() }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: "Clear Recently Used",
            message: "Remove all recently used emoji?",
            autoCancel: true,
            primaryButton: cancelButton,
            secondaryButton: clearButton
        ))
    }

    private func clearRecentEmoji(): Unit {
        this.recentEmojis = Array<String>(0, repeat: "")
        this.recentCustomEmojis = Array<StickerItem>(0, repeat: StickerItem())
        this.rebuildRows()
        getEmojiRecentService().clearRecent()
    }

    /** iOS 分组底部的整宽渐变按钮：Unlock/Add + 锁图标。 */
    @Builder
    func buildGroupActionButton(row: KeyboardRow) {
        Row {
            Text(row.title)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(0xFFFFFFFF)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
            if (row.actionLocked) {
                Text("\u{1F512}").fontSize(13).margin(left: 6)
            }
        }
        .width(100.percent)
        .height(40)
        .margin(top: 4, bottom: 6)
        .borderRadius(20)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        // iOS EmojiPagerContentComponent.swift:3337 的 backgroundColors 是四段：
        //   0x0077ff → 0x6b93ff → 0x8878ff → 0xe46ace（蓝 → 紫 → 品红）。
        // 此前照着「印象」写了两段紫→蓝，颜色和走向都反了。
        // 未锁定（Add）态 iOS 用的是纯 accent 底色，不是渐变。
        .linearGradient(
            angle: 90.0,
            colors: if (row.actionLocked) {
                [(0xFF0077FF, 0.0), (0xFF6B93FF, 0.33),
                 (0xFF8878FF, 0.66), (0xFFE46ACE, 1.0)]
            } else {
                [(0xFF007AFF, 0.0), (0xFF007AFF, 1.0)]
            })
        .onClick({ _evt =>
            if (row.actionLocked) {
                // iOS：Unlock XXX Emoji → PremiumIntro 的 animatedEmoji 演示页，
                // 页内 CTA 再进 Premium 购买页（见 PremiumDemoPage）。
                routerPush("PremiumDemoPage", "animatedEmoji")
            } else {
                this.installEmojiPackById(row.groupKey)
            }
        })
    }

    @Builder
    func buildRowItems(row: KeyboardRow) {
        if (row.embedded) {
            // iOS ItemGroup.isEmbedded → GroupEmbeddedView（一条横向 UIScrollView）。
            // trending 组不截断条数，靠横滚看完全部封面。
            List {
                LazyForEach(this.embeddedSource,
                    itemGenerator: { cell: KeyboardCell, index: Int64 =>
                        ListItem {
                            this.buildRowCell(row, cell, index)
                        }
                    },
                    keyGenerator: { cell: KeyboardCell, index: Int64 =>
                        "emb_${cell.item.documentId}_${index}"
                    })
            }
            .listDirection(Axis.Horizontal)
            .cachedCount(2)
            .scrollBar(BarState.Off)
            .width(100.percent)
            .height(row.height)
            .padding(left: row.sideInset, right: row.sideInset)
        } else {
        Row {
            ForEach(row.cells, itemGenerator: { cell: KeyboardCell, index: Int64 =>
                this.buildRowCell(row, cell, index)
            }, keyGenerator: { cell: KeyboardCell, index: Int64 =>
                // 稳定键：行表重建（明细到达 / 宽度变化）时，键没变的格子**原地复用**，
                // 不被拆毁重建 —— 拆重建会 stop 播放流，而重建出的实例收不到
                // 可靠的挂载回调，整片格子就此冻住（实测：滚动停止 1s 后明细 RPC
                // 返回触发 rebuildRows，7 条流被批量 stop，无一重启）。
                "${row.key}#${cell.item.documentId}#${cell.emoji}#${index}"
            })
        }
        .width(100.percent)
        .height(row.height)
        .padding(left: row.sideInset, right: row.sideInset)
        .alignItems(VerticalAlign.Top)
        }
    }

    @Builder
    func buildRowCell(row: KeyboardRow, cell: KeyboardCell, index: Int64) {
        if (cell.expandLabel.size > 0) {
            this.buildExpandCell(row, cell, index)
        } else if (cell.emoji.size > 0) {
            this.buildEmojiCell(row, cell.emoji, index)
        } else {
            this.buildCustomEmojiCell(row, cell.item, index)
        }
    }

    /** iOS GroupExpandActionButton：末位的 "+N"，点开该分组的其余内容。 */
    @Builder
    func buildExpandCell(row: KeyboardRow, cell: KeyboardCell, index: Int64) {
        Column {
            Text(cell.expandLabel)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(0x8E8E93)
        }
        .width(row.itemSize)
        .height(row.itemSize)
        .margin(left: this.tileLeftSpacing(row, index))
        .borderRadius(row.itemSize / 2.0)
        .backgroundColor(0x14767680)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _evt => this.expandGroup(row.groupKey) })
    }

    private func installEmojiPackById(packId: Int64): Unit {
        if (this.installingEmojiPackId == packId) { return }
        var target = StickerPackInfo()
        for (pack in this.featuredEmojiPacks) {
            if (pack.id == packId) { target = pack }
        }
        if (target.id == 0) { return }
        this.installingEmojiPackId = packId
        let requested = target
        let lifecycle = this.emojiLifecycleGeneration
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let previous = store.currentEmojiSnapshot()
        let optimisticVersion = store.optimisticallyInstallEmojiPack(
            accountToken, requested, Array<StickerItem>(0, repeat: StickerItem()))
        let _ = spawn {
            let result = getStickersService().installStickerSet(requested.id, requested.accessHash)
            if (result.success) {
                let packs = getStickersService().getEmojiStickers().packs.toArray()
                store.publishEmojiInstalledPacks(accountToken, packs)
                let detail = getStickersService().getStickerSet(requested.id, requested.accessHash)
                if (detail.success) { store.publishEmojiPackDetail(accountToken, detail) }
            } else {
                let _ = store.restoreEmojiSnapshotIfVersion(
                    accountToken, previous, optimisticVersion)
            }
            launch {
                if (this.emojiLifecycleGeneration == lifecycle) { this.installingEmojiPackId = 0 }
            }
        }
    }

    private func expandGroup(groupKey: Int64): Unit {
        for (existing in this.expandedGroups) {
            if (existing == groupKey) { return }
        }
        this.expandedGroups.add(groupKey)
        this.rebuildRows()
    }

    private func tileLeftSpacing(row: KeyboardRow, index: Int64): Float64 {
        if (index == 0) { return 0.0 }
        return row.horizontalSpacing
    }

    /**
     * 此前每个格子都挂了一个 bindPopup（肤色板），静态目录 1519 枚意味着
     * 1519 个 popup 控制器常驻——这是面板卡顿/闪退的另一半原因。
     * 现在肤色板改为面板级的单个覆盖层，格子只保留点击与长按识别。
     */
    @Builder
    func buildEmojiCell(row: KeyboardRow, emoji: String, index: Int64) {
        Text(this.displayEmoji(emoji))
            .fontSize(row.glyphSize())
            .width(row.itemSize)
            .height(row.itemSize)
            .margin(left: this.tileLeftSpacing(row, index))
            .textAlign(TextAlign.Center)
            .onClick({ evt =>
                this.handleEmojiTap(this.displayEmoji(emoji))
            })
            .onTouch({ event: TouchEvent => this.handleEmojiTouch(event, emoji) })
    }

    @Builder
    func buildCustomEmojiCell(row: KeyboardRow, item: StickerItem, index: Int64) {
        Stack(alignContent: Alignment.Center) {
            CustomEmojiImage(
                documentId: item.documentId,
                size: row.glyphSize(),
                placeholder: "",
                animationEpoch: this.customAnimationEpoch
            )
            if (this.isPremiumLocked(item)) {
                // iOS PremiumBadgeView：右下角一枚毛玻璃底的锁，而不是一颗星。
                //
                // 这里必须外包一层撑满的 Column 来定位：Stack 的子项位置由父级的
                // alignContent 决定（这里是 Center），子项自己链 .align() 改的是
                // **它自身内容**的对齐，不是它在 Stack 里的位置——实测锁被画在
                // 表情正中央，糊在脸上。
                Column {
                    Text("🔒")
                        .fontSize(9)
                        .width(15)
                        .height(15)
                        .textAlign(TextAlign.Center)
                        .borderRadius(8)
                        .backgroundColor(0x66FFFFFF)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.End)
            }
        }
        .width(row.itemSize)
        .height(row.itemSize)
        .margin(left: this.tileLeftSpacing(row, index))
        .onTouch({ event: TouchEvent => this.handleCustomEmojiTouch(event, item) })
        .onClick({ _event =>
            if (this.suppressNextCustomTap) {
                Hilog.info(0, "CjTelegram", "[EmojiTap] 被 suppressNextCustomTap 吞掉")
                this.suppressNextCustomTap = false
            } else if (row.groupKey == EMOJI_GROUP_TRENDING) {
                // iOS ChatEntityKeyboardInputNode.swift:664 —— featuredTop 的点击
                // **不是插入**：找到所属精选包，在面板内打开该包的浏览视图
                //（EmojiSearchContent, initialFocusId=该包）。我们的面板已把未装
                // 精选包渲染成带 Unlock/Add 的完整分组，对位是滚动定位过去。
                this.openFeaturedPackForTrending(item)
            } else {
                this.selectCustomEmoji(item)
            }
        })
    }

    /** 与 StickerGridCell 同一套时序：420ms 不松手且没移开就出预览。 */
    private func handleCustomEmojiTouch(event: TouchEvent, item: StickerItem): Unit {
        // iOS EmojiPagerContentComponent.swift:2841 —— 长按处理器对锁定项直接 return：
        //     if item.0.icon == .locked { return }
        // 锁定的表情用不了，预览它没有意义；点击本来就已经给出 Premium 提示。
        if (this.isPremiumLocked(item)) { return }
        match (event.eventType) {
            case TouchType.Down =>
                this.emojiPressActive = true
                this.emojiPressGeneration = this.emojiPressGeneration + 1
                let token = this.emojiPressGeneration
                let pressed = item
                let _ = spawn {
                    sleep(Duration.millisecond * 420)
                    launch {
                        if (this.emojiPressActive && this.emojiPressGeneration == token) {
                            this.suppressNextCustomTap = true
                            this.previewEmojiItem = pressed
                            this.showEmojiPreview = true
                        }
                    }
                }
            case TouchType.Up =>
                this.emojiPressActive = false
                this.emojiPressGeneration = this.emojiPressGeneration + 1
            case TouchType.Cancel =>
                this.emojiPressActive = false
                this.emojiPressGeneration = this.emojiPressGeneration + 1
            case _ => ()
        }
    }

    /** 6 列自适应肤色板；握手双肤色组合会自动换行，不截断选项。 */
    @Builder
    func buildEmojiVariantOverlay() {
        Column {}
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0x33000000)
            .onClick({ _event => this.dismissVariantPopup() })

        Flex(wrap: FlexWrap.Wrap) {
            ForEach(this.variantOptions, itemGenerator: { emoji: String, _index: Int64 =>
                Text(emoji)
                    .fontSize(28)
                    .width(44)
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .borderRadius(8)
                    .onClick({ _event => this.selectEmojiVariant(emoji) })
            })
        }
        .width(264)
        .padding(6)
        .backgroundColor(0xF5FFFFFF)
        .borderRadius(14)
        .shadow(radius: 12.0, color: Color(0x33000000))
    }

    /**
     * 8 个静态分类折叠成一个固定宽度的胶囊，内部自己横向滚动。
     *
     * iOS EntityKeyboardStaticStickersPanelComponent：这一整组在顶部面板里**只占
     * 一个条目的位置**，8 个图标装在一个 clipsToBounds 的 UIScrollView 里
     *（折叠态 itemSize 26 / spacing 4 / sideInset 2，见该文件 ItemLayout.init）。
     *
     * 我们此前是 8 个各占 36vp，把包封面挤到屏幕外——同账号下 iOS 一眼能看到 7 个包，
     * 我们只有 2 个。胶囊宽度取 4 个条目（144vp），腾出的位置直接归包封面。
     */
    @Builder
    func buildStaticCategoryPill() {
        Scroll {
            Row {
                ForEach(getCategoryIcons(), itemGenerator: { icon: String, index: Int64 =>
                    this.buildCategoryTab(icon, index)
                })
            }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width(144)
        .height(32)
        .borderRadius(16)
        .backgroundColor(0x14000000)
    }

    @Builder
    func buildCategoryTab(icon: String, index: Int64) {
        Column {
            Text(icon)
                .fontSize(20)
                .opacity(if (this.selectedCategory == index) { 1.0 } else { 0.45 })
        }
        .width(36)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(if (this.selectedCategory == index) { 0xFFE3F2FD } else { Color.Transparent })
        .borderRadius(8)
        .onClick({ evt =>
            this.selectStaticCategory(index)
        })
    }

    @Builder
    func buildCustomPackTab(pack: StickerPackInfo) {
        Stack(alignContent: Alignment.Center) {
            if (this.customPackCoverId(pack) != 0) {
                // iOS EntityKeyboardTopPanelComponent.swift:179
                //   itemLayer.isVisibleForAnimations = itemEnvironment.isContentInFocus && ...
                // 判据是「键盘在不在焦点」，**不是**「这一项选没选中」——顶部面板的
                // 全部封面都在播。此前这里只给选中项 epoch，导航条实测帧间差恒为 0.0。
                CustomEmojiImage(
                    documentId: this.customPackCoverId(pack),
                    size: 24.0,
                    placeholder: "",
                    navigationSlot: true,
                    animationEpoch: this.customAnimationEpoch
                )
            } else {
                Text("•").fontSize(20).fontColor(0xFF8E8E93)
            }
        }
        .width(36)
        .height(32)
        .backgroundColor(if (this.selectedCustomPackId == pack.id) { 0xFFE3F2FD } else { Color.Transparent })
        .borderRadius(8)
        .onClick({ _event => this.selectCustomPack(pack) })
    }

    @Builder
    func buildFeaturedEmojiPackTab(pack: StickerPackInfo) {
        Stack(alignContent: Alignment.Center) {
            if (this.customPackCoverId(pack) != 0) {
                CustomEmojiImage(
                    documentId: this.customPackCoverId(pack),
                    size: 24.0,
                    placeholder: "",
                    navigationSlot: true,
                    animationEpoch: this.customAnimationEpoch
                )
            } else {
                Text("+").fontSize(18).fontColor(0xFF007AFF)
            }
        }
        .width(36)
        .height(32)
        .border(width: 1, color: 0x33007AFF)
        .backgroundColor(if (this.selectedCustomPackId == pack.id) { 0xFFE3F2FD } else { Color.Transparent })
        .borderRadius(8)
        .onClick({ _event => this.selectCustomPack(pack) })
    }

    @Builder
    func buildSearchCategoryStrip() {
        Scroll {
            Row {
                ForEach(this.emojiSearchCategories,
                    itemGenerator: { group: EmojiGroupInfo, _index: Int64 =>
                        Column {
                            CustomEmojiImage(
                                documentId: group.iconEmojiId,
                                size: 24.0,
                                placeholder: "",
                                templateMode: true,
                                animationEpoch: -1
                            )
                        }
                        .width(40)
                        .height(36)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .backgroundColor(if (this.selectedSearchCategoryId == group.iconEmojiId) {
                            0xFFE3F2FD
                        } else { Color.Transparent })
                        .borderRadius(18)
                        .onClick({ _event => this.selectSearchCategory(group) })
                    })
            }
            .padding(left: 8, right: 8)
        }
        .height(40)
        .width(100.percent)
        .scrollable(ScrollDirection.Horizontal)
    }

    private func isEmojiPackInstalled(packId: Int64): Bool {
        for (pack in this.installedEmojiPacks) {
            if (pack.id == packId) { return true }
        }
        return false
    }

}

// ==================== Emoji 数据函数 ====================

private func currentEmojiSearchLanguage(): String {
    try {
        let value = I18nSystem.getAppPreferredLanguage().toAsciiLower()
        if (!value.isEmpty()) { return value }
    } catch (_e: Exception) {}
    return "en"
}

private func addUniqueEmoji(result: ArrayList<String>, emoji: String): Unit {
    if (emoji.isEmpty()) { return }
    for (existing in result) {
        if (existing == emoji) { return }
    }
    result.add(emoji)
}

public func getCategoryIcons(): Array<String> {
    return getIOSCategoryIcons()
}

public func getCategoryName(index: Int64): String {
    return getIOSCategoryName(index)
}

/**
 * 与 Telegram-iOS `staticEmojiMapping` 同源的完整分类数据。
 * 旧版的八组手写子集会导致新 Unicode Emoji、完整旗帜和活动/人物项缺失。
 */
public func getCategoryEmojis(index: Int64): Array<String> {
    return getIOSCategoryEmojis(index)
}


