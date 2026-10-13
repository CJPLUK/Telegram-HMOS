package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getBrowserService}

/**
 * BrowserScreenComponent — 浏览器地址栏 + 导航工具栏组件。
 *
 * 对应 iOS BrowserAddressBarComponent.swift + BrowserToolbarComponent.swift + SearchBarComponent 的核心交互。
 *
 * 功能：
 *   P2-048 页内搜索:
 *     - 工具栏"Find"按钮 → 展开 findBar
 *     - findBar：TextInput + 匹配计数 + 上一条/下一条/关闭按钮
 *   P2-050 阅读模式 / 字号 / 衬线:
 *     - 工具栏"Read"按钮 → 展开阅读工具条（toggle reader CSS，字号 -/=/+，衬线切换）
 *     - 字号显示：${fontSizePercent}%
 *   P2-053 Favicon:
 *     - 地址栏左侧显示 faviconLetter（首字母圆圈，因 SDK 无 onFaviconReceived 绑定）
 *   P2-054 安全锁:
 *     - 地址栏左侧显示 [S] (https) 或 [!] (http)
 *
 * D-002: build() 根容器不需要 NavDestination（此组件嵌入 BrowserScreen，非路由页）。
 */
@Component
public class BrowserScreenComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 混合迁移：删除未使用的 @Consume var pageStack（混合工程无 @Provide NavPathStack 祖先，
    // 该声明在源中即为死代码，从不读取；导航全部经构造回调 onNavigate/onBack/... 委托给父页）

    // 当前 URL（由 BrowserScreen 提供）
    var currentUrl: String = ""
    // 当前页面标题
    var currentTitle: String = ""
    // 是否正在加载
    var isLoading: Bool = false
    // 加载进度 0.0-100.0
    var loadProgress: Float64 = 0.0
    // 后退可用
    var canGoBack: Bool = false
    // 前进可用
    var canGoForward: Bool = false
    // 是否已收藏
    var isBookmarked: Bool = false

    // P2-054: 是否 https 安全
    var isSecure: Bool = false
    // P2-054: 是否已经加载过页面（控制显示锁图标的条件）
    var hasLoadedPage: Bool = false

    // P2-053: favicon 占位字母
    var faviconLetter: String = ""

    // P2-048: 搜索栏可见性
    var isFindBarVisible: Bool = false
    // P2-048: 当前搜索词（由 BrowserScreen 持有，组件显示用）
    var findQuery: String = ""
    // P2-048: 匹配计数
    var findResultCount: Int32 = 0
    // P2-048: 当前匹配序号
    var findCurrentIndex: Int32 = 0

    // P2-050: 阅读模式 / 字号 / 衬线状态（由 BrowserScreen 持有并传入）
    var isReaderModeOn: Bool = false
    var fontSizePercent: Int32 = 100
    var useSerifFont: Bool = false

    // P2-046: 当前"默认使用外部浏览器"偏好（反映 BrowserService 当前读取值）
    var openExternalByDefault: Bool = false

    // P2-049: Instant View 可用性（有 IV 时工具栏 "IV" 按钮可用）
    var hasInstantView: Bool = false

    // P2-051: Tab 数量 + 当前活动 tab 索引（用于工具栏 tab 计数器显示）
    var tabCount: Int64 = 1
    var activeTabIndex: Int64 = 0

    // 导航回调
    var onNavigate: (String) -> Unit = { _url: String => () }
    var onBack: () -> Unit = { => () }
    var onForward: () -> Unit = { => () }
    var onRefresh: () -> Unit = { => () }
    var onStop: () -> Unit = { => () }
    var onShare: () -> Unit = { => () }
    var onBookmark: () -> Unit = { => () }
    var onOpenBookmarks: () -> Unit = { => () }
    var onOpenExternal: () -> Unit = { => () }
    // P2-047: 历史记录回调
    var onOpenHistory: () -> Unit = { => () }
    // P2-046: 切换默认浏览器偏好回调
    var onToggleDefaultBrowser: () -> Unit = { => () }
    // P2-048 搜索回调
    var onToggleFind: () -> Unit = { => () }
    var onFindQueryChanged: (String) -> Unit = { _q: String => () }
    var onFindNext: () -> Unit = { => () }
    var onFindPrev: () -> Unit = { => () }
    var onCloseFind: () -> Unit = { => () }
    // P2-050 阅读模式回调
    var onToggleReaderMode: () -> Unit = { => () }
    var onIncreaseFontSize: () -> Unit = { => () }
    var onDecreaseFontSize: () -> Unit = { => () }
    var onResetFontSize: () -> Unit = { => () }
    var onToggleSerif: () -> Unit = { => () }
    // P2-049: Instant View 切换回调
    var onOpenInstantView: () -> Unit = { => () }
    // P2-051: 新 tab 打开回调 + tab bar toggle
    var onOpenNewTab: () -> Unit = { => () }
    var onToggleTabBar: () -> Unit = { => () }

    // 地址栏编辑状态
    @State var isEditing: Bool = false
    @State var editText: String = ""
    // P2-048: 搜索栏输入状态（本地临时值，提交时通过回调同步到 BrowserScreen）
    @State var findInputText: String = ""
    // P2-050: 阅读工具条是否展开（本地UI状态）
    @State var isReaderToolbarExpanded: Bool = false

    private func getDisplayHost(): String {
        return getBrowserService().extractDisplayHost(this.currentUrl)
    }

    private func submitEditText(): Unit {
        let url = getBrowserService().normalizeUrl(this.editText)
        if (url.size > 0) {
            this.isEditing = false
            this.onNavigate(url)
        } else {
            this.isEditing = false
        }
    }

    // ─── P2-054: 安全锁文字 ────────────────────────────────────────────────────
    private func securityLabel(): String {
        if (!this.hasLoadedPage) {
            return ""
        }
        if (this.isSecure) {
            return "[S]"
        }
        return "[!]"
    }

    private func securityColor(): Int64 {
        if (!this.hasLoadedPage) {
            return 0x8E8E93
        }
        if (this.isSecure) {
            return 0x34C759
        }
        return 0xFF9500
    }

    // ─── P2-053: Favicon 显示辅助 ──────────────────────────────────────────────
    private func hasFaviconLetter(): Bool {
        return this.faviconLetter.size > 0
    }

    // ─── P2-048: 匹配计数文字 ──────────────────────────────────────────────────
    private func findCountText(): String {
        if (this.findResultCount <= 0) {
            return "0/0"
        }
        return "${this.findCurrentIndex}/${this.findResultCount}"
    }

    // ─── P2-050: 字号显示文字 ─────────────────────────────────────────────────
    private func fontSizeLabel(): String {
        return "${this.fontSizePercent}%"
    }

    // ─── P2-049: Instant View 按钮文字 ────────────────────────────────────────
    private func ivButtonLabel(): String {
        if (this.hasInstantView) { return "IV" } else { return "[IV]" }
    }

    private func ivButtonColor(): Int64 {
        if (this.hasInstantView) { return 0x007AFF } else { return 0xC0C0C0 }
    }

    // ─── P2-051: Tab 计数器标签 ───────────────────────────────────────────────
    private func tabCountLabel(): String {
        return "${this.tabCount}"
    }

    func build() {
        Column {
            // 地址栏行（含 P2-053 favicon + P2-054 锁）
            Row {
                // 后退按钮
                Button("<")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(if (this.canGoBack) { 0x007AFF } else { 0xC0C0C0 })
                    .backgroundColor(Color.Transparent)
                    .width(40)
                    .height(40)
                    .enabled(this.canGoBack)
                    .onClick({ _e: ClickEvent =>
                        this.onBack()
                    })

                // 前进按钮
                Button(">")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(if (this.canGoForward) { 0x007AFF } else { 0xC0C0C0 })
                    .backgroundColor(Color.Transparent)
                    .width(40)
                    .height(40)
                    .enabled(this.canGoForward)
                    .onClick({ _e: ClickEvent =>
                        this.onForward()
                    })

                // 地址栏（含 favicon + 安全锁）
                if (this.isEditing) {
                    TextInput(text: this.editText)
                        .fontSize(14)
                        .fontColor(0x000000)
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(8)
                        .padding(left: 8, right: 8, top: 4, bottom: 4)
                        .layoutWeight(1)
                        .height(36)
                        .onChange({ val: String =>
                            this.editText = val
                        })
                        .onSubmit({ _enterKey: EnterKeyType =>
                            this.submitEditText()
                        })
                } else {
                    Row {
                        // P2-053: favicon 占位字母圆圈
                        if (this.hasFaviconLetter()) {
                            Row {
                                Text(this.faviconLetter)
                                    .fontSize(11)
                                    .fontColor(0xFFFFFF)
                                    .fontWeight(FontWeight.Bold)
                            }
                            .width(20)
                            .height(20)
                            .borderRadius(10)
                            .backgroundColor(0x007AFF)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(VerticalAlign.Center)
                            .margin(right: 4)
                        }

                        // P2-054: 安全锁指示器
                        if (this.hasLoadedPage) {
                            Text(this.securityLabel())
                                .fontSize(11)
                                .fontColor(this.securityColor())
                                .fontWeight(FontWeight.Medium)
                                .margin(right: 4)
                        }

                        if (this.isLoading) {
                            LoadingProgress()
                                .width(16)
                                .height(16)
                                .color(0x007AFF)
                                .margin(right: 4)
                        }
                        Text(if (this.getDisplayHost().size > 0) { this.getDisplayHost() } else { "Enter URL..." })
                            .fontSize(14)
                            .fontColor(if (this.getDisplayHost().size > 0) { 0x000000 } else { 0x8E8E93 })
                            .layoutWeight(1)
                            .textAlign(TextAlign.Center)
                            .maxLines(1)
                    }
                    .layoutWeight(1)
                    .height(36)
                    .backgroundColor(0xF2F2F7)
                    .borderRadius(8)
                    .padding(left: 8, right: 8, top: 0, bottom: 0)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _e: ClickEvent =>
                        this.editText = this.currentUrl
                        this.isEditing = true
                    })
                }

                // 刷新/停止按钮
                Button(if (this.isLoading) { "X" } else { "R" })
                    .fontSize(14)
                    .fontColor(if (this.isLoading) { 0xFF3B30 } else { 0x007AFF })
                    .backgroundColor(Color.Transparent)
                    .width(40)
                    .height(40)
                    .onClick({ _e: ClickEvent =>
                        if (this.isLoading) {
                            this.onStop()
                        } else {
                            this.onRefresh()
                        }
                    })

                // 收藏按钮
                Button(if (this.isBookmarked) { "*" } else { "+" })
                    .fontSize(18)
                    .fontColor(if (this.isBookmarked) { 0xFFCC00 } else { 0x007AFF })
                    .backgroundColor(Color.Transparent)
                    .width(40)
                    .height(40)
                    .onClick({ _e: ClickEvent =>
                        this.onBookmark()
                    })
            }
            .width(100.percent)
            .height(48)
            .padding(left: 4, right: 4, top: 4, bottom: 4)
            .backgroundColor(0xF7F7F7)
            .alignItems(VerticalAlign.Center)

            // 加载进度条（onProgressChange 未在 Cangjie SDK 6.0 绑定，用二态进度替代）
            if (this.isLoading) {
                Progress(value: this.loadProgress, total: 100.0, progressType: ProgressType.Linear)
                    .width(100.percent)
                    .height(3)
                    .color(0x007AFF)
                    .backgroundColor(0xE5E5EA)
            }

            // P2-048: 页内搜索栏（isFindBarVisible=true 时显示）
            if (this.isFindBarVisible) {
                Row {
                    // 搜索输入框
                    TextInput(text: this.findInputText)
                        .fontSize(14)
                        .fontColor(0x000000)
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(8)
                        .padding(left: 8, right: 8, top: 4, bottom: 4)
                        .layoutWeight(1)
                        .height(34)
                        .onChange({ val: String =>
                            this.findInputText = val
                            this.onFindQueryChanged(val)
                        })
                        .onSubmit({ _enterKey: EnterKeyType =>
                            this.onFindNext()
                        })

                    // 匹配计数
                    Text(this.findCountText())
                        .fontSize(13)
                        .fontColor(if (this.findResultCount > 0) { 0x007AFF } else { 0x8E8E93 })
                        .width(44)
                        .textAlign(TextAlign.Center)

                    // 上一条
                    Button("^")
                        .fontSize(16)
                        .fontColor(if (this.findResultCount > 0) { 0x007AFF } else { 0xC0C0C0 })
                        .backgroundColor(Color.Transparent)
                        .width(36)
                        .height(36)
                        .enabled(this.findResultCount > 0)
                        .onClick({ _e: ClickEvent =>
                            this.onFindPrev()
                        })

                    // 下一条
                    Button("v")
                        .fontSize(16)
                        .fontColor(if (this.findResultCount > 0) { 0x007AFF } else { 0xC0C0C0 })
                        .backgroundColor(Color.Transparent)
                        .width(36)
                        .height(36)
                        .enabled(this.findResultCount > 0)
                        .onClick({ _e: ClickEvent =>
                            this.onFindNext()
                        })

                    // 关闭按钮
                    Button(trSource("Done"))
                        .fontSize(13)
                        .fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .height(36)
                        .padding(left: 6, right: 6, top: 0, bottom: 0)
                        .onClick({ _e: ClickEvent =>
                            this.findInputText = ""
                            this.onCloseFind()
                        })
                }
                .width(100.percent)
                .height(44)
                .padding(left: 8, right: 8, top: 4, bottom: 4)
                .backgroundColor(0xF7F7F7)
                .alignItems(VerticalAlign.Center)
            }

            // P2-050: 阅读工具条（isReaderToolbarExpanded=true 时显示）
            if (this.isReaderToolbarExpanded) {
                Row {
                    // 阅读模式开关按钮
                    Button(if (this.isReaderModeOn) { "[Read ON]" } else { "[Read OFF]" })
                        .fontSize(12)
                        .fontColor(if (this.isReaderModeOn) { 0xFFFFFF } else { 0x007AFF })
                        .backgroundColor(if (this.isReaderModeOn) { 0x007AFF } else { 0xF2F2F7 })
                        .borderRadius(6)
                        .height(32)
                        .padding(left: 8, right: 8, top: 0, bottom: 0)
                        .onClick({ _e: ClickEvent =>
                            this.onToggleReaderMode()
                        })

                    Blank().layoutWeight(1)

                    // 字号减小
                    Button("A-")
                        .fontSize(13)
                        .fontColor(if (this.fontSizePercent > 50) { 0x007AFF } else { 0xC0C0C0 })
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(6)
                        .width(36)
                        .height(32)
                        .enabled(this.fontSizePercent > 50)
                        .onClick({ _e: ClickEvent =>
                            this.onDecreaseFontSize()
                        })

                    // 字号显示 + 重置按钮
                    Button(this.fontSizeLabel())
                        .fontSize(13)
                        .fontColor(if (this.fontSizePercent == 100) { 0x8E8E93 } else { 0x007AFF })
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(6)
                        .height(32)
                        .padding(left: 8, right: 8, top: 0, bottom: 0)
                        .onClick({ _e: ClickEvent =>
                            this.onResetFontSize()
                        })

                    // 字号增大
                    Button("A+")
                        .fontSize(13)
                        .fontColor(if (this.fontSizePercent < 200) { 0x007AFF } else { 0xC0C0C0 })
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(6)
                        .width(36)
                        .height(32)
                        .enabled(this.fontSizePercent < 200)
                        .onClick({ _e: ClickEvent =>
                            this.onIncreaseFontSize()
                        })

                    // 衬线切换
                    Button(if (this.useSerifFont) { "Serif" } else { "Sans" })
                        .fontSize(12)
                        .fontColor(if (this.useSerifFont) { 0xFFFFFF } else { 0x007AFF })
                        .backgroundColor(if (this.useSerifFont) { 0x5856D6 } else { 0xF2F2F7 })
                        .borderRadius(6)
                        .height(32)
                        .padding(left: 8, right: 8, top: 0, bottom: 0)
                        .margin(left: 4)
                        .onClick({ _e: ClickEvent =>
                            this.onToggleSerif()
                        })
                }
                .width(100.percent)
                .height(44)
                .padding(left: 8, right: 8, top: 4, bottom: 4)
                .backgroundColor(0xF2F7FF)
                .alignItems(VerticalAlign.Center)
            }

            // 底部工具栏（行1）：后退/前进/分享/查找/阅读/书签
            Row {
                Button("<")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(if (this.canGoBack) { 0x007AFF } else { 0xC0C0C0 })
                    .backgroundColor(Color.Transparent)
                    .width(40)
                    .height(44)
                    .enabled(this.canGoBack)
                    .onClick({ _e: ClickEvent =>
                        this.onBack()
                    })
                Button(">")
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(if (this.canGoForward) { 0x007AFF } else { 0xC0C0C0 })
                    .backgroundColor(Color.Transparent)
                    .width(40)
                    .height(44)
                    .enabled(this.canGoForward)
                    .onClick({ _e: ClickEvent =>
                        this.onForward()
                    })
                // P2-045: Share 按钮（弹分享菜单）
                Button(trSource("Share"))
                    .fontSize(13)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .height(44)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .onClick({ _e: ClickEvent =>
                        this.onShare()
                    })
                // P2-048: Find 按钮（切换搜索栏）
                Button(if (this.isFindBarVisible) { "[F]" } else { "Find" })
                    .fontSize(13)
                    .fontColor(if (this.isFindBarVisible) { 0xFF9500 } else { 0x007AFF })
                    .backgroundColor(Color.Transparent)
                    .height(44)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .onClick({ _e: ClickEvent =>
                        this.onToggleFind()
                    })
                // P2-050: Read 按钮（展开阅读工具条）
                Button(if (this.isReaderToolbarExpanded) { "[Rd]" } else { "Read" })
                    .fontSize(13)
                    .fontColor(if (this.isReaderModeOn) { 0x34C759 } else if (this.isReaderToolbarExpanded) { 0xFF9500 } else { 0x007AFF })
                    .backgroundColor(Color.Transparent)
                    .height(44)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .onClick({ _e: ClickEvent =>
                        this.isReaderToolbarExpanded = !this.isReaderToolbarExpanded
                    })
                Button(if (this.isBookmarked) { "*Bk" } else { "Bk" })
                    .fontSize(13)
                    .fontColor(if (this.isBookmarked) { 0xFFCC00 } else { 0x007AFF })
                    .backgroundColor(Color.Transparent)
                    .height(44)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .onClick({ _e: ClickEvent =>
                        this.onOpenBookmarks()
                    })
                // P2-049: Instant View 切换按钮（有 IV 时蓝色可点，无 IV 时灰色禁用）
                Button(this.ivButtonLabel())
                    .fontSize(13)
                    .fontColor(this.ivButtonColor())
                    .backgroundColor(Color.Transparent)
                    .height(44)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .enabled(this.hasInstantView)
                    .onClick({ _e: ClickEvent =>
                        this.onOpenInstantView()
                    })
                // P2-051: Tab 计数器按钮（显示当前 tab 数量，点击展开 tab 管理栏）
                Button(this.tabCountLabel())
                    .fontSize(13)
                    .fontColor(0x007AFF)
                    .backgroundColor(0xF2F2F7)
                    .borderRadius(6)
                    .width(32)
                    .height(32)
                    .onClick({ _e: ClickEvent =>
                        this.onToggleTabBar()
                    })
            }
            .width(100.percent)
            .height(44)
            .justifyContent(FlexAlign.SpaceEvenly)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xF7F7F7)

            // 底部工具栏（行2）：P2-046 外部打开 + 默认浏览器切换 / P2-047 历史
            Row {
                // P2-046: 在系统浏览器中打开当前页
                Button("Open Ext")
                    .fontSize(13)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .height(40)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .onClick({ _e: ClickEvent =>
                        this.onOpenExternal()
                    })
                // P2-046: 切换"默认使用外部浏览器"偏好
                Button(if (this.openExternalByDefault) { "[Ext Default ON]" } else { "Set Ext Default" })
                    .fontSize(11)
                    .fontColor(if (this.openExternalByDefault) { 0xFFFFFF } else { 0x007AFF })
                    .backgroundColor(if (this.openExternalByDefault) { 0xFF9500 } else { 0xF2F2F7 })
                    .borderRadius(6)
                    .height(32)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .onClick({ _e: ClickEvent =>
                        this.onToggleDefaultBrowser()
                    })
                Blank().layoutWeight(1)
                // P2-047: 历史记录按钮
                Button(trSource("History"))
                    .fontSize(13)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .height(40)
                    .padding(left: 6, right: 6, top: 0, bottom: 0)
                    .onClick({ _e: ClickEvent =>
                        this.onOpenHistory()
                    })
            }
            .width(100.percent)
            .height(40)
            .padding(left: 8, right: 8, top: 0, bottom: 0)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(0xF7F7F7)
        }
        .width(100.percent)
    }
}
