package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.services.{failedStoreHas, failedStoreLastText, failedStoreLastTimestamp, triggerHaptic}
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.utils.formatRelativeTimestamp
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, PresentationStringsSnapshot, currentPresentationStrings}
import std.sync.*
import std.time.*

/**
 * 聊天列表项组件（P2-100/105/106 iOS 保真度对齐版）
 *
 * 对照 iOS ChatListItem.swift + ChatListItemStrings.swift 补齐缺口：
 *
 * P2-100:
 *   - 时间戳格式 HH:mm / Yesterday / M/D / M/D/YY（由 formatTimestamp 生成，此处直接显示 chat.time）
 *   - 置顶 pin 图标（已有 📌）
 *   - 静音图标 🔇（已有）
 *   - 对话类型图标：频道 📢 / 保密聊天 🔒（新增）
 *   - 消息状态勾：✓（灰=已发未读）/ ✓✓（蓝=已读）（已有，保留）
 *
 * P2-105:
 *   - 未读数 badge（圆形，正常蓝/静音灰）（已有，保留）
 *   - 未读提及 @ badge（蓝圆/灰圆视静音状态）（新增）
 *   - Reaction badge 💬（蓝圆）（新增）
 *   - 多 badge 竖排（mention → reaction → unread 从上到下）（新增）
 *
 * P2-106:
 *   - 发送者前缀：群组中显示 "You: " 或 "Name: "（新增）
 *   - 媒体类型图标：🖼 Photo / 📹 Video / 🎤 Voice / 📎 File / 📍 Location 等（增强）
 *   - Saved Messages 显示（isSavedMessages，由头像处理，预览仅显示文本）
 *   - Draft 红色前缀（已有，保留）
 *   - typing 指示（已有，保留）
 *
 * 布局：
 * ┌──────────────────────────────────────────────────────────┐
 * │ [头像🟢]  📌🔒📢 联系人名称        14:30               │
 * │           ✓✓ You: 🖼 Photo        🔇 [@] [💬] [3]      │
 * └──────────────────────────────────────────────────────────┘
 */
@Component
public class ChatListItem {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 返修（diag-suite_settings_appearance-TC-0401-round9.md F-1）：本订阅曾在 c129b3fd5（RC-3）
    // 交付并通过评审，被 a8998a341（整文件取 origin/main 覆盖）连带删除，导致聊天列表行不随
    // 主题切换。@StorageLink 可在非 @Entry 的普通 @Component 子组件内直接使用（与 AppStorage
    // 双向同步，不依赖父组件传参），写法与仓内先例一致：pages/MainTabPage.cj:100、
    // pages/AppearanceSettingsPage.cj:44。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()

    @Prop var chat: Chat

    var isTyping: Bool = false
    // F-4（diag-suite_settings_appearance-TC-0417-round5.md，peer_avatar_node 授权改动，2 行纯转发）：
    // 转发给 Avatar 的字母覆盖参数，默认空串不改变现有调用点行为。
    public var avatarLetters: String = ""

    public var onClick: () -> Unit = { => }
    /** 长按触发；参数为被按行的窗口 Y 与高度（vp），面板据此定位并从行处弹出 */
    public var onLongPress: (Float64, Float64) -> Unit = { _y: Float64, _h: Float64 => }
    /**
     * 长按激活后手指仍未抬起时的移动 / 抬起回调（窗口坐标 vp）。
     *
     * 对齐 iOS：ContextGesture 激活时只是把 state 置为 .began，**手势不结束**，
     * 之后继续把坐标喂给 ContextController（ContextControllerImpl.swift:222-254 的
     * externalUpdated / externalEnded），于是可以按住不放直接滑到某个动作上松手执行，
     * 跨行时还有一次轻触觉。此前我们在触发瞬间就结束手势，用户必须抬手再点一次。
     */
    public var onLongPressMove: (Float64, Float64) -> Unit = { _x: Float64, _y: Float64 => }
    public var onLongPressEnd: () -> Unit = { => }

    // CTL-SHARED-002: 行按压高亮态
    @State var isPressed: Bool = false

    // 长按识别 —— 与消息气泡统一为同一套语义（MessageBubble.handleMessageContextTouch）：
    // 按下即起定时器、手指移动超阈值取消、触发时给触觉反馈。
    // 此前是在 TouchType.Up 里回算按住时长，导致必须**松手之后**菜单才出现，
    // 且滑动列表时只要手指停留够久同样会误触发。
    private var pressGeneration: Int64 = 0
    private var pressActive: Bool = false
    private var touchStartX: Float64 = 0.0
    private var touchStartY: Float64 = 0.0
    // 长按已消费本次手势，随后的 onClick 不应再进会话
    private var suppressNextClick: Bool = false
    // 长按已激活、手指仍在屏幕上：后续 Move/Up 转发给页面做动作高亮与执行
    private var contextActive: Bool = false

    /**
     * 按压缩放 —— 对齐 iOS ContextControllerSourceNode.activationProgress。
     *
     * iOS 的时序是两段：beginDelay 120ms **完全无反馈**，随后一个 200ms 的
     * DisplayLinkAnimator 把 progress 线性推到 1，progress 持续驱动行缩小到
     *   minScale = max(0.7, (w - 15) / w)
     * （ContextControllerSourceNode.swift:95-99），激活发生在动画结束时（合计 320ms）。
     * 提前松手则 200ms easeOut 弹回（同文件 .ended 分支）。
     *
     * 此前我们只有一个 isPressed 布尔量切背景色，没有任何渐进反馈，
     * 用户按下去在触发前完全不知道「正在长按」。
     */
    // R-131: ArkUI 的 .scale 收 Float32
    @State var pressScale: Float32 = 1.0
    // 行宽（vp），用于按 iOS 公式算 minScale；未测量到时用整屏宽度的常见值兜底
    private var rowWidth: Float64 = 390.0
    // 行在窗口中的顶缘与高度（vp）—— 交给页面给菜单定位、做起跳动画
    private var rowTop: Float64 = 0.0
    private var rowHeight: Float64 = 76.0

    private func getDraftPreview(): String {
        let draft = this.chat.draftText
        if (draft.size > 50) {
            let runes = draft.toRuneArray()
            var preview = ""
            var count: Int64 = 0
            for (r in runes) {
                if (count >= 50) { break }
                preview = preview + r.toString()
                count = count + 1
            }
            return preview + "..."
        }
        return draft
    }

    /**
     * P2-106: 媒体类型 → 带 emoji 前缀的预览文本
     * 对应 iOS ChatListItemStrings.swift 的 messageText 逻辑
     */
    private func mediaPreviewText(): String {
        let mtype = this.chat.lastMessageType
        let mtext = this.chat.lastMessage
        if (mtype == "photo") {
            return if (mtext.size > 0 && mtext != "Photo") { "🖼 ${mtext}" } else { "🖼 Photo" }
        } else if (mtype == "video") {
            return if (mtext.size > 0 && mtext != "Video") { "📹 ${mtext}" } else { "📹 Video" }
        } else if (mtype == "voice") {
            return if (mtext.size > 0 && mtext != "Voice Message") { "🎤 ${mtext}" } else { "🎤 Voice Message" }
        } else if (mtype == "round_video" || mtype == "video_note") {
            return "📹 Video Message"
        } else if (mtype == "gif") {
            return if (mtext.size > 0 && mtext != "GIF") { "GIF ${mtext}" } else { "GIF" }
        } else if (mtype == "sticker") {
            return if (mtext.size > 0) { "${mtext} Sticker" } else { "Sticker" }
        } else if (mtype == "audio") {
            return if (mtext.size > 0 && mtext != "Music") { "🎵 ${mtext}" } else { "🎵 Music" }
        } else if (mtype == "document") {
            return if (mtext.size > 0) { "📎 ${mtext}" } else { "📎 File" }
        } else if (mtype == "location") {
            return "📍 Location"
        } else if (mtype == "contact") {
            return "👤 Contact"
        } else if (mtype == "poll") {
            return if (mtext.size > 0) { "📊 ${mtext}" } else { "📊 Poll" }
        } else {
            return mtext
        }
    }

    /**
     * 失败消息预览只在它仍是会话最后一条时显示（iOS ChatListItem.swift:2430
     * hasFailedMessages = messages.last?.flags.contains(.Failed)）。此后收到 / 发出的
     * 新消息成为预览，旧失败消息只留在会话里的气泡红叹号上。
     */
    private func previewIsFailed(): Bool {
        if (!failedStoreHas(this.chat.id)) { return false }
        return this.chat.lastMessageTimestamp <= 0 ||
            failedStoreLastTimestamp(this.chat.id) >= this.chat.lastMessageTimestamp
    }

    /**
     * P2-106: 是否为草稿状态
     */
    private func previewIsDraft(): Bool {
        return this.chat.draftText.size > 0 && !this.isTyping
    }

    /**
     * P2-106: 群组发送者前缀（"You: " / "Name: " / ""）
     */
    private func previewSenderPrefix(): String {
        if (this.previewIsDraft() || (this.isTyping && this.chat.draftText.size == 0)) {
            return ""
        }
        if (this.chat.lastMessageSenderName.size > 0) {
            let sender = if (this.chat.lastMessageSenderName == "You") {
                this.presentationStrings.getOr("DialogList_You", "You")
            } else {
                this.chat.lastMessageSenderName
            }
            return "${sender}: "
        }
        return ""
    }

    // Appearance → Text Size (lists) scales the row text: iOS ChatListItem.swift:2294-2298 derives
    // title/text/date/badge fonts as floor(itemListBaseFontSize * n / 17). The literals here are
    // the iOS sizes at its default base; this project's default listsFontSize (BASE_FONT_SIZE) is
    // 16, so that value is the unscaled reference and the default rendering stays as before.
    private func listFont(n: Int64): Int64 {
        let base = Int64(this.presentation.listsFontSize)
        if (base <= 0) { return n }
        return n * base / 16
    }

    private func localizedTimestamp(): String {
        if (this.chat.lastMessageTimestamp > 0) {
            return formatRelativeTimestamp(this.chat.lastMessageTimestamp, this.presentationStrings)
        }
        return this.chat.time
    }

    /**
     * P2-106: 预览正文（不含 sender prefix）
     */
    private func previewBody(): String {
        if (this.isTyping && this.chat.draftText.size == 0) {
            return "typing..."
        }
        if (this.chat.draftText.size > 0) {
            return this.getDraftPreview()
        }
        return this.mediaPreviewText()
    }

    public func build() {

        Row {
            // 1. 头像区域 — Avatar 组件 (P2-142)
            Avatar(
                avatarUrl: this.chat.avatarLocalPath,
                displayName: this.chat.name,
                avatarSize: 60,
                avatarColor: this.chat.avatarColor,
                isOnline: this.chat.isOnline && !this.chat.isGroup && !this.chat.isChannel,
                showOnlineIndicator: !this.chat.isGroup && !this.chat.isChannel,
                peerId: this.chat.id,
                specialPeer: if (this.chat.isSavedMessages) {
                    AvatarSpecialPeer.SavedMessages
                } else if (this.chat.isDeletedAccount) {
                    AvatarSpecialPeer.Deleted
                } else {
                    AvatarSpecialPeer.Normal
                },
                isForum: false,
                letters: this.avatarLetters
            )

            // 2. 中间内容区域
            Column {
                // 2.1 第一行：图标 + 名称 + 时间
                Row {
                    Row {
                        // P2-100: 置顶图标（资源保真修复：真实矢量图标 clist_ic_pin 替代 emoji 字形）
                        if (this.chat.isPinned) {
                            Image(@r(app.media.clist_ic_pin))
                                .width(12)
                                .height(12)
                                .fillColor(0x8E8E93)
                                .margin(right: 2)
                        }
                        // P2-100: Secret Chat 图标（资源保真修复：真实矢量图标 clist_ic_secretchat 替代 emoji 字形）
                        if (this.chat.isSecretChat) {
                            Image(@r(app.media.clist_ic_secretchat))
                                .width(12)
                                .height(12)
                                .fillColor(0x00C853)
                                .margin(right: 2)
                        }
                        // P2-100: 频道图标（非 megagroup 的 channel）（资源保真修复：真实矢量图标 clist_ic_newchannel 替代 emoji 字形）
                        if (this.chat.isChannel && !this.chat.isMegagroup) {
                            Image(@r(app.media.clist_ic_newchannel))
                                .width(12)
                                .height(12)
                                .fillColor(0x8E8E93)
                                .margin(right: 2)
                        }

                        // 名称
                        // iOS parity: ChatListItem 名称 semibold16（仓颉 FontWeight 无 Semibold，用 Medium 近似）
                        // flexShrink(1)：名称按内容宽度排布、过长时收缩截断，使认证徽章紧贴名称右侧
                        // （不用 layoutWeight，否则名称会撑满把徽章顶到时间旁）。
                        Text(this.chat.name)
                            .fontSize(this.listFont(16))
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.textColor)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                            .flexShrink(1)

                        // iOS parity: 认证蓝勾徽章（名称右侧，紧邻名称）
                        if (this.chat.isVerified) {
                            Image(@r(app.media.clist_ic_verified))
                                .width(16)
                                .height(16)
                                .margin(left: 3)
                        }

                        // P2-304: Premium emoji status badge（名称旁金色 emoji 状态图标）
                        if (this.chat.isPremium && this.chat.emojiStatusEmoji.size > 0) {
                            Text(this.chat.emojiStatusEmoji)
                                .fontSize(14)
                                .margin(left: 2)
                        } else if (this.chat.isPremium) {
                            Text(trSource(""))
                                .fontSize(14)
                                .fontColor(0xFFD700)
                                .margin(left: 2)
                        }

                        // iOS parity: 静音图标在名字右侧 inline（灰色 iOS 矢量资源 PeerMutedIcon）
                        if (this.chat.isMuted) {
                            Image(@r(app.media.clist_ic_muted))
                                .width(15)
                                .height(15)
                                .fillColor(0x8E8E93)
                                .margin(left: 4)
                        }

                        // 吸收剩余空间，使名称+徽章左对齐（iOS 名称区左贴、时间右贴）
                        Blank().layoutWeight(1)
                    }
                    .layoutWeight(1)

                    // iOS parity: 已读勾在顶行时间戳左侧（iOS 矢量勾资源：绿双勾=已读/灰单勾=已发未读），时间恒灰
                    Row {
                        if (!this.previewIsDraft() && !(this.isTyping && this.chat.draftText.size == 0) && this.chat.lastMessageOutgoing) {
                            Image(if (this.chat.lastMessageRead) { @r(app.media.clist_ic_check_double) } else { @r(app.media.clist_ic_check_single) })
                                .width(if (this.chat.lastMessageRead) { 18 } else { 13 })
                                .height(13)
                                // iOS parity: 单勾(已发)与双勾(已读)同色 = theme.chatList.checkmarkColor 绿；
                                // 区别仅勾数（单=未读/双=已读），不分灰绿。
                                .fillColor(0x21C004)
                                .margin(right: 3)
                        }
                        Text(this.localizedTimestamp())
                            .fontSize(this.listFont(14))
                            .fontColor(0x8E8E93)
                    }
                    .margin(left: 8)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)

                // 2.2 第二行：预览 + 多 badge 组（已读勾已移至顶行时间左侧）
                Row {

                    // P2-106: 预览文本区域（typing / draft / sender+media）
                    // 发送失败预览优先（对齐 iOS：列表保留未发出消息 + 红色感叹号圆标）
                    if (this.previewIsFailed()) {
                        Row {
                            Text("!")
                                .fontSize(11)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(0xFFFFFF)
                                .textAlign(TextAlign.Center)
                                .width(16)
                                .height(16)
                                .borderRadius(8)
                                .backgroundColor(0xFF3B30)
                                .margin(right: 5)
                            Text(failedStoreLastText(this.chat.id))
                                .fontSize(this.listFont(15))
                                .fontColor(0x8E8E93)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                                .layoutWeight(1)
                        }
                        .layoutWeight(1)
                    } else if (this.isTyping && this.chat.draftText.size == 0) {
                        Text("typing...")
                            .fontSize(this.listFont(15))
                            .fontColor(0x317AFF)
                            .layoutWeight(1)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                    } else if (this.previewIsDraft()) {
                        Row {
                            Text("Draft: ")
                                .fontSize(this.listFont(13))
                                .fontColor(0xDD4B39)
                            Text(this.previewBody())
                                .fontSize(this.listFont(13))
                                .fontColor(0x8E8E93)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                                .layoutWeight(1)
                        }
                        .layoutWeight(1)
                    } else if (this.previewSenderPrefix().size > 0) {
                        Row {
                            Text(this.previewSenderPrefix())
                                .fontSize(this.listFont(15))
                                .fontColor(this.presentation.textColor)
                            Text(this.previewBody())
                                .fontSize(this.listFont(15))
                                .fontColor(0x8E8E93)
                                .maxLines(2)
                                .textOverflow(TextOverflow.Ellipsis)
                                .layoutWeight(1)
                        }
                        .layoutWeight(1)
                    } else {
                        // iOS parity: 预览最多 2 行
                        Text(this.previewBody())
                            .fontSize(this.listFont(15))
                            .fontColor(0x8E8E93)
                            .layoutWeight(1)
                            .maxLines(2)
                            .textOverflow(TextOverflow.Ellipsis)
                    }

                    // P2-105: 静音图标 + 多 badge 竖排区域
                    Column {
                        // iOS parity: OPEN 按钮仅对 bot_has_main_app(flags2.13) 的 bot 显示（与 iOS 同门控）
                        if (this.chat.isBot && this.chat.botHasMainApp) {
                            Text(trSource("OPEN"))
                                .fontSize(13)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0xFFFFFF)
                                .textAlign(TextAlign.Center)
                                .padding(left: 12, right: 12, top: 5, bottom: 5)
                                .backgroundColor(0x317AFF)
                                .borderRadius(14)
                                .margin(bottom: 2)
                                .onClick({ _ => this.onClick() })
                        }
                        // 静音图标已移至名字右侧 inline（iOS parity）——此处不再重复
                        // P2-105: @ mention badge
                        if (this.chat.mentionCount > 0) {
                            Text("@")
                                .fontSize(11)
                                .fontColor(0xFFFFFF)
                                .fontWeight(FontWeight.Bold)
                                .padding(left: 5, right: 5, top: 1, bottom: 1)
                                .backgroundColor(if (this.chat.isMuted) { 0x8E8E93 } else { 0x317AFF })
                                .borderRadius(9)
                                .margin(bottom: 2)
                        }
                        // P2-105: Reaction badge（💬 unseen reactions）
                        if (this.chat.unreadReactionsCount > 0) {
                            Text("💬")
                                .fontSize(11)
                                .fontColor(0xFFFFFF)
                                .padding(left: 4, right: 4, top: 1, bottom: 1)
                                .backgroundColor(0x317AFF)
                                .borderRadius(9)
                                .margin(bottom: 2)
                        }
                        // P2-105: 未读数 badge（99+ 截断）
                        if (this.chat.unreadCount > 0) {
                            // iOS parity: 未读徽章最小 20 直径圆（单位数也是圆），多位数横向撑开
                            Text(if (this.chat.unreadCount > 99) { "99+" } else { "${this.chat.unreadCount}" })
                                .fontSize(this.listFont(12))
                                .fontColor(0xFFFFFF)
                                .fontWeight(FontWeight.Medium)
                                .textAlign(TextAlign.Center)
                                .padding(left: 6, right: 6, top: 2, bottom: 2)
                                .constraintSize(minWidth: 20, minHeight: 20)
                                .backgroundColor(if (this.chat.isMuted) { 0x8E8E93 } else { 0x317AFF })
                                .borderRadius(10)
                        } else if (this.chat.isMarkedUnread) {
                            // iOS ChatListItem.swift:3441-3447：已读计数为 0 但被标为未读时
                            // badgeContent = .blank——同直径的空心文字徽章（纯色圆点）。
                            Column {}
                                .width(20)
                                .height(20)
                                .backgroundColor(if (this.chat.isMuted) { 0x8E8E93 } else { 0x317AFF })
                                .borderRadius(10)
                        }
                    }
                    .alignItems(HorizontalAlign.End)
                    .margin(left: 8)
                }
                .width(100.percent)
                .margin(top: 4)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin(left: 12)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        // CTL-SHARED-002: iOS 行按压高亮 0xE5E5EA（瞬入，松开 0.3s 淡出）
        .backgroundColor(if (this.isPressed) { this.presentation.itemHighlightedBackgroundColor } else if (this.chat.isPinned) { this.presentation.pinnedItemBackgroundColor } else { this.presentation.cardColor })
        // 长按渐进缩放（iOS sublayerTransform，以行中心为锚点）
        .scale(x: this.pressScale, y: this.pressScale)
        .onClick({ evt =>
            if (this.suppressNextClick) {
                this.suppressNextClick = false
                return
            }
            this.onClick()
        })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down =>
                    if (evt.touches.size > 0) {
                        // 屏幕坐标：左滑出操作按钮 / 列表滚动时行内容随手指平移，
                        // 组件内坐标几乎不变，用它判位移会让滑动中的长按照样触发。
                        this.touchStartX = evt.touches[0].screenX
                        this.touchStartY = evt.touches[0].screenY
                    }
                    this.isPressed = true
                    this.pressActive = true
                    this.pressGeneration += 1
                    let generation = this.pressGeneration
                    // 第一段：120ms 静默期结束后，才开始 200ms 的渐进缩小
                    spawn {
                        sleep(Duration.millisecond * 120)
                        launch {
                            if (this.pressActive && generation == this.pressGeneration) {
                                safeAnimateTo(
                                    { => this.getUIContext() },
                                    AnimateParam(duration: 200, curve: Curve.Linear),
                                    { => this.pressScale = this.minPressScale() }
                                )
                            }
                        }
                    }
                    // 第二段：120 + 200 = 320ms 时激活，与 iOS 的 beginDelay + animator 合计一致
                    spawn {
                        sleep(Duration.millisecond * 320)
                        launch {
                            if (this.pressActive && generation == this.pressGeneration) {
                                // iOS 激活时调 endPressedAppearance() 把缩放弹回
                                this.resetPressScale()
                                this.pressActive = false
                                this.suppressNextClick = true
                                // 手势不结束：进入「已激活、仍按住」状态，继续转发坐标
                                this.contextActive = true
                                triggerHaptic("impact", "light")
                                this.onLongPress(this.rowTop, this.rowHeight)
                            }
                        }
                    }
                case TouchType.Move =>
                    if (this.contextActive) {
                        // 已激活：位移不再取消，而是喂给动作面板做高亮
                        if (evt.touches.size > 0) {
                            this.onLongPressMove(evt.touches[0].screenX, evt.touches[0].screenY)
                        }
                    } else if (this.pressActive && evt.touches.size > 0) {
                        // 尚未激活：滑动列表不应触发长按，位移超过 8vp 即放弃本次识别。
                        // iOS 靠手势仲裁（pan 抢占 ContextGesture）达到同样效果，
                        // ArkUI 拿不到等价仲裁，用位移阈值近似。
                        let dx = evt.touches[0].screenX - this.touchStartX
                        let dy = evt.touches[0].screenY - this.touchStartY
                        if (dx * dx + dy * dy > 64.0) {
                            this.pressActive = false
                            this.pressGeneration += 1
                            this.isPressed = false
                            this.resetPressScale()
                        }
                    }
                case TouchType.Up =>
                    this.pressActive = false
                    this.resetPressScale()
                    this.pressGeneration += 1
                    if (this.contextActive) {
                        this.contextActive = false
                        this.onLongPressEnd()
                    }
                    safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseInOut), { =>
                        this.isPressed = false
                    })
                case _ =>
                    this.pressActive = false
                    this.pressGeneration += 1
                    this.resetPressScale()
                    if (this.contextActive) {
                        this.contextActive = false
                        this.onLongPressEnd()
                    }
                    this.isPressed = false
            }
        })
        .onAreaChange({ _: Area, newArea: Area =>
            this.rowWidth = newArea.width.value
            this.rowHeight = newArea.height.value
            match (newArea.globalPosition.y) {
                case Some(top) => this.rowTop = top.value
                case None => ()
            }
        })
    }

    /** iOS: minScale = max(0.7, (w - 15) / w)（ContextControllerSourceNode.swift:96-97） */
    private func minPressScale(): Float32 {
        if (this.rowWidth <= 0.0) { return 1.0 }
        let scaled = (this.rowWidth - 15.0) / this.rowWidth
        if (scaled < 0.7) { return 0.7f32 }
        return Float32(scaled)
    }

    /** 松手 / 激活时把缩放弹回（iOS .ended 分支：200ms easeOut） */
    private func resetPressScale(): Unit {
        if (this.pressScale == 1.0) { return }
        safeAnimateTo(
            { => this.getUIContext() },
            AnimateParam(duration: 200, curve: Curve.EaseOut),
            { => this.pressScale = 1.0 }
        )
    }
}
