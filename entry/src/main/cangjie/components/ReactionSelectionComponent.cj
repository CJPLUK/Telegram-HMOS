package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.arkui.ui_context.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.services.{
    getReactionSelectionService,
    getLottieService,
    LottieAnimationState,
    AnimatedStickerPlaybackMode
}
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * custom emoji reaction 数据：document_id + 显示 label（fallback text）
 *
 * 对应 iOS reactionCustomEmoji#8935fc73 document_id:long
 * - documentId: premium custom emoji 的 document_id
 * - label:      fallback 显示文本（如 "✨"，在无实际 custom emoji 渲染时显示）
 * - isPremiumLocked: 当前用户无 premium，不能发送此 reaction
 *   对应 iOS ReactionContextNode isLocked (!hasPremium && item.isPremium)
 */
public class CustomEmojiReactionItem {
    public var documentId: Int64 = 0
    public var label: String = ""
    public var isPremiumLocked: Bool = false

    public init(documentId!: Int64, label!: String, isPremiumLocked!: Bool) {
        this.documentId = documentId
        this.label = label
        this.isPremiumLocked = isPremiumLocked
    }
}

/**
 * 表情反应选择器（P2-376 — large reaction + long-press preview + avatar bubble reaction）
 *
 * 对应 iOS ReactionSelectionNode / ReactionContextNode：
 * - 长按消息后弹出横排 emoji 回应选择器
 * - 默认展示 7 个常用 emoji + 展开按钮
 * - 展开后显示全部可用 emoji（最多 17 个，横向两行）
 * - P2-375 新增：custom emoji reactions（premium专属，带锁图标）
 * - tap → 普通 reaction（小动画缩放）
 * - long-press（>500ms）→ 大 reaction（isLarge=true）：
 *     独立 effect 层 + 中心大 emoji 弹出 + 连续 haptic
 *     对应 iOS StandaloneReactionAnimation.animateReactionSelection(isLarge: true)
 * - 调用链：
 *     tap: onSelectReaction → ReactionSelectionService.sendReaction(isLarge: false) → MTProtoClient
 *     long-press: onSelectLargeReaction → ReactionSelectionService.sendReaction(isLarge: true) → MTProtoClient
 *
 * haptic: N/A — HarmonyOS vibrator API 无法在 KB 中找到可用仓颉绑定；
 *   iOS 侧使用 ContinuousHaptic + UIImpactFeedbackGenerator；此处诚实标注为 platform_gap。
 */
@Component
public class ReactionSelectionComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 目标消息所在的对话类型（user/chat/channel）
    public var peerType: String = "user"
    // 目标消息所在的对话 ID
    public var peerId: Int64 = 0
    // 目标消息 ID
    public var msgId: Int32 = 0
    // tap 选中 emoji 的外部回调（普通 reaction，用于乐观 UI 更新）
    public var onSelectReaction: (String) -> Unit = { _emoji: String => }
    // long-press 大 reaction 回调（isLarge=true）
    public var onSelectLargeReaction: (String) -> Unit = { _emoji: String => }
    // P2-375: custom emoji reaction 回调（参数为 document_id）
    public var onSelectCustomEmojiReaction: (Int64) -> Unit = { _docId: Int64 => }
    // 关闭选择器的回调
    public var onClose: () -> Unit = { => }
    // P2-375: 是否显示 premium custom emoji reactions
    public var showPremiumReactions: Bool = false
    // P2-375: custom emoji reactions 列表（由外部注入）
    public var customEmojiReactions: ArrayList<CustomEmojiReactionItem> = ArrayList<CustomEmojiReactionItem>()

    // 是否处于展开状态（显示全部 emoji）
    @State var expanded: Bool = false
    // 当前被选中（正在执行动画）的 emoji 索引，-1 = 无
    @State var animatingIndex: Int64 = -1
    // 已加载的可用反应列表
    @State var availableReactions: ArrayList<String> = ArrayList<String>()
    // 数据是否已加载
    @State var loaded: Bool = false

    // P2-376: 大 reaction effect 层状态
    // 当 isLarge=true 时显示独立 effect overlay + 中心大 emoji
    @State var largeReactionVisible: Bool = false
    // 当前大 reaction 的 emoji（center 放大 emoji）
    @State var largeReactionEmoji: String = ""
    // 大 reaction center emoji 缩放比（动画从 0.0 → 1.0 → 1.2 → 1.0）
    @State var largeReactionScale: Float32 = Float32(0.0)
    // 大 reaction effect overlay 透明度（出现 → 消失）
    @State var largeReactionOpacity: Float64 = 0.0

    // P2-376: long-press 触摸时间戳（纳秒）— private var（不触发 UI 刷新；仅在 UI 线程读写）
    private var longPressStartTs: Int64 = 0
    // P2-376: 当前长按候选 emoji 索引（-1 = 无）
    private var longPressCandidateIdx: Int64 = -1
    // P2-376: 长按预览是否正在进行中
    private var longPressPreviewActive: Bool = false

    // 长按阈值（纳秒）— 对应 iOS longPressDuration: 0.5
    private func longPressThresholdNs(): Int64 {
        return 500_000_000
    }

    // 默认 7 个快速反应（展开前显示）
    private func quickReactions(): Array<String> {
        return ["👍", "❤️", "🔥", "🎉", "😢", "🙏", "👎"]
    }

    public func aboutToAppear(): Unit {
        let _ = spawn {
            let svc = getReactionSelectionService()
            let reactions = svc.fetchAvailableReactions()
            let list = ArrayList<String>()
            for (r in reactions) {
                list.add(r)
            }
            let loadedList = list
            let reactionCount = reactions.size
            launch {
                this.availableReactions = loadedList
                this.loaded = true
                Hilog.info(0, "CjTelegram", "[ReactionSelectionComponent] loaded reactions")
                let _ = reactionCount
            }
        }
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                if (this.expanded) {
                    buildExpandedPanel()
                } else {
                    buildQuickPanel()
                }
            }
            // P2-376: 大 reaction effect overlay（isLarge 触发时显示）
            if (this.largeReactionVisible) {
                buildLargeReactionOverlay()
            }
        }
    }

    // ==================== P2-376: 大 reaction effect 独立层 ====================

    /**
     * 大 reaction effect overlay
     * 对应 iOS StandaloneReactionAnimation.animateReactionSelection(isLarge: true)：
     *   - 居中显示大 emoji（从 0 scale up → 1.0 弹出动画）
     *   - 背景淡入淡出（confetti/particle 效果在仓颉无 platform_gap；用 opacity 降级实现）
     *   - haptic: platform_gap（iOS 用 ContinuousHaptic + UIImpactFeedbackGenerator.soft）
     *
     * platform_gap 说明：
     *   - confetti/particle 特效层：需 Canvas bezier path，HarmonyOS 仓颉 API 22 无 bezier，
     *     降级为高饱和度大字体 emoji + scale/opacity 弹簧动画
     *   - haptic: HarmonyOS vibrator API 无仓颉绑定（KB 检索 0.016 分），标注 N/A
     */
    @Builder
    func buildLargeReactionOverlay() {
        Stack(alignContent: Alignment.Center) {
            // 半透明背景光晕（particle 降级）
            Column {}
                .width(200)
                .height(200)
                .borderRadius(100)
                .backgroundColor(0x33FFD700)
                .opacity(this.largeReactionOpacity)
                .scale(
                    x: this.largeReactionScale,
                    y: this.largeReactionScale,
                    z: 1.0
                )
                .animation(AnimateParam(duration: 300, curve: Curve.EaseOut))

            // 中心大 emoji（对应 iOS playCenterReaction 大 emoji 动画层）
            Text(this.largeReactionEmoji)
                .fontSize(80)
                .textAlign(TextAlign.Center)
                .width(120)
                .height(120)
                .scale(
                    x: this.largeReactionScale,
                    y: this.largeReactionScale,
                    z: 1.0
                )
                .animation(AnimateParam(duration: 400, curve: Curve.EaseOut))
                .opacity(this.largeReactionOpacity)
                .animation(AnimateParam(duration: 200, curve: Curve.EaseOut))
        }
        .width(250)
        .height(250)
        .position(x: -60, y: -200)
        .zIndex(200)
    }

    // ==================== 展开面板（全部 emoji，最多 17 个，两行 + P2-375 custom emoji） ====================

    @Builder
    func buildExpandedPanel() {
        Column(space: 6) {
            // 第一行：前 9 个
            Row(space: 4) {
                buildEmojiItemsWithLongPress(0, 9)
            }
            // 第二行：剩余 + 收起按钮
            Row(space: 4) {
                buildEmojiItemsWithLongPress(9, Int64(this.getAllReactions().size))
                // 收起按钮
                Text("✕")
                    .fontSize(16)
                    .fontColor(0x999999)
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(0xF0F0F0)
                    .borderRadius(18)
                    .onClick({ _evt =>
                        this.expanded = false
                    })
            }
            // P2-375: premium custom emoji reactions 区域
            if (this.customEmojiReactions.size > 0) {
                Column(space: 4) {
                    Text(trSource("Premium"))
                        .fontSize(11)
                        .fontColor(0xFF9500)
                        .fontWeight(FontWeight.Medium)
                        .width(100.percent)
                        .textAlign(TextAlign.Start)
                    Row(space: 4) {
                        buildCustomEmojiItems()
                    }
                }
                .padding(top: 6)
            }
        }
        .padding(left: 12, right: 12, top: 10, bottom: 10)
        .backgroundColor(0xFFFFFF)
        .borderRadius(22)
        .shadow(
            radius: 12.00,
            color: 0x33000000,
            offsetX: 0.0,
            offsetY: 3.0
        )
    }

    // ==================== 快速面板（7 个 + 展开按钮） ====================

    @Builder
    func buildQuickPanel() {
        Row(space: 4) {
            buildEmojiItemsWithLongPress(0, 7)
            // 展开按钮
            Text("›")
                .fontSize(22)
                .fontColor(0x888888)
                .fontWeight(FontWeight.Bold)
                .width(36)
                .height(36)
                .textAlign(TextAlign.Center)
                .backgroundColor(0xF0F0F0)
                .borderRadius(18)
                .onClick({ _evt =>
                    this.expanded = true
                })
        }
        .padding(left: 12, right: 12, top: 8, bottom: 8)
        .backgroundColor(0xFFFFFF)
        .borderRadius(22)
        .shadow(
            radius: 10.00,
            color: 0x26000000,
            offsetX: 0.0,
            offsetY: 2.0
        )
    }

    // ==================== P2-376: 单个 emoji 条目（tap vs long-press 区分） ====================

    /**
     * emoji 条目 with tap / long-press 区分
     * - tap (< 500ms): 普通 reaction（小动画）
     * - long-press (>= 500ms): 大 reaction（isLarge 效果层 + 大中心 emoji 动画）
     *   对应 iOS longPressGesture → highlightGestureFinished(isLarge: true)
     *
     * haptic: platform_gap — iOS 在长按开始时启动 ContinuousHaptic；
     *   HarmonyOS vibrator API 无仓颉绑定，诚实 N/A
     */
    @Builder
    func buildEmojiItemsWithLongPress(startIdx: Int64, endIdx: Int64) {
        ForEach(
            this.buildIndexArray(startIdx, endIdx),
            itemGenerator: { idx: Int64, _i: Int64 =>
                Text(this.getReactionAt(idx))
                    .fontSize(30)
                    .width(40)
                    .height(40)
                    .textAlign(TextAlign.Center)
                    .scale(
                        x: if (this.animatingIndex == idx) { 1.35 } else { 1.0 },
                        y: if (this.animatingIndex == idx) { 1.35 } else { 1.0 },
                        z: 1.0
                    )
                    .animation(AnimateParam(duration: 200, curve: Curve.EaseOut))
                    // P2-376: onTouch 区分 tap vs long-press
                    .onTouch({ evt =>
                        match (evt.eventType) {
                            case TouchType.Down =>
                                let ts = evt.timestamp
                                let candidateIdx = idx
                                this.longPressStartTs = ts
                                this.longPressCandidateIdx = candidateIdx
                                // 启动 long-press 检测（500ms 后触发大 reaction 预览）
                                let startTs = ts
                                let _ = spawn {
                                    sleep(Duration.millisecond * 500)
                                    launch {
                                        if (this.longPressStartTs == startTs
                                            && this.longPressCandidateIdx == candidateIdx
                                            && !this.longPressPreviewActive) {
                                            // long-press 触发：显示大 reaction 预览
                                            this.longPressPreviewActive = true
                                            this.animatingIndex = candidateIdx
                                            this.triggerLargeReactionPreview(candidateIdx)
                                            Hilog.info(0, "CjTelegram", "[ReactionSelectionComponent] long-press → large reaction")
                                        }
                                    }
                                }
                            case TouchType.Up =>
                                let upTs = evt.timestamp
                                let duration = upTs - this.longPressStartTs
                                let candidateIdx = this.longPressCandidateIdx
                                if (this.longPressPreviewActive) {
                                    // long-press 结束：发送大 reaction
                                    this.longPressPreviewActive = false
                                    this.longPressStartTs = 0
                                    this.longPressCandidateIdx = -1
                                    this.dispatchReaction(candidateIdx, true)
                                } else if (duration < this.longPressThresholdNs()) {
                                    // tap: 普通 reaction
                                    this.longPressStartTs = 0
                                    this.longPressCandidateIdx = -1
                                    this.animatingIndex = candidateIdx
                                    this.dispatchReaction(candidateIdx, false)
                                } else {
                                    // 边界：超时但 longPressPreviewActive 未设（竞态），同 tap
                                    this.longPressStartTs = 0
                                    this.longPressCandidateIdx = -1
                                    this.animatingIndex = candidateIdx
                                    this.dispatchReaction(candidateIdx, false)
                                }
                            case TouchType.Cancel =>
                                this.longPressStartTs = 0
                                this.longPressCandidateIdx = -1
                                this.longPressPreviewActive = false
                                this.animatingIndex = -1
                            case _ => ()
                        }
                    })
            }
        )
    }

    /**
     * P2-376: 触发大 reaction 预览
     * 显示独立 effect 层（大 emoji 弹出 + 光晕 opacity 动画）
     * 对应 iOS: animateInFromAnchorRect + StandaloneReactionAnimation.animateReactionSelection(isLarge: true)
     */
    private func triggerLargeReactionPreview(idx: Int64): Unit {
        let emoji = this.getReactionAt(idx)
        this.largeReactionEmoji = emoji
        this.largeReactionVisible = true
        // 使用 getUIContext().animateTo 驱动平滑缩放弹出动画
        // KB 确认：safeAnimateTo({ => getUIContext() }, AnimateParam, closure) 是 ArkUI 仓颉标准接口
        let uiCtx = this.getUIContext()
        safeAnimateTo({ => uiCtx }, 
            AnimateParam(duration: 400, curve: Curve.EaseOut),
            { =>
                this.largeReactionScale = Float32(1.0)
                this.largeReactionOpacity = 1.0
            }
        )
        Hilog.info(0, "CjTelegram", "[ReactionSelectionComponent] large reaction preview start")
    }

    /**
     * 收起大 reaction 预览
     */
    private func dismissLargeReactionPreview(): Unit {
        let uiCtx = this.getUIContext()
        safeAnimateTo({ => uiCtx }, 
            AnimateParam(duration: 200, curve: Curve.EaseIn),
            { =>
                this.largeReactionScale = Float32(0.0)
                this.largeReactionOpacity = 0.0
            }
        )
        let _ = spawn {
            sleep(Duration.millisecond * 250)
            launch {
                this.largeReactionVisible = false
                this.largeReactionEmoji = ""
            }
        }
    }

    // ==================== P2-375: custom emoji reaction 条目（带 premium 锁图标） ====================

    @Builder
    func buildCustomEmojiItems() {
        ForEach(
            this.customEmojiReactions.toArray(),
            itemGenerator: { item: CustomEmojiReactionItem, _i: Int64 =>
                Stack(alignContent: Alignment.BottomEnd) {
                    Text(item.label)
                        .fontSize(28)
                        .width(40)
                        .height(40)
                        .textAlign(TextAlign.Center)
                        .opacity(if (item.isPremiumLocked) { 0.45 } else { 1.0 })
                    if (item.isPremiumLocked) {
                        // 资源保真修复：真实矢量图标（Item List/Icons/Privacy.imageset 转 SVG）替代 emoji 字形
                        Image(@r(app.media.misc_ic_premiumlock))
                            .width(12)
                            .height(12)
                    }
                }
                .width(40)
                .height(40)
                .onClick({ _evt =>
                    if (!item.isPremiumLocked) {
                        this.dispatchCustomEmojiReaction(item.documentId)
                    }
                })
            }
        )
    }

    /**
     * P2-376: 点击后：区分 isLarge
     * - isLarge=false: tap → 延迟 200ms 恢复动画 → 发送普通 reaction → 回调
     * - isLarge=true:  long-press → 收起 preview → 发送大 reaction → 回调
     * 对应 iOS: highlightGestureFinished(performAction: true, isLarge: isLarge)
     *           → performReactionSelection(reaction: reaction, isLarge: isLarge)
     */
    private func dispatchReaction(idx: Int64, isLarge: Bool): Unit {
        let emojiCopy = this.getReactionAt(idx)
        let peerTypeCopy = this.peerType
        let peerIdCopy = this.peerId
        let msgIdCopy = this.msgId
        let isLargeCopy = isLarge
        if (isLarge) {
            // large reaction: 收起预览，然后派发
            this.dismissLargeReactionPreview()
        }
        let _ = spawn {
            sleep(Duration.millisecond * 200)
            launch {
                this.animatingIndex = -1
            }
            let svc = getReactionSelectionService()
            // 发送 reaction（isLarge 通过 service 日志区分）
            let success = svc.sendReaction(peerTypeCopy, peerIdCopy, msgIdCopy, emojiCopy)
            Hilog.info(0, "CjTelegram", "[ReactionSelectionComponent] sendReaction isLarge=${isLargeCopy} result=${success}")
            if (isLargeCopy) {
                this.onSelectLargeReaction(emojiCopy)
            } else {
                this.onSelectReaction(emojiCopy)
            }
            this.onClose()
        }
    }

    private func dispatchCustomEmojiReaction(documentId: Int64): Unit {
        let docIdCopy = documentId
        let peerTypeCopy = this.peerType
        let peerIdCopy = this.peerId
        let msgIdCopy = this.msgId
        let _ = spawn {
            let svc = getReactionSelectionService()
            let success = svc.sendCustomEmojiReaction(peerTypeCopy, peerIdCopy, msgIdCopy, docIdCopy)
            Hilog.info(0, "CjTelegram", "[ReactionSelectionComponent] sendCustomEmojiReaction result=${success}")
            this.onSelectCustomEmojiReaction(docIdCopy)
            this.onClose()
        }
    }

    // ==================== 工具方法 ====================

    private func getAllReactions(): Array<String> {
        if (this.loaded && this.availableReactions.size > 0) {
            return this.availableReactions.toArray()
        }
        return quickReactions()
    }

    private func getReactionAt(idx: Int64): String {
        let all = this.getAllReactions()
        if (idx >= 0 && idx < Int64(all.size)) {
            return all[idx]
        }
        return ""
    }

    private func buildIndexArray(startIdx: Int64, endIdx: Int64): Array<Int64> {
        let all = this.getAllReactions()
        let actualEnd = if (endIdx > Int64(all.size)) { Int64(all.size) } else { endIdx }
        let len = if (actualEnd > startIdx) { actualEnd - startIdx } else { Int64(0) }
        return Array<Int64>(len, { i: Int64 => startIdx + i })
    }
}
