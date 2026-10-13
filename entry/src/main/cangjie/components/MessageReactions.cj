package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import ohos_app_cangjie_entry.utils.safeAnimateTo

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.models.ReactionData
import ohos_app_cangjie_entry.services.{
    getStickersService, getUserPhotoService, StickerItem, StickerPackInfo,
    AvailableReactionsResult
}
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.router.routerPush
import ohos_app_cangjie_entry.app.getAppState
import ohos.resource.__GenerateResource__
import kit.ImageKit.PixelMap
import ohos_app_cangjie_entry.services.{
    ensureAnimatedStickerDocumentLoaded,
    ensureAnimatedStickerDocumentPreviewLoaded,
    getAnimatedStickerDocumentFrame,
    getAnimatedStickerDocumentFrameCount
}

private var _startNextQuickReactionExpanded: Bool = false
private let quickReactionPreloadMonitor = Monitor()
private var quickReactionPreloadStarted: Bool = false

/**
 * Warm the seven reactions used by the collapsed context bar before the first
 * long press. iOS keeps AvailableReactions in AccountContext and starts fetching
 * each ReactionNode resource as soon as the node is prepared. Mirror that
 * behavior by caching metadata, publishing frame zero first, then completing
 * the short appear animations in the background.
 */
public func preloadQuickReactionLottie(): Unit {
    synchronized(quickReactionPreloadMonitor) {
        if (quickReactionPreloadStarted) { return }
        quickReactionPreloadStarted = true
    }
    spawn {
        let service = getStickersService()
        let cached = service.getCachedAvailableReactions()
        if (cached.success && !cached.reactions.isEmpty()) {
            publishQuickReactionItems(cached)
        }
        let result = service.getAvailableReactions(hash: 0)
        if (!result.success || result.reactions.size == 0) {
            if (cached.success && !cached.reactions.isEmpty()) { return }
            synchronized(quickReactionPreloadMonitor) {
                quickReactionPreloadStarted = false
            }
            return
        }
        publishQuickReactionItems(result)
    }
}

public func startNextQuickReactionExpanded(): Unit {
    _startNextQuickReactionExpanded = true
}

private func consumeQuickReactionExpandedStart(): Bool {
    let result = _startNextQuickReactionExpanded
    _startNextQuickReactionExpanded = false
    return result
}

/**
 * 消息反应组件（P2-376 增强版）
 *
 * 对应 TelegramHarmony MessageReactions
 *
 * 功能:
 * - 显示消息的 emoji 反应列表（气泡行）
 * - 每个气泡显示 emoji + 数量，已选中的蓝色高亮
 * - 点击气泡触发 onReactionTap 回调（切换反应）
 * - "+" 按钮触发 onAddReaction 回调（打开反应选择器）
 * - P2-376: 大 reaction 触发时气泡执行"头像气泡弹出"动画
 *   对应 iOS StandaloneReactionAnimation additionalAnimationNode（effectavatar.json 动画）
 *   platform_gap: iOS 播放独立 avatar 粒子 Lottie；此处用 scale+opacity 弹出动画降级
 */
@Component
public class MessageReactions {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // iOS ChatMessageReactionButtonsNode 在父消息 updateNode/apply 时总会收到最新的
    // ReactionsMessageAttribute。这里必须使用父子单向状态通道；普通 var 只在组件首次
    // 创建时取值，父 MessageBubble 后续重绘会复用本组件并保留旧 reaction 数据。
    @Prop var reactions: ArrayList<ReactionData>
    // 是否为发送的消息（影响颜色方案）
    public var isSent: Bool = false
    // 点击已有反应的回调（切换 emoji）
    public var onReactionTap: (String) -> Unit = { _emoji: String => }
    // P2-116: 点击反应计数查看 reactor 列表的回调（参数为 messageId）
    public var onReactionCountTap: (Int64) -> Unit = { _msgId: Int64 => }
    // 消息 ID（传给 onReactionCountTap）
    public var messageId: Int64 = 0
    // 点击 "+" 添加反应的回调
    public var onAddReaction: () -> Unit = { => }
    // P2-376: 大 reaction 触发时通知本组件播放"头像气泡"动画的 emoji
    // 外部在发送大 reaction 成功后设置此字段触发动画
    // 对应 iOS: reactionSelected?.(.reaction, isLarge) → animateReactionSelection(isLarge: true)
    public var largeReactionEmoji: String = ""

    // P2-116: 反应选中时的缩放动画索引（-1=无动画）
    @State var animatingEmoji: String = ""
    // P2-376: 头像气泡弹出动画 emoji
    @State var bubbleAnimEmoji: String = ""
    // P2-376: 气泡弹出缩放值（0.0 → 1.3 → 1.0）
    @State var bubbleScale: Float32 = Float32(0.0)
    // P2-376: 气泡弹出浮层透明度
    @State var bubbleOpacity: Float64 = 0.0
    // P2-376: 气泡弹出浮层是否可见
    @State var bubbleVisible: Bool = false

    public override func aboutToAppear(): Unit {
        // 若外部已设置 largeReactionEmoji，立刻播放头像气泡动画
        if (this.largeReactionEmoji.size > 0) {
            this.playBubbleAnimation(this.largeReactionEmoji)
        }
    }

    /**
     * P2-376: 播放头像气泡弹出动画
     * 对应 iOS: 长按 reaction 后消息气泡上显示 avatar 小人弹出效果
     *   platform_gap: iOS 使用 effectavatar.json Lottie 动画；
     *   此处用 scale+opacity 弹出动画（0→1.3→1.0）降级实现
     * haptic: platform_gap — iOS 在此时调用 hapticFeedback.impact(.soft)；
     *   HarmonyOS 无 vibrator 仓颉绑定，N/A
     */
    public func playBubbleAnimation(emoji: String): Unit {
        this.bubbleAnimEmoji = emoji
        this.bubbleVisible = true
        this.bubbleScale = Float32(0.0)
        this.bubbleOpacity = 0.0
        // 弹出：scale 0→1.3（在 UI 线程调用 animateTo）
        let uiCtx = this.getUIContext()
        safeAnimateTo({ => uiCtx }, 
            AnimateParam(duration: 300, curve: Curve.EaseOut),
            { =>
                this.bubbleScale = Float32(1.3)
                this.bubbleOpacity = 1.0
            }
        )
        // 后续阶段：在 spawn 中 sleep，再通过 launch 回到 UI 线程更新 @State
        // getUIContext() 只在 UI 线程调用，因此在 launch {} 内才调用
        let _ = spawn {
            // 收缩到 1.0
            sleep(Duration.millisecond * 350)
            launch {
                // 回到 UI 线程后再获取 context 并调用 animateTo
                safeAnimateTo({ => uiCtx }, 
                    AnimateParam(duration: 200, curve: Curve.EaseOut),
                    { =>
                        this.bubbleScale = Float32(1.0)
                    }
                )
            }
            // 消失
            sleep(Duration.millisecond * 800)
            launch {
                safeAnimateTo({ => uiCtx }, 
                    AnimateParam(duration: 200, curve: Curve.EaseIn),
                    { =>
                        this.bubbleOpacity = 0.0
                    }
                )
            }
            sleep(Duration.millisecond * 250)
            launch {
                this.bubbleVisible = false
                this.bubbleAnimEmoji = ""
                this.bubbleScale = Float32(0.0)
            }
        }
        Hilog.info(0, "CjTelegram", "[MessageReactions] bubble animation triggered")
    }

    private func avatarCount(reaction: ReactionData): Int64 {
        let count = Int64(reaction.peerIds.size)
        return if (count > 3) { 3 } else { count }
    }

    private func avatarIndices(reaction: ReactionData): Array<Int64> {
        return Array<Int64>(this.avatarCount(reaction), { i: Int64 => i })
    }

    /**
     * 对齐 iOS reaction button 的 value identity + content apply：emoji 是身份，
     * count/selected/recent peers 是内容。ArkUI ForEach 没有独立 updateNode，故把
     * 内容版本并入 key，确保同 emoji 的计数或点赞用户变化时更新对应 chip 子树。
     */
    private func reactionRenderKey(reaction: ReactionData): String {
        var key = reaction.emoji + ":" + reaction.customEmojiDocumentId.toString() + ":" +
            reaction.count.toString() + ":" + reaction.isSelected.toString()
        for (peerId in reaction.peerIds) { key = key + ":" + peerId.toString() }
        for (path in reaction.peerAvatarPaths) { key = key + ":" + path }
        for (initials in reaction.peerInitialsList) { key = key + ":" + initials }
        return key
    }

    private func avatarRenderKey(reaction: ReactionData, index: Int64): String {
        var key = index.toString()
        if (index >= 0 && index < Int64(reaction.peerIds.size)) {
            key = key + ":" + reaction.peerIds[index].toString()
        }
        if (index >= 0 && index < Int64(reaction.peerAvatarPaths.size)) {
            key = key + ":" + reaction.peerAvatarPaths[index]
        }
        if (index >= 0 && index < Int64(reaction.peerInitialsList.size)) {
            key = key + ":" + reaction.peerInitialsList[index]
        }
        return key
    }

    private func hasRecentPeers(reaction: ReactionData): Bool {
        // Telegram's recent_reactions is intentionally a bounded preview, not
        // the complete reactor list. Render every identity the server gives us
        // even when the total count is larger than the preview.
        return !reaction.peerIds.isEmpty()
    }

    private func avatarPath(reaction: ReactionData, index: Int64): String {
        if (index >= 0 && index < Int64(reaction.peerIds.size)) {
            let latestPath = getUserPhotoService().getUserPhotoPath(reaction.peerIds[index])
            // iOS renders the cached peer representation immediately and
            // upgrades it when the full resource is available. At this 20vp
            // size Telegram's stripped thumbnail is a better identity-preserving
            // placeholder than synthetic text such as "Me".
            if (latestPath.startsWith("file://") || latestPath.startsWith("data:image/")) {
                return latestPath
            }
            if (index < Int64(reaction.peerAvatarPaths.size)) {
                let storedPath = reaction.peerAvatarPaths[index]
                if (storedPath.startsWith("file://") || storedPath.startsWith("data:image/")) {
                    return storedPath
                }
            }
        }
        return ""
    }

    private func avatarInitials(reaction: ReactionData, index: Int64): String {
        if (index >= 0 && index < Int64(reaction.peerInitialsList.size)) {
            return reaction.peerInitialsList[index]
        }
        return "?"
    }

    /**
     * 头像式 reaction 的底色保持稳定。当前用户是否参与已经由头像集合直接表达，
     * 若再随 isSelected 切换成高饱和实心色，子树更新时会产生明显的蓝/绿闪变。
     * 仍按消息方向使用 iOS 气泡色系，但不随点赞状态改变整条背景。
     */
    private func chipBgColor(reaction: ReactionData): Int64 {
        if (this.isSent) {
            return 0xFFCDEAC6
        }
        return 0xFFE9F4FC
    }

    /**
     * 与稳定浅底配套的固定前景色。
     */
    private func chipFgColor(reaction: ReactionData): Int64 {
        if (this.isSent) {
            return 0xFF3A7D34
        }
        return 0xFF2481CC
    }

    public func build() {
        Stack(alignContent: Alignment.BottomStart) {
            if (!this.reactions.isEmpty()) {
                // hug-content Row（Flex 主轴默认撑满父容器会把气泡撑大，见 KB）；水平对齐由父
                // Column 的 alignItems 决定（发送 End / 接收 Start），故此处不需再指定 justifyContent。
                Row {
                    ForEach(this.reactions.toArray(), itemGenerator: { reaction: ReactionData, _index: Int64 =>
                        Row(space: 3.vp) {
                            // 自定义表情反应只有 document_id，没有 emoticon —— 走素材渲染
                            if (reaction.isCustomEmoji()) {
                                CustomEmojiImage(
                                    documentId: reaction.customEmojiDocumentId,
                                    size: 18.0
                                )
                            } else {
                                Text(reaction.emoji)
                                    .fontSize(17)
                            }

                            if (this.hasRecentPeers(reaction)) {
                                Row(space: 0.vp) {
                                    ForEach(this.avatarIndices(reaction), itemGenerator: { avatarIndex: Int64, _avatarLoopIndex: Int64 =>
                                        if (this.avatarPath(reaction, avatarIndex).size > 0) {
                                            Stack {
                                                Image(this.avatarPath(reaction, avatarIndex))
                                                    .width(20)
                                                    .height(20)
                                                    .objectFit(ImageFit.Cover)
                                            }
                                            .width(20)
                                            .height(20)
                                            .borderRadius(10)
                                            .clip(true)
                                            .border(width: 1, color: 0xFFFFFFFF)
                                            .margin(left: if (avatarIndex > 0) { -5 } else { 0 })
                                        } else {
                                            Stack {
                                                Circle()
                                                    .width(20)
                                                    .height(20)
                                                    .fill(0xFF5B8DEF)
                                                Text(this.avatarInitials(reaction, avatarIndex))
                                                    .fontSize(8)
                                                    .fontWeight(FontWeight.Medium)
                                                    .fontColor(0xFFFFFFFF)
                                                    .width(20)
                                                    .height(20)
                                                    .textAlign(TextAlign.Center)
                                            }
                                            .width(20)
                                            .height(20)
                                            .borderRadius(10)
                                            .clip(true)
                                            .border(width: 1, color: 0xFFFFFFFF)
                                            .margin(left: if (avatarIndex > 0) { -5 } else { 0 })
                                        }
                                    }, keyGenerator: { avatarIndex: Int64, _avatarKeyIndex: Int64 =>
                                        this.avatarRenderKey(reaction, avatarIndex)
                                    })
                                }
                            } else {
                                Text(reaction.count.toString())
                                    .fontSize(14)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(this.chipFgColor(reaction))
                            }
                        }
                        .height(30)
                        .padding(left: 8, right: 8)
                        .backgroundColor(this.chipBgColor(reaction))
                        .borderRadius(15)
                        .margin(right: 4, bottom: 4)
                        // P2-116: 放大动画
                        .scale(
                            x: if (this.animatingEmoji == reaction.emoji) { Float32(1.2) } else { Float32(1.0) },
                            y: if (this.animatingEmoji == reaction.emoji) { Float32(1.2) } else { Float32(1.0) },
                            z: Float32(1.0)
                        )
                        .animation(AnimateParam(duration: 180, curve: Curve.EaseOut))
                        .onClick({ evt =>
                            let emojiCopy = reaction.emoji
                            this.animatingEmoji = emojiCopy
                            let _ = spawn {
                                sleep(Duration.millisecond * 200)
                                launch { this.animatingEmoji = "" }
                            }
                            this.onReactionTap(emojiCopy)
                        })
                    }, keyGenerator: { reaction: ReactionData, _reactionKeyIndex: Int64 =>
                        this.reactionRenderKey(reaction)
                    })
                }
                .padding(left: 8, right: 4, top: 5, bottom: 0)
            }

            // P2-376: 头像气泡弹出动画浮层
            // 对应 iOS: StandaloneReactionAnimation additionalAnimationNode
            //   （isLarge=true 时在消息气泡上弹出的 avatar 动画）
            if (this.bubbleVisible) {
                Stack(alignContent: Alignment.Center) {
                    // 光晕背景
                    Column {}
                        .width(60)
                        .height(60)
                        .borderRadius(30)
                        .backgroundColor(0x33FFD700)
                        .opacity(this.bubbleOpacity * 0.6)
                    // 头像气泡（emoji 字符 fallback；iOS 用真实头像）
                    Text(this.bubbleAnimEmoji)
                        .fontSize(32)
                        .textAlign(TextAlign.Center)
                        .width(48)
                        .height(48)
                }
                .width(80)
                .height(80)
                .scale(
                    x: this.bubbleScale,
                    y: this.bubbleScale,
                    z: 1.0
                )
                .opacity(this.bubbleOpacity)
                .position(x: 0, y: -80)
                .zIndex(100)
            }
        }
    }
}

/**
 * 单条快速反应条目视图模型（emoji + 是否会员专属锁定）
 *
 * 对应 iOS ReactionContextNode.isLocked (!hasPremium && item.isPremium)
 * isLocked 在加载时基于 AvailableReactionInfo.isPremium + 当前用户 isPremium 预先算好，
 * 渲染/点击时只读这个字段，不在 build() 内做布尔运算（避免 D-116 build() 内 let 限制）。
 */
public class QuickReactionItem <: ToString {
    public var emoji: String = ""
    public var title: String = ""
    public var isLocked: Bool = false
    public var document: StickerItem = StickerItem()
    public var customDocumentId: Int64 = 0

    public init(
        emoji!: String,
        isLocked!: Bool,
        title!: String = "",
        document!: StickerItem = StickerItem(),
        customDocumentId!: Int64 = 0
    ) {
        this.emoji = emoji
        this.title = title
        this.isLocked = isLocked
        this.document = document
        this.customDocumentId = customDocumentId
    }

    public func toString(): String {
        return this.emoji + "_" + this.customDocumentId.toString()
    }
}

private var quickReactionPreloadedItems = ArrayList<QuickReactionItem>()

private func cacheQuickReactionItems(items: ArrayList<QuickReactionItem>): Unit {
    synchronized(quickReactionPreloadMonitor) {
        quickReactionPreloadedItems = items
    }
}

private func getCachedQuickReactionItems(): ArrayList<QuickReactionItem> {
    synchronized(quickReactionPreloadMonitor) {
        return quickReactionPreloadedItems
    }
}

private func publishQuickReactionItems(result: AvailableReactionsResult): Unit {
    let premiumUser = isCurrentUserPremium()
    let warmedItems = ArrayList<QuickReactionItem>()
    for (info in result.reactions) {
        if (!info.isInactive) {
            warmedItems.add(QuickReactionItem(
                emoji: info.reaction,
                isLocked: info.isPremium && !premiumUser,
                title: info.title,
                document: info.appearAnimation
            ))
        }
    }
    if (!warmedItems.isEmpty()) {
        cacheQuickReactionItems(warmedItems)
        warmQuickReactionDocuments(warmedItems, 7)
    }
}

/**
 * Global reaction artwork warm-up shared by AppRoot and every chat.
 *
 * Preview publication is the latency-critical phase: the context bar never
 * needs to wait for a complete animation to display artwork. Full rendering
 * follows on the same worker and normally finishes before the first long
 * press; service-level caches deduplicate concurrent chat/menu requests.
 */
private func warmQuickReactionDocuments(
    source: ArrayList<QuickReactionItem>, limit: Int64
): Unit {
    let count = if (Int64(source.size) < limit) { Int64(source.size) } else { limit }
    var index: Int64 = 0
    while (index < count) {
        let document = source[index].document
        if (!document.isEmpty && document.documentId != 0) {
            let _ = spawn {
                if (ensureAnimatedStickerDocumentPreviewLoaded(document)) {
                    Hilog.info(0, "CjTelegram",
                        "[QuickReactionPreload] preview ready document=${document.documentId}")
                    if (ensureAnimatedStickerDocumentLoaded(document)) {
                        Hilog.info(0, "CjTelegram",
                            "[QuickReactionPreload] animation ready document=${document.documentId}")
                    }
                }
            }
        }
        index = index + 1
    }
}

/**
 * Message context-menu reaction bar backed by Telegram's available-reactions API.
 *
 * Premium reactions remain visible but locked for non-premium accounts. A
 * static free set keeps the menu usable while the network source is unavailable.
 */
@Component
public class QuickReactionBar {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var onSelectReaction: (String) -> Unit = { _emoji: String => }
    public var onSelectCustomReaction: (Int64) -> Unit = { _documentId: Int64 => }
    public var onClose: () -> Unit = { => }
    public var onExpanded: () -> Unit = { => }
    // Mirrors iOS ReactionContextNode's visualBackgroundFrame: the host must
    // use the real pill width as its hit region, never a fixed full-row box.
    public var onContentWidthChanged: (Float64) -> Unit = { _width: Float64 => }
    // iOS staggers from the cloud tail nearest the selected message.
    public var animateFromRight: Bool = false
    // Native previews must close ArkUI's context menu explicitly. Page-local
    // overlays own their dismissal and must not reach into that controller.
    public var closeNativeContextMenu: Bool = true
    public var embeddedInPopup: Bool = false
    @State var showExpanded: Bool = false
    @State var appearedItemCount: Int64 = 0
    @State var expandedVisible: Bool = false
    // 已加载的反应列表（含 premium 锁定标记），加载完成前使用 defaultItems() 兜底
    @State var items: ArrayList<QuickReactionItem> = ArrayList<QuickReactionItem>()
    @State var loaded: Bool = false
    @State var emojiPacks: ArrayList<StickerPackInfo> = ArrayList<StickerPackInfo>()
    @State var customItems: ArrayList<QuickReactionItem> = ArrayList<QuickReactionItem>()
    @State var searchItems: ArrayList<QuickReactionItem> = ArrayList<QuickReactionItem>()
    @State var selectedPackIndex: Int64 = -1
    @State var searchText: String = ""
    @State var packLoading: Bool = false
    @State var searchLoading: Bool = false
    @State var animationEpoch: Int64 = 0
    private var animationTimer: Option<Timer> = None<Timer>

    public override func aboutToAppear(): Unit {
        this.startAnimationClock()
        // ChatRoomPage normally populated this cache before the first long
        // press. Publish it synchronously so the first rendered artwork can be
        // the already-decoded Lottie frame, without a second metadata wait.
        let cachedItems = getCachedQuickReactionItems()
        if (cachedItems.size > 0) {
            this.items = cachedItems
            this.loaded = true
            // Do not wait for the three refresh RPCs below. AppRoot normally
            // completed this work already; this call is an idempotent safety
            // net for a long press immediately after account restoration.
            this.preloadReactionDocuments(cachedItems, 7)
        }
        this.onContentWidthChanged(this.collapsedContentWidth())
        if (consumeQuickReactionExpandedStart()) {
            this.showExpanded = true
            this.expandedVisible = true
            this.appearedItemCount = 8
        } else {
            let _ = spawn {
                sleep(Duration.millisecond * 10)
                var visibleCount: Int64 = 1
                while (visibleCount <= 8) {
                    let count = visibleCount
                    launch { this.appearedItemCount = count }
                    sleep(Duration.millisecond * 38)
                    visibleCount += 1
                }
            }
        }
        let _ = spawn {
            let svc = getStickersService()
            let result = svc.getAvailableReactions(hash: 0)
            let packsResult = svc.getEmojiStickers(hash: 0)
            let featuredPacksResult = svc.getFeaturedEmojiPacks(hash: 0)
            let premiumUser = isCurrentUserPremium()
            let built = ArrayList<QuickReactionItem>()
            if (result.success && result.reactions.size > 0) {
                for (info in result.reactions) {
                    if (!info.isInactive) {
                        let locked = info.isPremium && !premiumUser
                        built.add(QuickReactionItem(
                            emoji: info.reaction,
                            isLocked: locked,
                            title: info.title,
                            document: info.appearAnimation
                        ))
                    }
                }
            }
            let finalItems = built
            let finalCount = built.size
            if (finalCount > 0) { cacheQuickReactionItems(finalItems) }
            let packs = ArrayList<StickerPackInfo>()
            for (pack in packsResult.packs) { packs.add(pack) }
            for (featuredPack in featuredPacksResult.packs) {
                var duplicate = false
                for (installedPack in packs) {
                    if (installedPack.id == featuredPack.id) { duplicate = true }
                }
                if (!duplicate) { packs.add(featuredPack) }
            }
            launch {
                if (finalCount > 0) {
                    this.items = finalItems
                } else {
                    this.items = defaultQuickReactionItems()
                }
                this.loaded = true
                this.emojiPacks = packs
                this.onContentWidthChanged(this.collapsedContentWidth())
                Hilog.info(0, "CjTelegram", "[QuickReactionBar] loaded reactions count=${finalCount}, emojiPacks=${packs.size}")
            }
            this.preloadReactionDocuments(built, 7)
            this.preloadPackCovers(packs, 8)
        }
    }

    public override func aboutToDisappear(): Unit {
        match (this.animationTimer) {
            case Some(timer) =>
                timer.cancel()
                this.animationTimer = None<Timer>
            case None => ()
        }
    }

    private func startAnimationClock(): Unit {
        this.animationTimer = Some(Timer.repeat(
            Duration.millisecond * 34,
            Duration.millisecond * 34,
            { =>
                if (getAppState().isInForeground()) {
                    launch { this.animationEpoch = this.animationEpoch + 1 }
                }
            },
            style: CatchupStyle.Skip
        ))
    }

    private func documentFrame(item: QuickReactionItem): PixelMap {
        let count = getAnimatedStickerDocumentFrameCount(item.document.documentId)
        if (count > 0) {
            match (getAnimatedStickerDocumentFrame(item.document.documentId, this.animationEpoch % count)) {
                case Some(pixelMap) => return pixelMap
                case None => ()
            }
        }
        return getEmptyAnimatedEmojiPixelMap()
    }

    private func documentReady(item: QuickReactionItem): Bool {
        return getAnimatedStickerDocumentFrameCount(item.document.documentId) > 0
    }

    private func packLabel(pack: StickerPackInfo): String {
        let runes = pack.title.toRuneArray()
        if (runes.size > 0) { return runes[0].toString() }
        return "•"
    }

    private func packCoverReady(pack: StickerPackInfo): Bool {
        return pack.cover.documentId != 0 && getAnimatedStickerDocumentFrameCount(pack.cover.documentId) > 0
    }

    private func packCoverDocumentId(pack: StickerPackInfo): Int64 {
        if (pack.cover.documentId != 0) { return pack.cover.documentId }
        return pack.thumbDocumentId
    }

    private func packCoverFrame(pack: StickerPackInfo): PixelMap {
        let count = getAnimatedStickerDocumentFrameCount(pack.cover.documentId)
        if (count > 0) {
            match (getAnimatedStickerDocumentFrame(pack.cover.documentId, this.animationEpoch % count)) {
                case Some(pixelMap) => return pixelMap
                case None => ()
            }
        }
        return getEmptyAnimatedEmojiPixelMap()
    }

    private func preloadReactionDocuments(source: ArrayList<QuickReactionItem>, limit: Int64): Unit {
        let count = if (Int64(source.size) < limit) { Int64(source.size) } else { limit }
        var index: Int64 = 0
        while (index < count) {
            let document = source[index].document
            let _ = spawn {
                let previewLoaded = ensureAnimatedStickerDocumentPreviewLoaded(document)
                if (previewLoaded) {
                    launch { this.animationEpoch = this.animationEpoch + 1 }
                    // Frame zero is already visible. Continue immediately so
                    // the short appear animation is ready without an artificial
                    // one-second dead period.
                    if (ensureAnimatedStickerDocumentLoaded(document)) {
                        launch { this.animationEpoch = this.animationEpoch + 1 }
                    }
                }
            }
            index = index + 1
        }
    }

    private func preloadPackCovers(source: ArrayList<StickerPackInfo>, limit: Int64): Unit {
        let count = if (Int64(source.size) < limit) { Int64(source.size) } else { limit }
        var index: Int64 = 0
        while (index < count) {
            let cover = source[index].cover
            if (cover.documentId != 0) {
                let _ = spawn {
                    if (ensureAnimatedStickerDocumentLoaded(cover)) {
                        launch { this.animationEpoch = this.animationEpoch + 1 }
                    }
                }
            }
            index = index + 1
        }
    }

    private func selectStandardGroup(): Unit {
        this.selectedPackIndex = -1
        this.searchText = ""
        this.searchItems = ArrayList<QuickReactionItem>()
    }

    private func selectEmojiPack(index: Int64): Unit {
        if (index < 0 || index >= Int64(this.emojiPacks.size)) { return }
        this.selectedPackIndex = index
        this.searchText = ""
        this.searchItems = ArrayList<QuickReactionItem>()
        this.packLoading = true
        let pack = this.emojiPacks[index]
        let premiumUser = isCurrentUserPremium()
        let _ = spawn {
            let detail = getStickersService().getStickerSet(pack.id, pack.accessHash)
            let loadedItems = ArrayList<QuickReactionItem>()
            if (detail.success) {
                for (sticker in detail.stickers) {
                    loadedItems.add(QuickReactionItem(
                        emoji: sticker.altEmoji,
                        isLocked: sticker.isCustomEmoji && !sticker.isFreeEmoji && !premiumUser,
                        title: detail.info.title,
                        document: sticker,
                        customDocumentId: sticker.documentId
                    ))
                }
            }
            launch {
                if (this.selectedPackIndex == index) {
                    this.customItems = loadedItems
                    this.packLoading = false
                }
            }
            this.preloadReactionDocuments(loadedItems, 24)
        }
    }

    private func updateSearch(value: String): Unit {
        this.searchText = value
        if (value.size == 0) {
            this.searchItems = ArrayList<QuickReactionItem>()
            this.searchLoading = false
            return
        }
        this.searchLoading = true
        let query = value
        let premiumUser = isCurrentUserPremium()
        let _ = spawn {
            sleep(Duration.millisecond * 180)
            let result = getStickersService().searchCustomEmoji(query)
            let found = ArrayList<QuickReactionItem>()
            if (result.success) {
                for (sticker in result.documents) {
                    found.add(QuickReactionItem(
                        emoji: sticker.altEmoji,
                        isLocked: sticker.isCustomEmoji && !sticker.isFreeEmoji && !premiumUser,
                        document: sticker,
                        customDocumentId: sticker.documentId
                    ))
                }
            }
            launch {
                if (this.searchText == query) {
                    this.searchItems = found
                    this.searchLoading = false
                }
            }
            this.preloadReactionDocuments(found, 24)
        }
    }

    private func expandedItems(): ArrayList<QuickReactionItem> {
        if (this.searchText.size > 0) { return this.searchItems }
        if (this.selectedPackIndex >= 0) { return this.customItems }
        return this.currentItems()
    }

    // 收起态：前 7 条 + 展开箭头
    private func collapsedCount(): Int64 {
        let all = this.currentItems()
        return if (Int64(all.size) < 7) { Int64(all.size) } else { 7 }
    }

    /** Exact collapsed visual width: item slots + expand slot + gaps + padding. */
    private func collapsedContentWidth(): Float64 {
        let slotCount = this.collapsedCount() + 1
        let gapCount = if (slotCount > 0) { slotCount - 1 } else { 0 }
        return Float64(slotCount) * 36.0 + Float64(gapCount) * 8.0 + 12.0
    }

    // 展开态：全部条目（最多与服务端返回一致，无固定上限截断）
    private func expandedCount(): Int64 {
        return Int64(this.expandedItems().size)
    }

    private func currentItems(): ArrayList<QuickReactionItem> {
        if (this.loaded && this.items.size > 0) {
            return this.items
        }
        return defaultQuickReactionItems()
    }

    private func itemAt(idx: Int64): QuickReactionItem {
        let all = if (this.showExpanded) { this.expandedItems() } else { this.currentItems() }
        if (idx >= 0 && idx < Int64(all.size)) {
            return all[idx]
        }
        return QuickReactionItem(emoji: "", isLocked: false)
    }

    private func indexArray(count: Int64): Array<Int64> {
        return Array<Int64>(count, { i: Int64 => i })
    }

    private func itemHasAppeared(idx: Int64, count: Int64): Bool {
        if (this.showExpanded) { return true }
        if (this.animateFromRight) { return idx >= count - this.appearedItemCount }
        return idx < this.appearedItemCount
    }

    /** Route locked reactions to the premium page without applying a reaction. */
    private func dispatchTap(item: QuickReactionItem): Unit {
        if (item.isLocked) {
            if (this.closeNativeContextMenu) {
                this.getUIContext().getContextMenuController().close()
            }
            this.onClose()
            routerPush("PremiumPage", "")
            Hilog.info(0, "CjTelegram", "[QuickReactionBar] premium-locked reaction tapped -> menu closed -> PremiumPage")
        } else {
            if (this.closeNativeContextMenu) {
                this.getUIContext().getContextMenuController().close()
            }
            if (item.customDocumentId != 0) {
                this.onSelectCustomReaction(item.customDocumentId)
            } else {
                this.onSelectReaction(item.emoji)
            }
        }
    }

    private func expandPicker(): Unit {
        this.showExpanded = true
        this.onExpanded()
        this.expandedVisible = false
        let uiCtx = this.getUIContext()
        let _ = spawn {
            sleep(Duration.millisecond * 16)
            launch {
                safeAnimateTo({ => uiCtx }, 
                    AnimateParam(duration: 400, curve: Curve.Friction),
                    { => this.expandedVisible = true }
                )
            }
        }
    }

    @Builder
    func buildReactionItems(count: Int64) {
        ForEach(
            this.indexArray(count),
            itemGeneratorFunc: { idx: Int64, _i: Int64 =>
                // iOS tests each 36 pt item again with an 8 pt expanded
                // inset. ArkUI cannot override hitTest, so the collapsed row
                // uses one stable 44 pt interaction slot per item while the
                // visible artwork remains centered at its original 36 pt.
                Stack(alignContent: Alignment.Center) {
                    Stack(alignContent: Alignment.BottomEnd) {
                        if (this.documentReady(this.itemAt(idx))) {
                            Image(this.documentFrame(this.itemAt(idx)))
                                // Keep node identity stable while only its
                                // PixelMap frame changes. Re-keying at 29 fps
                                // can cancel a Down/Up click sequence.
                                .id("reaction_${this.itemAt(idx).document.documentId}")
                                .width(if (this.showExpanded) { 36 } else { 30 })
                                .height(if (this.showExpanded) { 36 } else { 30 })
                                .objectFit(ImageFit.Contain)
                                .opacity(if (this.itemAt(idx).isLocked) { 0.45 } else { 1.0 })
                        } else {
                            // Preserve geometry while the TGS document is decoded,
                            // but never flash the platform's static Emoji artwork.
                            Column {}
                                .width(if (this.showExpanded) { 36 } else { 30 })
                                .height(if (this.showExpanded) { 36 } else { 30 })
                        }
                        if (this.itemAt(idx).isLocked) {
                            Image(@r(app.media.misc_ic_premiumlock))
                                .width(10)
                                .height(10)
                        }
                    }
                    .width(if (this.showExpanded) { 38 } else { 36 })
                    .height(if (this.showExpanded) { 38 } else { 36 })
                }
                .width(if (this.showExpanded) { 38 } else { 44 })
                .height(if (this.showExpanded) { 38 } else { 36 })
                .margin(
                    right: if (this.showExpanded) { 3 } else { 0 },
                    bottom: if (this.showExpanded) { 5 } else { 0 }
                )
                .scale(
                    x: if (this.itemHasAppeared(idx, count)) { Float32(1.0) } else { Float32(0.01) },
                    y: if (this.itemHasAppeared(idx, count)) { Float32(1.0) } else { Float32(0.01) },
                    z: Float32(1.0)
                )
                .opacity(if (this.itemHasAppeared(idx, count)) { 1.0 } else { 0.0 })
                .animation(AnimateParam(duration: 400, curve: Curve.Friction))
                .onClick({ _evt => this.dispatchTap(this.itemAt(idx)) })
            },
            keyGeneratorFunc: { idx: Int64, _i: Int64 => this.itemAt(idx).toString() + "_" + idx.toString() }
        )
    }

    public func build() {
        Column {
            if (this.showExpanded) {
                Column(space: 6) {
                    Row {
                        this.buildReactionItems(if (this.expandedCount() < 7) { this.expandedCount() } else { 7 })
                    }
                    .width(306)
                    .height(42)

                    SearchBar(
                        loading: false,
                        backArrow: false,
                        text: this.searchText,
                        hint: trSource("Search Reactions"),
                        onChange: { value: String => this.updateSearch(value) }
                    )

                    Scroll() {
                        Row(space: 8.vp) {
                            Stack(alignContent: Alignment.Center) {
                                Text("◷").fontSize(19).fontColor(0xFF2481CC)
                            }
                            .width(32).height(32)
                            .borderRadius(16)
                            .backgroundColor(if (this.selectedPackIndex < 0) { 0xFFE5F2FC } else { Color.Transparent })
                            .onClick({ _evt => this.selectStandardGroup() })

                            ForEach(this.emojiPacks.toArray(), itemGenerator: { pack: StickerPackInfo, index: Int64 =>
                                Stack(alignContent: Alignment.Center) {
                                    if (this.packCoverReady(pack)) {
                                        Image(this.packCoverFrame(pack))
                                            .id("reaction_pack_${pack.cover.documentId}")
                                            .width(26).height(26)
                                            .objectFit(ImageFit.Contain)
                                    } else if (this.packCoverDocumentId(pack) != 0) {
                                        CustomEmojiImage(
                                            documentId: this.packCoverDocumentId(pack),
                                            size: 26.0,
                                            navigationSlot: true,
                                            animationEpoch: this.animationEpoch
                                        )
                                    } else {
                                        Text(this.packLabel(pack)).fontSize(16).fontWeight(FontWeight.Medium)
                                    }
                                }
                                .width(32).height(32)
                                .borderRadius(16)
                                .backgroundColor(if (this.selectedPackIndex == index) { 0xFFE5F2FC } else { Color.Transparent })
                                .onClick({ _evt => this.selectEmojiPack(index) })
                            })
                        }
                    }
                    .width(306)
                    .height(36)
                    .scrollable(ScrollDirection.Horizontal)

                    Scroll() {
                        Flex(wrap: FlexWrap.Wrap) {
                            this.buildReactionItems(this.expandedCount())
                        }
                        .width(306)
                    }
                    .width(306)
                    .height(190)
                }
                .width(330)
                .height(326)
                .padding(left: 12, right: 12, top: 10, bottom: 10)
                .backgroundColor(if (this.embeddedInPopup) { Color.Transparent } else { Color(0xFFFFFFFF) })
                .borderRadius(26)
                .shadow(
                    radius: if (this.embeddedInPopup) { 0.0 } else { 10.0 },
                    color: if (this.embeddedInPopup) { Color.Transparent } else { Color(0x26000000) },
                    offsetX: 0.0,
                    offsetY: 2.0
                )
                .scale(
                    x: if (this.expandedVisible) { Float32(1.0) } else { Float32(0.94) },
                    y: if (this.expandedVisible) { Float32(1.0) } else { Float32(0.94) },
                    z: Float32(1.0)
                )
                .opacity(if (this.expandedVisible) { 1.0 } else { 0.0 })
                .animation(AnimateParam(duration: 400, curve: Curve.Friction))
            } else {
                Row {
                    this.buildReactionItems(this.collapsedCount())
                    Stack(alignContent: Alignment.Center) {
                        Image(@r(app.media.chatroom_ic_reaction_expand))
                            .width(15)
                            .height(9)
                    }
                        .width(36)
                        .height(36)
                        .backgroundColor(0x66E5E5EA)
                        .borderRadius(18)
                        .scale(
                            x: if (this.appearedItemCount >= 8) { Float32(1.0) } else { Float32(0.01) },
                            y: if (this.appearedItemCount >= 8) { Float32(1.0) } else { Float32(0.01) },
                            z: Float32(1.0)
                        )
                        .opacity(if (this.appearedItemCount >= 8) { 1.0 } else { 0.0 })
                        .animation(AnimateParam(duration: 400, curve: Curve.Friction))
                        .onClick({ evt =>
                            this.expandPicker()
                        })
                }
                .padding(left: 6, right: 6, top: 10, bottom: 10)
                .backgroundColor(0xD9FFFFFF)
                .backdropBlur(24.0)
                .borderRadius(28)
                .shadow(
                    radius: 10.00,
                    color: 0x26000000,
                    offsetX: 0.0,
                    offsetY: 2.0
                )
            }
        }
    }
}

/**
 * 兜底反应集合（网络失败/服务端空响应时使用）：与
 * ReactionSelectionService.defaultFreeReactions() 保持一致的 17 个免费表情，
 * 全部 isLocked=false（离线场景下不应把用户挡在付费墙外，保底可用）。
 */
func defaultQuickReactionItems(): ArrayList<QuickReactionItem> {
    let emojis = ["👍", "👎", "❤️", "🔥", "🎉", "🤩", "😱", "😁", "😢", "🙏", "🤔", "🤯", "🥰", "🤮", "💩", "🤬", "👏"]
    let list = ArrayList<QuickReactionItem>()
    for (e in emojis) {
        list.add(QuickReactionItem(emoji: e, isLocked: false))
    }
    return list
}

/**
 * 当前用户是否为 Premium 会员（AuthStorage 持久化，同步读取）
 * 与 ChatFoldersPage.isPremiumUser() 同款判定逻辑（getAuthStorage().getUserData().isPremium）
 */
func isCurrentUserPremium(): Bool {
    match (getAuthStorage().getUserData()) {
        case Some(user) => user.isPremium
        case None => false
    }
}
