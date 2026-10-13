package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import stdx.encoding.base64.*
import ohos_app_cangjie_entry.core.storage.{getAuthStorage, recomputePresentation, PresentationSnapshot, currentPresentation, systemResolvedFontSize}
import ohos_app_cangjie_entry.services.{getThemesEngineService, getWallpaperBackgroundService, WallpaperInfo}
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.utils.formatClockHHMM
import std.time.DateTime

/**
 * TextSizeSelectionPage — 对位 submodules/SettingsUI/Sources/Text Size/TextSizeSelectionController.swift
 * (diag-suite_settings_appearance-TC-0404-round1.md「修法方向」F1)。
 *
 * TC-0404 回归修复：AppearanceSettingsPage.cj 的 "Text Size" 披露行此前指向的目的地从未建过，
 * 落成运行时空壳（route_map 无该 name）。本页把它建出来，并恢复其真正的持久化写入点——
 * 改前内联滑杆经 AuthStorage.saveAppearanceTextSize 写 appTheme.textSize（仍被
 * core/storage/AppTheme.cj:422/564 消费），本页原样恢复该写入路径，另加 services/ThemesEngineService.cj
 * 已就绪的 listsFontSize / useSystemFont 两个维度（TC-0404 F4 持久化层已由 core_presentation_data
 * 补齐，见该文件 saveListsFontSize/getListsFontSize/saveUseSystemFont/getUseSystemFont）。
 *
 * 源侧双尺寸量结构：第 1 页驱动 fontSize（聊天气泡），第 2 页驱动 listsFontSize（会话列表），
 * 用同一根滑杆按当前 Swiper 页切换驱动目标——不合并成单一尺寸量（round 0 判失败的形态）。
 *
 * 事务语义（对位源侧 Cancel/Set 工具条）：滑杆/开关只改本页 @State，预览随之实时刷新；
 * Set 一次性提交三处写入（useSystemFont / chatFontSize / listsFontSize）后统一调用
 * recomputePresentation() 让 Appearance 根屏右值镜像回流；Cancel 直接 routerPop()，
 * 因为提交前没有任何持久化写入发生，取消天然不需要额外回滚。
 *
 * 返修（diag-suite_settings_appearance-TC-0404-round3.md 修法 F-B1 / F-6r3）：
 *  - B1（RC-7）：源侧本屏不是 ItemListController，是自绘 TextSizeSelectionControllerNode——
 *    导航栏只有居中标题（左项显式空视图、无右项），Cancel/Set 在贴屏底的独立工具条里
 *    （TextSizeSelectionController.swift:606/:653-654/:761-766/:827-873）。本文件此前套用了
 *    本工程通用 ItemList 分组设置页范式（分节头 + 圆角卡 + 页脚说明 + 导航行放操作按钮），
 *    这四处偏差是"套错了页面范式"这一个决定的必然后果，本轮按源侧结构重排：预览区吃满
 *    导航行与工具条之间的全部高度，工具条整条满宽贴底、恰好三行（开关/滑杆/Cancel-Set 按钮）。
 *  - B3（RC-6）：预览体此前是两个手搓 Column、文案硬编码，且用错了预览数据族——目标现状的
 *    "Reinhardt"/"We need to find you some new music!"/"Enjoy the classics, like Hasselhoff!"
 *    是 Appearance 根屏 Appearance.Preview* 那一组（ThemeSettingsController.swift:436），本子屏
 *    源侧用的是完全不同的一族 4 条 Appearance.ThemePreview.Chat.*（Localizable.strings:4892-4895）。
 *    本轮按源侧 :453-480 的倒挂列表顺序换算好的屏上自上而下顺序补齐四条消息（含一条语音气泡）与
 *    壁纸底，全部文案沿用现有 .fontSize(Int64(this.previewChatFontSize())) 实时绑定形态（C2a 靠它；
 *    previewChatFontSize()/previewListsFontSize() 在 "Use System Text Size" 打开时改取系统字号）。
 *  - 会话列表分页使用源侧 Appearance.ThemePreview.ChatList.* 的六项数据，并保留置顶、
 *    正在输入、群作者、频道、私密聊天与未读计数等不同状态。
 */
@HybridComponentEntry
@Component
public class TextSizeSelectionPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- Swiper: 0 = 聊天气泡预览(驱动 chatFontSize)，1 = 会话列表预览(驱动 listsFontSize) ----
    @State var swiperIndex: Int32 = 0
    private let swiperController = SwiperController()

    // ---- 编辑态（提交前只改这里，不碰持久化） ----
    @State var editingChatFontSize: Int32 = 16
    @State var editingListsFontSize: Int32 = 16
    @State var editingUseSystemFont: Bool = false

    @State var loaded: Bool = false
    @State var previewReferenceTimestamp: Int64 = DateTime.now().toUnixTimeStamp().toSeconds()

    // F-6r3：壁纸底需要 isDarkMode 入参（入参形状照抄 AppearanceSettingsPage.cj:811-822 的
    // 已合入先例），本屏此前对呈现快照零订阅，为此补上这一处唯一先例写法
    // （AppearanceSettingsPage.cj:46）。本屏其余部分不做主题化改造——不在本轮 B1/B3 判据范围内。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadSettings()
    }

    private func localized(key: String, fallback: String): String {
        return this.sourceLocalizationPresentation.getOr(key, fallback)
    }

    private func loadSettings(): Unit {
        let storage = getAuthStorage()
        let svc = getThemesEngineService()
        this.editingChatFontSize = storage.getAppearanceTextSize()
        this.editingListsFontSize = svc.getListsFontSize()
        this.editingUseSystemFont = svc.getUseSystemFont()
        Hilog.info(0, "CjTelegram", "[TextSizeSelection] Loaded: chat=${this.editingChatFontSize} lists=${this.editingListsFontSize} useSystem=${this.editingUseSystemFont}")
    }

    // 当前 Swiper 页对应的滑杆值
    private func currentSliderValue(): Int32 {
        if (this.swiperIndex == 0) {
            return this.editingChatFontSize
        }
        return this.editingListsFontSize
    }

    // Preview sizes follow TextSizeSelectionController.swift:547-557: with "Use System Text Size"
    // on, both previews render at the system size (the stored slider values stay untouched and
    // are what the slider shows, disabled); with it off, they render at the slider values.
    private func previewChatFontSize(): Int32 {
        if (this.editingUseSystemFont) { return systemResolvedFontSize() }
        return this.editingChatFontSize
    }

    private func previewListsFontSize(): Int32 {
        if (this.editingUseSystemFont) { return systemResolvedFontSize() }
        return this.editingListsFontSize
    }

    private func onSliderChange(value: Float64): Unit {
        let rounded = Int32(value)
        if (this.swiperIndex == 0) {
            this.editingChatFontSize = rounded
        } else {
            this.editingListsFontSize = rounded
        }
    }

    private func onSwiperChange(index: Int32): Unit {
        this.swiperIndex = index
    }

    // 对位源侧 :704-712 apply(useSystemFont, fontSize, listsFontSize) 三元组一次性提交。
    private func commit(): Unit {
        let storage = getAuthStorage()
        let svc = getThemesEngineService()
        svc.saveUseSystemFont(this.editingUseSystemFont)
        storage.saveAppearanceTextSize(this.editingChatFontSize)
        svc.saveListsFontSize(this.editingListsFontSize)
        let _ = recomputePresentation()
        Hilog.info(0, "CjTelegram", "[TextSizeSelection] Committed: chat=${this.editingChatFontSize} lists=${this.editingListsFontSize} useSystem=${this.editingUseSystemFont}")
        routerPop()
    }

    private func cancel(): Unit {
        routerPop()
    }

    // F-6r3：预览壁纸底，入参形状照抄 pages/AppearanceSettingsPage.cj:127-129 已合入的
    // previewWallpaper() 先例。
    private func previewWallpaper(): WallpaperInfo {
        return getWallpaperBackgroundService().getCurrentWallpaper()
    }

    // F-6r3：语音气泡波形——源侧 TextSizeSelectionController.swift:472 的 waveformBase64 字面串
    // （Telegram 5-bit packed waveform），经 fromBase64String 解出字节数组直接喂
    // AudioWaveformComponent.waveformData（组件内部经 AudioWaveformService 解码，不在本文件
    // 自行拆位）。
    private func previewVoiceWaveform(): Array<Byte> {
        let b64 = "DAAOAAkACQAGAAwADwAMABAADQAPABsAGAALAA0AGAAfABoAHgATABgAGQAYABQADAAVABEAHwANAA0ACQAWABkACQAOAAwACQAfAAAAGQAVAAAAEwATAAAACAAfAAAAHAAAABwAHwAAABcAGQAAABQADgAAABQAHwAAAB8AHwAAAAwADwAAAB8AEwAAABoAFwAAAB8AFAAAAAAAHwAAAAAAHgAAAAAAHwAAAAAAHwAAAAAAHwAAAAAAHwAAAAAAAAA="
        match (fromBase64String(b64)) {
            case Some(bytes) => return bytes
            case None =>
                Hilog.info(0, "CjTelegram", "[TextSizeSelection] FATAL: preview waveform base64 decode failed")
                return Array<Byte>(0, repeat: 0)
        }
    }

    // 返修（diag-suite_settings_appearance-TC-0404-round3.md F-6r3，对位
    // components/ChatListItem.cj:103 floor(base*n/17) 形态）：引用块作者名/正文是气泡预览的
    // 次级字号，须随 editingChatFontSize 实时缩放（明文禁止固定成 13/11），不能借用
    // presentation.listsFontSize——那是「会话列表」字号维度，预览页 1 驱动的是「聊天气泡」
    // 维度，二者是本页要保持独立的两个可编辑量（见文件头「源侧双尺寸量结构」）。除数固定 17，
    // 与 ChatListItem.cj / SettingsPage.cj 的同形态换算基准保持一致。
    private func scaledFontSize(numerator: Int64): Float64 {
        let scaled = Int64(Float64(this.previewChatFontSize()) * Float64(numerator) / 17.0)
        return Float64(scaled)
    }

    // ==================== 预览页 1：聊天气泡 ====================
    // F-6r3：四条消息 + 壁纸底，顺序对位源侧 TextSizeSelectionController.swift:453-480 的倒挂
    // 列表换算结果（屏上自上而下 = message4/message3/message2/message1）。文案取源码字面值
    // （Localizable.strings:4892-4895 Appearance.ThemePreview.Chat.*），不照抄参照帧——参照帧上
    // Chat.1.Text 缺 ", to" 那部分是运行时语言包覆盖，案文 G13(3) 已登记为不改判据。
    @Builder
    func buildBubblePreviewPage() {
        Stack {
            WallpaperBackgroundComponent(
                wallpaperType: this.previewWallpaper().wallpaperType,
                solidColor: this.previewWallpaper().solidColor,
                gradientColorStart: this.previewWallpaper().gradientColorStart,
                gradientColorEnd: this.previewWallpaper().gradientColorEnd,
                gradientAngle: this.previewWallpaper().gradientAngle,
                imageUri: this.previewWallpaper().imageUri,
                fallbackColor: getWallpaperBackgroundService().getFallbackColor(),
                gradientColors: this.previewWallpaper().gradientColors,
                phase: this.previewWallpaper().phase,
                isDarkMode: this.presentation.isDark,
                patternIntensity: this.previewWallpaper().patternIntensity,
                patternFile: this.previewWallpaper().patternFile
            )

            Column {
                // #1 outgoing (message4, Chat.1.Text)
                Row {
                    Text("Does he want me to, to turn from the right or turn from the left? \u{1F914}")
                        .fontSize(Int64(this.previewChatFontSize()))
                        .fontColor(0xFFFFFF)
                        .padding(left: 10, right: 10, top: 6, bottom: 6)
                }
                .backgroundColor(ITEM_LIST_ACCENT)
                .borderRadius(12)
                .margin(top: 8)
                .alignSelf(ItemAlign.End)

                // #2 incoming voice message (message3) — forcedResourceStatus: .paused in source,
                // so the rendered control is the "resume playback" (play) glyph, not pause.
                Row {
                    Column {
                        Image(@r(app.media.media_ic_play))
                            .width(14)
                            .height(14)
                            .fillColor(0xFFFFFF)
                    }
                    .width(28)
                    .height(28)
                    .borderRadius(14)
                    .backgroundColor(ITEM_LIST_ACCENT)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)

                    // S-131：自定义 @Component 构造调用后不能直接链式修饰符（即便跨包，宏展开
                    // 会漏注入 __gen_parent/__gen_local_storage）——用内置 Row {} 包一层承载 margin。
                    Row {
                        AudioWaveformComponent(
                            waveformData: this.previewVoiceWaveform(),
                            progress: 0,
                            totalDuration: 23,
                            fallbackSeed: 0,
                            playedColor: Int32(ITEM_LIST_ACCENT),
                            unplayedColor: Int32(0xB0CBEF),
                            barCount: 20,
                            barWidth: 3,
                            barSpacing: 2,
                            componentHeight: 24,
                            onClick: { => }
                        )
                    }
                    .margin(left: 8, right: 8)

                    Text("0:23")
                        .fontSize(13)
                        .fontColor(ITEM_LIST_TEXT_SECONDARY)
                }
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(ITEM_LIST_BG_CARD)
                .borderRadius(12)
                .margin(top: 8)
                .alignSelf(ItemAlign.Start)

                // #3 incoming reply/quote (message2): quotes message4's text under "Bob Harris",
                // body is Chat.2.Text.
                Column {
                    Row {
                        Column {}
                            .width(3)
                            .backgroundColor(ITEM_LIST_ACCENT)
                            .borderRadius(2)

                        Column {
                            Text(trSource("Bob Harris"))
                                .fontSize(this.scaledFontSize(13))
                                .fontWeight(FontWeight.Medium)
                                .fontColor(ITEM_LIST_ACCENT)
                            Text("Does he want me to, to turn from the right or turn from the left? \u{1F914}")
                                .fontSize(this.scaledFontSize(11))
                                .fontColor(ITEM_LIST_TEXT_SECONDARY)
                                .maxLines(1)
                                .textOverflow(TextOverflow.Ellipsis)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                        .margin(left: 6)
                    }
                    .width(100.percent)
                    .padding(top: 4, bottom: 4)

                    Text(trSource("Right side. And, uh, with intensity."))
                        .fontSize(Int64(this.previewChatFontSize()))
                        .fontColor(ITEM_LIST_TEXT_PRIMARY)
                        .margin(top: 2)
                }
                .padding(left: 10, right: 10, top: 6, bottom: 6)
                .backgroundColor(ITEM_LIST_BG_CARD)
                .borderRadius(12)
                .margin(top: 8)
                .alignSelf(ItemAlign.Start)
                .alignItems(HorizontalAlign.Start)

                // #4 outgoing (message1, Chat.3.Text)
                Row {
                    Text("Is that everything? It seemed like he said quite a bit more than that. \u{1F62F}")
                        .fontSize(Int64(this.previewChatFontSize()))
                        .fontColor(0xFFFFFF)
                        .padding(left: 10, right: 10, top: 6, bottom: 6)
                }
                .backgroundColor(ITEM_LIST_ACCENT)
                .borderRadius(12)
                .margin(top: 8)
                .alignSelf(ItemAlign.End)
            }
            .width(100.percent)
            .height(100.percent)
            .padding(left: 16, right: 16, bottom: 12)
            .justifyContent(FlexAlign.End)
        }
        .width(100.percent)
        .height(100.percent)
    }

    // ==================== 预览页 2：会话列表 ====================
    private func previewTime(offset: Int64): String {
        return formatClockHHMM(this.previewReferenceTimestamp + offset)
    }

    @Builder
    func buildListPreviewRow(
        name: String,
        snippet: String,
        time: String,
        avatarLetter: String,
        avatarTopColor: UInt32,
        avatarBottomColor: UInt32,
        isPinned: Bool,
        isOnline: Bool,
        isSecret: Bool,
        unreadCount: Int32,
        isOutgoing: Bool
    ) {
        Row {
            Stack(alignContent: Alignment.BottomEnd) {
                Stack(alignContent: Alignment.Center) {
                    Text(avatarLetter)
                        .fontSize(25)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0xFFFFFFFF)
                }
                .width(60)
                .height(60)
                .borderRadius(30)
                .linearGradient(angle: 180.0, colors: [
                    (Color(avatarTopColor), 0.0),
                    (Color(avatarBottomColor), 1.0)
                ])

                if (isOnline) {
                    Stack(alignContent: Alignment.Center) {
                        Row { }
                            .width(13)
                            .height(13)
                            .borderRadius(7)
                            .backgroundColor(0xFF34C759)
                    }
                    .width(17)
                    .height(17)
                    .borderRadius(9)
                    .backgroundColor(this.presentation.cardColor)
                }
            }
            .width(64)
            .height(64)

            Column {
                Row {
                    if (isSecret) {
                        Image(@r(app.media.media_ic_lock))
                            .width(12)
                            .height(14)
                            .fillColor(0xFF34C759)
                            .margin(right: 3)
                    }
                    Text(name)
                        .fontSize(Int64(this.previewListsFontSize()))
                        .fontWeight(FontWeight.Medium)
                        .fontColor(if (isSecret) { 0xFF34C759 } else { this.presentation.textColor })
                        .layoutWeight(1)
                    if (isOutgoing) {
                        Image(@r(app.media.clist_ic_check_double))
                            .width(14)
                            .height(10)
                            .fillColor(0xFF34C759)
                            .margin(right: 4)
                    }
                    Text(time)
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                }
                .width(100.percent)
                Row {
                    Text(snippet)
                        .fontSize(Int64(this.previewListsFontSize()) - 2)
                        .fontColor(this.presentation.secondaryTextColor)
                        .maxLines(2)
                        .textOverflow(TextOverflow.Ellipsis)
                        .layoutWeight(1)
                    if (isPinned) {
                        Image(@r(app.media.clist_ic_pin))
                            .width(15)
                            .height(15)
                            .fillColor(this.presentation.secondaryTextColor)
                            .margin(left: 6)
                    }
                    if (unreadCount > 0) {
                        Text("${unreadCount}")
                            .fontSize(13)
                            .fontColor(0xFFFFFFFF)
                            .textAlign(TextAlign.Center)
                            .width(22)
                            .height(22)
                            .borderRadius(11)
                            .backgroundColor(ITEM_LIST_ACCENT)
                            .margin(left: 6)
                    }
                }
                .width(100.percent)
                .margin(top: 2)
            }
            .layoutWeight(1)
            .margin(left: 8)
        }
        .width(100.percent)
        .height(76)
        .padding(left: 16, right: 16, top: 6, bottom: 6)
    }

    @Builder
    func buildListPreviewPage() {
        Column {
            this.buildListPreviewRow(
                this.localized("Appearance.ThemePreview.ChatList.1.Name", "Alicia Torreaux"),
                this.localized("Appearance.ThemePreview.ChatList.1.Text", "Bob says hi. 😊 ❤️ 😱"),
                this.previewTime(120), "A", 0xFFFFCC73, 0xFFFF9E50,
                true, false, false, 0, true
            )
            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 86)
            this.buildListPreviewRow(
                this.localized("Appearance.ThemePreview.ChatList.2.Name", "Roberto"),
                "••• typing", this.previewTime(3660), "R", 0xFF79A9FF, 0xFF6559F5,
                false, true, false, 0, false
            )
            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 86)
            this.buildListPreviewRow(
                this.localized("Appearance.ThemePreview.ChatList.3.Name", "Campus Public Chat"),
                this.localized("Appearance.ThemePreview.ChatList.3.AuthorName", "Jennie Alpha") + "\n" +
                    this.localized("Appearance.ThemePreview.ChatList.3.Text", "We just reached 2,500 members! WOO!"),
                this.previewTime(3200), "C", 0xFF9ADF7E, 0xFF55C66D,
                false, false, false, 0, false
            )
            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 86)
            this.buildListPreviewRow(
                this.localized("Appearance.ThemePreview.ChatList.4.Name", "Veronica"),
                this.localized("Appearance.ThemePreview.ChatList.4.Text", "Table for four, 2PM. Be there."),
                this.previewTime(3000), "V", 0xFF20E0E2, 0xFF31BFC5,
                false, false, false, 0, false
            )
            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 86)
            this.buildListPreviewRow(
                this.localized("Appearance.ThemePreview.ChatList.5.Name", "Animal Videos"),
                this.localized("Appearance.ThemePreview.ChatList.5.Text", "Vote now! Moar cat videos in this channel?"),
                this.previewTime(1000), "A", 0xFF66CBF2, 0xFF2A9EF1,
                false, false, false, 0, false
            )
            Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 86)
            this.buildListPreviewRow(
                this.localized("Appearance.ThemePreview.ChatList.6.Name", "Little Sister"),
                this.localized("Appearance.ThemePreview.ChatList.6.Text", "Don't tell mom yet, but I got the job! I'm going to ROME!"),
                this.previewTime(-360), "L", 0xFF66CBF2, 0xFF2A9EF1,
                false, false, true, 1, false
            )
        }
        .width(100.percent)
        .backgroundColor(this.presentation.cardColor)
    }

    public func build() {
        Column {
            // F-B1：导航栏只保留居中标题（对位源侧 :653 navigationItem.title / :654
            // leftBarButtonItem = 显式空视图、无 rightBarButtonItem）。Cancel/Set 挪到下方贴底
            // 工具条；cancel()/commit() 方法体不变，只搬调用点。
            Row {
                Text(trSource("Text Size"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(ITEM_LIST_TEXT_PRIMARY)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .backgroundColor(ITEM_LIST_BG_CARD)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)

            // F-B1：本屏不再是可滚动列表（源侧 scrollNode 只承载横向分页，不做纵向滚动）——
            // 外层 Scroll 整体删除，根 Column 直接排三块：导航行 → 预览区 → 工具条。
            // 预览区吃满导航行与工具条之间的全部高度（对位源侧 :570 scrollNode.frame = bounds）。
            Swiper(controller: this.swiperController) {
                this.buildBubblePreviewPage()
                this.buildListPreviewPage()
            }
            .index(UInt32(this.swiperIndex))
            .indicator(true)
            .loop(false)
            .onChange({ index: Int32 => this.onSwiperChange(index) })
            .width(100.percent)
            .layoutWeight(1)

            // F-B1：贴底工具条，满宽平铺（不是圆角卡——圆角卡是本工程 ItemList 范式带来的、
            // 本屏不该有的东西），顶部一条 1px 分隔线（对位 topSeparatorNode），内部自上而下
            // 恰好三行：开关 → 滑杆 → Cancel/Set 按钮行（对位 :761-766 子节点穷举 /
            // :827-873 updateLayout）。TEXT SIZE 分节头、Bubble/List text size 说明行、页脚
            // 说明整段全部删除（源侧工具条子节点里没有这些，套用 ItemList 范式带出的多余节点）。
            Column {
                Divider().color(ITEM_LIST_SEPARATOR).strokeWidth(1)

                ItemListToggleRow(
                    title: "User System Text Size",
                    isOn: this.editingUseSystemFont,
                    onChange: { isOn: Bool => this.editingUseSystemFont = isOn }
                )
                ItemListSeparator()

                Row {
                    Text("A")
                        .fontSize(13)
                        .fontColor(ITEM_LIST_TEXT_SECONDARY)

                    Slider(
                        value: Float64(this.currentSliderValue()),
                        min: 12.0,
                        max: 24.0,
                        step: 1.0,
                        style: SliderStyle.OutSet
                    )
                    .enabled(!this.editingUseSystemFont)
                    .selectedColor(ITEM_LIST_ACCENT)
                    .trackColor(ITEM_LIST_SEPARATOR)
                    .layoutWeight(1)
                    .margin(left: 8, right: 8)
                    .onChange({ value: Float64, changeMode: SliderChangeMode =>
                        this.onSliderChange(value)
                    })

                    Text("A")
                        .fontSize(24)
                        .fontColor(ITEM_LIST_TEXT_SECONDARY)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 4)

                Divider().color(ITEM_LIST_SEPARATOR).strokeWidth(1).margin(top: 4)

                // F-B1：Cancel/Set 从导航行搬到这里，两个等宽按钮，中间一条竖线
                // （对位 :861-862 各 floor(width/2) 宽、49.0 高，:870 separatorNode）。文案与
                // 左右次序保持不变（B4 本轮 PASS，不得回退）。
                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(ITEM_LIST_ACCENT)
                        .layoutWeight(1)
                        .height(49)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.cancel() })

                    Divider().vertical(true).color(ITEM_LIST_SEPARATOR).strokeWidth(1).height(28)

                    Text(trSource("Set"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(ITEM_LIST_ACCENT)
                        .layoutWeight(1)
                        .height(49)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ => this.commit() })
                }
                .width(100.percent)
                .alignItems(VerticalAlign.Center)
            }
            .width(100.percent)
            .backgroundColor(ITEM_LIST_BG_CARD)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(ITEM_LIST_BG_GROUPED)
        // D-194:本页自绘顶部 chrome,必须成对预留 getSafeAreaTop()(这里)与 .ets 壳的
        // .expandSafeArea(...)(ets/pages/TextSizeSelectionPage.ets),否则标题会被系统
        // 状态栏窗口压住(观察到的失效形态是标题被压扁)。
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
