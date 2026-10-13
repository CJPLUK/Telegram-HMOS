package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.CoreFileKit.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.resource.__GenerateResource__
import std.sync.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.services.{
    getPrivacyEngineService,
    PrivacyEngineService,
    getGlobalAbilityContext,
    openAnimatedStickerFileStream,
    StreamingLottiePlayer
}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListToggleRow,
    getEmptyAnimatedEmojiPixelMap,
    KeyboardAnimationStream
}
import ohos_app_cangjie_entry.utils.readRawFileBytes
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * Archive Settings — TC-0085/TC-0086 返修（diag-suite_settings_root-TC-0085.md /
 * -TC-0086.md，两案同页同 symbol 同根因，按 TC-0086「修法方向」三处改动整页重建）
 *
 * round-2（diag-suite_settings_root-TC-0086.md，与本轮 TC-0085 section-3 发现并案）：
 * 上一轮整页重建本身有效（条目模型/条件装配/GlobalPrivacySettings 接线/&&isPremium
 * 硬覆盖/付费墙内容变体均未变动），本轮只修该次重建新引入的两处目标侧渲染缺陷，均在
 * components/ItemListComponents.cj 的 ItemListToggleRow 里（不在本文件）：
 *   P1-a 锁定态捕获层背景 0x00FFFFFF 在本 SDK 下渲染为不透明白（非透明）；
 *   P1-b 捕获层用百分比尺寸撑爆内容定尺的 Stack，连锁挤爆标题列/撑爆行高/顶出脚注/
 *        膨胀点击热区。
 * 本文件的改动只是配合 P2（ItemListToggleRow.isOn 改 @Prop 后，调用点必须传裸 @State
 * 字段而非表达式，见 unknownSwitchOn 镜像字段 + aboutToAppear() 提前读 isPremium）。
 *
 * iOS reference: submodules/SettingsUI/Sources/ArchiveSettingsController.swift
 *   archiveSettingsControllerEntries(:119-144) — 三分区条目模型的唯一装配路径：
 *     分区 1 UNMUTED CHATS         — 无条件
 *     分区 2 CHATS FROM FOLDERS    — 条件 `!settings.keepArchivedUnmuted`（:131）
 *     分区 3 NEW CHATS FROM UNKNOWN USERS — 条件 `isPremium || isPremiumEnabled`（:137），
 *       开关值 `isPremium && settings.archiveAndMuteNewNoncontactPeers`（&& isPremium 硬覆盖，
 *       :139），非 Premium 下叠锁形图标 + 点击弹付费墙提示（不写值）。
 *
 * 状态来源改接：此前本页读写本地孤儿键 AuthStorage.getArchiveKeepUnmuted/
 * saveArchiveKeepUnmuted（默认值 false，与源侧 GlobalPrivacySettings.default.
 * keepArchivedUnmuted=true 相反，是 TC-0085 E1「开关不持久化」的根因——该键从未被
 * PrivacyEngineService 读写，落地值与「隐私与安全」页刚改过的全局隐私状态互不相通）。
 * 现改走已被姊妹页 pages/PrivacySettingsPage.cj:251-262 验证过的
 * services/PrivacyEngineService.cj:202/234 getGlobalPrivacySettings/
 * setGlobalPrivacySettings 通路（read-modify-write，spawn 异步，不阻塞 UI 线程）。
 * AuthStorage 上的孤儿方法/键本身不在本 feature allowlist 内，未删除，见交付报告
 * Hand-off。
 *
 * ItemListSection 用 @BuilderParam 承接跨包 @Component 子项在本工程有已知限制
 * （components/ItemListComponents.cj 头注释 + Reviewer 复核：全仓零真实调用点），
 * 继续沿用本工程既有惯例——分区卡片用手写白色圆角 Column 包裹。
 *
 * round-3（diag-suite_settings_root-TC-0086.md）：付费墙 tooltip 左侧图标此前是静态
 * SVG（黑色，画在深色底上近乎不可见），源侧其实是一枚 Lottie 动画
 * （UndoOverlayControllerNode.swift:1296 AnimationNode("PremiumStar")，:2221-2224
 * 显示后 +0.2s 起播、不循环、停在白色星末帧）。本轮接上同页族先例
 * pages/ArchiveInfoPage.cj 已验证的 rlottie 播放通路（rawfile → 沙箱解码 →
 * StreamingLottiePlayer 帧推进），tooltip 每次弹出都从第 0 帧重播，解码失败时静默
 * 退回着色后的静态图。
 */
// PremiumStar Lottie 帧缓存 key（固定负常量，避免与消息贴纸的真实 document id（恒为正）
// 冲突）——命名与用法对位 pages/ArchiveInfoPage.cj:59 ARCHIVE_INFO_GOT_IT_ANIM_DOC_ID
// 同一先例；-9001001/-9002001 已分别被 ChangePhoneIntroPage/ArchiveInfoPage 占用，
// -9003001 未占用（全仓 grep 确认）。
private let ARCHIVE_SETTINGS_PREMIUM_STAR_DOC_ID: Int64 = -9003001

@HybridComponentEntry
@Component
public class ArchiveSettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var keepArchivedUnmuted: Bool = true
    @State var keepArchivedFolders: Bool = true
    @State var archiveAndMuteNewNoncontactPeers: Bool = false
    @State var isPremium: Bool = false
    @State var loaded: Bool = false

    // 镜像字段(TC-0086 round-2 修复 P2，按 dev_pattern.md D-125 范式)：
    // ItemListToggleRow.isOn 现为 @Prop，依赖追踪只认裸 @State 字段引用，不认
    // `this.isPremium && this.archiveAndMuteNewNoncontactPeers` 这种表达式。
    // 每次两个源字段变化都同步刷新本镜像，分区 3 的 isOn: 只传这个裸字段。
    @State var unknownSwitchOn: Bool = false

    // 付费墙 tooltip 可见性（ArchiveSettingsController.swift:161-169 updateUnknown(nil) 的
    // 目标侧呈现；页面本地叠加层，不写任何设置值，见 showPremiumPaywall）
    @State var showPaywallTooltip: Bool = false
    private var paywallTimer: Option<Timer> = None<Timer>

    // PremiumStar Lottie 播放状态——形状照抄 pages/ArchiveInfoPage.cj:69-73 的
    // gotItAnim* 字段族。openAnimatedStickerFileStream 返回的 StreamingLottiePlayer
    // 持有解码会话/当前帧，必须本地保留一份才能读帧/推进帧号，故带 starAnimStream
    // （ArchiveInfoPage.cj:70 gotItAnimStream 同型）。
    //
    // round-6（diag-suite_settings_root-TC-0086.md）：帧推进改挂共享帧钟
    // KeyboardAnimationStream（领养模式 + 一次性播放），逐字对位
    // components/AnimatedEmojiComponent.cj。此前的私有 Timer 帧泵每拍只调
    // advanceTo、从未在循环里 prepareNextFrame——advanceTo 从第 2 拍起全部返回
    // false，画面永久卡在第 1 帧（PremiumStar.tgs 第 1 帧恰好是 Circle 图层，
    // 视觉上是无特征白点）。starAnimFrameIndex/starAnimTimer 两个私有帧泵字段
    // 随之删除，改为直接持有当前帧 PixelMap（starFrame）+ 共享帧钟句柄
    // （starAnim）。
    @State var starAnimReady: Bool = false
    private var starAnimStream: Option<StreamingLottiePlayer> = None<StreamingLottiePlayer>
    @State var starFrame: PixelMap = getEmptyAnimatedEmojiPixelMap()
    private let starAnim: KeyboardAnimationStream = KeyboardAnimationStream()
    private var starAnimLocalPath: String = ""

    // isPremiumEnabled = !isPremiumDisabled（Premium.swift:159 默认 isPremiumDisabled=false）。
    // 目标侧当前无 appConfig `premium_purchase_blocked` 通路可读，固定取 true——
    // 本次修法唯一允许的目标侧简化（TC-0086 修法方向「改动 3」明文授权）。
    private let isPremiumEnabled: Bool = true

    // TC-0086 round-2 修复 F2-c：isPremium 的同步读取从 ensureLoaded()(onAppear，在首次
    // build() 之后)提前到 aboutToAppear()(在首次 build() 之前)。ItemListToggleRow 的
    // enableInteractiveChanges/displayLocked 仍是普通 var(只在组件首次构造时赋值一次)，
    // 必须保证首帧构造时 isPremium 已是真值，否则锁定三元组会永久停在非 Premium 态。
    public override func aboutToAppear(): Unit {
        match (getAuthStorage().getUserData()) {
            case Some(user) => this.isPremium = user.isPremium
            case None => this.isPremium = false
        }
        this.unknownSwitchOn = this.isPremium && this.archiveAndMuteNewNoncontactPeers
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadGlobalPrivacy()
        this.extractPremiumStarAnimation()
    }

    private func loadGlobalPrivacy(): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let gps = svc.getGlobalPrivacySettings()
            let unmuted = gps.keepArchivedUnmuted
            let folders = gps.keepArchivedFolders
            let autoArchive = gps.archiveAndMuteNewNoncontactPeers
            spawn(UIThread) {
                =>
                this.keepArchivedUnmuted = unmuted
                this.keepArchivedFolders = folders
                this.archiveAndMuteNewNoncontactPeers = autoArchive
                this.unknownSwitchOn = this.isPremium && this.archiveAndMuteNewNoncontactPeers
            }
        }
    }

    // 把 rawfile/PremiumStar.tgs 提取到沙箱——形状照抄
    // pages/ArchiveInfoPage.cj:105-133 extractGotItAnimation()（ctx 判空、mkdir 的
    // try/catch、每次覆盖写，避免升级后残留旧资源）。禁用 @rawfile() 宏：该宏生成的
    // native 符号在 CJ so 下解析失败会 SIGSEGV（证据见 auth/SplashPage.cj:284-286 与
    // ArchiveInfoPage.cj:100-104 的既有记载）。
    private func extractPremiumStarAnimation(): Unit {
        match (getGlobalAbilityContext()) {
            case None => return
            case Some(ctx) =>
                let filesDir = ctx.filesDir
                let animDir = filesDir + "/archive_settings_anim"
                try { FileIo.mkdir(animDir) } catch (_e: Exception) {}
                let name = "PremiumStar.tgs"
                let targetPath = animDir + "/" + name
                match (readRawFileBytes(name)) {
                    case None =>
                        Hilog.info(0, "CjTelegram",
                            "[ArchiveSettingsPage] extractPremiumStarAnimation: readRawFileBytes returned None for ${name}")
                    case Some(data) =>
                        if (data.size > 0) {
                            try {
                                let file = FileIo.open(targetPath, mode: 0o1101)
                                let _ = FileIo.write(file.fd, data)
                                FileIo.close(file)
                                this.starAnimLocalPath = "file://" + targetPath
                                this.loadPremiumStarAnimation()
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram",
                                    "[ArchiveSettingsPage] extractPremiumStarAnimation: write failed for ${name}")
                            }
                        }
                }
        }
    }

    // 解码沙箱内的 PremiumStar.tgs——形状照抄 pages/ArchiveInfoPage.cj:139-156
    // loadGotItAnimation()（spawn 里做 CPU 密集的 rlottie 解码，完成后 launch 回主线程
    // 刷新 @State）。只解码、不在这里起播——起播由 showPremiumPaywall() 触发（每次点击
    // 都从第 0 帧重播，对齐源侧每次新建 AnimationNode 从头 play() 的语义）。解码失败时
    // starAnimReady 保持 false，只 Hilog.info 记录，不弹任何 error UI、不改 tooltip 尺寸
    // （与 ArchiveInfoPage.cj:137-138、components/ProfileMuteIcon.cj:88-93 的静默降级同型）。
    private func loadPremiumStarAnimation(): Unit {
        let path = this.starAnimLocalPath
        if (path.size == 0) { return }
        let docId = ARCHIVE_SETTINGS_PREMIUM_STAR_DOC_ID
        spawn {
            match (openAnimatedStickerFileStream(docId, path)) {
                case Some(player) =>
                    if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
                    launch {
                        this.starAnimStream = Some(player)
                        match (player.getCurrentFrame()) {
                            case Some(frame) => this.starFrame = frame
                            case None => ()
                        }
                        this.starAnimReady = true
                    }
                case None => ()
            }
        }
    }

    // round-6：帧推进改挂共享帧钟 KeyboardAnimationStream.startAdoptedOneShot
    // （领养模式 + 一次性播放），逐字对位 components/AnimatedEmojiComponent.cj:194-226
    // startPlayback()/stopPlayback()。它在同一只 16ms 全局时钟上把 prepare（后台
    // 解码）与 advance（时钟线程）成对做，落后时按预算跳帧，播完自动摘钟并停在末帧，
    // 帧在 UI 线程整批下发——不是本页私有 Timer 那种「只 advanceTo、从不
    // prepareNextFrame」的坏形状。targetTickMs 固定 16（PremiumStar.tgs 是
    // 60fps，先例 AnimatedEmojiComponent.cj:199；默认 33 是 30fps 节流车道，会把
    // 0.83s 的动画拉成两倍时长）。
    private func startPremiumStarPlayback(): Unit {
        match (this.starAnimStream) {
            case Some(player) =>
                if (this.starAnim.isRunning()) { return }
                this.starAnim.targetTickMs = 16
                // startAdoptedOneShot 里有一次同步 prepare（真解码），不占 UI 线程。
                let _ = spawn {
                    let _ = this.starAnim.startAdoptedOneShot(player,
                        { pixelMap: PixelMap =>
                            // 共享帧钟在 UI 线程整批回调，直接写 @State。
                            this.starFrame = pixelMap
                        })
                }
            case None => ()
        }
    }

    private func stopPremiumStarPlayback(): Unit {
        // 领养模式：只从钟上摘下，播放器留在本页手里（下次点击还要复用）。
        this.starAnim.stop()
    }

    // 分区 1 开关：updateAccountKeepArchivedUnmuted（ArchiveSettingsController.swift:155）
    private func updateKeepArchivedUnmuted(enabled: Bool): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let gps = svc.getGlobalPrivacySettings()
            let confirmed = svc.setGlobalPrivacySettings(
                gps.archiveAndMuteNewNoncontactPeers, enabled, gps.keepArchivedFolders,
                gps.hideReadMarks, gps.newNoncontactPeersRequirePremium, gps.displayGiftsButton
            )
            let newVal = confirmed.keepArchivedUnmuted
            spawn(UIThread) { => this.keepArchivedUnmuted = newVal }
        }
    }

    // 分区 2 开关：updateAccountKeepArchivedFolders（ArchiveSettingsController.swift:156）
    private func updateKeepArchivedFolders(enabled: Bool): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let gps = svc.getGlobalPrivacySettings()
            let confirmed = svc.setGlobalPrivacySettings(
                gps.archiveAndMuteNewNoncontactPeers, gps.keepArchivedUnmuted, enabled,
                gps.hideReadMarks, gps.newNoncontactPeersRequirePremium, gps.displayGiftsButton
            )
            let newVal = confirmed.keepArchivedFolders
            spawn(UIThread) { => this.keepArchivedFolders = newVal }
        }
    }

    // 分区 3 开关：updateAccountAutoArchiveChats（ArchiveSettingsController.swift:163）——
    // 仅当 isPremium 时才会被调用（ItemListToggleRow 锁定态下 onChange 不触发）
    private func updateAutoArchiveNonContacts(enabled: Bool): Unit {
        let _ = spawn {
            let svc = getPrivacyEngineService()
            let gps = svc.getGlobalPrivacySettings()
            let confirmed = svc.setGlobalPrivacySettings(
                enabled, gps.keepArchivedUnmuted, gps.keepArchivedFolders,
                gps.hideReadMarks, gps.newNoncontactPeersRequirePremium, gps.displayGiftsButton
            )
            let newVal = confirmed.archiveAndMuteNewNoncontactPeers
            spawn(UIThread) {
                =>
                this.archiveAndMuteNewNoncontactPeers = newVal
                this.unknownSwitchOn = this.isPremium && this.archiveAndMuteNewNoncontactPeers
            }
        }
    }

    // ArchiveSettingsController.swift:161-169 updateUnknown(value: nil) — 非 Premium 下点击
    // 锁定开关只弹提示，绝不写值（B4/B5）。5000ms 自动消失对齐
    // UndoOverlayControllerNode.swift:1342 的 `timeout ?? (isUserInteractionEnabled ? 5 : 3)`
    // （本内容含可点链接 ⇒ isUserInteractionEnabled=true ⇒ 5s）。
    private func showPremiumPaywall(): Unit {
        this.cancelPaywallTimer()
        this.showPaywallTooltip = true
        // 每次点击都从第 0 帧重播——对齐源侧「每次 activatedWhileDisabled 都新建一个
        // overlay、新建的 AnimationNode 从头 play()」的语义。不加 0.2s 延迟：源侧那
        // 0.2s 是等 panelWrapperNode 的 spring animateIn 落定（:2205-2224），目标侧
        // tooltip 无入场动画，等待没有对应物，加了反而与源侧观感不一致。
        //
        // round-6：必须真正 seekTo(0)，不能只重置帧号——advanceTo 只认「已 prepare
        // 的那一帧」，且 currentIndex == index 时早退（AnimatedEmojiService.cj:265-267），
        // 不 seek 回零第二次点击的第一拍就会被早退吞掉，画面停在上一次的末帧。
        // seekTo 是唯一会就地渲染任意帧的入口，内部是真解码，放 spawn 里，逐字对位
        // components/AnimatedEmojiComponent.cj:250-276 commitTap() 的重播段。
        match (this.starAnimStream) {
            case Some(player) =>
                // 先从钟上摘下（可能正在播），seek 回 0 再重挂。
                this.starAnim.stop()
                let _ = spawn {
                    if (player.seekTo(0)) {
                        spawn(UIThread) {
                            =>
                            match (player.getCurrentFrame()) {
                                case Some(frame) => this.starFrame = frame
                                case None => ()
                            }
                            this.startPremiumStarPlayback()
                        }
                    }
                }
            case None => ()
        }
        let t = Timer.once(Duration.millisecond * 5000, {
            =>
            launch {
                this.showPaywallTooltip = false
                this.stopPremiumStarPlayback()
            }
        })
        this.paywallTimer = Some(t)
        Hilog.info(0, "CjTelegram", "[ArchiveSettings] showPremiumPaywall")
    }

    private func cancelPaywallTimer(): Unit {
        match (this.paywallTimer) {
            case Some(t) =>
                t.cancel()
                this.paywallTimer = None<Timer>
            case None => ()
        }
    }

    public override func aboutToDisappear(): Unit {
        this.cancelPaywallTimer()
        this.stopPremiumStarPlayback()
    }

    public func build() {
        Stack(alignContent: Alignment.Bottom) {
            Column {
                Row {
                    Text(trSource("Back"))
                        .fontSize(16)
                        .fontColor(0x317AFF)
                        .onClick({ evt => routerPop() })
                    Blank().layoutWeight(1)
                    Text(trSource("Archive Settings"))
                        .fontSize(18)
                        .fontWeight(FontWeight.Bold)
                    Blank().layoutWeight(1)
                    Row { }.width(60)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xFFFFFF)
                .alignItems(VerticalAlign.Center)

                Scroll {
                    Column {
                        // ── 分区 1: UNMUTED CHATS（无条件，ArchiveSettingsController.swift:127-129）──
                        ItemListSectionHeader(title: "UNMUTED CHATS")

                        Column {
                            ItemListToggleRow(
                                title: "Always Keep Archived",
                                isOn: this.keepArchivedUnmuted,
                                onChange: { v: Bool =>
                                    this.keepArchivedUnmuted = v
                                    this.updateKeepArchivedUnmuted(v)
                                }
                            )
                        }
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(10)
                        .margin(left: 16, right: 16)

                        ItemListSectionFooter(
                            text: "Keep archived chats in the Archive even if they are unmuted and get a new message."
                        )

                        // ── 分区 2: CHATS FROM FOLDERS（条件 !keepArchivedUnmuted，:131-135）──
                        // C2：首次进入默认态(keepArchivedUnmuted=true)本分区不存在；D1/D2/D3 由
                        // @State 驱动的整段 if 插入/消失承载（animateChanges 对应的差量插入语义，
                        // 本工程 ArkUI 绑定无法复刻逐帧插入动效，结构性条件插入已按源侧逻辑复刻）。
                        if (!this.keepArchivedUnmuted) {
                            ItemListSectionHeader(title: "CHATS FROM FOLDERS", topPad: 24)

                            Column {
                                ItemListToggleRow(
                                    title: "Always Keep Archived",
                                    isOn: this.keepArchivedFolders,
                                    onChange: { v: Bool =>
                                        this.keepArchivedFolders = v
                                        this.updateKeepArchivedFolders(v)
                                    }
                                )
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(10)
                            .margin(left: 16, right: 16)

                            ItemListSectionFooter(
                                text: "Keep archived chats from folders in the Archive even if they are unmuted and get a new message."
                            )
                        }

                        // ── 分区 3: NEW CHATS FROM UNKNOWN USERS（条件 isPremium || isPremiumEnabled，:137-141）──
                        if (this.isPremium || this.isPremiumEnabled) {
                            ItemListSectionHeader(title: "NEW CHATS FROM UNKNOWN USERS", topPad: 24)

                            Column {
                                ItemListToggleRow(
                                    title: "Automatically Archive",
                                    // isPremium && settings.archiveAndMuteNewNoncontactPeers（:139 硬覆盖，不可省）。
                                    // 传镜像字段 unknownSwitchOn（裸 @State），不传表达式本身——ItemListToggleRow.isOn
                                    // 现为 @Prop，依赖追踪只认裸 @State 字段引用（D-125），见 unknownSwitchOn 声明处注释。
                                    isOn: this.unknownSwitchOn,
                                    enabled: true,
                                    enableInteractiveChanges: this.isPremium,
                                    displayLocked: !this.isPremium,
                                    onChange: { v: Bool =>
                                        this.archiveAndMuteNewNoncontactPeers = v
                                        this.unknownSwitchOn = this.isPremium && this.archiveAndMuteNewNoncontactPeers
                                        this.updateAutoArchiveNonContacts(v)
                                    },
                                    onActivatedWhileDisabled: { => this.showPremiumPaywall() }
                                )
                            }
                            .backgroundColor(0xFFFFFF)
                            .borderRadius(10)
                            .margin(left: 16, right: 16)

                            ItemListSectionFooter(
                                text: "Automatically archive and mute new private chats, groups and channels from non-contacts."
                            )
                        }

                        Text(trSource("")).height(32)
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())

            // 付费墙提示：page-local 叠加层，不复用 UndoToastService/UndoToast（其"Undo 按钮"
            // 内容形态与本提示"图标+可点内联链接+无按钮"结构不同，且两文件不在本 feature
            // allowlist 内——见交付报告 Hand-off）。
            if (this.showPaywallTooltip) {
                this.buildPaywallTooltip()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    // UndoOverlayControllerNode.swift:1292-1336 的 .premiumPaywall 内容变体：
    // 左侧 PremiumStar 图标 + markdown 链接解析出的可点内联 span + 无 Undo/Action 按钮。
    @Builder
    func buildPaywallTooltip() {
        Row {
            // 动画就绪时播 rlottie 解出的真实帧（源侧原生白色，不需要着色）；未就绪
            // （解码中/失败）时静默退回着色后的静态 SVG——.fillColor(0xFFFFFF) 修掉
            // 「黑星画在 0xF0202020 深色底上近乎不可见」，该 SVG 是单 path 纯 fill
            // （非描边），fillColor 在本工程同类用法已有先例（app/TelegramNavBar.cj:142
            // 等 223 处），语义正确（非把开放描边误填成实心的那类坑）。
            if (this.starAnimReady) {
                Image(this.starFrame)
                    .id("archiveSettingsPremiumStar")
                    .width(24)
                    .height(24)
                    .objectFit(ImageFit.Contain)
                    .margin(right: 10)
            } else {
                Image(@r(app.media.set2_ic_premiumstar))
                    .width(24)
                    .height(24)
                    .fillColor(0xFFFFFF)
                    .margin(right: 10)
            }

            Text() {
                Span("This setting is available only to the subscribers of ")
                    .fontColor(0xFFFFFF)
                Span(trSource("Telegram Premium"))
                    .fontColor(0x64B5F6)
                    .onClick({ _ => routerPush("PremiumPage") })
                Span(".")
                    .fontColor(0xFFFFFF)
            }
            .fontSize(15)
            .lineHeight(20)
            .layoutWeight(1)
        }
        .width(92.percent)
        .padding(top: 12, bottom: 12, left: 16, right: 16)
        .borderRadius(12)
        .backgroundColor(0xF0202020)
        .margin(bottom: 24)
        .alignItems(VerticalAlign.Center)
    }
}
