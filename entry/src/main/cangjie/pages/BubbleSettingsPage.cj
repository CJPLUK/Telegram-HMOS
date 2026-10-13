package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{getThemesEngineService, getWallpaperBackgroundService, WallpaperType, WallpaperInfo}
import ohos_app_cangjie_entry.core.storage.currentPresentation
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.utils.formatMessageTimestampAt
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * BubbleSettingsPage — 对位 submodules/SettingsUI/Sources/BubbleSettings/BubbleSettingsController.swift
 * (diag-suite_settings_appearance-TC-0404-round1.md「修法方向」F2）。
 *
 * TC-0406 round2/round3 返修（diag-suite_settings_appearance-TC-0406-round2.md F-2/F-3；
 * round3 只重申、不重新推导）：屏体改为源侧的「整屏聊天预览 + 贴底工具条」两层结构，
 * 半径滑杆改为源侧的 5 档值域，预览接上真实气泡渲染器 components/MessageBubble.cj。
 *
 * 事务语义（对位源侧 Cancel/Set 工具条，round7 F-C 重写，diag-suite_settings_appearance-
 * TC-0406-round7.md §六 F-C 第 7 步）：round2~round6 曾经为了保住 C3「实时预览」而让
 * onRadiusChange 每次滑杆 tick 都**立即**写入 ThemesEngineService——因为当时
 * components/MessageBubble.cj 不在本 feature allowlist、半径只能从持久化存储读，这是让
 * "预览用真实渲染器"与"预览随拖拽实时更新"同时成立的唯一手段，代价是要在 cancel() /
 * aboutToDisappear() 里补两处回滚才能维持源侧「Cancel 从不落盘」的事务语义。
 * round7 Coordinator 把 MessageBubble.cj 临时授权进本 feature allowlist（scope 见
 * feature json tasks[0].target_files_notes），半径改成了真正的渲染入参
 * （overrideMainRadius/overrideAuxRadius 哨兵，-1 = 无覆盖，见 MessageBubble.cj）——
 * 编辑期不再落盘，即时写入与两处回滚随之整体删除：commit() 才落盘半径 + mergeCorners，
 * cancel() 单纯 pop，事务语义等价于源侧 `cancel -> dismiss()` 从不落盘。round6 为堵住
 * "系统返回手势/硬件返回键绕开 Cancel"而新增的 aboutToDisappear() 回滚收尾点，其唯一职责
 * 就是补一次半径回滚——既然编辑期已经没有任何写入需要回滚，round7 把该覆写连同
 * editSettled/originalMainRadius/originalAuxRadius/rollbackRadiusIfDirty() 一并整体删除；
 * 系统返回手势/硬件返回键现在天然安全，因为没有东西可回滚。
 */
@HybridComponentEntry
@Component
public class BubbleSettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 编辑态（Adjust Adjacent 仍事务化到 Set 才提交；半径 round7 起同样事务化到 commit()
    // 才落盘，见上方类注释） ----
    @State var editingMainRadius: Int32 = 16
    @State var editingAuxRadius: Int32 = 8
    @State var editingMergeCorners: Bool = true

    @State var loaded: Bool = false

    // D-160 双相同分支挂载守卫：MessageBubble 是全仓唯一 @Reusable 组件，它的
    // overrideMainRadius/overrideAuxRadius（连同六个主题色）只在 aboutToReuse 里被重新注入，
    // 已挂载实例不会自动回灌——翻转本字段强制走"回收 + aboutToReuse"路径，新哨兵值才会
    // 送达（round7 F-C 起半径本身已是渲染入参，不再依赖持久化存储；本守卫职责不变，只是
    // 现在搬运的是入参而不是触发重新读盘）。
    @State var previewBubbleMountToggle: Bool = false

    // F-D3（diag-suite_settings_appearance-TC-0406-round8.md「修法方向」步骤 3）：四条预览
    // fixture 只构造一次、缓存在这里,交给下方 initPreviewMessages() 里的已有邻接分组引擎
    // computeMessageGroupPositions() 算出 isFirstInGroup/isLastInGroup/isSingleMessage,而不是
    // 像此前那样让 previewMsgN() 每次 build 都现 new 一条孤立消息、把分组标记写死成字面量。
    @State var previewMessages: ArrayList<Message> = ArrayList<Message>()

    // ---- 预览壁纸底输入（对位 AppearanceSettingsPage.cj previewWp* 镜像，一次性加载，
    // 本页不随全局主题切换刷新——本页打开期间不存在切主题入口） ----
    @State var previewWpType: WallpaperType = WallpaperType.SolidColor
    @State var previewWpSolid: UInt32 = 0xFFE8E6DF
    @State var previewWpGradStart: UInt32 = 0xFF8CA0D8
    @State var previewWpGradEnd: UInt32 = 0xFF4A5F9E
    @State var previewWpGradAngle: Float64 = 180.0
    @State var previewWpImageUri: String = ""
    @State var previewWpGradColors: Array<UInt32> = [0xFF7FA381, 0xFFD3B48F, 0xFF336F55, 0xFFFBE37D]
    @State var previewWpPhase: Int32 = 0
    @State var previewWpPatternIntensity: Float64 = 0.5
    @State var previewWpPatternFile: String = ""
    @State var previewIsDark: Bool = false

    // ---- 预览气泡颜色输入（对位 AppearanceSettingsPage.cj previewBubble*/previewReplyAuthorColor） ----
    @State var previewBubbleOutColor: UInt32 = 0xE8F5E9
    @State var previewBubbleInColor: UInt32 = 0xF0F0F0
    @State var previewBubbleTextColor: UInt32 = 0x000000
    @State var previewReplyAuthorColor: UInt32 = 0x4897D8

    // TC-0406 round9 返修（diag-suite_settings_appearance-TC-0406-round9.md「修法方向」步骤 1）：
    // build() 早于 .onAppear，而 previewMessages 此前只在 ensureLoaded()（由 .onAppear 驱动）里
    // 填充，四个 @Builder 又用常量下标读它 —— 首次 build() 必然对空表取 [0] 崩溃。这里改为
    // aboutToAppear()（早于 build() 的生命周期钩子）填充，保证 previewMessages 在首次 build()
    // 之前已非空。签名对齐 auth/EmailLoginPage.cj:47-49/:96 已验证的同形先例。
    public override func aboutToAppear(): Unit {
        this.initPreviewMessages()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadSettings()
    }

    private func loadSettings(): Unit {
        let svc = getThemesEngineService()
        this.editingMainRadius = svc.getBubbleMainRadius()
        this.editingAuxRadius = svc.getBubbleAuxRadius()
        this.editingMergeCorners = svc.getBubbleMergeCorners()

        let wp = getWallpaperBackgroundService().getCurrentWallpaper()
        this.previewWpType = wp.wallpaperType
        this.previewWpSolid = wp.solidColor
        this.previewWpGradStart = wp.gradientColorStart
        this.previewWpGradEnd = wp.gradientColorEnd
        this.previewWpGradAngle = wp.gradientAngle
        this.previewWpImageUri = wp.imageUri
        this.previewWpGradColors = wp.gradientColors
        this.previewWpPhase = wp.phase
        this.previewWpPatternIntensity = wp.patternIntensity
        this.previewWpPatternFile = wp.patternFile

        let presentation = currentPresentation()
        this.previewIsDark = presentation.isDark
        this.previewBubbleOutColor = presentation.bubbleOutColor
        this.previewBubbleInColor = presentation.bubbleInColor
        this.previewBubbleTextColor = presentation.textColor
        this.previewReplyAuthorColor = presentation.accentColor

        Hilog.info(0, "CjTelegram", "[BubbleSettings] Loaded: mainRadius=${this.editingMainRadius} auxRadius=${this.editingAuxRadius} mergeCorners=${this.editingMergeCorners}")
    }

    // F-2（diag-suite_settings_appearance-TC-0406-round2.md）：aux 每次拖动都无条件重算，
    // 对位源侧 BubbleSettingsController.swift:122-123 `auxiliaryRadius = Int32(value / 2)`。
    //
    // round7 F-C：不再即时落盘。真实气泡渲染器 components/MessageBubble.cj 现在把半径当
    // 渲染入参接收（overrideMainRadius/overrideAuxRadius），预览随拖拽实时更新靠的是
    // 下面翻转 previewBubbleMountToggle 驱动 aboutToReuse 把新哨兵值送进已挂载实例——不再
    // 需要"编辑期写盘、退出前回滚"这层。commit()/cancel() 见下方。
    private func onRadiusChange(value: Float64): Unit {
        this.editingMainRadius = Int32(value)
        this.editingAuxRadius = this.editingMainRadius / 2
        this.previewBubbleMountToggle = !this.previewBubbleMountToggle
    }

    private func commit(): Unit {
        // round7 F-C：半径改为在此处随 mergeCorners 一起落盘（此前 onRadiusChange 每次滑杆
        // tick 都即时写入，round7 起该写入已删除）。对位源侧
        // toolbarNode.done -> apply(chatBubbleSettings) 把整份设置当一个事务提交。
        let svc = getThemesEngineService()
        svc.saveBubbleMainRadius(this.editingMainRadius)
        svc.saveBubbleAuxRadius(this.editingAuxRadius)
        svc.saveBubbleMergeCorners(this.editingMergeCorners)
        Hilog.info(0, "CjTelegram", "[BubbleSettings] Committed: mainRadius=${this.editingMainRadius} auxRadius=${this.editingAuxRadius} mergeCorners=${this.editingMergeCorners}")
        routerPop()
    }

    private func cancel(): Unit {
        // round7 F-C：编辑期不再落盘，cancel 单纯 pop，对位源侧 cancel -> dismiss() 从不
        // 落盘——磁盘上的半径值本来就没被改动过，不需要回滚。
        routerPop()
    }

    // ==================== F-3 预览气泡 fixture ====================
    // 四条消息文案逐字取自 Localizable.strings 的 Appearance.ThemePreview.Chat.{1,2,3}.Text /
    // Chat.2.ReplyName（BubbleSettingsController.swift:161-181 的构造顺序），排布顺序照
    // diag-suite_settings_appearance-TC-0406-round2.md「修法方向」F-3 给出的 1..4 次序。

    private func previewMsg1(): Message {
        // 上方另加一条日期头（对位源侧 makeChatMessageDateHeaderItem，round2 F-3）——
        // components/MessageBubble.cj:2879-2882 已原生支持 showDateSeparator/dateSeparatorText，
        // 挂在本组最靠上（先渲染）的一条消息上即可，不需要额外的日期头组件。
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isSent = true
        msg.senderId = 0
        msg.status = "read"
        msg.content = "Is that everything? It seemed like he said quite a bit more than that. \u{1F62F}"
        msg.showDateSeparator = true
        msg.dateSeparatorText = "Today"
        return msg
    }

    private func previewMsg2(): Message {
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isSent = false
        msg.senderId = 1
        msg.content = "Right side. And, uh, with intensity."
        msg.replyToMsgId = 3
        msg.replyToSenderName = "Bob Harris"
        msg.replyToText = "Does he want me to, to turn from the right or turn from the left? \u{1F914}"
        return msg
    }

    private func previewMsg3(): Message {
        // BubbleSettingsController.swift:171-173：23s 语音，forcedResourceStatus 为暂停态。
        // id 取一个不会与真实会话消息碰撞的负值，getVoicePlayerManager() 按 id 查播放态，
        // 未知 id 天然返回未播放，静态展示即为暂停态，不需要真实音频文件。
        let msg = Message()
        msg.id = -9001
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isSent = false
        msg.senderId = 1
        msg.messageType = "voice"
        msg.audioDuration = 23
        return msg
    }

    private func previewMsg4(): Message {
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isSent = true
        msg.senderId = 0
        msg.status = "read"
        msg.content = "Does he want me to, to turn from the right or turn from the left? \u{1F914}"
        return msg
    }

    // F-D3（diag-suite_settings_appearance-TC-0406-round8.md「修法方向」步骤 3/4）：源侧从不给
    // 四条 fixture 写死分组标记，而是把它们塞进一个列表、靠统一引擎按邻接关系（同 sender/同
    // 方向/间隔 ≤ 10min/无 service 打断）推出 isFirstInGroup/isLastInGroup/isSingleMessage
    // （BubbleSettingsController.swift:157-215 updateMessagesLayout → ChatMessageItemImpl.swift
    // messagesShouldBeMerged）。目标侧同职责引擎已存在于 pages/ChatRoomPage.cj（同 package 可
    // 见），此前本页没有调用它。这里按 1→2→3→4 顺序只构造一次列表，跑一遍
    // computeMessageGroupPositions()，四个 @Builder 之后改为读这份列表而不再每次 build 现 new
    // ——现 new 会让每条消息都是孤立消息，引擎算出的标记会被丢弃。
    private func initPreviewMessages(): Unit {
        this.previewMessages = ArrayList<Message>()
        this.previewMessages.add(this.previewMsg1())
        this.previewMessages.add(this.previewMsg2())
        this.previewMessages.add(this.previewMsg3())
        this.previewMessages.add(this.previewMsg4())
        computeMessageGroupPositions(this.previewMessages)
        // 日期头必须在引擎之后复原：computeMessageGroupPositions 会按 rawTimestamp 自行重算
        // showDateSeparator/dateSeparatorText，四条 fixture 的 rawTimestamp 都是源侧固定参考值
        // 66000（1970-01-01），会被算成 "January 1"。对位源侧：日期头是独立的 header item
        // （makeChatMessageDateHeaderItem），不参与 mergedWithItems；目标侧把日期头挂在最上
        // 一条消息上是既有约定（previewMsg1() 注释已写明），这里保持它不被引擎覆盖。
        this.previewMessages[0].showDateSeparator = true
        this.previewMessages[0].dateSeparatorText = "Today"
    }

    @Builder
    func buildPreviewMsg1() {
        MessageBubble(
            message: this.previewMessages[0],
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewBubbleOutColor,
            bubbleInColor: this.previewBubbleInColor,
            bubbleOutTextColor: this.previewBubbleTextColor,
            bubbleInTextColor: this.previewBubbleTextColor,
            replyAuthorAccentColor: this.previewReplyAuthorColor,
            bubbleOutAccentTextColor: 0x00A700,
            overrideMainRadius: this.editingMainRadius,
            overrideAuxRadius: this.editingAuxRadius
        )
    }

    @Builder
    func buildPreviewMsg2() {
        MessageBubble(
            message: this.previewMessages[1],
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewBubbleOutColor,
            bubbleInColor: this.previewBubbleInColor,
            bubbleOutTextColor: this.previewBubbleTextColor,
            bubbleInTextColor: this.previewBubbleTextColor,
            replyAuthorAccentColor: this.previewReplyAuthorColor,
            bubbleOutAccentTextColor: 0x00A700,
            overrideMainRadius: this.editingMainRadius,
            overrideAuxRadius: this.editingAuxRadius
        )
    }

    @Builder
    func buildPreviewMsg3() {
        MessageBubble(
            message: this.previewMessages[2],
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewBubbleOutColor,
            bubbleInColor: this.previewBubbleInColor,
            bubbleOutTextColor: this.previewBubbleTextColor,
            bubbleInTextColor: this.previewBubbleTextColor,
            replyAuthorAccentColor: this.previewReplyAuthorColor,
            bubbleOutAccentTextColor: 0x00A700,
            overrideMainRadius: this.editingMainRadius,
            overrideAuxRadius: this.editingAuxRadius
        )
    }

    @Builder
    func buildPreviewMsg4() {
        MessageBubble(
            message: this.previewMessages[3],
            voicePlaybackEpoch: 0,
            bubbleOutColor: this.previewBubbleOutColor,
            bubbleInColor: this.previewBubbleInColor,
            bubbleOutTextColor: this.previewBubbleTextColor,
            bubbleInTextColor: this.previewBubbleTextColor,
            replyAuthorAccentColor: this.previewReplyAuthorColor,
            bubbleOutAccentTextColor: 0x00A700,
            overrideMainRadius: this.editingMainRadius,
            overrideAuxRadius: this.editingAuxRadius
        )
    }

    public func build() {
        // F-AB 重构（diag-suite_settings_appearance-TC-0406-round7.md §六 F-AB）：round4 把
        // 标题条 / 消息层 / 工具条做成根 Stack 的三个 zIndex=0 兄弟，靠 .align(Alignment.Top)
        // 单独顶对齐标题条、靠根 Stack 的 .alignContent(Alignment.Bottom) 贴底工具条——两处
        // 对齐 API 都被用错了方向（.align/.alignSelf 只管"节点内部内容"或 Flex 交叉轴，不是
        // Stack 子节点定位手段），标题条因此被钉在屏底、盖住按钮行 57.6%（RC-A/A2+B4）。
        // round7 改成两层：满屏壁纸底 + 一个满屏纵向 Column 浮层，标题条/消息层/工具条是这个
        // Column 的三个纵向兄弟，天然顶对齐/贴底，不再需要任何对齐覆盖。形态照抄本仓已在跑的
        // "整屏壁纸 + 顶部自绘栏 + 中部内容 + 贴底栏"页面（如 pages/ChatRoomPage.cj）。
        // 源侧对位：BubbleSettingsController.swift:95-96/:287-289（壁纸层与消息层同框叠放）+
        // :290-293（消息底缘 = toolbarHeight + 46，这条依赖关系在这里被结构化：消息层分到
        // "标题条与工具条之间"那一格，谁都不用再去算工具条有多高，也就不可能再漏，RC-B）+
        // :292（工具条贴底）+ :331/:332（标题在导航位、无 Back 控件）。
        Stack {
            // ===== 底层：整屏壁纸 =====
            // S-131：自定义 @Component 构造调用后不能直接链式修饰符（即使跨包也会退化成
            // missing arguments 编译错误），modifiers 必须落在包一层的内置容器上。
            Stack {
                WallpaperBackgroundComponent(
                    wallpaperType: this.previewWpType,
                    solidColor: this.previewWpSolid,
                    gradientColorStart: this.previewWpGradStart,
                    gradientColorEnd: this.previewWpGradEnd,
                    gradientAngle: this.previewWpGradAngle,
                    imageUri: this.previewWpImageUri,
                    fallbackColor: getWallpaperBackgroundService().getFallbackColor(),
                    gradientColors: this.previewWpGradColors,
                    phase: this.previewWpPhase,
                    isDarkMode: this.previewIsDark,
                    patternIntensity: this.previewWpPatternIntensity,
                    patternFile: this.previewWpPatternFile
                )
            }
            .width(100.percent)
            .height(100.percent)

            // ===== 顶层：满屏纵向浮层（标题条 → 消息层 → 工具条）=====
            Column {
                // ----- 标题条（只补标题，不补返回键）-----
                // 边界条件（诊断报告已锁死，不留给下一轮重新取舍）：
                // - 不补 Back 控件：源侧 BubbleSettingsController.swift:332 把 leftBarButtonItem
                //   显式置成空 UIView()，本屏 .modal 呈现、靠 Cancel 退出，补返回键会把「与源侧
                //   一致的正确行为」改坏。
                // - 标题不下沉进底部工具条：源侧标题在导航栏、按钮在底部工具条，是两层。
                // - 标题条不透明（ITEM_LIST_BG_CARD）会盖住预览层顶端 56vp，这与源侧一致（源侧
                //   导航栏 style: .glass 同样浮在整屏预览之上）。字号/字重/字色沿用 round1 被删
                //   那段（`9cb8b5843`）的原值。
                Column {
                    Text(trSource("Message Corners"))
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(ITEM_LIST_TEXT_PRIMARY)
                }
                .width(100.percent)
                .height(56)
                .backgroundColor(ITEM_LIST_BG_CARD)
                .alignItems(HorizontalAlign.Center)
                .justifyContent(FlexAlign.Center)

                // ----- 中层：消息预览，分到标题条与工具条之间的剩余高度 -----
                Column {
                    if (this.previewBubbleMountToggle) {
                        this.buildPreviewMsg1()
                        this.buildPreviewMsg2()
                        this.buildPreviewMsg3()
                        this.buildPreviewMsg4()
                    } else {
                        this.buildPreviewMsg1()
                        this.buildPreviewMsg2()
                        this.buildPreviewMsg3()
                        this.buildPreviewMsg4()
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
                .padding(left: 16, right: 16, top: 4, bottom: 46)
                .justifyContent(FlexAlign.End)

                // ----- 底层：贴底工具条（Corner Radius+Slider → Cancel/Set），
                // 对位 BubbleSettingsController.swift:539-546 -----
                // TC-0406 round10 (diag-suite_settings_appearance-TC-0406-round10.md F-R10): the
                // "Adjust Adjacent" toggle that used to open this Column was a revived dead
                // control — source's equivalent layout block for this row is commented out /
                // never mounted (frame stays CGRect.zero, never in the AX tree, never
                // interactive), so mergeBubbleCorners is permanently the stored default on the
                // real app. This target build had turned that dead block into a live, persisted
                // toggle with a truncated title ("Adjust Adjacent" vs source's "Adjust Adjacent
                // Corners") and a fabricated subtitle. Deleted along with its separator (the
                // separator's only job was dividing the toggle row from the row below; source's
                // toolbar has no such line — its two real dividers, topSeparatorNode and the
                // Cancel/Set vertical separator, both already exist elsewhere in this Column and
                // are untouched).
                Column {
                    Row {
                        Text("Corner Radius")
                            .fontSize(17)
                            .fontColor(ITEM_LIST_TEXT_PRIMARY)
                            .layoutWeight(1)
                        Text("${this.editingMainRadius}vp")
                            .fontSize(14)
                            .fontColor(ITEM_LIST_ACCENT)
                    }
                    .width(100.percent)
                    .constraintSize(minHeight: 44)
                    .padding(left: 16, right: 16, top: 10)

                    // F-2：5 档值域 {8,10,12,14,16}，对位源侧 BubbleSettingsRadiusItemNode.didLoad
                    // 的 positionsCount 5 / (value - 8) / 2。
                    Slider(
                        value: Float64(this.editingMainRadius),
                        min: 8.0,
                        max: 16.0,
                        step: 2.0,
                        style: SliderStyle.OutSet
                    )
                    .selectedColor(ITEM_LIST_ACCENT)
                    .trackColor(ITEM_LIST_SEPARATOR)
                    .width(100.percent)
                    .padding(left: 16, right: 16, bottom: 8)
                    .onChange({ value: Float64, changeMode: SliderChangeMode =>
                        this.onRadiusChange(value)
                    })

                    Divider().color(ITEM_LIST_SEPARATOR).strokeWidth(1)

                    Row {
                        Text(trSource("Cancel"))
                            .fontSize(17)
                            .fontColor(ITEM_LIST_ACCENT)
                            .textAlign(TextAlign.Center)
                            .width(50.percent)
                            .height(49)
                            .onClick({ _ => this.cancel() })

                        Divider().vertical(true).color(ITEM_LIST_SEPARATOR).strokeWidth(1).height(49)

                        Text(trSource("Set"))
                            .fontSize(17)
                            .fontColor(ITEM_LIST_ACCENT)
                            .fontWeight(FontWeight.Medium)
                            .textAlign(TextAlign.Center)
                            .width(50.percent)
                            .height(49)
                            .onClick({ _ => this.commit() })
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .backgroundColor(ITEM_LIST_BG_CARD)
                .padding(bottom: getSafeAreaBottom())
            }
            .width(100.percent)
            .height(100.percent)
        }
        .width(100.percent)
        .height(100.percent)
        // D-194：本页仍自绘顶部内容（整屏预览铺到物理上沿），必须与 .ets 壳的
        // .expandSafeArea(...)（ets/pages/BubbleSettingsPage.ets）成对预留 getSafeAreaTop()——
        // F-3 重构版式后这次配对从旧的顶部工具条 Row 搬到本根 Stack,不得在重构中丢失
        // （round3「修法方向」§6.1）。底部同理配对 getSafeAreaBottom(),已落在工具条自身
        // padding 里（对位源侧 resultHeight = contentHeight + bottomInset）,根节点这里
        // 只需再留一次 top,避免预览顶端画进系统状态栏窗口。
        .padding(top: getSafeAreaTop())
        .onAppear({ => this.ensureLoaded() })
    }
}
