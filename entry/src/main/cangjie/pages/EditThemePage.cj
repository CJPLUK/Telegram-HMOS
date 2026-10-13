package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.CoreFileKit.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getThemesEngineService,
    getWallpaperBackgroundService,
    WallpaperInfo,
    triggerHaptic,
    JsonParser
}
import ohos_app_cangjie_entry.interop.{callArkAsync, PICK_DOCUMENT}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListInputRow,
    ItemListDisclosureRow,
    WallpaperBackgroundComponent,
    MessageBubble,
    ITEM_LIST_TEXT_PRIMARY,
    ITEM_LIST_BG_CARD,
    ITEM_LIST_BG_GROUPED,
    ITEM_LIST_ACCENT,
    ITEM_LIST_CHEVRON,
    ITEM_LIST_NAVBAR_H
}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.core.storage.currentPresentation
import ohos_app_cangjie_entry.core.theme.generateThemeName
import ohos_app_cangjie_entry.utils.{safeAnimateTo, formatMessageTimestampAt}
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import std.unicode.*

/**
 * EditThemePage — 对位 submodules/SettingsUI/Sources/Themes/EditThemeController.swift 的
 * `.create` 分支（diag-suite_settings_appearance-TC-0416.md §F2）。
 *
 * 本轮只有 `.create` 可达（入口行 `pages/ChatThemesPage.cj` 的 "Create a New Theme" 由
 * `set_theme_settings` 负责，routerPush 到本页时携带 mode=create，见该报告 §F1）；但导航栏
 * 标题的三分支（`.create` / `.edit`+无文件 / `.edit`+有文件，源侧 `:718-728`）按报告要求
 * 一次写全，不留到下一轮——`.edit` 分支目前是死代码路径（无调用点传 mode=edit），但结构完整。
 *
 * 路由参数格式：宽松解析，接受空串（默认 create）/ "create" / "mode=create" /
 * "edit"/"edit:hasfile"/"edit:nofile" / "mode=edit:hasfile" 等形态——调用方（另一 feature）
 * 的确切格式未强约束，此处不假设唯一写法，只要能识别 "create"/"edit" 词以及紧跟的
 * "hasfile" 标记即可。
 *
 * 创建与文件导入均使用 Telegram 的真实 account.createTheme/account.uploadTheme 链路；
 * 系统 DocumentViewPicker 只授予用户所选文件的临时访问范围。
 *
 * 平台差异：目标侧尚无 iOS PresentationTheme 解码器，选中文件后不在本地重绘预览，
 * 但 Done 会上传所选原文件并由服务端校验、创建，失败时保持当前页并展示服务端错误。
 *
 * 已知交互约束：
 *   - 第 4 行聊天预览块（diag-suite_settings_appearance-TC-0416-round3.md §F2 F-2）：壁纸底 +
 *     两条真实气泡（`components/MessageBubble.cj`，调用形态逐字照抄
 *     `pages/ChatThemesPage.cj#buildPreviewIncomingBubble/buildPreviewOutgoingBubble`），块高
 *     改为内容驱动（同文件 `previewContentHeight` 回路同型）。气泡的 `.hitTestBehavior(None)`
 *     不可用——`dev_pattern.md` D-149：本工程 ArkUI 绑定不暴露 `hitTestBehavior`/`HitTestMode`
 *     （`components/UndoToast.cj:729-732` 已实测确认该 API 缺口），故这两条预览气泡当前仍可
 *     响应点击/长按手势（源侧 `itemNode.isUserInteractionEnabled = false` 未能等价复刻）；
 *     气泡内的回调（reply/reaction 等）此处均未接线，实际点击不产生可观察副作用。
 */
@HybridComponentEntry
@Component
public class EditThemePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    private let titleInputId: String = "edit_theme_title_input"

    // ---- 路由参数（三分支标题的驱动字段，见类头注释） ----
    @State var mode: String = "create"        // "create" | "edit"
    @State var hasExistingFile: Bool = false  // 仅 mode == "edit" 时有意义

    // ---- 表单状态 ----
    @State var title: String = ""
    @State var titleShakeOffset: Float64 = 0.0
    @State var updating: Bool = false
    @State var submitError: String = ""
    @State var selectedThemePath: String = ""
    @State var selectedThemeName: String = ""

    @State var loaded: Bool = false

    // ---- 聊天预览块内容驱动高度（F-2，同 pages/ChatThemesPage.cj:351 的收敛上界写法：
    // 回路只能收缩，初值必须是真实内容高的上界，见该文件 round7 修复注释） ----
    @State var previewContentHeight: Float64 = 260.0

    // ==================== 生命周期 ====================

    private func ensureLoaded(): Unit {
        if (this.loaded) {
            return
        }
        this.loaded = true
        this.parseRouteParam(takePending("EditThemePage"))
        // C4（诊断报告）：每次进屏重新生成，不缓存、不持久化。入参用当前生效强调色，
        // 对位源侧 `theme.rootController.navigationBar.buttonColor`
        // （`EditThemeController.swift:331`，目标侧等价物是 presentation 的强调色）。
        this.title = generateThemeName(getThemesEngineService().getAccentColor())
    }

    // 宽松子串匹配而非严格分隔符/JSON 解析——本页不是本 feature 的入口 owner
    // （`set_theme_settings` 拥有 "Create a New Theme" 行本身），caller 传参的确切格式
    // （"create" / "mode=create" / JSON 形如 `{"mode":"edit","hasFile":true}` 等）未强约束，
    // 子串匹配对格式变化最鲁棒，默认（不含 "edit" 字样）落到 create 分支——本轮唯一真实
    // 调用点就是 create。
    private func parseRouteParam(param: String): Unit {
        let lower = param.toAsciiLower()
        if (lower.contains("edit")) {
            this.mode = "edit"
            this.hasExistingFile = lower.contains("hasfile") || lower.contains("has_file")
        } else {
            this.mode = "create"
            this.hasExistingFile = false
        }
    }

    // ==================== 派生值 ====================

    // 对位源侧 `:718-728`：`.create` ⇒ Create Theme；`.edit` 且无文件 ⇒ 同样 Create Theme；
    // `.edit` 且有文件 ⇒ Edit Theme。
    private func navTitle(): String {
        if (this.mode == "edit" && this.hasExistingFile) {
            return "Edit Theme"
        }
        return "Create Theme"
    }

    // 对位源侧 `:514`：`.create` 分支只看 title，不看 slug。
    private func isDoneEnabled(): Bool {
        this.title.trim().size > 0
    }

    // ==================== 抖动反馈（128 字符校验失败，对位 ShakeAnimation） ====================
    // 与 components/ItemListComponents.cj#ItemListInputRow.triggerIllegalCharFeedback 同型
    // 写法（0 → +3vp → -3vp → +3vp → -3vp → 0，共 0.3s，每段 0.06s、不衰减）。

    private func runTitleShakeStep(offsets: Array<Float64>, idx: Int64): Unit {
        if (idx >= offsets.size) {
            return
        }
        let nextIdx = idx + 1
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 60, curve: Curve.Linear, onFinish: { =>
            this.runTitleShakeStep(offsets, nextIdx)
        }), { =>
            this.titleShakeOffset = offsets[idx]
        })
    }

    private func triggerTitleTooLongFeedback(): Unit {
        this.runTitleShakeStep([3.0, -3.0, 3.0, -3.0, 0.0], 0)
        triggerHaptic("notification", "error")
    }

    // ==================== 交互 ====================

    // 对位源侧 `:499`：左上 close = 直接退出，不保存，无二次确认。
    private func onCloseClick(): Unit {
        routerPop()
    }

    // 对位源侧 `:520-522`：字符数 > 128 时触发抖动、不提交、不弹文字提示，按钮不变转圈。
    private func onDoneClick(): Unit {
        if (!this.isDoneEnabled() || this.updating) {
            return
        }
        if (this.title.toRuneArray().size > 128) {
            this.triggerTitleTooLongFeedback()
            return
        }
        this.updating = true
        this.submitError = ""
        let themeTitle = this.title.trim()
        let selectedPath = this.selectedThemePath
        let selectedName = this.selectedThemeName
        let _ = spawn {
            let result = if (selectedPath.size > 0) {
                let data = this.readFileBytes(selectedPath)
                getThemesEngineService().createThemeFromFile(themeTitle, data, selectedName)
            } else {
                getThemesEngineService().createThemeFromCurrentSettings(themeTitle)
            }
            spawn(UIThread) {
                =>
                this.updating = false
                if (result.success) {
                    routerPop()
                } else {
                    this.submitError = if (result.errorMessage.size > 0) { result.errorMessage } else { "Unable to create theme" }
                    triggerHaptic("notification", "error")
                }
            }
        }
    }

    private func onTitleChange(v: String): Unit {
        this.title = v
    }

    private func onChangeColorsClick(): Unit {
        routerPush("ThemeAccentColorPickerPage", "")
    }

    private func openThemeFilePicker(): Unit {
        callArkAsync(PICK_DOCUMENT, "{\"suffixes\":[\".tgios-theme\"],\"maxSelectNumber\":1}") { resJson =>
            var pickedPath = ""
            var pickedName = ""
            try {
                let json = JsonParser.parseObject(resJson)
                if (json.getBool("ok") && json.getString("status") == "picked") {
                    let paths = json.getArray("paths")
                    let names = json.getArray("names")
                    if (paths.size() > 0 && names.size() > 0) {
                        pickedPath = paths.getString(0)
                        pickedName = names.getString(0)
                    }
                }
            } catch (e: Exception) {
                Hilog.warn(0, "CjTelegram", "[EditThemePage] document pick response parse failed: ${e}")
            }
            if (pickedPath.size > 0 && pickedName.size > 0) {
                let path = pickedPath
                let name = pickedName
                spawn(UIThread) {
                    =>
                    this.selectedThemePath = path
                    this.selectedThemeName = name
                    this.hasExistingFile = true
                    this.submitError = ""
                }
            }
        }
    }

    private func readFileBytes(path: String): Array<Byte> {
        if (path.size == 0) { return Array<Byte>(0, repeat: 0) }
        try {
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return Array<Byte>(0, repeat: 0) }
            let file = FileIo.open(path, mode: 0o0)
            let data = Array<Byte>(stat.size, repeat: 0)
            let _ = FileIo.read(file.fd, data)
            FileIo.close(file)
            return data
        } catch (e: Exception) {
            Hilog.warn(0, "CjTelegram", "[EditThemePage] unable to read selected theme file: ${e}")
            return Array<Byte>(0, repeat: 0)
        }
    }

    private func previewWallpaper(): WallpaperInfo {
        return getWallpaperBackgroundService().getCurrentWallpaper()
    }

    // F-2（diag-...-TC-0416-round3.md §4.1/§6）：预览块 fixture，源侧
    // EditThemeController.swift:287 的 .create 分支两条 ChatPreviewMessageItem，文案取自
    // en.lproj/Localizable.strings:4938-4941（本报告 §4.1 逐行实读实值）。函数体结构逐字照抄
    // pages/ChatThemesPage.cj#previewIncomingMessage/previewOutgoingMessage，只替换四个文案槽。
    private func previewIncomingMessage(): Message {
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isLastInGroup = true
        msg.isSingleMessage = true
        msg.isSent = false
        msg.content = "Use your current colors"
        msg.replyToMsgId = 3
        msg.replyToSenderName = "Bob"
        msg.replyToText = "How does it work?"
        return msg
    }

    private func previewOutgoingMessage(): Message {
        let msg = Message()
        msg.rawTimestamp = 66000
        msg.time = formatMessageTimestampAt(66000, 66000, true)
        msg.isLastInGroup = true
        msg.isSingleMessage = true
        msg.isSent = true
        msg.status = "read"
        msg.content = "Or upload a theme file"
        return msg
    }

    // 调用形态逐字照抄 pages/ChatThemesPage.cj#buildPreviewIncomingBubble/
    // buildPreviewOutgoingBubble。颜色参数取 currentPresentation() 逐字段值——本页无
    // `presentation` @StorageLink/@State 字段（同型先例：本文件 :258 现有
    // `isDarkMode: currentPresentation().isDark`）。MessageBubble 的六个颜色入参声明为
    // `@State`（非 `@Prop`，见 components/MessageBubble.cj:220-249 的 SDK 语义说明：@State
    // 只在构造时取值一次，无论调用点是裸字段还是函数调用，行为等价），因此 D-125 的
    // `@Prop` 调用点依赖追踪限制在此不适用。
    @Builder
    func buildPreviewIncomingBubble() {
        MessageBubble(
            message: this.previewIncomingMessage(),
            voicePlaybackEpoch: 0,
            bubbleOutColor: currentPresentation().bubbleOutColor,
            bubbleInColor: currentPresentation().bubbleInColor,
            bubbleOutTextColor: currentPresentation().textColor,
            bubbleInTextColor: currentPresentation().textColor,
            replyAuthorAccentColor: currentPresentation().accentColor,
            bubbleOutAccentTextColor: 0x00A700
        )
    }

    @Builder
    func buildPreviewOutgoingBubble() {
        MessageBubble(
            message: this.previewOutgoingMessage(),
            voicePlaybackEpoch: 0,
            bubbleOutColor: currentPresentation().bubbleOutColor,
            bubbleInColor: currentPresentation().bubbleInColor,
            bubbleOutTextColor: currentPresentation().textColor,
            bubbleInTextColor: currentPresentation().textColor,
            replyAuthorAccentColor: currentPresentation().accentColor,
            bubbleOutAccentTextColor: 0x00A700
        )
    }

    // ==================== build ====================

    public func build() {
        Column {
            // 导航栏：左 close 叉 / 标题(三分支) / 右 done 对勾
            // （对位 EditThemeController.swift:499,:508-523,:718-730）。
            Row {
                Image(@r(app.media.username_nav_ic_close))
                    .width(22)
                    .height(22)
                    .fillColor(ITEM_LIST_TEXT_PRIMARY)
                    .onClick({ _ => this.onCloseClick() })

                Blank().layoutWeight(1)
                Text(this.navTitle())
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(ITEM_LIST_TEXT_PRIMARY)
                Blank().layoutWeight(1)

                if (this.updating) {
                    LoadingProgress().width(22).height(22).color(ITEM_LIST_ACCENT)
                } else {
                    Image(@r(app.media.username_nav_ic_done))
                        .width(22)
                        .height(22)
                        .fillColor(if (this.isDoneEnabled()) { ITEM_LIST_ACCENT } else { ITEM_LIST_CHEVRON })
                        .onClick({ _ => this.onDoneClick() })
                }
            }
            .width(100.percent)
            .height(ITEM_LIST_NAVBAR_H + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(ITEM_LIST_BG_CARD)
            .alignItems(VerticalAlign.Center)

            Scroll {
                Column {
                    // ── 第 1 行：Theme Name 输入框（自动获焦；D-153/D-155：本行是页级、
                    // 无条件挂载，`.onAppear` + `FocusControl.requestFocus` 与
                    // auth/PhoneInputPage.cj:441-446 同型先例，不受任何 if 门控竞态） ──
                    Column {
                        ItemListInputRow(
                            title: "",
                            inputId: this.titleInputId,
                            text: this.title,
                            placeholder: trSource("Theme Name"),
                            onChange: this.onTitleChange,
                            showClearButton: true
                        )
                    }
                    .backgroundColor(ITEM_LIST_BG_CARD)
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 16)
                    .translate(x: this.titleShakeOffset)
                    .onAppear({ => FocusControl.requestFocus(this.titleInputId) })

                    // ── 第 2 行：说明文字（EditTheme.Create.TopInfo） ──
                    ItemListSectionFooter(
                        text: "The theme will be based on your currently selected colors and wallpaper.",
                        topPad: 8
                    )

                    // ── 第 3 行：分节头（EditTheme.Preview 大写） ──
                    ItemListSectionHeader(title: "CHAT PREVIEW", topPad: 24)

                    // ── 第 4 行：聊天预览块（壁纸底 + 两条真实气泡，F-2） ──
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
                            isDarkMode: currentPresentation().isDark,
                            patternIntensity: this.previewWallpaper().patternIntensity,
                            patternFile: this.previewWallpaper().patternFile
                        )
                        Column {
                            this.buildPreviewIncomingBubble()
                            this.buildPreviewOutgoingBubble()
                        }
                        .width(100.percent)
                        .padding(top: 4, bottom: 4)
                        .onAreaChange({ _: Area, newArea: Area =>
                            let h = newArea.height.value
                            if (h > this.previewContentHeight + 0.5 || h < this.previewContentHeight - 0.5) {
                                this.previewContentHeight = h
                            }
                        })
                    }
                    // D-165：本节点自身不透明背景全靠子组件 WallpaperBackgroundComponent
                    // 内部 width(100.percent) 撑满，不能在本节点上再显式声明 width(100.percent)
                    // ——否则叠加水平 margin 会撑出溢出的 margin 盒。去掉 width 声明后按本文件
                    // 同 Column 下其余卡片（:274/:288 及 components/ItemListComponents.cj 内
                    // 同款 clip+margin 卡片、先例 pages/LogoutOptionsPage.cj:135）的既有写法：
                    // 无自身 width + margin 左右 16，box 会正确贴合"父宽 - 32"并按 margin 内缩，
                    // 圆角裁剪边界与实际可见内容边界重合。
                    // F-2：块高改为内容驱动（previewContentHeight），不再固定 180——源侧
                    // ThemeSettingsChatPreviewItem.swift:206-211 contentSize.height 同为内容驱动，
                    // 固定高会在气泡换行时裁切（pages/ChatThemesPage.cj#buildChatPreview 同型）。
                    .height(this.previewContentHeight)
                    .clip(true)
                    .borderRadius(12)
                    .margin(left: 16, right: 16, top: 8)

                    // ── 第 5 行：Change Colors ──
                    Column {
                        ItemListDisclosureRow(
                            title: "Change Colors",
                            value: "",
                            onClick: { => this.onChangeColorsClick() }
                        )
                    }
                    .backgroundColor(ITEM_LIST_BG_CARD)
                    .borderRadius(12)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 16)

                    // ── 第 6 行：Create from File...（hasSettings=false 分支，无 chevron） ──
                    Column {
                        ItemListDisclosureRow(
                            title: "Create from File...",
                            value: this.selectedThemeName,
                            showChevron: false,
                            onClick: { => this.openThemeFilePicker() }
                        )
                    }
                    .backgroundColor(ITEM_LIST_BG_CARD)
                    .borderRadius(12)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 16)

                    // ── 第 7 行：说明文字（EditTheme.Create.BottomInfo） ──
                    ItemListSectionFooter(
                        text: "You can also use a manually edited custom theme file.",
                        topPad: 8
                    )
                    if (this.submitError.size > 0) {
                        Text(this.submitError)
                            .fontSize(13)
                            .fontColor(0xFFFF3B30)
                            .width(100.percent)
                            .padding(left: 32, right: 32, top: 8)
                    }
                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .backgroundColor(ITEM_LIST_BG_GROUPED)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(ITEM_LIST_BG_GROUPED)
        .onAppear({ => this.ensureLoaded() })
    }
}
