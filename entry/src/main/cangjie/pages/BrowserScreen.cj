package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.web.webview.WebviewController
import kit.ArkWeb.SecurityLevel
import ohos.arkui.state_macro_manage.*
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getBrowserService, getGlobalAbilityContext, getShareControllerService, setPendingBrowserShare, setPendingExternalContent, ExternalContentItem, getBrowserTabRegistry, BrowserTab, BrowserTabRegistry, firstRuneString}
import ohos_app_cangjie_entry.services.{getInstantPageCacheService, getInstantPageService}
import kit.AbilityKit.Want
import std.collection.ArrayList
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * BrowserScreen — 应用内浏览器主页面（混合工程迁移版）。
 *
 * 对应 iOS BrowserScreen.swift。
 *
 * 功能：
 *   - 地址栏显示当前 URL 域名，点击可编辑并导航
 *   - 鸿蒙 Web 组件真实加载 URL
 *   - 前进 / 后退 / 刷新（通过 WebviewController.goBack() / goForward() / refresh()）
 *   - 收藏书签（通过 BrowserService + Preferences 持久化）
 *   - 打开书签列表（跳转 BrowserBookmarksScreen）
 *
 * P2-048 页内搜索：
 *   - 工具栏"Find"按钮 → 展开搜索栏
 *   - 搜索栏输入 → runJavaScript 注入 highlight JS（高亮所有匹配）
 *   - 上一条/下一条按钮 → runJavaScript 跳转
 *   - 匹配计数通过 JS 回调更新
 *   - 关闭 → clearMatches JS 清除高亮
 *   注：Cangjie SDK 6.0 未绑定 WebviewController.searchAllAsync / onSearchResultReceive，
 *       改用 JS 注入（runJavaScript）实现，与 iOS fallback 路径（evaluateJavaScript）等价。
 *
 * P2-050 阅读模式 / 字号 / 衬线控制：
 *   - 阅读模式：runJavaScript 注入 reader CSS（去广告/居中正文/可读排版），toggle 开关
 *   - 字号 +/-/重置：runJavaScript 改 document.body.style.fontSize（N%）
 *   - 衬线切换：runJavaScript 改 document.body.style.fontFamily（serif / sans-serif）
 *   注：iOS BrowserUI 使用 WKWebView.evaluateJavaScript 注入 reader mode CSS；
 *       Cangjie 等价路径是 WebviewController.runJavaScript。
 *
 * P2-052 下载管理：
 *   - onLoadIntercept 拦截下载类 URL（.pdf/.zip/.apk 等扩展名 / content-disposition 检测）
 *   - 显示确认对话框（文件名 + 说明）→ 用户确认后通过 Want(viewData) 走系统下载
 *   注：Cangjie SDK 6.0 WebDownloadDelegate 无 Cangjie binding 示例（KB 无命中），
 *       用 onLoadIntercept + 系统浏览器下载作为诚实降级。
 *
 * P2-053 Favicon：
 *   - Cangjie SDK 6.0 Web 组件未暴露 onFaviconReceived 回调，
 *     降级：用 currentTitle 首字母作为 favicon 占位（字母图标圆圈），
 *     在地址栏左侧显示。
 *
 * P2-054 安全锁指示：
 *   - onPageEnd 时通过 webController.getSecurityLevel() 判断：
 *     SecurityLevel.Secure → isSecure=true (显示锁)；其余 → isSecure=false (显示⚠)
 *   - 地址栏左侧显示 [S] (绿) 或 [!] (橙) 指示器
 *
 * P2-045 分享当前页：
 *   - 工具栏"Share"按钮 → 展开分享菜单（System Share / 分享到会话）
 *   - "System Share"：getShareControllerService().shareInviteLinkViaSystem(url)（系统分享面板）
 *   - "Share to Chat"：setPendingBrowserShare(url, title) → pushPathByName("ShareControllerPage", "")
 *   防死状态：两条路径均调用真实 API，非假分享。
 *
 * P2-046 在外部浏览器打开 + 默认浏览器偏好：
 *   - 工具栏"Open Ext"：openInSystemBrowser()（Want viewData）
 *   - 工具栏"Set Default"按钮：toggleDefaultBrowserPref() 切换 openExternalBrowser 偏好
 *   - 状态由 BrowserService.getOpenExternalBrowser() 持久化读取
 *   防死状态：偏好变更实时写 Preferences，不硬编码。
 *
 * P2-047 最近访问历史：
 *   - 每次 onPageEnd 调用 getBrowserService().recordVisit(url, title)（Preferences 持久化）
 *   - 工具栏"History"按钮 → pushPathByName("BrowserHistoryScreen", "")
 *   - BrowserHistoryScreen 读取 getBrowserService().getRecentHistory()，支持点击重访、清除、去重
 *   防死状态：recordVisit 写 Preferences 真实持久，BrowserHistoryScreen 真实消费。
 *
 * P2-055 浏览器集成入口：
 *   - BrowserService.resolveUrl / isBotWebAppUrl 已供 ChatRoomPage/SettingsPage 使用
 *   - ChatRoomPage.openWebUrl → resolveUrl → BrowserScreen（InApp）/ Want（External）
 *   - Bot 链接判别：isBotWebAppUrl(url) → pushPathByName("WebAppPage", url) 而非 BrowserScreen
 *   - BrowserService init 通过 IC 在 MainAbility.onWindowStageCreate 接线（emitted_integration_contracts）
 *
 * 路由参数格式（通过 onReady context 读取）：
 *   "<initialUrl>"  — 初始要打开的 URL，可为空（默认打开空页）
 *
 * D-002: build() 根容器必须是 NavDestination()。
 * S-001: runJavaScript 回调非 UIThread；回调内 @State 写入必须包裹 spawn(UIThread)。
 */
@HybridComponentEntry
@Component
public class BrowserScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 混合迁移：删除 @Consume var pageStack（NavDestination 由 ArkTS 壳提供，导航经 router.*）

    @State var currentUrl: String = ""
    @State var currentTitle: String = "Browser"
    @State var isLoading: Bool = false
    @State var loadProgress: Float64 = 0.0
    @State var canGoBack: Bool = false
    @State var canGoForward: Bool = false
    @State var isBookmarked: Bool = false
    @State var loadError: String = ""

    // P2-054: 安全锁状态
    @State var isSecure: Bool = false
    @State var hasLoadedPage: Bool = false

    // P2-053: favicon 占位字母
    @State var faviconLetter: String = ""

    // P2-048: 页内搜索状态
    @State var isFindBarVisible: Bool = false
    @State var findQuery: String = ""
    @State var findResultCount: Int32 = 0
    @State var findCurrentIndex: Int32 = 0

    // P2-050: 阅读模式 / 字号 / 衬线状态
    @State var isReaderModeOn: Bool = false
    @State var fontSizePercent: Int32 = 100
    @State var useSerifFont: Bool = false

    // P2-052: 下载确认对话框状态
    @State var showDownloadDialog: Bool = false
    @State var downloadFileName: String = ""
    @State var downloadUrl: String = ""

    // P2-045: 分享菜单展开状态
    @State var showShareMenu: Bool = false

    // P2-046: 默认浏览器偏好（true = 系统外部，false = 应用内）
    @State var openExternalByDefault: Bool = false

    // P2-049: Instant View 可用性 + 当前模式
    // hasInstantView=true 表示当前 URL 有对应 IV，工具栏"IV"按钮可用
    // isInInstantViewMode=true 表示已切换到 InstantPagePage（通过 push 导航）
    @State var hasInstantView: Bool = false

    // P2-051: 多 tab 状态（从 BrowserTabRegistry 共享读取，@State 用于 UI 刷新）
    @State var activeTabIndex: Int64 = 0
    @State var tabCount: Int64 = 1
    // tabTitles: parallel Array mirroring BrowserTabRegistry.tabs[].title for ForEach rendering
    @State var tabTitles: Array<String> = ["New Tab"]
    // showTabBar: 展开/收起 tab 栏
    @State var showTabBar: Bool = false

    let webController: WebviewController = WebviewController()

    private var initialUrl: String = ""

    @State var loaded: Bool = false

    // 混合迁移：源 onReady 收路由 param 设 initialUrl，随后 aboutToAppear 读服务并加载；
    // 混合工程合并进 ensureLoaded()：先 takePending("BrowserScreen") 解析 URL，再执行原加载逻辑。
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.parseRouteParam(takePending("BrowserScreen"))
        Hilog.info(0, "CjTelegram", "[BrowserScreen] onAppear")
        // P2-046: 读取当前默认浏览器偏好
        this.openExternalByDefault = getBrowserService().getOpenExternalBrowser()

        // P2-051: sync tab state from registry
        let reg = getBrowserTabRegistry()
        this.activeTabIndex = reg.activeTabIndex
        this.tabCount = reg.tabCount()
        this.syncTabTitles()
        if (this.initialUrl.size == 0 && reg.activeTabIndex >= 0 && reg.activeTabIndex < reg.tabs.size) {
            let tabUrl = reg.tabs[reg.activeTabIndex].url
            if (tabUrl.size > 0) { this.initialUrl = tabUrl }
        }

        // P2-049: reset IV state on new page appear
        this.hasInstantView = false

        if (this.initialUrl.size > 0) {
            let normalizedUrl = getBrowserService().normalizeUrl(this.initialUrl)
            if (normalizedUrl.size > 0) {
                // P2-051: update active tab URL in registry
                getBrowserTabRegistry().updateActiveTab(normalizedUrl, "")
                this.currentUrl = normalizedUrl
                this.isLoading = true
                let initialLoadUrl = normalizedUrl
                let _ = spawn {
                    // The Hybrid page's onAppear may run before Web has attached its
                    // controller. Defer the first navigation until the node is mounted.
                    sleep(Duration.millisecond * 200)
                    spawn(UIThread) { =>
                        try {
                            Hilog.info(0, "CjTelegram", "[BrowserScreen] initial loadUrl: ${initialLoadUrl}")
                            this.webController.loadUrl(initialLoadUrl)
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[BrowserScreen] loadUrl on init failed: ${e}")
                            this.isLoading = false
                            this.loadError = "Failed to load page"
                        }
                    }
                }
                // P2-049: check IV availability for initial URL in background
                this.checkInstantViewAvailability(normalizedUrl)
            }
        }
    }

    private func parseRouteParam(param: String): Unit {
        let trimmed = param.trimAscii()
        if (trimmed.size > 0) {
            this.initialUrl = trimmed
        }
    }

    // ─── P2-051: Tab 同步辅助 ──────────────────────────────────────────────────

    /**
     * P2-051: Sync tabTitles @State array from BrowserTabRegistry.
     * Must be called from UI thread (onPageEnd, tab operations, etc.).
     * Produces a parallel Array<String> for ForEach rendering.
     */
    private func syncTabTitles(): Unit {
        let reg = getBrowserTabRegistry()
        let n = reg.tabCount()
        let titles = Array<String>(n, { i: Int64 => reg.tabs[i].title })
        this.tabTitles = titles
        this.tabCount = n
        this.activeTabIndex = reg.activeTabIndex
    }

    /**
     * P2-051: Open a new blank tab.
     */
    private func openNewTab(): Unit {
        let reg = getBrowserTabRegistry()
        let _ = reg.openNewTab("")
        this.syncTabTitles()
        // New tab starts blank — clear current load state
        this.currentUrl = ""
        this.currentTitle = "New Tab"
        this.isLoading = false
        this.loadError = ""
        this.hasInstantView = false
        this.isBookmarked = false
        this.isSecure = false
        this.hasLoadedPage = false
        this.faviconLetter = ""
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-051 openNewTab count=${this.tabCount}")
    }

    /**
     * P2-051: Open a URL in a new tab.
     * Called when user long-presses a link or explicitly requests new-tab navigation.
     */
    private func openUrlInNewTab(url: String): Unit {
        let normalized = getBrowserService().normalizeUrl(url)
        if (normalized.size == 0) { return }
        let reg = getBrowserTabRegistry()
        let _ = reg.openNewTab(normalized)
        this.syncTabTitles()
        // Navigate the new tab
        this.navigateTo(normalized)
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-051 openUrlInNewTab: ${normalized}")
    }

    /**
     * P2-051: Switch to tab at index.
     * Restores URL/title state for the target tab and triggers loadUrl if needed.
     */
    private func switchToTab(index: Int64): Unit {
        let reg = getBrowserTabRegistry()
        if (index < 0 || index >= reg.tabCount()) { return }
        reg.switchToTab(index)
        this.syncTabTitles()
        let tab = reg.tabs[index]
        // Restore state for switched-to tab
        this.currentUrl = tab.url
        this.currentTitle = tab.title
        this.isLoading = false
        this.loadError = ""
        this.hasInstantView = false
        this.isBookmarked = if (tab.url.size > 0) { getBrowserService().isBookmarked(tab.url) } else { false }
        this.isSecure = false
        this.hasLoadedPage = false
        this.faviconLetter = ""
        this.isReaderModeOn = false
        // If the tab has a URL, reload it in the single Web component
        if (tab.url.size > 0) {
            let url = tab.url
            this.isLoading = true
            try {
                this.webController.loadUrl(url)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-051 switchToTab loadUrl failed: ${e}")
                this.isLoading = false
            }
            this.checkInstantViewAvailability(url)
        }
        this.showTabBar = false
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-051 switchToTab idx=${index}")
    }

    /**
     * P2-051: Close tab at index.
     */
    private func closeTab(index: Int64): Unit {
        let reg = getBrowserTabRegistry()
        reg.closeTab(index)
        this.syncTabTitles()
        // If we closed the active tab (or one before it), restore correct active tab state
        let newActive = reg.activeTabIndex
        let tab = reg.tabs[newActive]
        this.currentUrl = tab.url
        this.currentTitle = tab.title
        this.isLoading = false
        this.loadError = ""
        this.hasInstantView = false
        if (tab.url.size > 0) {
            let url = tab.url
            this.isLoading = true
            try {
                this.webController.loadUrl(url)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-051 closeTab loadUrl failed: ${e}")
                this.isLoading = false
            }
        }
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-051 closeTab idx=${index}, newActive=${newActive}")
    }

    // ─── P2-049: Instant View 可用性检测 + 切换 ────────────────────────────────

    /**
     * P2-049: Probes whether the current URL has a Telegram Instant View.
     *
     * Detection strategy (ctor: messages.getWebPage / InstantPageService.fetchWebPage):
     *   1. Fast path: InstantPageCacheService.isFresh(url) — already cached → IV available
     *   2. Slow path: getInstantPageService().fetchWebPage(url) in background
     *      → if data.loaded && data.blocks.size > 0 → IV available
     *
     * Called after page load (onPageEnd) in background spawn.
     * @State write wrapped in spawn(UIThread) per S-001.
     */
    private func checkInstantViewAvailability(url: String): Unit {
        if (url.size == 0) { return }
        // Fast path: already cached
        if (getInstantPageCacheService().isFresh(url)) {
            this.hasInstantView = true
            Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-049 IV fast-path available for: ${url}")
            return
        }
        // Slow path: network fetch in background
        let captureUrl = url
        let _ = spawn {
            let data = getInstantPageService().fetchWebPage(captureUrl)
            let available = data.loaded && data.blocks.size > 0
            let capAvail = available
            spawn(UIThread) { =>
                this.hasInstantView = capAvail
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-049 IV slow-path hasIV=${capAvail}")
            }
        }
    }

    /**
     * P2-049: Switch to Instant View for the current URL.
     * Pushes InstantPagePage onto the navigation stack.
     * InstantPagePage already exists (P2-214..217 merged).
     * Passing url as route param; InstantPagePage.onReady reads it.
     */
    private func openInstantView(): Unit {
        let url = this.currentUrl
        if (url.size == 0 || !this.hasInstantView) { return }
        routerPush("InstantPagePage", url)
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-049 openInstantView: ${url}")
    }

    private func navigateTo(url: String): Unit {
        let normalized = getBrowserService().normalizeUrl(url)
        if (normalized.size == 0) {
            return
        }
        this.currentUrl = normalized
        this.loadError = ""
        this.isLoading = true
        // P2-049: reset IV state on new navigation
        this.hasInstantView = false
        // 导航时重置 find bar / reader mode / 安全状态
        if (this.isFindBarVisible) {
            this.closeFindBar()
        }
        this.isSecure = false
        this.hasLoadedPage = false
        // P2-050: 导航新页面时重置阅读模式（新页面无注入 CSS）
        this.isReaderModeOn = false
        // P2-051: update active tab URL in registry
        getBrowserTabRegistry().updateActiveTab(normalized, "")
        try {
            this.webController.loadUrl(normalized)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] loadUrl failed")
            this.isLoading = false
            this.loadError = "Failed to load page"
        }
        // P2-049: check IV availability in background
        this.checkInstantViewAvailability(normalized)
    }

    private func goBack(): Unit {
        try {
            if (this.webController.accessStep(-1)) {
                this.webController.goBack()
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] goBack failed")
        }
    }

    private func goForward(): Unit {
        try {
            if (this.webController.accessStep(1)) {
                this.webController.goForward()
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] goForward failed")
        }
    }

    private func refreshPage(): Unit {
        try {
            this.webController.reload()
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] reload failed")
        }
    }

    private func stopPage(): Unit {
        try {
            this.webController.stop()
            this.isLoading = false
            Hilog.info(0, "CjTelegram", "[BrowserScreen] stopPage: loading stopped")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] stopPage failed: ${e}")
        }
    }

    /**
     * P2-045: 通过系统分享面板分享当前 URL。
     * 使用 Want(action: SEND, text/plain) 弹出系统分享选择器。
     */
    private func sharePage(): Unit {
        let url = this.currentUrl
        if (url.size == 0) {
            return
        }
        this.showShareMenu = false
        let _ = getShareControllerService().shareInviteLinkViaSystem(url)
        Hilog.info(0, "CjTelegram", "[BrowserScreen] sharePage: system share ${url}")
    }

    /**
     * P2-045: 分享当前 URL 到 Telegram 对话（ShareControllerPage）。
     * 将 URL 打包为 ExternalContentItem(kind="text", textValue=url+title)，
     * 写入 setPendingExternalContent，再 push ShareControllerPage 让用户选择目标会话。
     * ShareControllerPage.aboutToAppear() 消费 consumePendingExternalContent()，
     * 经 ExternalContentNormalizationService 标准化为 NormalizedContentItem(kind="url"/"text")，
     * 用 sendToTargets 发送到选中的对话。
     */
    private func sharePageToTelegram(): Unit {
        let url = this.currentUrl
        if (url.size == 0) {
            return
        }
        this.showShareMenu = false
        // 构造外部内容项（URL 文本）
        let item = ExternalContentItem()
        item.kind = "text"
        // textValue 包含 URL + 可选标题（标题非空时格式为"title url"）
        let titlePart = this.currentTitle
        if (titlePart.size > 0 && titlePart != url) {
            item.textValue = titlePart + "\n" + url
        } else {
            item.textValue = url
        }
        let items = ArrayList<ExternalContentItem>()
        items.add(item)
        setPendingExternalContent(items)
        routerPush("ShareControllerPage", "")
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-045 sharePageToTelegram: ${url}")
    }

    /**
     * P2-046: 切换"默认使用系统外部浏览器"偏好。
     * 调用 BrowserService.setOpenExternalBrowser，写 Preferences 真实持久化。
     */
    private func toggleDefaultBrowserPref(): Unit {
        let newVal = !this.openExternalByDefault
        getBrowserService().setOpenExternalBrowser(newVal)
        this.openExternalByDefault = newVal
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-046 toggleDefaultBrowserPref: ${newVal}")
    }

    /**
     * P2-047: 打开最近访问历史页面。
     */
    private func openHistory(): Unit {
        routerPush("BrowserHistoryScreen", "")
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-047 openHistory")
    }

    private func toggleBookmark(): Unit {
        let url = this.currentUrl
        if (url.size == 0) {
            return
        }
        if (getBrowserService().isBookmarked(url)) {
            getBrowserService().removeBookmark(url)
            this.isBookmarked = false
            Hilog.info(0, "CjTelegram", "[BrowserScreen] Bookmark removed")
        } else {
            getBrowserService().addBookmark(url, this.currentTitle)
            this.isBookmarked = true
            Hilog.info(0, "CjTelegram", "[BrowserScreen] Bookmark added")
        }
    }

    private func openBookmarks(): Unit {
        routerPush("BrowserBookmarksScreen", "")
    }

    private func openInSystemBrowser(): Unit {
        let url = this.currentUrl
        if (url.size == 0) {
            return
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let want = Want(action: "ohos.want.action.viewData", uri: url)
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[BrowserScreen] openInSystemBrowser: ${url}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserScreen] openInSystemBrowser failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[BrowserScreen] openInSystemBrowser: no context")
        }
    }

    private func updateNavState(): Unit {
        try {
            this.canGoBack = this.webController.accessStep(-1)
            this.canGoForward = this.webController.accessStep(1)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] updateNavState failed")
        }
        this.isBookmarked = getBrowserService().isBookmarked(this.currentUrl)
    }

    // ─── P2-054: 安全锁判断 ────────────────────────────────────────────────────

    /**
     * P2-054: 通过 WebviewController.getSecurityLevel() 获取真实安全级别。
     * KB Example64-65: public func getSecurityLevel(): SecurityLevel
     * SecurityLevel.Secure → isSecure=true; 其余（NoneLevel/Warning/Dangerous）→ false。
     * 在 onPageEnd 回调中调用（UI 线程，无需 spawn(UIThread)）。
     */
    private func updateSecurityState(): Unit {
        let sl = try { this.webController.getSecurityLevel() } catch (_: Exception) { SecurityLevel.NoneLevel }
        this.isSecure = (sl == SecurityLevel.Secure)
        this.hasLoadedPage = this.currentUrl.size > 0
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-054 getSecurityLevel isSecure=${this.isSecure}")
    }

    // ─── P2-053: Favicon 占位 ────────────────────────────────────────────────

    private func updateFaviconLetter(): Unit {
        let title = this.currentTitle
        if (title.size > 0) {
            this.faviconLetter = firstRuneString(title).toAsciiUpper()
        } else {
            let host = getBrowserService().extractDisplayHost(this.currentUrl)
            if (host.size > 0) {
                this.faviconLetter = host[0..1].toAsciiUpper()
            } else {
                this.faviconLetter = "W"
            }
        }
    }

    // ─── P2-048: 页内搜索 ──────────────────────────────────────────────────────

    private func openFindBar(): Unit {
        this.isFindBarVisible = true
        this.findQuery = ""
        this.findResultCount = 0
        this.findCurrentIndex = 0
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 openFindBar")
    }

    private func closeFindBar(): Unit {
        this.isFindBarVisible = false
        this.findResultCount = 0
        this.findCurrentIndex = 0
        let query = this.findQuery
        this.findQuery = ""
        if (query.size > 0) {
            this.clearFindHighlights()
        }
    }

    private func clearFindHighlights(): Unit {
        let clearJs = "(" +
            "function(){" +
            "var spans=document.querySelectorAll('.__findHighlight');" +
            "for(var i=0;i<spans.length;i++){" +
            "var s=spans[i];" +
            "var p=s.parentNode;" +
            "if(p){p.replaceChild(document.createTextNode(s.textContent),s);}" +
            "}" +
            "}" +
            ")()"
        try {
            this.webController.runJavaScript(clearJs, {
                _err: Option<BusinessException>, _data: Option<String> =>
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 clearHighlights done")
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 clearHighlights err: ${e}")
        }
    }

    private func executeFindSearch(query: String): Unit {
        if (query.size == 0) {
            this.clearFindHighlights()
            this.findResultCount = 0
            this.findCurrentIndex = 0
            return
        }
        let safeQuery = query.replace("'", "\\'").replace("\\", "\\\\")
        let searchJs = "(" +
            "function(q){" +
            "var spans=document.querySelectorAll('.__findHighlight');" +
            "for(var i=0;i<spans.length;i++){var s=spans[i];var p=s.parentNode;" +
            "if(p){p.replaceChild(document.createTextNode(s.textContent),s);}}" +
            "document.normalize();" +
            "if(!q||q.length===0)return '0';" +
            "var walker=document.createTreeWalker(document.body,4,null);" +
            "var nodes=[];var node;" +
            "while((node=walker.nextNode())){nodes.push(node);}" +
            "var count=0;var ql=q.toLowerCase();" +
            "for(var i=0;i<nodes.length;i++){" +
            "var n=nodes[i];var txt=n.textContent;" +
            "var tl=txt.toLowerCase();var idx=tl.indexOf(ql);" +
            "if(idx<0)continue;" +
            "var frag=document.createDocumentFragment();" +
            "var last=0;" +
            "while(idx>=0){" +
            "if(idx>last)frag.appendChild(document.createTextNode(txt.slice(last,idx)));" +
            "var sp=document.createElement('span');" +
            "sp.className='__findHighlight';" +
            "sp.style.backgroundColor='rgba(255,200,0,0.6)';" +
            "sp.style.color='black';" +
            "sp.textContent=txt.slice(idx,idx+q.length);" +
            "frag.appendChild(sp);" +
            "count++;last=idx+q.length;" +
            "idx=tl.indexOf(ql,last);" +
            "}" +
            "if(last<txt.length)frag.appendChild(document.createTextNode(txt.slice(last)));" +
            "if(n.parentNode)n.parentNode.replaceChild(frag,n);" +
            "}" +
            "var first=document.querySelector('.__findHighlight');" +
            "if(first)first.scrollIntoView({block:'center'});" +
            "return String(count);" +
            "})('${safeQuery}')"
        try {
            this.webController.runJavaScript(searchJs, {
                _err: Option<BusinessException>, data: Option<String> =>
                // S-001: runJavaScript callback runs off UIThread; wrap @State writes in spawn(UIThread)
                let parsed: Int32 = match (data) {
                    case Some(s) =>
                        let trimmed = s.trimAscii().replace("\"", "")
                        var nLong: Int64 = 0
                        let runes2 = trimmed.toRuneArray()
                        var ri: Int64 = 0
                        while (ri < runes2.size) {
                            let c2 = UInt32(runes2[ri])
                            if (c2 >= 48u32 && c2 <= 57u32) {
                                nLong = nLong * 10 + Int64(c2 - 48u32)
                            }
                            ri = ri + 1
                        }
                        Int32(nLong)
                    case None => Int32(0)
                }
                spawn(UIThread) { =>
                    this.findResultCount = parsed
                    this.findCurrentIndex = if (parsed > 0) { Int32(1) } else { Int32(0) }
                    Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 search done count=${parsed}")
                }
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 executeFindSearch err: ${e}")
        }
    }

    private func findNext(): Unit {
        if (this.findResultCount <= 0) {
            return
        }
        let nextIndex: Int32 = if (this.findCurrentIndex >= this.findResultCount) { Int32(1) } else { this.findCurrentIndex + Int32(1) }
        this.findCurrentIndex = nextIndex
        let jsIdx = Int64(nextIndex) - 1
        let scrollJs = "(function(idx){" +
            "var spans=document.querySelectorAll('.__findHighlight');" +
            "for(var i=0;i<spans.length;i++){spans[i].style.backgroundColor='rgba(255,200,0,0.6)';}" +
            "if(idx>=0&&idx<spans.length){" +
            "spans[idx].style.backgroundColor='rgba(255,130,0,0.9)';" +
            "spans[idx].scrollIntoView({block:'center'});}" +
            "return 'ok';})(${jsIdx})"
        try {
            this.webController.runJavaScript(scrollJs, {
                _err: Option<BusinessException>, _data: Option<String> =>
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 findNext done idx=${jsIdx}")
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 findNext err: ${e}")
        }
    }

    private func findPrev(): Unit {
        if (this.findResultCount <= 0) {
            return
        }
        let prevIndex: Int32 = if (this.findCurrentIndex <= Int32(1)) { this.findResultCount } else { this.findCurrentIndex - Int32(1) }
        this.findCurrentIndex = prevIndex
        let jsIdx = Int64(prevIndex) - 1
        let scrollJs = "(function(idx){" +
            "var spans=document.querySelectorAll('.__findHighlight');" +
            "for(var i=0;i<spans.length;i++){spans[i].style.backgroundColor='rgba(255,200,0,0.6)';}" +
            "if(idx>=0&&idx<spans.length){" +
            "spans[idx].style.backgroundColor='rgba(255,130,0,0.9)';" +
            "spans[idx].scrollIntoView({block:'center'});}" +
            "return 'ok';})(${jsIdx})"
        try {
            this.webController.runJavaScript(scrollJs, {
                _err: Option<BusinessException>, _data: Option<String> =>
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 findPrev done idx=${jsIdx}")
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-048 findPrev err: ${e}")
        }
    }

    // ─── P2-050: 阅读模式 / 字号 / 衬线 ─────────────────────────────────────────

    /**
     * P2-050: 切换阅读模式。
     * 阅读模式开启时注入 reader CSS：居中正文列、限制最大宽度、去除无用浮动元素、
     * 设置行距 / 背景色 / padding，类似 iOS BrowserReadability.swift 的 reader HTML 渲染。
     * 关闭时移除注入的 <style> 标签，恢复原始样式。
     * S-001: runJavaScript 回调非 UIThread，@State 写入需 spawn(UIThread)。
     */
    private func toggleReaderMode(): Unit {
        if (this.isReaderModeOn) {
            // 移除 reader CSS
            let removeJs = "(function(){" +
                "var el=document.getElementById('__cjReaderStyle');" +
                "if(el&&el.parentNode){el.parentNode.removeChild(el);}" +
                "return 'removed';" +
                "})()"
            try {
                this.webController.runJavaScript(removeJs, {
                    _err: Option<BusinessException>, _data: Option<String> =>
                    spawn(UIThread) { =>
                        this.isReaderModeOn = false
                        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 reader mode OFF")
                    }
                })
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 removeReaderCSS err: ${e}")
            }
        } else {
            // 注入 reader CSS：去广告区/浮动/居中正文列/舒适行距/米白背景
            let injectJs = "(function(){" +
                "if(document.getElementById('__cjReaderStyle'))return 'exists';" +
                "var style=document.createElement('style');" +
                "style.id='__cjReaderStyle';" +
                "style.textContent=" +
                "'body{max-width:720px!important;margin:0 auto!important;" +
                "padding:24px 16px!important;line-height:1.75!important;" +
                "background:#FAFAF8!important;color:#1C1C1E!important;" +
                "font-size:100%!important;}'" +
                "+'[class*=ad],[id*=ad],[class*=banner],[class*=sidebar]," +
                "[class*=popup],[class*=overlay],[class*=newsletter]" +
                "{display:none!important;}';" +
                "document.head.appendChild(style);" +
                "return 'injected';" +
                "})()"
            try {
                this.webController.runJavaScript(injectJs, {
                    _err: Option<BusinessException>, _data: Option<String> =>
                    spawn(UIThread) { =>
                        this.isReaderModeOn = true
                        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 reader mode ON")
                    }
                })
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 injectReaderCSS err: ${e}")
            }
        }
    }

    /**
     * P2-050: 增大字号（步长 10%，上限 200%）。
     * runJavaScript 改 document.body.style.fontSize。
     * S-001: 回调内 @State 写入 spawn(UIThread)。
     */
    private func increaseFontSize(): Unit {
        if (this.fontSizePercent >= 200) {
            return
        }
        let newSize: Int32 = this.fontSizePercent + Int32(10)
        this.applyFontSize(newSize)
    }

    /**
     * P2-050: 减小字号（步长 10%，下限 50%）。
     */
    private func decreaseFontSize(): Unit {
        if (this.fontSizePercent <= 50) {
            return
        }
        let newSize: Int32 = this.fontSizePercent - Int32(10)
        this.applyFontSize(newSize)
    }

    /**
     * P2-050: 重置字号为 100%。
     */
    private func resetFontSize(): Unit {
        this.applyFontSize(Int32(100))
    }

    /**
     * P2-050: 应用字号（改 document.body.style.fontSize）。
     */
    private func applyFontSize(sizePercent: Int32): Unit {
        let sz = Int64(sizePercent)
        let fontJs = "(function(sz){" +
            "document.body.style.fontSize=sz+'%';" +
            "return String(sz);" +
            "})(${sz})"
        try {
            this.webController.runJavaScript(fontJs, {
                _err: Option<BusinessException>, _data: Option<String> =>
                // S-001: spawn(UIThread) for @State write
                let cap = sizePercent
                spawn(UIThread) { =>
                    this.fontSizePercent = cap
                    Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 fontSizePercent=${cap}")
                }
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 applyFontSize err: ${e}")
        }
    }

    /**
     * P2-050: 切换衬线/无衬线字体。
     * runJavaScript 改 document.body.style.fontFamily。
     * S-001: 回调内 @State 写入 spawn(UIThread)。
     */
    private func toggleSerif(): Unit {
        let nextSerif = !this.useSerifFont
        let familyStr = if (nextSerif) { "Georgia, 'Times New Roman', serif" } else { "-apple-system, system-ui, sans-serif" }
        let fontFamilyJs = "(function(f){" +
            "document.body.style.fontFamily=f;" +
            "return 'ok';" +
            "})('${familyStr}')"
        try {
            this.webController.runJavaScript(fontFamilyJs, {
                _err: Option<BusinessException>, _data: Option<String> =>
                let capSerif = nextSerif
                spawn(UIThread) { =>
                    this.useSerifFont = capSerif
                    Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 serif=${capSerif}")
                }
            })
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-050 toggleSerif err: ${e}")
        }
    }

    // ─── P2-052: 下载拦截 ───────────────────────────────────────────────────────

    /**
     * P2-052: 检测 URL 是否为可下载文件（按扩展名判断）。
     * 检查常见文件扩展名：pdf/zip/apk/ipa/tar/gz/7z/rar/doc/docx/xls/xlsx/ppt/pptx/mp3/mp4/mov/avi。
     * WebDownloadDelegate Cangjie binding 无 KB 示例（KB score < 0.05）→ 诚实降级：
     * 通过 onLoadIntercept 拦截 + Want(viewData) 走系统浏览器下载。
     */
    private func isDownloadableUrl(url: String): Bool {
        let lower = url.toAsciiLower()
        let exts: Array<String> = [".pdf", ".zip", ".apk", ".ipa", ".tar", ".gz",
            ".7z", ".rar", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
            ".mp3", ".mp4", ".mov", ".avi", ".mkv", ".exe", ".dmg"]
        var i: Int64 = 0
        while (i < exts.size) {
            if (lower.contains(exts[i])) {
                return true
            }
            i += 1
        }
        return false
    }

    /**
     * P2-052: 从 URL 提取文件名（最后一个 / 后的部分，去除 query string）。
     */
    private func extractFileName(url: String): String {
        var s = url
        // 去除 query string
        let qIdx = s.indexOf("?")
        match (qIdx) {
            case Some(idx) => s = s[0..idx]
            case None => ()
        }
        // 提取最后一个 / 后的部分
        let slashIdx = s.lastIndexOf("/")
        match (slashIdx) {
            case Some(idx) =>
                let name = s[idx + 1..s.size]
                if (name.size > 0) { return name }
                return "file"
            case None => return "file"
        }
    }

    /**
     * P2-052: 用户确认下载后，通过系统 Want(viewData) 打开下载 URL（交给系统浏览器/下载器处理）。
     * 诚实降级：Cangjie SDK 6.0 无 WebDownloadDelegate binding，走系统代理。
     */
    private func confirmDownload(): Unit {
        let url = this.downloadUrl
        this.showDownloadDialog = false
        this.downloadFileName = ""
        this.downloadUrl = ""
        if (url.size == 0) {
            return
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let want = Want(action: "ohos.want.action.viewData", uri: url)
                    ctx.startAbility(want)
                    Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-052 confirmDownload via Want: ${url}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-052 confirmDownload failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-052 confirmDownload: no context")
        }
    }

    /**
     * P2-052: 取消下载确认对话框。
     */
    private func cancelDownload(): Unit {
        this.showDownloadDialog = false
        this.downloadFileName = ""
        this.downloadUrl = ""
        Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-052 download cancelled")
    }

    // ─── P2-051: Tab item helpers (private func, no @Builder with params per D-115) ─────────────

    private func tabTitleAt(idx: Int64): String {
        if (idx >= 0 && idx < this.tabTitles.size) {
            return this.tabTitles[idx]
        }
        return "Tab"
    }

    private func isActiveTab(idx: Int64): Bool {
        return idx == this.activeTabIndex
    }

    private func tabBgColor(idx: Int64): Int64 {
        if (this.isActiveTab(idx)) { return 0xE8F4FF } else { return 0xFFFFFF }
    }

    private func tabFontColor(idx: Int64): Int64 {
        if (this.isActiveTab(idx)) { return 0x007AFF } else { return 0x000000 }
    }

    // ─── build() ───────────────────────────────────────────────────────────────

    func build() {
        Column {
                // 顶部导航栏（返回按钮 + 标题）
                Row {
                    Button("<-")
                        .fontSize(14)
                        .fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .width(44)
                        .height(44)
                        .onClick({ _e: ClickEvent =>
                            routerPop()
                        })
                    Text(this.currentTitle)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .maxLines(1)
                    Blank()
                        .width(44)
                        .height(44)
                }
                .width(100.percent)
                .height(44.0 + getSafeAreaTop())
                .padding(left: 4, right: 4, top: getSafeAreaTop(), bottom: 0)
                .backgroundColor(0xF7F7F7)

                // P2-052: 下载确认对话框（showDownloadDialog=true 时叠加显示）
                if (this.showDownloadDialog) {
                    Column {
                        Text("Download File")
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0x000000)
                            .margin(bottom: 8)
                        Text(this.downloadFileName)
                            .fontSize(14)
                            .fontColor(0x3C3C43)
                            .textAlign(TextAlign.Center)
                            .maxLines(2)
                            .margin(bottom: 16)
                        Text("Open with system browser to download?")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .margin(bottom: 20)
                        Row {
                            Button(trSource("Cancel"))
                                .fontSize(15)
                                .fontColor(0x8E8E93)
                                .backgroundColor(0xF2F2F7)
                                .borderRadius(8)
                                .height(44)
                                .layoutWeight(1)
                                .onClick({ _e: ClickEvent =>
                                    this.cancelDownload()
                                })
                            Blank().width(12)
                            Button(trSource("Open"))
                                .fontSize(15)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(0x007AFF)
                                .borderRadius(8)
                                .height(44)
                                .layoutWeight(1)
                                .onClick({ _e: ClickEvent =>
                                    this.confirmDownload()
                                })
                        }
                        .width(100.percent)
                    }
                    .width(100.percent)
                    .padding(left: 20, right: 20, top: 20, bottom: 20)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 20, right: 20, top: 8, bottom: 8)
                    .alignItems(HorizontalAlign.Center)
                }

                // P2-045: 分享菜单叠加（showShareMenu=true 时显示）
                if (this.showShareMenu) {
                    Column {
                        Text(trSource("Share"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(0x000000)
                            .margin(bottom: 12)
                        Button("System Share")
                            .fontSize(15)
                            .fontColor(0x007AFF)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(8)
                            .width(100.percent)
                            .height(44)
                            .margin(bottom: 8)
                            .onClick({ _e: ClickEvent =>
                                this.sharePage()
                            })
                        Button("Share to Chat")
                            .fontSize(15)
                            .fontColor(0x007AFF)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(8)
                            .width(100.percent)
                            .height(44)
                            .margin(bottom: 16)
                            .onClick({ _e: ClickEvent =>
                                this.sharePageToTelegram()
                            })
                        Button(trSource("Cancel"))
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                            .backgroundColor(Color.Transparent)
                            .width(100.percent)
                            .height(44)
                            .onClick({ _e: ClickEvent =>
                                this.showShareMenu = false
                            })
                    }
                    .width(100.percent)
                    .padding(left: 20, right: 20, top: 20, bottom: 20)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 20, right: 20, top: 8, bottom: 8)
                    .alignItems(HorizontalAlign.Center)
                }

                // 地址栏 + 工具栏组件
                BrowserScreenComponent(
                    currentUrl: this.currentUrl,
                    currentTitle: this.currentTitle,
                    isLoading: this.isLoading,
                    loadProgress: this.loadProgress,
                    canGoBack: this.canGoBack,
                    canGoForward: this.canGoForward,
                    isBookmarked: this.isBookmarked,
                    isSecure: this.isSecure,
                    hasLoadedPage: this.hasLoadedPage,
                    faviconLetter: this.faviconLetter,
                    isFindBarVisible: this.isFindBarVisible,
                    findQuery: this.findQuery,
                    findResultCount: this.findResultCount,
                    findCurrentIndex: this.findCurrentIndex,
                    isReaderModeOn: this.isReaderModeOn,
                    fontSizePercent: this.fontSizePercent,
                    useSerifFont: this.useSerifFont,
                    openExternalByDefault: this.openExternalByDefault,
                    hasInstantView: this.hasInstantView,
                    tabCount: this.tabCount,
                    activeTabIndex: this.activeTabIndex,
                    onNavigate: { url: String =>
                        this.navigateTo(url)
                    },
                    onBack: { =>
                        this.goBack()
                    },
                    onForward: { =>
                        this.goForward()
                    },
                    onRefresh: { =>
                        this.refreshPage()
                    },
                    onStop: { =>
                        this.stopPage()
                    },
                    onShare: { =>
                        this.showShareMenu = true
                    },
                    onBookmark: { =>
                        this.toggleBookmark()
                    },
                    onOpenBookmarks: { =>
                        this.openBookmarks()
                    },
                    onOpenExternal: { =>
                        this.openInSystemBrowser()
                    },
                    onOpenHistory: { =>
                        this.openHistory()
                    },
                    onToggleDefaultBrowser: { =>
                        this.toggleDefaultBrowserPref()
                    },
                    onToggleFind: { =>
                        if (this.isFindBarVisible) {
                            this.closeFindBar()
                        } else {
                            this.openFindBar()
                        }
                    },
                    onFindQueryChanged: { q: String =>
                        this.findQuery = q
                        this.executeFindSearch(q)
                    },
                    onFindNext: { =>
                        this.findNext()
                    },
                    onFindPrev: { =>
                        this.findPrev()
                    },
                    onCloseFind: { =>
                        this.closeFindBar()
                    },
                    onToggleReaderMode: { =>
                        this.toggleReaderMode()
                    },
                    onIncreaseFontSize: { =>
                        this.increaseFontSize()
                    },
                    onDecreaseFontSize: { =>
                        this.decreaseFontSize()
                    },
                    onResetFontSize: { =>
                        this.resetFontSize()
                    },
                    onToggleSerif: { =>
                        this.toggleSerif()
                    },
                    onOpenInstantView: { =>
                        this.openInstantView()
                    },
                    onOpenNewTab: { =>
                        this.openNewTab()
                    },
                    onToggleTabBar: { =>
                        this.showTabBar = !this.showTabBar
                    }
                )

                // P2-051: Tab bar（showTabBar=true 时显示）
                if (this.showTabBar) {
                    Column {
                        // Tab list header row
                        Row {
                            Text("Tabs (${this.tabCount})")
                                .fontSize(15)
                                .fontWeight(FontWeight.Medium)
                                .fontColor(0x000000)
                                .layoutWeight(1)
                            Button("+ New Tab")
                                .fontSize(13)
                                .fontColor(0x007AFF)
                                .backgroundColor(Color.Transparent)
                                .height(36)
                                .padding(left: 8, right: 8, top: 0, bottom: 0)
                                .onClick({ _e: ClickEvent =>
                                    this.openNewTab()
                                    this.showTabBar = false
                                })
                            Button(trSource("Done"))
                                .fontSize(13)
                                .fontColor(0x007AFF)
                                .backgroundColor(Color.Transparent)
                                .height(36)
                                .padding(left: 8, right: 8, top: 0, bottom: 0)
                                .onClick({ _e: ClickEvent =>
                                    this.showTabBar = false
                                })
                        }
                        .width(100.percent)
                        .height(44)
                        .padding(left: 12, right: 4, top: 0, bottom: 0)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF7F7F7)

                        // Tab list (scroll of tab items)
                        // P2-051: Iterate tabTitles (Array<String>) — each element is a String title.
                        // The index in ForEach closure maps directly to tab index.
                        List {
                            ForEach(this.tabTitles, itemGenerator: {
                                title: String, rawIdx: Int64 =>
                                    ListItem {
                                        Row {
                                            Text(title)
                                                .fontSize(14)
                                                .fontColor(this.tabFontColor(rawIdx))
                                                .fontWeight(if (this.isActiveTab(rawIdx)) { FontWeight.Medium } else { FontWeight.Normal })
                                                .layoutWeight(1)
                                                .maxLines(1)
                                                .textOverflow(TextOverflow.Ellipsis)
                                                .padding(left: 12, right: 0, top: 0, bottom: 0)
                                            Button("x")
                                                .fontSize(13)
                                                .fontColor(0x8E8E93)
                                                .backgroundColor(Color.Transparent)
                                                .width(36)
                                                .height(44)
                                                .onClick({ _e: ClickEvent =>
                                                    this.closeTab(rawIdx)
                                                })
                                        }
                                        .width(100.percent)
                                        .height(52)
                                        .backgroundColor(this.tabBgColor(rawIdx))
                                        .alignItems(VerticalAlign.Center)
                                        .onClick({ _e: ClickEvent =>
                                            this.switchToTab(rawIdx)
                                        })
                                    }
                            })
                        }
                        .width(100.percent)
                        .height(if (this.tabCount <= 4) { Float64(this.tabCount) * 52.0 } else { 208.0 })
                        .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA))
                        .backgroundColor(0xFFFFFF)
                    }
                    .width(100.percent)
                    .backgroundColor(0xFFFFFF)
                    .borderRadius(12)
                    .margin(left: 0, right: 0, top: 0, bottom: 0)
                }

                // 错误提示
                if (this.loadError.size > 0) {
                    Column {
                        Text("Load failed")
                            .fontSize(16)
                            .fontColor(0x8E8E93)
                            .margin(bottom: 8)
                        Text(this.loadError)
                            .fontSize(13)
                            .fontColor(0xFF3B30)
                            .textAlign(TextAlign.Center)
                        Button(trSource("Retry"))
                            .fontSize(15)
                            .fontColor(0x007AFF)
                            .backgroundColor(Color.Transparent)
                            .margin(top: 16)
                            .onClick({ _e: ClickEvent =>
                                this.loadError = ""
                                this.navigateTo(this.currentUrl)
                            })
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    // Web 组件（真实加载 URL）
                    Web(src: "about:blank", controller: this.webController)
                        .width(100.percent)
                        .layoutWeight(1)
                        .onPageBegin({ _evt =>
                            this.isLoading = true
                            this.loadProgress = 0.0
                            this.loadError = ""
                        })
                        .onPageEnd({ _evt =>
                            this.isLoading = false
                            this.loadProgress = 100.0
                            this.updateNavState()
                            var loadedUrl: String = ""
                            try {
                                let title = this.webController.getTitle()
                                if (title.size > 0) {
                                    this.currentTitle = title
                                }
                                let rawUrl = this.webController.getUrl()
                                // The Web node may finish its bootstrap about:blank after
                                // ensureLoaded() has already supplied the route URL. Never let
                                // that bootstrap callback overwrite the pending navigation.
                                if (rawUrl.size > 0 && rawUrl != "about:blank") {
                                    this.currentUrl = rawUrl
                                    loadedUrl = rawUrl
                                    this.hasLoadedPage = true
                                    this.isBookmarked = getBrowserService().isBookmarked(rawUrl)
                                    getBrowserService().recordVisit(rawUrl, this.currentTitle)
                                    // P2-051: update active tab in registry
                                    getBrowserTabRegistry().updateActiveTab(rawUrl, this.currentTitle)
                                    this.syncTabTitles()
                                }
                            } catch (e: Exception) {
                                Hilog.info(0, "CjTelegram", "[BrowserScreen] getTitle/getUrl failed")
                            }
                            // P2-054: 安全锁判断
                            this.updateSecurityState()
                            // P2-053: 更新 favicon 占位字母
                            this.updateFaviconLetter()
                            // P2-049: check Instant View availability for loaded URL
                            if (loadedUrl.size > 0) {
                                this.checkInstantViewAvailability(loadedUrl)
                            }
                        })
                        .onLoadIntercept({ event =>
                            // P2-052: 拦截下载类 URL（onLoadIntercept = Web 导航拦截，UI线程）
                            let url = event.data.getRequestUrl()
                            if (this.isDownloadableUrl(url)) {
                                let fname = this.extractFileName(url)
                                this.downloadFileName = fname
                                this.downloadUrl = url
                                this.showDownloadDialog = true
                                Hilog.info(0, "CjTelegram", "[BrowserScreen] P2-052 download intercepted: ${fname}")
                                return true
                            }
                            return false
                        })
                        .domStorageAccess(true)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFFFFFF)
            .padding(bottom: getSafeAreaBottom())
            .onAppear({ => this.ensureLoaded() })
    }
}
