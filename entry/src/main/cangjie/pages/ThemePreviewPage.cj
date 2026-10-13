package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings,
    PresentationSnapshot, resolvePresentationSnapshot, themeIconColors, ThemeIconColors,
    THEME_KIND_DAY_CLASSIC}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.{getWallpaperBackgroundService, WallpaperInfo,
    getThemesEngineService, JsonParser, ThemeItem, AppliedCloudTheme, saveAppliedCloudTheme,
    clearAppliedCloudTheme, clearSelectedWallpaper, applyCloudThemeLocally, clearActiveThemeWallpapers}
import ohos_app_cangjie_entry.components.{
    WallpaperBackgroundComponent,
    MessageBubble,
    ChatListItem,
    ITEM_LIST_TEXT_PRIMARY,
    ITEM_LIST_NAVBAR_H
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.dispatchEvent
import ohos_app_cangjie_entry.models.{Message, Chat, ChatEntry}
import ohos_app_cangjie_entry.core.storage.{currentPresentation, getAppTheme, getAuthStorage, recomputePresentation}
import ohos_app_cangjie_entry.core.mtproto.Base64
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.utils.formatMessageTimestampAt

/**
 * ThemePreviewPage — 对位 submodules/SettingsUI/Sources/Themes/ThemePreviewController.swift +
 * ThemePreviewControllerNode.swift（diag-suite_settings_appearance-TC-0417-round2.md §F2）。
 *
 * 路由参数格式由既存唯一调用点 `pages/ChatThemesPage.cj:232-238`（owner `set_theme_settings`，
 * 早于本页写入本分支）定义，本页只解析、不定义。`takePending("ThemePreviewPage")` 返回值形如
 * `{"builtin":true,"ref":<int>}`（内建主题，`ref` 取 `ChatThemesPage.cj:195-208` 的编号：
 * 0=Classic/dayClassic、1=Night Accent/nightAccent、2=Day/day、3=Night/night）或
 * `{"builtin":false,"slug":"<str>"}`（云主题，`slug` 对位 `ThemeItem.slug`）：
 *   - builtin=true 且 ref∈{0,3} ⇒ 标题 "🏠"（对位源侧 `.builtin(.dayClassic)`/`.builtin(.night)`，
 *     `ThemePreviewController.swift:126-127`）；ref=1 ⇒ "Tinted Night"、ref=2 ⇒ "Day"
 *     （对位 `previewTheme.name.string`，`PresentationTheme.swift:1534-1548`）。
 *   - builtin=false ⇒ 标题取 `slug` 在 `getThemesEngineService().getChatThemes()` 查得的
 *     `ThemeItem.title`；查不到返回空标题（源侧此分支另有 `emoticon` 优先级，目标 `ThemeItem`
 *     无该字段，属已知限制，不在本文件模拟）。该查询经 `MTProtoClient.sendRequest()` 阻塞 RPC
 *     （`core/mtproto/MTProtoClient.cj:793-825`），故 `resolveCloudTitle()` 必须整段包在
 *     `spawn{}` 里跑（对位 `pages/ChatThemesPage.cj:157-167 loadChatThemes()` 的既有正例，
 *     R-138），首帧标题短暂为空、`spawn` 内 `launch{}` 写回 `cloudTitle`（`@State`）后随重渲染
 *     补上，不在 UI 线程同步阻塞。
 *   - 解析失败 / 空串：退化为 builtin=true、ref=0（dayClassic）——镜像
 *     pages/EditThemePage.cj 的降级惯例。
 *   - 任何分支都不得把未解析的原始路由参数原样回显为标题（该路径系本文件此前的缺陷，
 *     源侧不存在对应实现，见 diag-suite_settings_appearance-TC-0417-round3.md §3/§4.3）。
 *
 * 预览的 theme/accent/bubble/wallpaper 全部由路由携带的主题引用求值，不读取当前全局主题作为
 * 替代。该结构对位 ThemePickerController.previewTheme 中的 makePresentationTheme(...)：预览
 * 只消费被点击主题，不在 Apply 前写 PresentationThemeSettings。
 *
 * 已知限制（详见 featureX.md「已知限制」，此处只记代码级根因）：
 *   - 模态呈现（源侧 `navigationPresentation = .modal`）未接线：`router/router.cj#isModalRoute`
 *     与 `ets/router/CustomTransition.ets#MODAL_ROUTES` 均不在本 feature allowlist（归属
 *     `shell_settings_misc`，`git grep "owner shell_settings_misc"` 可查同型先例
 *     `pages/RecentSessionScreen.ets`/`pages/ProxySettingsPage.cj`）。本轮先按普通 push 落地，
 *     "ThemePreviewPage" 需要的 modal 两处登记留给该 owner 后续接线；接线前到达本屏会退化成
 *     默认横向 push 转场（同 RecentSessionScreen 先例）。
 *   - 导航栏 "glass" 材质（`style: .glass`，源侧 `:62-68`）未落地真实背景模糊：本 SDK
 *     wrapper 未发现 blurStyle 类 API（检索 `ohos.arkui.component.swiper.cj.d` 等定义无果），
 *     退化为半透明纯色近似。
 *   - P2 底部 80pt 渐变遮罩（源侧 `maskNode`/`generateMaskImage`，`:18-31`/`:757`）未落地：
 *     改用固定底部内边距为最后一行让出空间，视觉上不做渐隐过渡（该项不在本 case A-E 判据
 *     清单内，纯视觉打磨，本轮从简）。
 */
@HybridComponentEntry
@Component
public class ThemePreviewPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- 路由参数（见类头文档；解析自 pages/ChatThemesPage.cj:232-238 发出的 JSON） ----
    @State var isBuiltinRef: Bool = true
    @State var builtinRef: Int32 = 0
    @State var cloudSlug: String = ""
    @State var cloudTitle: String = ""
    // 云主题条目解析完成后翻转，重建预览壁纸（WallpaperBackgroundComponent 参数只在构造时生效）
    @State var cloudPreviewReady: Bool = false
    // S7-106：已解析云主题的壁纸/配色（Apply 时经 saveAppliedCloudTheme 落库，驱动 recomputePresentation）
    private var cloudTheme: Option<AppliedCloudTheme> = None
    @State var cloudDark: Bool = false
    @State var cloudPatternFile: String = ""
    private var cloudItem: Option<ThemeItem> = None
    private var previewConfiguration: Option<ThemePreviewConfiguration> = None
    @State var applying: Bool = false
    @State var applyFailed: Bool = false

    @State var loaded: Bool = false
    @State var currentPage: Int32 = 0
    @State var previewMountToggle: Bool = false
    @State var previewBubbleMountToggle: Bool = false
    private let themeSelectionChangedEvent: String = "settings.chatThemes.selectionChanged"

    // ==================== 生命周期 ====================

    private func ensureLoaded(): Unit {
        match (takePendingThemePreviewConfiguration()) {
            case Some(configuration) =>
                // iOS 每次点击都会创建一个新的 ThemePreviewController。Harmony 路由会复用
                // HybridComponent 实例，因此每次 onAppear 必须优先消费新的完整配置，不能让上次
                // 预览的 loaded 状态截断本次选择。
                this.loaded = true
                this.currentPage = 0
                this.applying = false
                this.applyFailed = false
                this.applyPreviewConfiguration(configuration)
                return
            case None => ()
        }
        if (this.loaded) { return }
        this.loaded = true
        this.parseRouteParam(takePending("ThemePreviewPage"))
    }

    private func applyPreviewConfiguration(configuration: ThemePreviewConfiguration): Unit {
        this.previewConfiguration = Some(configuration)
        this.isBuiltinRef = configuration.isBuiltin
        this.builtinRef = configuration.builtinRef
        this.cloudDark = configuration.isDark
        this.cloudTitle = configuration.title
        this.cloudItem = configuration.cloudItem
        match (configuration.cloudItem) {
            case Some(item) =>
                this.cloudSlug = item.slug
                this.cloudTheme = Some(ThemePreviewPage.cloudThemeFromItem(item))
            case None =>
                this.cloudSlug = ""
                this.cloudTheme = None
        }
        this.cloudPatternFile = configuration.wallpaper.patternFile
        // Source creates a fresh ThemePreviewController for each selection. Recreate the two
        // target children that retain drawing/message props as instance state, so the new complete
        // presentation object becomes their constructor input as well as their parent props.
        this.previewMountToggle = !this.previewMountToggle
        this.previewBubbleMountToggle = !this.previewBubbleMountToggle
        if (!configuration.isBuiltin && configuration.wallpaper.patternOverlayEnabled &&
            configuration.wallpaper.patternFile.size == 0 && configuration.patternSlug.size > 0) {
            this.resolveConfiguredPattern(configuration.patternSlug)
        }
    }

    // 解析调用点 `ChatThemesPage.cj:234,:236` 发出的 JSON：
    // `{"builtin":true,"ref":<int>}` 或 `{"builtin":false,"slug":"<str>"}`。
    // 空串/解析失败一律退化为 builtin dayClassic（ref=0），镜像 EditThemePage.cj 的降级惯例。
    private func parseRouteParam(param: String): Unit {
        if (param.size == 0) {
            this.isBuiltinRef = true
            this.builtinRef = 0
            return
        }
        let obj = JsonParser.parseObject(param)
        if (!obj.has("builtin")) {
            this.isBuiltinRef = true
            this.builtinRef = 0
            return
        }
        this.isBuiltinRef = obj.getBool("builtin")
        if (this.isBuiltinRef) {
            this.builtinRef = Int32(obj.getInt("ref"))
            this.applyPreviewConfiguration(makeBuiltinThemePreviewConfiguration(this.builtinRef))
        } else {
            this.cloudSlug = obj.getString("slug")
            this.cloudDark = obj.has("dark") && obj.getBool("dark")
            // 调用点未事先 setPendingThemePreviewConfiguration（仅路由参数）时的兜底：按 slug 查
            // 云主题条目，补齐标题 / 预览配置 / Apply 用的 AppliedCloudTheme。
            if (this.previewConfiguration.isNone()) {
                this.resolveCloudTitle()
            }
        }
    }

    // 云主题标题解析：查一次即缓存到 @State，不在 navTitle() 里重复发起网络请求。
    // getChatThemes() 内部经 ThemesEngineService -> MTProtoClient.sendRequest() 是阻塞 RPC
    // （core/mtproto/MTProtoClient.cj:793-825，注释自述"阻塞等待本请求自己的响应"），
    // 从 onAppear 可达故不得同步跑在 UI 线程（R-138）；照抄同一调用在本文件同族内的既有正例
    // pages/ChatThemesPage.cj:157-167 loadChatThemes() 的 spawn+launch 范式：网络请求本体在
    // spawn{} 里跑，结果只在 launch{} 里写回 @State。查不到返回空标题（源侧此分支另有
    // emoticon 优先级，目标 ThemeItem 无该字段，属已知限制）。
    private func resolveCloudTitle(): Unit {
        let slug = this.cloudSlug
        let dark = this.cloudDark
        spawn {
            let themes = getThemesEngineService().getChatThemes(0).themes
            let title = ThemePreviewPage.findCloudTitle(themes, slug)
            let found = ThemePreviewPage.findCloudItem(themes, slug)
            launch {
                this.cloudTitle = title
                match (found) {
                    case Some(item) =>
                        // applyPreviewConfiguration 自己翻转 previewMountToggle 重建壁纸，这里不再翻 cloudPreviewReady
                        //（buildChatPage 以两位异或判定重挂载，双翻会抵消）
                        this.applyPreviewConfiguration(makeCloudThemePreviewConfiguration(item, dark, ""))
                    case None =>
                        this.cloudTheme = None
                        this.cloudPreviewReady = !this.cloudPreviewReady
                }
            }
        }
    }

    private static func findCloudItem(themes: ArrayList<ThemeItem>, slug: String): Option<ThemeItem> {
        for (item in themes) {
            if (item.slug == slug) { return Some(item) }
        }
        return None
    }

    /** theme.settings.first 的壁纸与配色部分（iOS ThemePreviewController previewTheme 的 chat.defaultWallpaper）。 */
    private static func cloudThemeFromItem(item: ThemeItem): AppliedCloudTheme {
        let t = AppliedCloudTheme()
        t.slug = item.slug
        t.wallpaperColors = item.wallpaperColors
        t.wallpaperIntensity = item.wallpaperIntensity
        t.wallpaperSlug = item.wallpaperSlug
        // baseTheme night / tinted 是深色基底（iOS PresentationBuiltinThemeReference(baseTheme:)）
        t.baseIsDark = item.settingsBaseTheme == "night" || item.settingsBaseTheme == "tinted"
        // S7-106：配色（theme.settings.first 的 accent / outbox accent / message colors），
        // 应用后由 recomputePresentation 套到强调色与气泡色上。
        if (item.hasSettings) {
            t.baseTheme = if (item.settingsBaseTheme.isEmpty()) { "classic" } else { item.settingsBaseTheme }
            t.accentColor = UInt32(Int64(item.settingsAccentColor) & 0xFFFFFFFF)
            t.outgoingAccentColor = UInt32(Int64(item.settingsOutboxAccentColor) & 0xFFFFFFFF)
            t.messageColors = item.settingsMessageColors
        }
        return t
    }

    // lambda 不允许捕获可变变量直接调用（Cangjie 语言限制），故把查找结果收敛成不可变
    // `let` 返回值，供 `resolveCloudTitle()` 的 `spawn{}` 传给 `launch{}` 闭包捕获。
    private static func findCloudTitle(themes: ArrayList<ThemeItem>, slug: String): String {
        for (item in themes) {
            if (item.slug == slug) {
                return item.title
            }
        }
        return ""
    }

    // ==================== 派生值 ====================

    // 对位源侧 `ThemePreviewController.swift:110-131` 的标题取值表：
    // builtin dayClassic(0)/night(3) ⇒ "🏠"；nightAccent(1) ⇒ "Tinted Night"；
    // day(2) ⇒ "Day"（`PresentationTheme.swift:1534-1548`）；云主题 ⇒ 已解析的 ThemeItem.title。
    // 任何分支都不得返回原始路由参数或其子串。
    private func navTitle(): String {
        if (this.isBuiltinRef) {
            if (this.builtinRef == 0 || this.builtinRef == 3) {
                return "🏠"
            }
            if (this.builtinRef == 1) {
                return "Tinted Night"
            }
            if (this.builtinRef == 2) {
                return "Day"
            }
            return ""
        }
        return this.cloudTitle
    }

    // 对位源侧 `ThemePreviewController.apply`（本 feature `source_refs` 第二条）。
    // 本轮无云主题/自定义主题目录可切，按 (isBuiltinRef, builtinRef) 只在内建 Light/Dark
    // 之间落地——真实调用既有 `getAppTheme().applyTheme(Int32)`（pages/AppearanceSettingsPage.cj
    // 同款既有真实 API，非本文件新造），触发 `recomputePresentation()`，非空操作按钮。
    // 明暗映射逐字对位 ChatThemesPage.cj:517 已在用的身份：nightAccent(1)/night(3) 深色，
    // dayClassic(0)/day(2) 浅色；云主题分支保持浅色兜底（目标侧无云主题本地应用通道，
    // 与 ChatThemesPage 类头已记的同一限制一致）。
    private func onApplyClick(): Unit {
        if (this.applying) {
            return
        }
        this.applying = true
        this.applyFailed = false
        let isBuiltin = this.isBuiltinRef
        let builtin = this.builtinRef
        let slug = this.cloudSlug
        var cloudIsDark = this.cloudDark
        match (this.cloudTheme) {
            case Some(cloud) => if (cloud.baseIsDark) { cloudIsDark = true }
            case None => ()
        }
        let dark = if (isBuiltin) { builtin == 1 || builtin == 3 } else { cloudIsDark }

        // ThemeSettingsController.selectThemeImpl starts applyTheme(account...) independently,
        // then always commits PresentationThemeSettings locally. Network reachability must not
        // gate the user's selection or leave this preview open with a false failure state.
        // S7-106: persist the choice like the Appearance carousel (applyThemePreset → saveTheme):
        // computeSnapshot() rebuilds the presentation from AuthStorage, so an in-memory-only
        // applyTheme() was lost on the next recompute and never reached the chat preview.
        // ThemePreviewController.swift:369-415: the applied theme becomes the current theme
        // (.cloud for cloud themes) and themeSpecificChatWallpapers[updatedTheme.index] = nil, so
        // chats show that theme's own default wallpaper.
        if (isBuiltin) {
            clearActiveThemeWallpapers()
            getThemesEngineService().saveSelectedChatThemeSlug("")
            getThemesEngineService().saveThemePreset(builtin)
            clearAppliedCloudTheme()
            getWallpaperBackgroundService().clearCurrentPreset()
            clearSelectedWallpaper()
            dispatchEvent(this.themeSelectionChangedEvent, "")
        } else {
            match (this.cloudTheme) {
                case Some(cloud) =>
                    saveAppliedCloudTheme(cloud)
                    clearSelectedWallpaper()
                case None => ()
            }
            match (this.cloudItem) {
                case Some(item) =>
                    applyCloudThemeLocally(item, dark)
                    dispatchEvent(this.themeSelectionChangedEvent, item.slug)
                case None => ()
            }
        }
        let targetTheme: Int32 = if (dark) { 1 } else { 0 }
        getAuthStorage().saveAppearanceTheme(targetTheme)
        getAppTheme().applyTheme(targetTheme)
        let _ = recomputePresentation()
        Hilog.info(0, "CjTelegram",
            "[ThemePreviewPage] Apply tapped isBuiltinRef=${isBuiltin} builtinRef=${builtin} cloudSlug=${slug} -> theme=${targetTheme}")
        routerPop()

        spawn {
            let _ = if (isBuiltin) {
                let baseId: Int32 = if (builtin == 0) { 0 } else if (builtin == 1) { 3 } else if (builtin == 2) { 1 } else { 2 }
                getThemesEngineService().installTheme(dark, None, None, Some(baseId))
            } else {
                let _ = getThemesEngineService().saveTheme(slug, false)
                getThemesEngineService().installTheme(dark, Some(slug), None, None)
            }
        }
    }

    private func onCloseClick(): Unit {
        routerPop()
    }

    private func resolveConfiguredPattern(slug: String): Unit {
        getWallpaperBackgroundService().resolveThemePatternFile(slug, { uri: String =>
            launch {
                this.cloudPatternFile = uri
                match (this.previewConfiguration) {
                    case Some(configuration) => configuration.wallpaper.patternFile = uri
                    case None => ()
                }
            }
        })
    }

    private func previewIsDark(): Bool {
        match (this.previewConfiguration) {
            case Some(configuration) => return configuration.isDark
            case None => ()
        }
        match (this.cloudTheme) {
            case Some(cloud) => return cloud.baseIsDark
            case None => ()
        }
        return currentPresentation().isDark
    }

    private func previewSnapshot(): PresentationSnapshot {
        match (this.previewConfiguration) {
            case Some(configuration) => return configuration.presentation
            case None => ()
        }
        return resolvePresentationSnapshot(0, false)
    }

    private func previewThemeColors(): ThemeIconColors {
        match (this.previewConfiguration) {
            case Some(configuration) => return configuration.colors
            case None => ()
        }
        return themeIconColors(THEME_KIND_DAY_CLASSIC)
    }

    private func previewAccentColor(): UInt32 {
        match (this.previewConfiguration) {
            case Some(configuration) => return configuration.accentColor
            case None => ()
        }
        return 0x0088FF
    }

    private func previewWallpaper(): WallpaperInfo {
        match (this.previewConfiguration) {
            case Some(configuration) => return configuration.wallpaper
            case None => ()
        }
        // S7-106 兜底：仅有路由参数、尚未解析出完整预览配置时，云主题取其 settings 壁纸，
        // 否则取当前聊天壁纸。
        if (!this.isBuiltinRef) {
            match (this.cloudTheme) {
                case Some(cloud) =>
                    if (cloud.wallpaperColors.size > 0) {
                        return getWallpaperBackgroundService().cloudThemeDefaultWallpaper(cloud)
                    }
                case None => ()
            }
            return getWallpaperBackgroundService().getCurrentWallpaper()
        }
        return makeBuiltinThemePreviewConfiguration(THEME_KIND_DAY_CLASSIC).wallpaper
    }

    private func toolbarHeight(): Float64 {
        return 49.0 + getSafeAreaBottom()
    }

    // ==================== P1：假聊天屏内容（对位 updateMessagesLayout `:593-701`） ====================

    // 语音消息波形：源侧固定 base64（`:623`），照抄不生成。
    private let VOICE_WAVEFORM_BASE64: String =
        "DAAOAAkACQAGAAwADwAMABAADQAPABsAGAALAA0AGAAfABoAHgATABgAGQAYABQADAAVABEAHwANAA0ACQAWABkACQAOAAwACQAfAAAAGQAVAAAAEwATAAAACAAfAAAAHAAAABwAHwAAABcAGQAAABQADgAAABQAHwAAAB8AHwAAAAwADwAAAB8AEwAAABoAFwAAAB8AFAAAAAAAHwAAAAAAHgAAAAAAHwAAAAAAHwAAAAAAHwAAAAAAHwAAAAAAAAA="

    // 名称/文案逐字取自 en.lproj/Localizable.strings 的
    // Appearance.ThemePreview.Chat.{1..7}.Text / .2.ReplyName（写死英文，不照抄参照帧渲染值，
    // 见诊断报告 §F2 第3条 -- TC-0415 B1 的前车之鉴）。
    private func buildPreviewMessages(): Array<Message> {
        let replyName = "Bob Harris"
        let text4 = "For relaxing times, make it Suntory time. \u{1F60E}"
        let text5 = "He wants you to turn, look in camera. O.K.?"
        let text6 = "That\u{2019}s all he said?"
        let text7 = "Yes, turn to camera."
        let text1 = "Does he want me to, to turn from the right or turn from the left? \u{1F914}"
        let text2 = "Right side. And, uh, with intensity."
        let text3 = "Is that everything? It seemed like he said quite a bit more than that. \u{1F62F}"

        let msg1 = Message()
        msg1.id = 1
        msg1.isSent = true
        msg1.status = "read"
        msg1.content = text4
        msg1.rawTimestamp = 66000
        msg1.time = formatMessageTimestampAt(66000, 66000, true)
        msg1.isFirstInGroup = true
        msg1.isLastInGroup = true
        msg1.isSingleMessage = true
        msg1.showDateSeparator = true
        msg1.dateSeparatorText = "Today"

        let msg2 = Message()
        msg2.id = 2
        msg2.isSent = false
        msg2.senderName = replyName
        msg2.content = text5
        msg2.rawTimestamp = 66001
        msg2.time = formatMessageTimestampAt(66001, 66000, true)
        msg2.isFirstInGroup = true
        msg2.isLastInGroup = true
        msg2.isSingleMessage = true

        let msg3 = Message()
        msg3.id = 3
        msg3.isSent = true
        msg3.status = "read"
        msg3.content = text6
        msg3.rawTimestamp = 66002
        msg3.time = formatMessageTimestampAt(66002, 66000, true)
        msg3.isFirstInGroup = true
        msg3.isLastInGroup = true
        msg3.isSingleMessage = true

        let msg4 = Message()
        msg4.id = 4
        msg4.isSent = false
        msg4.senderName = replyName
        msg4.content = text7
        msg4.rawTimestamp = 66003
        msg4.time = formatMessageTimestampAt(66003, 66000, true)
        msg4.isFirstInGroup = true
        msg4.isLastInGroup = true
        msg4.isSingleMessage = true

        let msg5 = Message()
        msg5.id = 5
        msg5.isSent = true
        msg5.status = "read"
        msg5.content = text1
        msg5.rawTimestamp = 66004
        msg5.time = formatMessageTimestampAt(66004, 66000, true)
        msg5.isFirstInGroup = true
        msg5.isLastInGroup = true
        msg5.isSingleMessage = true
        msg5.replyToMsgId = 4
        msg5.replyToSenderName = replyName
        msg5.replyToText = text7

        let msg6 = Message()
        msg6.id = 6
        msg6.isSent = false
        msg6.senderName = replyName
        msg6.messageType = "voice"
        msg6.audioDuration = 23
        msg6.audioWaveform = Base64.decode(this.VOICE_WAVEFORM_BASE64)
        msg6.rawTimestamp = 66005
        msg6.time = formatMessageTimestampAt(66005, 66000, true)
        msg6.isFirstInGroup = true
        msg6.isLastInGroup = true
        msg6.isSingleMessage = true

        let msg7 = Message()
        msg7.id = 7
        msg7.isSent = false
        msg7.senderName = replyName
        msg7.content = text2
        msg7.rawTimestamp = 66006
        msg7.time = formatMessageTimestampAt(66006, 66000, true)
        msg7.isFirstInGroup = true
        msg7.isLastInGroup = true
        msg7.isSingleMessage = true
        msg7.replyToMsgId = 5
        msg7.replyToSenderName = replyName
        msg7.replyToText = text1

        let msg8 = Message()
        msg8.id = 8
        msg8.isSent = true
        msg8.status = "read"
        msg8.content = text3
        msg8.rawTimestamp = 66007
        msg8.time = formatMessageTimestampAt(66007, 66000, true)
        msg8.isFirstInGroup = true
        msg8.isLastInGroup = true
        msg8.isSingleMessage = true

        return [msg1, msg2, msg3, msg4, msg5, msg6, msg7, msg8]
    }

    @Builder
    func buildPreviewWallpaper() {
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
                isDarkMode: this.previewIsDark(),
                patternIntensity: this.previewWallpaper().patternIntensity,
                patternFile: this.previewWallpaper().patternFile,
                patternOverlayEnabled: this.previewWallpaper().patternOverlayEnabled
            )
    }

    @Builder
    func buildPreviewMessageList() {
        ForEach(this.buildPreviewMessages(), itemGenerator: { msg: Message, _idx: Int64 =>
            MessageBubble(
                message: msg,
                voicePlaybackEpoch: 0,
                bubbleOutColor: this.previewThemeColors().outgoingBubbleColor,
                bubbleInColor: this.previewThemeColors().incomingBubbleColor,
                bubbleOutTextColor: this.previewSnapshot().textColor,
                bubbleInTextColor: this.previewSnapshot().textColor,
                replyAuthorAccentColor: this.previewAccentColor(),
                bubbleOutAccentTextColor: 0x00A700
            )
        })
    }

    @Builder
    func buildChatPage() {
        Stack {
            // 两个翻转位任一变化都重建壁纸子组件（配置替换 / 云主题条目解析完成）
            if (this.previewMountToggle != this.cloudPreviewReady) {
                this.buildPreviewWallpaper()
            } else {
                this.buildPreviewWallpaper()
            }
            Scroll {
                Column {
                    if (this.previewBubbleMountToggle) {
                        this.buildPreviewMessageList()
                    } else {
                        this.buildPreviewMessageList()
                    }
                }
                .width(100.percent)
                .padding(top: 8, bottom: this.toolbarHeight() + 36.0)
            }
            .width(100.percent)
            .height(100.percent)
        }
        .width(100.percent)
        .height(100.percent)
    }

    // ==================== P2：假会话列表（对位 updateChatsLayout `:367-591`） ====================

    // 头像色板照抄 components/Avatar.cj#avatarPaletteColor 的 7 色数值（该函数包私有，
    // 本文件不同包不可 import，逐值复制常量本身不构成逻辑重复）。
    private func avatarColorFor(index: Int64): Int64 {
        let palette: Array<Int64> = [
            0xFFff516a, 0xFFffa85c, 0xFF665fff, 0xFF54cb68,
            0xFF4acccd, 0xFF2a9ef1, 0xFFd669ed
        ]
        let idx = ((index % 7) + 7) % 7
        return palette[idx]
    }

    private func buildPreviewChats(): Array<ChatEntry> {
        let now: Int64 = 66000

        // avatarColorFor() 的入参是源侧 fixture peer 的内部 id（ThemePreviewControllerNode.swift
        // `:472-479`：依次 1,2,3,4,5,5,6，peer5/peer6 分别是 CloudChannel id 5、SecretChat id 5，
        // 故第 5、6 行同色），不是本文件行内自定义的 c.id（101..107）——两者是两条独立的编号空间，
        // 求色只认前者。规则本身（%7）不变，只对齐这里喂进去的取值。

        let c1 = Chat()
        c1.id = 101
        c1.name = "Alicia Torreaux"
        c1.lastMessage = "Bob says hi. \u{1F60A} \u{2764}\u{FE0F} \u{1F631}"
        c1.time = formatMessageTimestampAt(now + 120, now, true)
        c1.avatarColor = this.avatarColorFor(1)
        c1.peerType = "user"

        let c2 = Chat()
        c2.id = 102
        c2.name = "Roberto"
        c2.lastMessage = ""
        c2.time = formatMessageTimestampAt(now + 3660, now, true)
        c2.avatarColor = this.avatarColorFor(2)
        c2.peerType = "user"
        c2.isOnline = true

        let c3 = Chat()
        c3.id = 103
        c3.name = "Campus Public Chat"
        c3.lastMessage = "We just reached 2,500 members! WOO!"
        c3.lastMessageSenderName = "Jennie Alpha"
        c3.time = formatMessageTimestampAt(now + 3200, now, true)
        c3.avatarColor = this.avatarColorFor(3)
        c3.peerType = "channel"
        c3.isChannel = true
        c3.isMegagroup = true
        c3.isGroup = true

        let c4 = Chat()
        c4.id = 104
        c4.name = "Veronica"
        c4.lastMessage = "Table for four, 2PM. Be there."
        c4.time = formatMessageTimestampAt(now + 3000, now, true)
        c4.avatarColor = this.avatarColorFor(4)
        c4.peerType = "user"

        let c5 = Chat()
        c5.id = 105
        c5.name = "Animal Videos"
        c5.lastMessage = "Vote now! Moar cat videos in this channel?"
        c5.time = formatMessageTimestampAt(now + 1000, now, true)
        c5.avatarColor = this.avatarColorFor(5)
        c5.peerType = "channel"
        c5.isChannel = true
        c5.isMegagroup = false

        // Little Sister：secret chat 命名空间（对位源侧 Namespaces.Peer.SecretChat）。
        // 源侧 peer id 与 c5 同为 5（SecretChat id 5），故与 Animal Videos 同色，非笔误。
        let c6 = Chat()
        c6.id = 106
        c6.name = "Little Sister"
        c6.lastMessage = "Don't tell mom yet, but I got the job! I'm going to ROME!"
        c6.time = formatMessageTimestampAt(now - 360, now, true)
        c6.avatarColor = this.avatarColorFor(5)
        c6.peerType = "secret"
        c6.isSecretChat = true

        let c7 = Chat()
        c7.id = 107
        c7.name = "Jennie Alpha"
        c7.lastMessage = "\u{1F5BC} Check these out"
        c7.time = formatMessageTimestampAt(now - 420, now, true)
        c7.avatarColor = this.avatarColorFor(6)
        c7.peerType = "user"

        return [
            ChatEntry(c1), ChatEntry(c2), ChatEntry(c3), ChatEntry(c4),
            ChatEntry(c5), ChatEntry(c6), ChatEntry(c7)
        ]
    }

    @Builder
    func buildChatListPage() {
        Column {
            Scroll {
                Column {
                    // 对位源侧 P2 全部行 isUserInteractionEnabled=false（`:560`/`:573`，
                    // diag-suite_settings_appearance-TC-0417-round2.md §4.2/§六 F2 第4条）：
                    // ChatListItem 自身 build() 内建无条件按压高亮/长按手势树，调用方必须在
                    // 调用点显式 `.enabled(false)` 才能禁用交互，仅仅不传回调不生效。
                    // .enabled(false) 直接链在自定义 @Component 调用后会让宏展开的构造参数
                    // 列表对不上（同型陷阱见 pages/ChatRoomPage.cj:3414-3423 AnimatedEmojiEffectComponent
                    // 的既有解法），故用 Stack 包一层、把修饰符链在容器上。
                    ForEach(this.buildPreviewChats(), itemGenerator: { entry: ChatEntry, _idx: Int64 =>
                        Stack {
                            ChatListItem(
                                chat: entry.chat,
                                isTyping: entry.chat.id == 102
                            )
                        }
                        .width(100.percent)
                        .enabled(false)
                    })
                }
                .width(100.percent)
                .padding(bottom: this.toolbarHeight() + 8.0)
            }
            .width(100.percent)
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.previewSnapshot().backgroundColor)
    }

    // ==================== 页指示器 + 工具条 ====================

    @Builder
    func buildPageIndicator() {
        Row(space: 7.vp) {
            Column {}
                .width(7)
                .height(7)
                .borderRadius(3.5)
                .backgroundColor(if (this.currentPage == 0) { 0xFFFFFFFF } else { 0x66FFFFFF })
            Column {}
                .width(7)
                .height(7)
                .borderRadius(3.5)
                .backgroundColor(if (this.currentPage == 1) { 0xFFFFFFFF } else { 0x66FFFFFF })
        }
        .padding(left: 7, right: 7, top: 7, bottom: 7)
        .backgroundColor(0x4D000000)
        .borderRadius(10.5)
    }

    @Builder
    func buildToolbar() {
        Column {
            Row {
                Text(if (this.applying) { trSource("Applying…") } else { trSource("Apply For All Chats") })
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.previewAccentColor())
            }
            .width(100.percent)
            .height(49)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .onClick({ _evt => this.onApplyClick() })
            if (this.applyFailed) {
                Text(trSource("Unable to apply this theme. Please try again."))
                    .fontSize(13)
                    .fontColor(0xFFFF3B30)
                    .padding(bottom: 8)
            }
        }
        .width(100.percent)
        .backgroundColor(this.previewSnapshot().cardColor)
        .padding(bottom: getSafeAreaBottom())
    }

    // ==================== build ====================

    public func build() {
        Column {
            // 导航栏："glass" 材质近似（见类头已知限制）+ 左 close 图形 + 三分支标题 + 无右按钮
            // （对位源侧 `:150-152`：`.settings` 源在 init 作用域一律 isPreview=true ⇒ 右上分享
            // 按钮永不出现，负向硬断言，不得多做）。
            Row {
                Image(@r(app.media.username_nav_ic_close))
                    .width(22)
                    .height(22)
                    .fillColor(0xFFFFFFFF)
                    .onClick({ _evt => this.onCloseClick() })
                Blank().layoutWeight(1)
                Text(this.navTitle())
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFFFFFFFF)
                Blank().layoutWeight(1)
                Column {}.width(22).height(22)
            }
            .width(100.percent)
            .height(ITEM_LIST_NAVBAR_H)
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(0x33000000)
            .alignItems(VerticalAlign.Center)

            // 顶层容器：横向分页，两页，对位源侧 `:317-322` isPagingEnabled=true + bounces=false
            // （Swiper 是本仓唯一允许的等价物，见诊断报告 §F2 第2条；`.effectMode(EdgeEffect.None)`
            // 禁用边缘回弹，对位 bounces=false——`ohos.arkui.component.swiper.cj.d:553-560`
            // 声明 `effectMode(value: ?EdgeEffect)`，`EdgeEffect.None` 见
            // `ohos.arkui.component.common.cj.d:4269-4296`）。
            Stack(alignContent: Alignment.Bottom) {
                Swiper() {
                    this.buildChatPage()
                    this.buildChatListPage()
                }
                .index(UInt32(this.currentPage))
                .loop(false)
                .indicator(false)
                .effectMode(EdgeEffect.None)
                .width(100.percent)
                .height(100.percent)
                .onChange({ idx: Int32 =>
                    this.currentPage = idx
                })

                this.buildToolbar()

                Column {
                    this.buildPageIndicator()
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Center)
                .margin(bottom: this.toolbarHeight() + 28.0)
            }
            .layoutWeight(1)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF000000)
        .onAppear({ => this.ensureLoaded() })
    }
}
