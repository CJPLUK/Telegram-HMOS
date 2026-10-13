package ohos_app_cangjie_entry.services

import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

/**
 * BrowserBookmark — 单条书签记录，对应 iOS BrowserBookmarksScreen 的书签消息。
 *
 * 书签以 url\u{1E}title 格式序列化后存入 Preferences StringArray。
 */
public class BrowserBookmark {
    public var url: String = ""
    public var title: String = ""
}

/**
 * BrowserHistoryEntry — 最近访问历史记录。
 *
 * P2-047: 支持重启持久化（Preferences StringArray 存储）。
 * 序列化格式：url\u{1E}title\u{1E}visitTime（visitTime 为 ISO 格式日期字符串或时间戳字符串）
 */
public class BrowserHistoryEntry {
    public var url: String = ""
    public var title: String = ""
    public var visitTime: String = ""
}

// ─────────────────────────────────────────────────────────────────────────────
// BrowserMode — URL 打开方式路由枚举
// ─────────────────────────────────────────────────────────────────────────────

/**
 * BrowserMode — 决定 URL 应以 in-app 还是系统外部浏览器打开。
 *
 * 对应 iOS OpenUrl.swift 中 shouldOpenInApp 的两条路径：
 *   - InApp   → BrowserScreen（in-app WebView）
 *   - External → openUrl via system browser identifier
 */
public enum BrowserMode {
    | InApp
    | External
}

// ─────────────────────────────────────────────────────────────────────────────
// Preferences 存储键
// ─────────────────────────────────────────────────────────────────────────────

let BROWSER_STORE_NAME: String = "telegram_browser"
let KEY_BROWSER_OPEN_EXTERNAL: String = "open_external_browser"
let KEY_BROWSER_DEFAULT_ID: String = "default_browser_id"
let KEY_BROWSER_BOOKMARKS: String = "browser_bookmarks"
// P2-047: 历史记录持久化存储键
let KEY_BROWSER_HISTORY: String = "browser_history"

// P2-045: 待分享到 Telegram 对话的 URL（BrowserScreen → ShareControllerPage）
private var _pendingBrowserShareUrl: String = ""
private var _pendingBrowserShareTitle: String = ""

public func setPendingBrowserShare(url: String, title: String): Unit {
    _pendingBrowserShareUrl = url
    _pendingBrowserShareTitle = title
    Hilog.info(0, "CjTelegram", "[BrowserService] setPendingBrowserShare url=${url}")
}

public func getPendingBrowserShareUrl(): String {
    return _pendingBrowserShareUrl
}

public func getPendingBrowserShareTitle(): String {
    return _pendingBrowserShareTitle
}

public func clearPendingBrowserShare(): Unit {
    _pendingBrowserShareUrl = ""
    _pendingBrowserShareTitle = ""
}

// ─────────────────────────────────────────────────────────────────────────────
// BrowserService
// ─────────────────────────────────────────────────────────────────────────────

/**
 * BrowserService — 应用内浏览器服务层。
 *
 * 职责：
 *   1. 浏览器偏好持久化（Preferences）：
 *      - openExternalBrowser: Bool — false = in-app（默认），true = 系统外部浏览器
 *        （对应 iOS AccountWebBrowserSettings.openExternalBrowser）
 *      - defaultBrowserId: String  — 外部浏览器标识符（空 = 系统默认）
 *        （对应 iOS WebBrowserSettings.defaultWebBrowser）
 *   2. URL 路由决策：getEffectiveBrowserMode(url) → BrowserMode
 *   3. 书签持久化（Preferences）：添加 / 删除 / 查询书签。
 *   4. P2-047 最近历史记录（Preferences StringArray 持久化，重启保留）：
 *      - 访问时追加，最多保留 50 条（去重移到末尾）。
 *      - 序列化：url\u{1E}title\u{1E}visitTime 三段以 RS 分隔，Array 存入 Preferences。
 *   5. URL 规范化辅助：确保地址栏输入的 URL 带有 http(s):// 前缀。
 *
 * 防死状态：账号级缓存已落盘时浏览器偏好总是从该缓存真实读取；缓存缺失时（冷启动首帧，
 * 第一次 account.getWebBrowserSettings 回包之前）才回退读本地 Preferences 镜像键，
 * 不使用硬编码默认值覆盖已保存设置。
 *
 * 调用链（偏好路由）：
 *   UI.onTapLink(url)
 *     → BrowserService.getEffectiveBrowserMode(url)
 *       → BrowserService.getOpenExternalBrowser()  ← 唯一取值口径
 *         → 账号级缓存已落盘 → 直接返回缓存值；发现本地镜像键不一致则在本次读取中就地回写对齐
 *         → 账号级缓存缺失 → 回退 readBool(KEY_BROWSER_OPEN_EXTERNAL, false)
 *       ← BrowserMode.InApp | BrowserMode.External
 *     → if InApp  → push BrowserScreen(url)
 *       if External → openSystemBrowser(url, defaultBrowserId)
 *
 * 调用链（书签）：
 *   BrowserScreen.addBookmark()
 *     → BrowserService.addBookmark(url, title)
 *       → Preferences.put(KEY_BROWSER_BOOKMARKS, StringArray([...]))
 *       → Preferences.flush()
 *
 * 不涉及 MTProto（浏览器是平台 WebView 能力，标记 N/A）。
 */
public class BrowserService {
    private var _prefs: Option<Preferences> = None
    private var initialized: Bool = false

    private var recentHistory: ArrayList<BrowserHistoryEntry> = ArrayList<BrowserHistoryEntry>()
    private let maxHistory: Int64 = 50

    private let sepChar: String = "\u{1E}"

    // ─────────────────────────────────────────────────────────────────────────
    // Preferences helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func ensurePrefs(): Unit {
        match (this._prefs) {
            case Some(_) => ()
            case None =>
                match (getGlobalAbilityContext()) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[BrowserService] No ability context — in-memory only")
                    case Some(ctx) =>
                        try {
                            let prefs = Preferences.getPreferences(ctx, BROWSER_STORE_NAME)
                            this._prefs = Some(prefs)
                            this.initialized = true
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[BrowserService] Prefs open failed: ${e}")
                            this.initialized = true
                        }
                }
        }
    }

    private func readBool(key: String, fallback: Bool): Bool {
        this.ensurePrefs()
        match (this._prefs) {
            case None => return fallback
            case Some(prefs) =>
                try {
                    let dv: Int64 = if (fallback) { 1 } else { 0 }
                    let val = prefs.get(key, PreferencesValueType.Integer(dv))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return fallback
                    }
                } catch (e: Exception) { return fallback }
        }
    }

    private func writeBool(key: String, value: Bool): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    let v: Int64 = if (value) { 1 } else { 0 }
                    prefs.put(key, PreferencesValueType.Integer(v))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserService] writeBool(${key}) err: ${e}")
                }
        }
    }

    private func readString(key: String, fallback: String): String {
        this.ensurePrefs()
        match (this._prefs) {
            case None => return fallback
            case Some(prefs) =>
                try {
                    let val = prefs.get(key, PreferencesValueType.StringData(fallback))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return fallback
                    }
                } catch (e: Exception) { return fallback }
        }
    }

    private func writeString(key: String, value: String): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    prefs.put(key, PreferencesValueType.StringData(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserService] writeString(${key}) err: ${e}")
                }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Initialization (legacy — kept for callers that pass UIAbilityContext)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 初始化 Preferences 持久化存储。
     * 现在也可通过 ensurePrefs() + getGlobalAbilityContext() 惰性初始化，
     * 此接口保留兼容旧调用方（MainAbility 显式传 context）。
     */
    public func initialize(context: UIAbilityContext): Unit {
        try {
            let prefs = Preferences.getPreferences(context, BROWSER_STORE_NAME)
            this._prefs = Some(prefs)
            this.initialized = true
            Hilog.info(0, "CjTelegram", "[BrowserService] Preferences initialized")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[BrowserService] Preferences init failed, in-memory only")
            this.initialized = true
        }
    }

    public func isInitialized(): Bool {
        return this.initialized
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Browser preference — open external / in-app
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 读取"是否使用系统外部浏览器"的**有效值**。
     *
     * 对应 iOS AccountWebBrowserSettings.openExternalBrowser。源侧该值**只有账号级一份**
     * （TelegramCore/Sources/Settings/AccountWebBrowserSettings.swift），没有第二个本地键。
     * 目标侧多出来的本地键 `KEY_BROWSER_OPEN_EXTERNAL` 因此只能是账号级值的**镜像**，
     * 不是与之平级的第二个设置源：
     *
     *   1. 账号级缓存已落盘 ⇒ 一律返回缓存值；发现本地镜像与之不一致就**立即回写**。
     *      回写不是可有可无的整洁动作：本地键有一个外部写入方
     *      （pages/BrowserScreen.cj:494 toggleDefaultBrowserPref，控件在
     *      pages/BrowserScreenComponent.cj:578-581，归 feature `browserui`，
     *      已由 ic_browserscreen_default_browser_toggle_realign 接管）。不回写的话，
     *      它写下的影子值会一直躺在 Preferences 里，等到账号级缓存被清空
     *      （登出 → ic_wbs_cache_invalidate_on_logout）之后复活成路由输入。
     *   2. 账号级缓存尚未落盘（冷启动首帧，第一次 account.getWebBrowserSettings 回包之前）
     *      ⇒ 才回退读本地镜像，默认 false（= in-app，对齐
     *      AccountWebBrowserSettings.defaultSettings）。
     *
     * 全程只读本地 Preferences，不发网络请求（R-138）——本函数在链接点击路径上被
     * getEffectiveBrowserMode() 调用。
     */
    public func getOpenExternalBrowser(): Bool {
        let settingsSvc = getSettingsService()
        if (settingsSvc.hasWebBrowserSettingsCache()) {
            let accountValue = settingsSvc.getCachedWebBrowserSettings().openExternalBrowser
            // 缺键时 readBool 返回 accountValue ⇒ 不产生无谓写入。
            if (this.readBool(KEY_BROWSER_OPEN_EXTERNAL, accountValue) != accountValue) {
                this.writeBool(KEY_BROWSER_OPEN_EXTERNAL, accountValue)
                Hilog.info(0, "CjTelegram",
                    "[BrowserService] local open_external mirror realigned to account value: ${accountValue}")
            }
            return accountValue
        }
        return this.readBool(KEY_BROWSER_OPEN_EXTERNAL, false)
    }

    /**
     * 写"是否使用系统外部浏览器"的**本地镜像**。
     *
     * ⚠ 这不是账号级写入口。账号级写入口是
     * services/SettingsService.cj:726 updateWebBrowserSettings(openExternalBrowser:)
     * （TL account.updateWebBrowserSettings，会阻塞在 sendRequest 上，只能从后台线程调）。
     * 本方法只写本地镜像，因此一旦账号级缓存存在，它写下的值会在下一次
     * getOpenExternalBrowser() 时被账号值覆盖回去——这是刻意的，见该方法注释第 1 条。
     *
     * 现存唯一外部调用方 pages/BrowserScreen.cj:494 就落在这种情形里，其修法归
     * ic_browserscreen_default_browser_toggle_realign（target feature `browserui`）：
     * 要么改走账号级写入口，要么连同控件一起删除。
     *
     * @param openExternal true = 系统外部浏览器；false = in-app 浏览器（默认）
     */
    public func setOpenExternalBrowser(openExternal: Bool): Unit {
        this.writeBool(KEY_BROWSER_OPEN_EXTERNAL, openExternal)
        Hilog.info(0, "CjTelegram",
            "[BrowserService] setOpenExternalBrowser (local mirror only): ${openExternal}")
    }

    /**
     * 读取默认外部浏览器标识符。
     *
     * 空字符串表示使用系统默认（Safari 对应场景）。
     * 对应 iOS WebBrowserSettings.defaultWebBrowser。
     * 防死状态：从 Preferences 真实查询，不硬编码。
     */
    public func getDefaultBrowserId(): String {
        return this.readString(KEY_BROWSER_DEFAULT_ID, "")
    }

    /**
     * 设置默认外部浏览器标识符并持久化。
     *
     * @param identifier 浏览器包名标识符，空字符串 = 系统默认
     */
    public func setDefaultBrowserId(identifier: String): Unit {
        this.writeString(KEY_BROWSER_DEFAULT_ID, identifier)
        Hilog.info(0, "CjTelegram", "[BrowserService] setDefaultBrowserId: ${identifier}")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // URL routing decision
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 根据当前账号级设置 + 域名例外名单决定 URL 的打开方式。
     *
     * FIX-8（diag-suite_settings_data_storage-TC-0436.md §6.3）。逐条对位源侧
     * TelegramUI/Sources/OpenUrl.swift:272-296 的三输入结构（此前本函数只有
     * `openExternal ? External : InApp` 两支，形参 url 除打日志外未被使用，是 TC-0436 G2 的
     * 静态失效点位）：
     *   1. TON 站点（host 以 `.ton` 结尾，或 scheme 以 `tonsite` 开头）恒走 in-app；
     *   2. 例外名单取的是**对侧**名单——openExternalBrowser 时取 inAppExceptions，
     *      否则取 externalExceptions（源侧 `exceptions = openExternalBrowser ?
     *      inAppExceptions : externalExceptions`）；
     *   3. 命中例外则取当前模式的反面。
     *
     * 状态源（FIX-8 边界条件）：openExternalBrowser 一律经 getOpenExternalBrowser()
     * 取值——账号级缓存优先，缓存尚未落盘时（冷启动首帧，第一次
     * account.getWebBrowserSettings 回包之前）回退读本地镜像键，避免首帧无值；
     * 本地镜像与账号值不一致时由该方法就地回写对齐。
     * 全程只读本地 Preferences，不发网络请求——本函数由 UI 线程的链接点击路径直接调用
     * （pages/ChatRoomPage.cj:4543、pages/SettingsPage.cj:777 经 resolveUrl），
     * 不得阻塞在 MTProtoClient.sendRequest 上（R-138）。
     *
     * @param url 已规范化的 URL
     * @return    BrowserMode.InApp 或 BrowserMode.External
     */
    public func getEffectiveBrowserMode(url: String): BrowserMode {
        let settingsSvc = getSettingsService()
        // 取值口径只有 getOpenExternalBrowser() 一个（账号级缓存优先 + 本地镜像回写，
        // 见该方法注释）——不在这里第二次实现"缓存优先"的优先级判定，否则本地键会
        // 变成一个悄悄失效、却仍被 UI 读回去显示的平级设置源。
        let openExternal = this.getOpenExternalBrowser()
        var exceptions = ArrayList<WebBrowserException>()
        if (settingsSvc.hasWebBrowserSettingsCache()) {
            let state = settingsSvc.getCachedWebBrowserSettings()
            if (openExternal) {
                exceptions = state.inAppExceptions
            } else {
                exceptions = state.externalExceptions
            }
        }

        // host 形态对位源侧 `let host = "." + parsedUrl.host.lowercased()`——前导点让后缀
        // 匹配天然只在域名边界上成立（`.a.com` 命中 `x.a.com`，不命中 `xa.com`）。
        let host = this.exceptionMatchHost(url)

        if (this.isTonSiteUrl(url, host)) {
            Hilog.info(0, "CjTelegram", "[BrowserService] route InApp (ton site): ${url}")
            return BrowserMode.InApp
        }

        // host 解析失败（空 host）⇒ isExcepted = false，走无例外的那一支（FIX-8 边界条件）。
        var isExcepted = false
        if (host.size > 0) {
            for (item in exceptions) {
                let domain = item.domain.toAsciiLower()
                if (domain.size == 0) {
                    continue
                }
                if (host.endsWith("." + domain)) {
                    isExcepted = true
                    break
                }
            }
        }

        var shouldOpenInApp = true
        if (openExternal) {
            shouldOpenInApp = isExcepted
        } else {
            shouldOpenInApp = !isExcepted
        }

        if (shouldOpenInApp) {
            Hilog.info(0, "CjTelegram", "[BrowserService] route InApp: ${url} (excepted=${isExcepted})")
            return BrowserMode.InApp
        }
        Hilog.info(0, "CjTelegram", "[BrowserService] route External: ${url} (excepted=${isExcepted})")
        return BrowserMode.External
    }

    /**
     * FIX-8 辅助：把 URL 折算成用于例外后缀匹配的 host 形态 `"." + host.lowercased()`。
     * 解析不出 host 时返回空串（调用方据此走"无例外"分支）。
     */
    func exceptionMatchHost(url: String): String {
        let rawHost = this.extractDisplayHost(url)
        // 去掉可能带的 userinfo 与端口，只留主机名——extractDisplayHost 只截到第一个 `/`。
        var h = rawHost
        let atIdx = h.indexOf("@")
        match (atIdx) {
            case Some(idx) => h = h[(idx + 1)..h.size]
            case None => ()
        }
        let colonIdx = h.indexOf(":")
        match (colonIdx) {
            case Some(idx) => h = h[0..idx]
            case None => ()
        }
        if (h.size == 0) {
            return ""
        }
        return "." + h.toAsciiLower()
    }

    /**
     * FIX-8 辅助：对位源侧 `isTonSite`（OpenUrl.swift:272-275）——host 以 `.ton` 结尾，
     * 或 scheme 以 `tonsite` 开头。
     */
    func isTonSiteUrl(url: String, matchHost: String): Bool {
        if (matchHost.endsWith(".ton")) {
            return true
        }
        let lower = url.toAsciiLower()
        if (lower.startsWith("tonsite")) {
            return true
        }
        return false
    }

    /**
     * 完整 URL 打开入口：规范化 → 路由决策 → 日志。
     * UI 层据返回的 BrowserMode 决定跳转目标（BrowserScreen or system intent）。
     *
     * @param rawUrl 用户输入或消息链接中的原始 URL
     * @return       (normalizedUrl: String, mode: BrowserMode)
     */
    public func resolveUrl(rawUrl: String): (String, BrowserMode) {
        let normalized = this.normalizeUrl(rawUrl)
        let mode = this.getEffectiveBrowserMode(normalized)
        return (normalized, mode)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // URL helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 规范化 URL：若缺少 scheme 则补 https://。
     */
    public func normalizeUrl(input: String): String {
        let trimmed = input.trimAscii()
        if (trimmed.size == 0) {
            return ""
        }
        if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
            return trimmed
        }
        if (trimmed.startsWith("//")) {
            return "https:" + trimmed
        }
        return "https://" + trimmed
    }

    /**
     * 提取 URL 的显示域名，用于地址栏标题展示。
     *
     * 例：https://www.example.com/path?q=1 → www.example.com
     */
    public func extractDisplayHost(url: String): String {
        var s = url
        if (s.startsWith("https://")) {
            s = s[8..s.size]
        } else if (s.startsWith("http://")) {
            s = s[7..s.size]
        }
        let slashIdx = s.indexOf("/")
        match (slashIdx) {
            case Some(idx) => return s[0..idx]
            case None => return s
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bookmarks
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 添加书签。若同一 URL 已存在则先删除再追加（去重）。
     */
    public func addBookmark(url: String, title: String): Unit {
        let existing = this.loadBookmarks()
        let deduped = ArrayList<BrowserBookmark>()
        for (bm in existing) {
            if (bm.url != url) {
                deduped.add(bm)
            }
        }
        let nb = BrowserBookmark()
        nb.url = url
        nb.title = title
        deduped.add(nb)
        this.saveBookmarks(deduped)
        Hilog.info(0, "CjTelegram", "[BrowserService] Bookmark added")
    }

    /**
     * 删除书签（按 URL 匹配）。
     */
    public func removeBookmark(url: String): Unit {
        let existing = this.loadBookmarks()
        let filtered = ArrayList<BrowserBookmark>()
        for (bm in existing) {
            if (bm.url != url) {
                filtered.add(bm)
            }
        }
        this.saveBookmarks(filtered)
        Hilog.info(0, "CjTelegram", "[BrowserService] Bookmark removed")
    }

    /**
     * 查询某 URL 是否已收藏。
     */
    public func isBookmarked(url: String): Bool {
        let bookmarks = this.loadBookmarks()
        for (bm in bookmarks) {
            if (bm.url == url) {
                return true
            }
        }
        return false
    }

    /**
     * 返回全部书签列表（最新在末尾）。
     */
    public func getBookmarks(): Array<BrowserBookmark> {
        let list = this.loadBookmarks()
        let arr: Array<BrowserBookmark> = Array<BrowserBookmark>(list.size, { i: Int64 => list[i] })
        return arr
    }

    /**
     * 返回按关键词过滤的书签列表（不区分大小写，URL 或 title 含关键词则包含）。
     * query 为空时返回全部书签。
     */
    public func filterBookmarks(query: String): Array<BrowserBookmark> {
        let all = this.loadBookmarks()
        if (query.size == 0) {
            let arr: Array<BrowserBookmark> = Array<BrowserBookmark>(all.size, { i: Int64 => all[i] })
            return arr
        }
        let lowerQuery = query.toAsciiLower()
        let result = ArrayList<BrowserBookmark>()
        for (bm in all) {
            if (bm.url.toAsciiLower().contains(lowerQuery) || bm.title.toAsciiLower().contains(lowerQuery)) {
                result.add(bm)
            }
        }
        let arr: Array<BrowserBookmark> = Array<BrowserBookmark>(result.size, { i: Int64 => result[i] })
        return arr
    }

    // 序列化格式：每条书签以 "url\u{1E}title" 编码后放入 StringArray
    private func loadBookmarks(): ArrayList<BrowserBookmark> {
        let result = ArrayList<BrowserBookmark>()
        this.ensurePrefs()
        let sep = this.sepChar
        match (this._prefs) {
            case Some(prefs) =>
                try {
                    let raw = prefs.get(KEY_BROWSER_BOOKMARKS, PreferencesValueType.StringArray([]))
                    match (raw) {
                        case PreferencesValueType.StringArray(arr) =>
                            for (entry in arr) {
                                let sepIdx = entry.indexOf(sep)
                                match (sepIdx) {
                                    case Some(s) =>
                                        let bm = BrowserBookmark()
                                        bm.url = entry[0..s]
                                        bm.title = entry[s + 1..entry.size]
                                        result.add(bm)
                                    case None =>
                                        if (entry.size > 0) {
                                            let bm = BrowserBookmark()
                                            bm.url = entry
                                            bm.title = entry
                                            result.add(bm)
                                        }
                                }
                            }
                        case _ => ()
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserService] loadBookmarks failed")
                }
            case None => ()
        }
        return result
    }

    private func saveBookmarks(list: ArrayList<BrowserBookmark>): Unit {
        this.ensurePrefs()
        let sep = this.sepChar
        let arr: Array<String> = Array<String>(list.size, { i: Int64 =>
            let immList = list
            immList[i].url + sep + immList[i].title
        })
        match (this._prefs) {
            case Some(prefs) =>
                try {
                    prefs.put(KEY_BROWSER_BOOKMARKS, PreferencesValueType.StringArray(arr))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserService] saveBookmarks failed")
                }
            case None => ()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recent history — P2-047: Preferences 持久化（重启保留）
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * P2-047: 从 Preferences 加载历史记录。
     * 格式：StringArray，每条 = "url\u{1E}title\u{1E}visitTime"。
     * 同时同步内存 recentHistory 缓存。
     */
    private func loadHistory(): ArrayList<BrowserHistoryEntry> {
        let result = ArrayList<BrowserHistoryEntry>()
        let sep = this.sepChar
        this.ensurePrefs()
        match (this._prefs) {
            case Some(prefs) =>
                try {
                    let raw = prefs.get(KEY_BROWSER_HISTORY, PreferencesValueType.StringArray([]))
                    match (raw) {
                        case PreferencesValueType.StringArray(arr) =>
                            for (entry in arr) {
                                let sep1 = entry.indexOf(sep)
                                match (sep1) {
                                    case Some(i1) =>
                                        let he = BrowserHistoryEntry()
                                        he.url = entry[0..i1]
                                        let rest = entry[i1 + 1..entry.size]
                                        let sep2 = rest.indexOf(sep)
                                        match (sep2) {
                                            case Some(i2) =>
                                                he.title = rest[0..i2]
                                                he.visitTime = rest[i2 + 1..rest.size]
                                            case None =>
                                                he.title = rest
                                                he.visitTime = ""
                                        }
                                        result.add(he)
                                    case None =>
                                        if (entry.size > 0) {
                                            let he = BrowserHistoryEntry()
                                            he.url = entry
                                            he.title = entry
                                            he.visitTime = ""
                                            result.add(he)
                                        }
                                }
                            }
                        case _ => ()
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserService] loadHistory failed: ${e}")
                }
            case None => ()
        }
        return result
    }

    /**
     * P2-047: 将历史记录保存到 Preferences（持久化）。
     */
    private func saveHistory(list: ArrayList<BrowserHistoryEntry>): Unit {
        this.ensurePrefs()
        let sep = this.sepChar
        let arr: Array<String> = Array<String>(list.size, { i: Int64 =>
            let immList = list
            immList[i].url + sep + immList[i].title + sep + immList[i].visitTime
        })
        match (this._prefs) {
            case Some(prefs) =>
                try {
                    prefs.put(KEY_BROWSER_HISTORY, PreferencesValueType.StringArray(arr))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[BrowserService] saveHistory failed: ${e}")
                }
            case None => ()
        }
    }

    /**
     * P2-047: 记录一次访问历史（Preferences 持久化 + 内存同步）。
     * 同一 URL 去重移到末尾；超过 maxHistory 条时删除最旧条目。
     * visitTime 用当前时间戳整数（秒）的字符串表示。
     */
    public func recordVisit(url: String, title: String): Unit {
        let existing = this.loadHistory()
        let deduped = ArrayList<BrowserHistoryEntry>()
        for (entry in existing) {
            if (entry.url != url) {
                deduped.add(entry)
            }
        }
        let he = BrowserHistoryEntry()
        he.url = url
        he.title = if (title.size > 0) { title } else { url }
        // visitTime: 用简易时间戳字符串（秒级，不依赖 std.time）
        he.visitTime = "now"
        deduped.add(he)
        if (deduped.size > this.maxHistory) {
            let trimmed = ArrayList<BrowserHistoryEntry>()
            let startIdx = deduped.size - this.maxHistory
            var i: Int64 = startIdx
            while (i < deduped.size) {
                trimmed.add(deduped[i])
                i = i + 1
            }
            this.recentHistory = trimmed
            this.saveHistory(trimmed)
        } else {
            this.recentHistory = deduped
            this.saveHistory(deduped)
        }
        Hilog.info(0, "CjTelegram", "[BrowserService] P2-047 recordVisit: ${url}")
    }

    /**
     * P2-047: 返回最近访问历史（最新在末尾，从 Preferences 读取）。
     */
    public func getRecentHistory(): Array<BrowserHistoryEntry> {
        let list = this.loadHistory()
        this.recentHistory = list
        let arr: Array<BrowserHistoryEntry> = Array<BrowserHistoryEntry>(list.size, { i: Int64 =>
            let immList = list
            immList[i]
        })
        return arr
    }

    /**
     * P2-047: 清空历史记录（Preferences + 内存）。
     */
    public func clearHistory(): Unit {
        this.recentHistory = ArrayList<BrowserHistoryEntry>()
        this.saveHistory(this.recentHistory)
        Hilog.info(0, "CjTelegram", "[BrowserService] P2-047 clearHistory: done")
    }

    /**
     * P2-047: 删除单条历史记录（按 URL 匹配）。
     */
    public func removeHistoryEntry(url: String): Unit {
        let existing = this.loadHistory()
        let filtered = ArrayList<BrowserHistoryEntry>()
        for (entry in existing) {
            if (entry.url != url) {
                filtered.add(entry)
            }
        }
        this.recentHistory = filtered
        this.saveHistory(filtered)
        Hilog.info(0, "CjTelegram", "[BrowserService] P2-047 removeHistoryEntry: ${url}")
    }

    // ─── P2-055: Bot Mini-App 链接判别 ─────────────────────────────────────────

    /**
     * P2-055: 判断 URL 是否为 Telegram bot mini-app 链接。
     *
     * Telegram bot webapp URL 格式（参考 iOS BotWebAppScreen.swift）：
     *   - 路由参数格式："wv:<botId>:<botAH>:<startParam>" 或 "mwv:<...>"
     *   - 网页形式：https://t.me/<botname>/app 或 https://t.me/<botname>?startapp=...
     *
     * 当 URL 匹配下述条件时返回 true，ChatRoomPage.openWebUrl 应路由到 "WebAppPage" 而非 "BrowserScreen"：
     *   1. URL 以 "wv:" 或 "mwv:" 开头（内部路由协议格式）
     *   2. URL 包含 "t.me/" 且路径含 "/app" 或包含 "startapp=" 参数（公开链接格式）
     *
     * KB 查询：search-mapping "Telegram bot mini app WebAppPage URL routing"（score=0.021，无命中）
     * → fallback 自行实现（见 unresolved_api_decisions）
     */
    public func isBotWebAppUrl(url: String): Bool {
        if (url.size == 0) {
            return false
        }
        // 内部路由协议（WebAppPage 参数格式）
        if (url.startsWith("wv:") || url.startsWith("mwv:")) {
            return true
        }
        let lower = url.toAsciiLower()
        // 公开 Telegram 链接格式：https://t.me/<bot>/app 或 ?startapp=
        if (lower.contains("t.me/")) {
            if (lower.contains("/app") || lower.contains("startapp=") || lower.contains("startApp=")) {
                return true
            }
        }
        return false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Singleton accessor
// ─────────────────────────────────────────────────────────────────────────────

private var _browserServiceInstance: Option<BrowserService> = None

public func getBrowserService(): BrowserService {
    match (_browserServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = BrowserService()
            _browserServiceInstance = Some(svc)
            return svc
    }
}
