package ohos_app_cangjie_entry.services

import std.collection.ArrayList
import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos.business_exception.BusinessException

/**
 * SettingsPageService — Settings hub service
 *
 * P2-317: 提供设置项全局索引 + 搜索过滤能力
 * P2-319: 本人资料 QR 弹层由 SettingsPage 直接本地展示（sentinel routeName "profile_qr"，
 *         与 help_* 条目同款处理），本 Service 仅提供其搜索索引条目
 *
 * M4 修法（diag-suite_settings_root-TC-0505-round2.md 增量 E-1/E-2/E-3，round1 §M4 本体沿用）：
 * 源侧 SettingsSearchableItems.swift 的 301 条构造（15 个分类 builder + 4 条顶层自建条目）
 * 逐叶子核验。
 *
 * round7 判据变更（supervisor_rulings[ruling-tc0505-e2-granularity]，commit fbf50a228，
 * 2026-09-04）：E-2 就绪门禁由「分类级整组交付」改为「目的屏级逐叶子」——某条 isVisible=true
 * 的叶子可交付 ⟺ 它自己 routeName 指向的目的屏已能消费 paramJson 的 item/category（或该叶子
 * 是 1:1 专属目的屏、无需 item/category 消费，抵达即完整代表该叶子，如
 * UsernameSettingsPage/ProfileColorPage/LogoutOptionsPage/AutoNightSettingsPage/
 * TextSizeSelectionPage/BubbleSettingsPage/WebBrowserSettingsPage/IntentsSettingsPage/
 * DeleteAccountOptionsScreen 这类"整页即该叶子"的目的屏）。判否只影响该条，不牵连同分类
 * 其它叶子。isVisible=false 的深链哨兵不受此门禁约束——searchSettings() 的
 * `entry.isVisible && entry.matches(query)` 短路，哨兵从不经由搜索结果被点击到达，故其
 * routeName 指向的目的屏是否就绪与其是否入索引无关；本轮按 E-3 硬性要求逐条建入（title 为空
 * 时 title 传空串），但目的屏本身完全不存在（如 PeerSelectionScreen、"passkey"/"auto-delete"
 * 消歧页等）的子树，哨兵也不建——没有可引用的真实 routeName，建了即臆造。
 *
 * round1/round2 判定 PASS 并交付：chatFolders（4 条，见下方 "folders" 根级条目后）、
 * energySaving（7 条，见下方 "power-saving" 根级条目后）——均 isVisible:false，不受本轮判据
 * 变更影响，原样保留。round6 交付 notifications 的 4 条 .../sound 叶子（目的屏
 * NotificationSoundSelectionPage 已消费 category 参数，commit 777fae75d），category 取值
 * 按目标侧真实枚举 "users"/"chats"/"broadcasts"/"stories"，原样保留。
 *
 * round7（本轮）按新判据逐叶子补充：notifications 分类的 5 条可见分类根叶子
 * （4 条 category 根 + reactions，目的屏 NotificationsPeerCategoryPage 已消费 category）+
 * 21 条 E-3 哨兵（上一轮遗漏，见 diag-suite_settings_root-TC-0505-round2.md 修法方向增量
 * E-3 与该分类促成的返修单）；premium 分类的 13 条叶子（目的屏 PremiumDemoPage，identifier
 * 逐条对应）；privacy 分类的 11 种 selective-privacy kind 叶子 + 其 33 条哨兵子项 +
 * open-links 1 条（目的屏分别是 SelectivePrivacySettingsPage/WebBrowserSettingsPage）；
 * profile 分类的 3 条 1:1 专属目的屏叶子（edit/username→UsernameSettingsPage、
 * edit/your-color→ProfileColorPage、edit/log-out→LogoutOptionsPage）+ 11 条哨兵；
 * appearance 分类的 3 条 1:1 专属目的屏叶子（auto-night-mode/text-size/message-corners）+
 * 1 条哨兵；data 分类的 data/share-sheet 1 条 + 3 条哨兵；calls/devices 分类各补 3/2 条哨兵
 * （目的屏 CallHistoryPage/DevicesPage 本身已就绪且已是本分类根级条目的既有目的地，哨兵不受
 * itemTag 未消费影响）；顶层 delete-account 1 条（目的屏 DeleteAccountOptionsScreen）。
 * 其余分类/叶子（devices/calls/proxy/sticker/data/appearance 的多数叶子、language、
 * premium/business 子分类等）目的屏无 item/category 消费能力（如 NotificationSettingsPage
 * 零 itemTag 消费、DevicesPage/CallHistoryPage/ProxySettingsPage/StickersSettingsPage/
 * DataPrivacySettingsPage/StorageUsagePage/ChatThemesPage/LanguageSettingsPage/
 * PremiumBusinessPage 均无 itemTag 消费）或目的屏根本不存在（PeerSelectionScreen、
 * my-profile/{gifts,posts,archived-posts}、quick-reaction、passkey、auto-delete、
 * bot-settings、do-not-translate、stars/earn、wallpapers/set 消歧页、LoginEmailPage 未登记
 * route_map 等），本轮不交付，也不建哨兵（无可引用的真实 routeName）。myProfile/sticker/proxy/
 * language/help(除已交付三条)/stars/ton/send-gift/business 等分类本轮未逐叶子重新核验到
 * profile/premium/privacy 同等深度，风险与后续动作见 set_root_and_search.md Hand-off。
 *
 * iOS 参考: TelegramUI/Sources/Settings/SettingsController.swift
 *           TelegramUI/Sources/Settings/SettingsSearch/SettingsSearchController.swift
 */

/**
 * M1 修法（diag-suite_settings_root-TC-0505.md）：对位源侧 SettingsSearchableItemPresentation
 * （SettingsSearchableItems.swift:63-68）——目的屏的呈现语义，navigateToSearchResult()
 * 按此字段四路分发。
 */
public enum SettingsSearchPresentation {
    | Push
    | Modal
    | Immediate
    | Dismiss
}

/**
 * 单个设置搜索条目，包含标题、搜索关键词、路由目标
 * M1 修法（diag-suite_settings_root-TC-0505.md）：字段模型对齐源侧 SettingsSearchableItem
 * （SettingsSearchableItems.swift:70-97）——新增 itemId/breadcrumbs/alternate/presentation/
 * isVisible，删除 subtitle（面包屑接管了它原先"分区名"的展示位，语义不同：subtitle 是自造
 * 分区名，breadcrumbs 是源侧路径式面包屑数组，根级条目为空数组、不渲染副标题节点）。
 */
public class SettingsSearchEntry {
    // 源侧 SettingsSearchableItem.id 的路径式字符串原文（如 "notifications/groups/sound"）。
    // 最近搜索的存取键（见 addRecentSettingsSearchEntry/getRecentSettingsSearchEntries）现在
    // 按这个字段做，不再按 routeName——M4 补齐叶子条目后多条会共用同一个 routeName，按
    // routeName 回查会取到错误条目。
    public var itemId: String = ""
    public var title: String = ""
    public var routeName: String = ""
    public var keywords: Array<String> = Array<String>(0, repeat: "")
    // 面包屑路径（对位源侧 breadcrumbs: [String]）。根级条目为空数组——
    // pages/SettingsPage.cj 的行渲染据此判断是否渲染副标题节点（空数组时不渲染，不是渲染
    // 空串）。
    public var breadcrumbs: Array<String> = Array<String>()
    // 同义词（对位源侧 alternate: synonyms(...)）。结构字段随 M1 落地；M1 阶段全部条目仍是
    // 根级条目、无同义词数据，实际同义词填充是 M4 的工作，matches()/matchableText() 暂不消费
    // 此字段（现状零行为变化，见 matches() 处注释）。
    public var alternate: Array<String> = Array<String>()
    // 对位源侧 present(...) 的呈现语义。navigateToSearchResult() 据此四路分发。
    public var presentation: SettingsSearchPresentation = SettingsSearchPresentation.Push
    // 对位源侧 isVisible（深链专用哨兵置 false，不出现在搜索结果里，见 searchSettings()）。
    public var isVisible: Bool = true
    // diag-suite_settings_root-TC-0083.md round4 M-2-d.3：通用传参通道（非
    // ChangePhoneIntroPage 专用）——目的路由需要携带路由参数时经此字段透传，默认空串
    // 对既有 40+ 条目零改动。routerPush 消费方见 pages/SettingsPage.cj:navigateToSearchResult。
    public var paramJson: String = ""

    // F2 修法（diag-suite_settings_root-TC-0076.md 修法 M2）：分词 + 前缀判定，对位
    // SettingsSearchableItems.swift:4519-4570（matchStringTokens）。之前是三段 contains
    // 子串判定，会让 "guage" 命中 "Language"；现在只有分词后是"任一条目词前缀"才算命中。
    // 匹配串组装为 title + 各非空 keywords（trim 后），**不含 breadcrumbs**——本轮（M1）未改
    // 此判定，沿用 F2 已过 review 的逻辑边界不动。本仓无变音符折叠 API 且索引/查询均为
    // ASCII，toAsciiLower() 是此处唯一可达的等价折叠，不引入字符映射表。
    public func matches(query: String): Bool {
        if (query.size == 0) { return true }
        let queryTokens = tokenizeSettingsSearchText(query)
        if (queryTokens.size == 0) { return false }
        let entryTokens = tokenizeSettingsSearchText(this.matchableText())
        var i: Int64 = 0
        while (i < Int64(queryTokens.size)) {
            if (!settingsSearchAnyTokenHasPrefix(entryTokens, queryTokens[i])) {
                return false
            }
            i = i + 1
        }
        return true
    }

    // title + 各非空 keywords（trim 后），供 matches() 分词。
    private func matchableText(): String {
        var s = this.title
        var i: Int64 = 0
        while (i < Int64(this.keywords.size)) {
            let kw = this.keywords[i].trimAscii()
            if (kw.size > 0) {
                s = s + " " + kw
            }
            i = i + 1
        }
        return s
    }
}

/**
 * F2 修法（diag-suite_settings_root-TC-0076.md 修法 M2）：按 ASCII 字母数字边界分词
 * （非字母数字视为分隔符），逐词转小写。对位源侧 CFStringTokenizer 词单元切分——本工程
 * ASCII 输入下等价，不引入未经验证的分词 API。
 */
private func tokenizeSettingsSearchText(text: String): ArrayList<String> {
    let tokens = ArrayList<String>()
    let current = StringBuilder()
    for (ch in text.toRuneArray()) {
        if (ch.isAsciiNumberOrLetter()) {
            current.append(ch)
        } else if (current.size > 0) {
            tokens.add(current.toString().toAsciiLower())
            current.reset()
        }
    }
    if (current.size > 0) {
        tokens.add(current.toString().toAsciiLower())
    }
    return tokens
}

/**
 * 分词判定的核心：`prefix` 是 `tokens` 中任一词的前缀即命中。对位 matchStringTokens 的
 * "token1.hasPrefix(token2)"（单/多查询词共用同一原语，由调用方 matches() 对每个查询词
 * 分别调用并要求全部命中）。
 */
private func settingsSearchAnyTokenHasPrefix(tokens: ArrayList<String>, prefix: String): Bool {
    var i: Int64 = 0
    while (i < Int64(tokens.size)) {
        if (tokens[i].startsWith(prefix)) {
            return true
        }
        i = i + 1
    }
    return false
}

// TC-0075 返修（修法 M4a）：最近设置搜索持久化通道常量，命名风格对位
// services/EmojiRecentService.cj 的 EMOJI_RECENT_PREFS/EMOJI_RECENT_KEY/EMOJI_RECENT_MAX/EMOJI_SEP。
private let SETTINGS_RECENT_SEARCH_PREFS: String = "telegram_settings_recent_search"
private let SETTINGS_RECENT_SEARCH_KEY: String = "recent_ids_v1"
private let SETTINGS_RECENT_SEARCH_MAX: Int32 = 100
private let SETTINGS_RECENT_SEARCH_SEP: String = "|"

// M1 修法（diag-suite_settings_root-TC-0505.md）：签名对齐 SettingsSearchEntry 的新字段模型。
// itemId 取代原先的位置参数 subtitle；presentation/breadcrumbs/alternate/isVisible 走具名
// 可选参数（默认值对应"根级、Push、可见"——本轮 buildSearchIndex() 里 23 条全部是这一类，
// 只有 "passport" 一条显式传 presentation: Modal）。
private func makeEntry(
    itemId: String,
    title: String,
    routeName: String,
    kws: ArrayList<String>,
    presentation!: SettingsSearchPresentation = SettingsSearchPresentation.Push,
    paramJson!: String = "",
    breadcrumbs!: Array<String> = Array<String>(),
    alternate!: Array<String> = Array<String>(),
    isVisible!: Bool = true
): SettingsSearchEntry {
    let e = SettingsSearchEntry()
    e.itemId = itemId
    e.title = title
    e.routeName = routeName
    e.keywords = kws.toArray()
    e.presentation = presentation
    e.paramJson = paramJson
    e.breadcrumbs = breadcrumbs
    e.alternate = alternate
    e.isVisible = isVisible
    return e
}

/**
 * SettingsPageService — 提供设置搜索索引和语言名称显示
 */
public class SettingsPageService {

    private var searchIndex: Array<SettingsSearchEntry> = Array<SettingsSearchEntry>(0, repeat: SettingsSearchEntry())

    public init() {
        this.searchIndex = buildSearchIndex()
    }

    /**
     * 搜索设置项，返回匹配 query 的所有条目（query 为空则返回全部）
     * P2-317 死状态防护: 非空 query 时结果来自真实索引，不是默认空数组
     */
    public func searchSettings(query: String): Array<SettingsSearchEntry> {
        if (query.size == 0) {
            return this.searchIndex
        }
        let results = ArrayList<SettingsSearchEntry>()
        var i: Int64 = 0
        while (i < Int64(this.searchIndex.size)) {
            let entry = this.searchIndex[i]
            // M1 边界（diag-suite_settings_root-TC-0505.md）：对位源侧 searchSettingsItems
            // 的 `guard item.isVisible || showAll`——本工程不实现 `#all` 调试查询，isVisible
            // == false 等价于「只走深链、不出现在搜索里」。本轮 23 条全部 isVisible=true，
            // 这条判断现在零行为差异，是给 M4 深链专用哨兵条目预留的边界。
            if (entry.isVisible && entry.matches(query)) {
                results.add(entry)
            }
            i = i + 1
        }
        return results.toArray()
    }

    /**
     * TC-0075 返修（diag-suite_settings_root-TC-0075.md 修法 M4a）：最近设置搜索存储。
     * 对位 SettingsSearchRecentQueries.swift:39-54——有序 id 列表、新 id 插最前、上限 100、
     * id 含非 ASCII 时静默不写入。持久化通道沿用本仓已验证先例
     * services/EmojiRecentService.cj（Preferences.getPreferences 同步 API，读同步/写 spawn{}）。
     */
    public func addRecentSettingsSearchEntry(id: String): Unit {
        if (!isAsciiSettingsSearchId(id)) {
            // 源侧 SettingsSearchRecentQueries.swift:39-54：id 非 ASCII 时静默不写入。
            return
        }
        let ctxOpt = getGlobalAbilityContext()
        match (ctxOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[SettingsPageService] no context for addRecentSettingsSearchEntry")
            case Some(ctx) =>
                let _ = spawn {
                    try {
                        let prefs = Preferences.getPreferences(ctx, SETTINGS_RECENT_SEARCH_PREFS)
                        let val = prefs.get(SETTINGS_RECENT_SEARCH_KEY, PreferencesValueType.StringData(""))
                        let raw = match (val) {
                            case PreferencesValueType.StringData(s) => s
                            case _ => ""
                        }
                        let existing = if (raw.size > 0) { parseSettingsSearchIds(raw) } else { Array<String>(0, repeat: "") }
                        let updated = insertRecentSettingsSearchId(existing, id)
                        let serialized = serializeSettingsSearchIds(updated)
                        prefs.put(SETTINGS_RECENT_SEARCH_KEY, PreferencesValueType.StringData(serialized))
                        prefs.flush()
                    } catch (e: BusinessException) {
                        Hilog.info(0, "CjTelegram", "[SettingsPageService] addRecentSettingsSearchEntry failed")
                    }
                }
        }
    }

    /**
     * F3 修法（diag-suite_settings_root-TC-0076.md 修法 M3-a）：按 id 删单条最近搜索，对位
     * SettingsSearchRecentQueries.swift:47-53 removeRecentSettingsSearchItem——同样的 ASCII
     * 守卫 + 按 id 删一条 + 静默失败。结构逐句照抄 addRecentSettingsSearchEntry()。
     */
    public func removeRecentSettingsSearchEntry(id: String): Unit {
        if (!isAsciiSettingsSearchId(id)) {
            return
        }
        let ctxOpt = getGlobalAbilityContext()
        match (ctxOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[SettingsPageService] no context for removeRecentSettingsSearchEntry")
            case Some(ctx) =>
                let _ = spawn {
                    try {
                        let prefs = Preferences.getPreferences(ctx, SETTINGS_RECENT_SEARCH_PREFS)
                        let val = prefs.get(SETTINGS_RECENT_SEARCH_KEY, PreferencesValueType.StringData(""))
                        let raw = match (val) {
                            case PreferencesValueType.StringData(s) => s
                            case _ => ""
                        }
                        let existing = if (raw.size > 0) { parseSettingsSearchIds(raw) } else { Array<String>(0, repeat: "") }
                        let updated = removeRecentSettingsSearchId(existing, id)
                        let serialized = serializeSettingsSearchIds(updated)
                        prefs.put(SETTINGS_RECENT_SEARCH_KEY, PreferencesValueType.StringData(serialized))
                        prefs.flush()
                    } catch (e: BusinessException) {
                        Hilog.info(0, "CjTelegram", "[SettingsPageService] removeRecentSettingsSearchEntry failed")
                    }
                }
        }
    }

    /**
     * 按存储顺序取回最近搜索条目，逐个到 buildSearchIndex() 索引里查——查不到的 id 直接跳过、
     * 不显示、不报错（对位 SettingsSearchItem.swift:394-402）。
     * M1 修法（diag-suite_settings_root-TC-0505.md）：查找键从 routeName 改为 itemId——
     * M4 补齐叶子条目后多条会共用同一个 routeName（同一目的页的不同深链），按 routeName
     * 回查会取到错误条目；itemId 对每条目唯一，对位源侧存的就是 item.id
     * （SettingsSearchRecentQueries.swift:39-54）。
     */
    public func getRecentSettingsSearchEntries(): Array<SettingsSearchEntry> {
        let ids = readRecentSettingsSearchIds()
        let result = ArrayList<SettingsSearchEntry>()
        var i: Int64 = 0
        while (i < Int64(ids.size)) {
            let id = ids[i]
            var j: Int64 = 0
            var found = false
            while (j < Int64(this.searchIndex.size) && !found) {
                if (this.searchIndex[j].itemId == id) {
                    result.add(this.searchIndex[j])
                    found = true
                }
                j = j + 1
            }
            i = i + 1
        }
        return result.toArray()
    }

    /**
     * 清空最近搜索存储（对位 "Clear" 分组动作）。
     */
    public func clearRecentSettingsSearchEntries(): Unit {
        let ctxOpt = getGlobalAbilityContext()
        match (ctxOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[SettingsPageService] no context for clearRecentSettingsSearchEntries")
            case Some(ctx) =>
                let _ = spawn {
                    try {
                        let prefs = Preferences.getPreferences(ctx, SETTINGS_RECENT_SEARCH_PREFS)
                        prefs.put(SETTINGS_RECENT_SEARCH_KEY, PreferencesValueType.StringData(""))
                        prefs.flush()
                    } catch (e: BusinessException) {
                        Hilog.info(0, "CjTelegram", "[SettingsPageService] clearRecentSettingsSearchEntries failed")
                    }
                }
        }
    }

    /**
     * Returns display name for a language code (e.g. "en" -> "English").
     */
    public func getLangDisplayName(code: String): String {
        if (code == "en") { return "English" }
        if (code == "zh-hans-raw") { return "简体中文" }
        if (code == "ja-raw") { return "日本語" }
        if (code == "ko") { return "한국어" }
        if (code == "de") { return "Deutsch" }
        if (code == "ru") { return "Русский" }
        if (code == "es") { return "Español" }
        if (code == "fr") { return "Français" }
        return "English"
    }
}

/**
 * 构建设置项全局搜索索引
 * 对应 iOS SettingsController 中所有一级/二级设置条目
 *
 * M1 修法（diag-suite_settings_root-TC-0505.md）：itemId 取代原 makeEntry 的 subtitle
 * 位置参数——本轮 23 条全部是源侧 breadcrumbs:[] 的根级条目，itemId 取源侧
 * SettingsSearchableItems.swift 里对应条目的 id 字面量原文；源侧无对应条目的（自造入口）
 * 用 kebab-case 合成 id，见各条目行内注释。presentation 缺省 Push（构造函数默认值），仅
 * "passport" 一条显式传 Modal（源侧 :4472-4483 present(.modal, SecureIdAuthController)，
 * 本工程唯一命中的 .modal 根级条目——见 set_root_and_search.md 分类表）。
 */
private func buildSearchIndex(): Array<SettingsSearchEntry> {
    let idx = ArrayList<SettingsSearchEntry>()

    var kw = ArrayList<String>()
    kw.add("saved"); kw.add("bookmarks"); kw.add("messages")
    idx.add(makeEntry("saved-messages", "Saved Messages", "SavedMessagesPage", kw))

    kw = ArrayList<String>()
    kw.add("calls"); kw.add("recent"); kw.add("history"); kw.add("phone")
    idx.add(makeEntry("calls", "Recent Calls", "CallHistoryPage", kw))

    // round7 修法：calls 分类——`calls/show-tab`（可见，源侧 `SettingsSearchableItems.swift:
    // 1197-1206`，itemTag `.showTab`）与 `calls/start-call`（不可见但目的语义是直接发起通话
    // UI、非设置页导航）判否：`pages/CallHistoryPage.cj` 全文件无 itemTag/focus 消费，
    // `calls/start-call` 无对应目的屏可引用。以下 3 条 E-3 哨兵（`calls/all`/`calls/missed`/
    // `calls/edit`，源侧 `:1168-1196`，title 为空或 isVisible:false）目的屏就是本分类已交付的
    // `CallHistoryPage`（本条根级条目同一路由），不受 itemTag 未消费影响、照建。
    kw = ArrayList<String>()
    idx.add(makeEntry("calls/all", "", "CallHistoryPage", kw,
        breadcrumbs: ["Recent Calls"], isVisible: false, paramJson: "{\"itemTag\":\"all\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("calls/missed", "", "CallHistoryPage", kw,
        breadcrumbs: ["Recent Calls"], isVisible: false, paramJson: "{\"itemTag\":\"missed\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("calls/edit", "", "CallHistoryPage", kw,
        breadcrumbs: ["Recent Calls"], isVisible: false, paramJson: "{\"itemTag\":\"edit\"}"))

    kw = ArrayList<String>()
    kw.add("devices"); kw.add("sessions"); kw.add("login"); kw.add("active")
    idx.add(makeEntry("devices", "Devices", "DevicesPage", kw))

    // round7 修法：devices 分类——`devices/terminate-sessions`/`devices/link-desktop`（可见，
    // 源侧 `:486-509`）判否：`pages/DevicesPage.cj` 无 itemTag 消费，`link-desktop` 目的屏源侧是
    // 二维码扫码流程（`QrCodeScanScreen`），目标侧无对应"扫码登录桌面"专属页可确认对齐，不臆造。
    // 以下 2 条 E-3 哨兵（`devices/edit`/`devices/auto-terminate`，源侧 isVisible:false）目的屏
    // 是本分类已交付的 `DevicesPage`，照建。
    kw = ArrayList<String>()
    idx.add(makeEntry("devices/edit", "", "DevicesPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"edit\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("devices/auto-terminate", "", "DevicesPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"autoTerminate\"}"))

    kw = ArrayList<String>()
    kw.add("folders"); kw.add("chats"); kw.add("organize"); kw.add("filter")
    idx.add(makeEntry("folders", "Chat Folders", "ChatFoldersPage", kw))

    // M4 修法（diag-suite_settings_root-TC-0505-round2.md 增量 E-2/E-3）：chatFolders 分类
    // 判定 PASS——源侧 chatFoldersSearchableItems()（SettingsSearchableItems.swift:1221-1341）
    // 除 "folders" 根级条目（已建，上一行）外，其余 4 条全部 isVisible:false，目的屏统一是
    // 已存在的 ChatFoldersPage（本文件 "folders" 根级条目已用的同一路由，本页在设置根屏内
    // 已可达，见 pages/SettingsPage.cj:1287 routerPush("ChatFoldersPage", "")），isVisible:false
    // ⇒ 从不经由 navigateToSearchResult() 被搜索结果点击到达（searchSettings() 的
    // `entry.isVisible && entry.matches(query)` 短路，见本文件 searchSettings()），不构成
    // R47（半交付指向目的屏根态）风险，因此不受 E-2 逐叶子 item/category 消费能力门禁约束
    // ——该门禁只约束「会被搜索点击到达」的可见叶子。4 条里 3 条（create/add-recommended/
    // show-tags）源侧带真实 title 但仍 isVisible:false，同一豁免逻辑适用（非 E-3 严格定义的
    // "title 为空" 哨兵，但同样从不被搜索结果渲染/点击，遵循同一豁免依据，见本 Worker 交付
    // 报告"分类判定方法论"节）。paramJson 携带 itemTag/action 语义供 ChatFoldersPage 未来
    // 接入焦点定位时消费，当前该页尚未解析该字段，属已知限制。
    kw = ArrayList<String>()
    idx.add(makeEntry("folders/edit", "", "ChatFoldersPage", kw,
        breadcrumbs: ["Chat Folders"], isVisible: false, paramJson: "{\"itemTag\":\"edit\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("folders/create", "Create New Folder", "ChatFoldersPage", kw,
        breadcrumbs: ["Chat Folders"], isVisible: false, paramJson: "{\"action\":\"create\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("folders/add-recommended", "Recommended Folders", "ChatFoldersPage", kw,
        breadcrumbs: ["Chat Folders"], isVisible: false, paramJson: "{\"itemTag\":\"addRecommended\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("folders/show-tags", "Show Folder Tags", "ChatFoldersPage", kw,
        breadcrumbs: ["Chat Folders"], isVisible: false, paramJson: "{\"itemTag\":\"displayTags\"}"))

    kw = ArrayList<String>()
    kw.add("notifications"); kw.add("sounds"); kw.add("alerts"); kw.add("mute"); kw.add("push")
    idx.add(makeEntry("notifications", "Notifications and Sounds", "NotificationSettingsPage", kw))

    // M5 修法（round6 返修，取代 round2 报告 E-1 的取值假设）：`notifications` 分类的
    // 4 条 `.../sound` 叶子（源侧 `SettingsSearchableItems.swift:1674 / :1746-1762 / :1820 /
    // :1893`），按 E-2 判据核验——目的屏 `NotificationSoundSelectionPage.cj:194-198`
    // `ensureLoaded()` 已消费 `category` 参数（`commit 777fae75d`），
    // `services/NotificationSoundSelectionService.cj:186-204/213-230` 的
    // `commitSelection`/`getCategorySound` 均按 `categoryKey(prefix, category)` 做「分类各自的
    // 键」读写——E-2 判据 PASS，整组开工。
    //
    // **category 取值改正**：round2 报告 E-1 假设 `"private-chats"/"groups"/"channels"/"stories"`
    // （抄自源侧 `SettingsSearchableItem.id` 路径字面量），但目标侧真正落地的分类枚举是
    // `"users"/"chats"/"broadcasts"/"stories"`（`pages/NotificationsPeerCategoryPage.cj:57,80,
    // 141-143` `isPeerCategory()`：`category == "users" || category == "chats" ||
    // category == "broadcasts"`；:152 `hasSoundAndExceptions()` 额外接纳 `"stories"`；该页
    // `:352-353 openSoundSelection()` 就是用这套字符串构造 `routerPush("NotificationSoundSelectionPage",
    // ...)` 的），该页面本身在 round2 报告成文（2026-08-23）之后才由其它 feature 演进出这条
    // NotificationSettingsPage → NotificationsPeerCategoryPage → NotificationSoundSelectionPage
    // 的真实导航链。用 round2 假设的分类字符串会让搜索深链写入与常规导航完全不同的
    // Preferences 键（`categoryKey()` 只是 `prefix + category` 原样拼接，无白名单校验，两套
    // 字符串各自落到独立存储桶、永不相遇）——若照抄会造成"深链改的铃声在正常设置页看不见"的
    // 静默数据分裂，故本轮改用已验证的真实枚举值，不采信报告原文的取值。
    // `item` 字段与 `folders/*`/`power-saving/*` 的 `itemTag` 同一性质：随条目落地，供
    // `NotificationSoundSelectionPage` 未来扩展消费，当前该页只读 `category`/`currentSoundId`/
    // `currentAccessHash`/`defaultSoundId`，`item` 暂未被解析，属已知限制（与 M4 遗留的
    // `itemTag` 未解析限制同一性质，见交付报告）。
    // `presentation: Modal` 的呈现半边（`.ets` `MODAL_ROUTES` + `.cj` `isModalRoute()` +
    // `NotificationSoundSelectionPage.ets` 的 `.mode(DIALOG)` 壳）不在本 feature allowlist
    // 内，已按 `router.cj:113-117` 与本文件既有 `ic_passport_modal_route_registration` 同款
    // 先例 emit `emitted_integration_contracts[ic_nsnd_modal_route_registration]`
    // （target=shell_settings_misc）。
    kw = ArrayList<String>()
    kw.add("sound"); kw.add("ringtone"); kw.add("private"); kw.add("chats")
    idx.add(makeEntry("notifications/private-chats/sound", "Sound", "NotificationSoundSelectionPage", kw,
        presentation: SettingsSearchPresentation.Modal,
        breadcrumbs: ["Notifications and Sounds", "Private Chats"],
        paramJson: "{\"item\":\"notifications/private-chats/sound\",\"category\":\"users\"}"))
    kw = ArrayList<String>()
    kw.add("sound"); kw.add("ringtone"); kw.add("group"); kw.add("groups")
    idx.add(makeEntry("notifications/groups/sound", "Sound", "NotificationSoundSelectionPage", kw,
        presentation: SettingsSearchPresentation.Modal,
        breadcrumbs: ["Notifications and Sounds", "Group Chats"],
        paramJson: "{\"item\":\"notifications/groups/sound\",\"category\":\"chats\"}"))
    kw = ArrayList<String>()
    kw.add("sound"); kw.add("ringtone"); kw.add("channel"); kw.add("channels")
    idx.add(makeEntry("notifications/channels/sound", "Sound", "NotificationSoundSelectionPage", kw,
        presentation: SettingsSearchPresentation.Modal,
        breadcrumbs: ["Notifications and Sounds", "Channels"],
        paramJson: "{\"item\":\"notifications/channels/sound\",\"category\":\"broadcasts\"}"))
    kw = ArrayList<String>()
    kw.add("sound"); kw.add("ringtone"); kw.add("story"); kw.add("stories")
    idx.add(makeEntry("notifications/stories/sound", "Sound", "NotificationSoundSelectionPage", kw,
        presentation: SettingsSearchPresentation.Modal,
        breadcrumbs: ["Notifications and Sounds", "Stories"],
        paramJson: "{\"item\":\"notifications/stories/sound\",\"category\":\"stories\"}"))

    // round7 修法（本轮，diag-suite_settings_root-TC-0505-round2.md 增量 E-2 新判据，逐叶子）：
    // notifications 分类的 5 条可见分类根叶子——4 条 category 根（private-chats/groups/
    // channels/stories，源侧 :1636/:1709/:1782/:1855）+ reactions（源侧 :1929）。目的屏
    // NotificationsPeerCategoryPage 已消费 category 参数（`:117-121 takePending +
    // JsonParser.parseObject(...).getString("category")`），且已额外支持 `category=="reactions"`
    // （`:60/:72-76/:133 titleForCategory` 与 `:141-152 isPeerCategory/hasSoundAndExceptions`
    // 均显式处理 reactions 分支，:386-389 NotificationSettingsPage 已用同一路由+category
    // 正常导航到 reactions），E-2 判据 PASS。add-exception（4 条，目的屏
    // NotificationExceptionsController 对位的 `pages/NotificationExceptionsPage.cj` 文件头
    // 自述"尚未接入 route_map.json、无 .ets 壳"，不可路由）与 in-app-sounds/in-app-vibrate/
    // in-app-preview/lock-screen-names/include-channels/count-unread-messages/new-contacts/
    // reset（8 条，目的屏 NotificationSettingsPage 全文件 `grep -n
    // "itemTag|focusOnItemTag" pages/NotificationSettingsPage.cj` 零命中，无 itemTag 消费）
    // 判否，按新判据只影响这 12 条自身，不牵连本组已就绪的这 5 条，本轮不建。
    kw = ArrayList<String>()
    kw.add("private"); kw.add("chats"); kw.add("message"); kw.add("notifications")
    idx.add(makeEntry("notifications/private-chats", "Private Chats", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Message Notifications"],
        paramJson: "{\"category\":\"users\"}"))
    kw = ArrayList<String>()
    kw.add("group"); kw.add("groups"); kw.add("chats"); kw.add("notifications")
    idx.add(makeEntry("notifications/groups", "Group Chats", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Message Notifications"],
        paramJson: "{\"category\":\"chats\"}"))
    kw = ArrayList<String>()
    kw.add("channel"); kw.add("channels"); kw.add("notifications")
    idx.add(makeEntry("notifications/channels", "Channels", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Message Notifications"],
        paramJson: "{\"category\":\"broadcasts\"}"))
    kw = ArrayList<String>()
    kw.add("story"); kw.add("stories"); kw.add("notifications")
    idx.add(makeEntry("notifications/stories", "Stories", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Message Notifications"],
        paramJson: "{\"category\":\"stories\"}"))
    kw = ArrayList<String>()
    kw.add("reactions"); kw.add("notifications")
    idx.add(makeEntry("notifications/reactions", "Reactions", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds"],
        paramJson: "{\"category\":\"reactions\"}"))

    // round7 修法：E-3 深链哨兵——上一轮 notifications 分类下的哨兵未建（round7 required_fixes
    // 已指出遗漏），本轮补齐全部 21 条（源侧 title 为空/isVisible:false 的深链落点）。均
    // isVisible:false，不参与搜索（searchSettings() 短路），不受 E-2 门禁约束；routeName 沿用
    // 同子树已交付的目的屏，itemTag 随 paramJson 落地供目的屏未来扩展消费、当前均未解析，
    // 属已知限制（与 folders/*、power-saving/* 既有哨兵同一性质）。
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/accounts", "", "NotificationSettingsPage", kw,
        breadcrumbs: ["Notifications and Sounds"], isVisible: false,
        paramJson: "{\"itemTag\":\"allAccounts\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/private-chats/edit", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Private Chats"], isVisible: false,
        paramJson: "{\"category\":\"users\",\"itemTag\":\"edit\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/private-chats/show", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Private Chats"], isVisible: false,
        paramJson: "{\"category\":\"users\",\"itemTag\":\"show\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/private-chats/preview", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Private Chats"], isVisible: false,
        paramJson: "{\"category\":\"users\",\"itemTag\":\"preview\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/private-chats/delete-exceptions", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Private Chats"], isVisible: false,
        paramJson: "{\"category\":\"users\",\"itemTag\":\"deleteExceptions\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/groups/edit", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Group Chats"], isVisible: false,
        paramJson: "{\"category\":\"chats\",\"itemTag\":\"edit\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/groups/show", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Group Chats"], isVisible: false,
        paramJson: "{\"category\":\"chats\",\"itemTag\":\"show\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/groups/preview", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Group Chats"], isVisible: false,
        paramJson: "{\"category\":\"chats\",\"itemTag\":\"preview\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/groups/delete-exceptions", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Group Chats"], isVisible: false,
        paramJson: "{\"category\":\"chats\",\"itemTag\":\"deleteExceptions\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/channels/edit", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Channels"], isVisible: false,
        paramJson: "{\"category\":\"broadcasts\",\"itemTag\":\"edit\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/channels/show", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Channels"], isVisible: false,
        paramJson: "{\"category\":\"broadcasts\",\"itemTag\":\"show\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/channels/preview", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Channels"], isVisible: false,
        paramJson: "{\"category\":\"broadcasts\",\"itemTag\":\"preview\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/channels/delete-exceptions", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Channels"], isVisible: false,
        paramJson: "{\"category\":\"broadcasts\",\"itemTag\":\"deleteExceptions\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/stories/new", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Stories"], isVisible: false,
        paramJson: "{\"category\":\"stories\",\"itemTag\":\"enable\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/stories/important", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Stories"], isVisible: false,
        paramJson: "{\"category\":\"stories\",\"itemTag\":\"important\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/stories/show-sender", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Stories"], isVisible: false,
        paramJson: "{\"category\":\"stories\",\"itemTag\":\"preview\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/stories/delete-exceptions", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Stories"], isVisible: false,
        paramJson: "{\"category\":\"stories\",\"itemTag\":\"deleteExceptions\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/reactions/messages", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Reactions"], isVisible: false,
        paramJson: "{\"category\":\"reactions\",\"itemTag\":\"messages\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/reactions/stories", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Reactions"], isVisible: false,
        paramJson: "{\"category\":\"reactions\",\"itemTag\":\"stories\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/reactions/show-sender", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Reactions"], isVisible: false,
        paramJson: "{\"category\":\"reactions\",\"itemTag\":\"showSender\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("notifications/reactions/sound", "", "NotificationsPeerCategoryPage", kw,
        breadcrumbs: ["Notifications and Sounds", "Reactions"], isVisible: false,
        paramJson: "{\"category\":\"reactions\",\"itemTag\":\"sound\"}"))

    kw = ArrayList<String>()
    kw.add("privacy"); kw.add("security"); kw.add("last seen"); kw.add("blocked"); kw.add("two-step")
    idx.add(makeEntry("privacy", "Privacy and Security", "PrivacySettingsPage", kw))

    // round7 修法：privacy 分类——11 种 selective-privacy kind 叶子（源侧
    // `privacySearchableItems()` :2058-3236）目的屏 `SelectivePrivacySettingsPage.cj:66-76`
    // 文件头 SSOT 注释逐字列出这 11 个已识别 kindParam（`last_seen|phone_number|
    // profile_photo|forwards|groups|calls|voice_messages|bio|birthday|saved_music|gifts`），
    // `pages/PrivacySettingsPage.cj:1093-1171` 已用同一套字符串常态导航到本页，E-2 判据 PASS。
    // 该页把 kindParam 当**裸字符串**路由参数消费（`routerPush("SelectivePrivacySettingsPage",
    // "<kindParam>")` → `:275-280 takePending(...)` 直接赋给 `this.kindParam`，不是 JSON），
    // 故本组 paramJson 一律是裸 kindParam 字面量，不包 `{}`。`privacy/blocked` 判否——目标侧无
    // BlockedUsersPage/BlockedPeersPage 等对应文件（已 `find pages/ -iname "*Block*"` 确认
    // 零命中），destination 不存在，其 4 条子项也不建哨兵（无真实 routeName 可引用）。
    //
    // round8 修法（TC-0505）：round7 把 `privacy/messages` 与 `privacy/blocked` 并列判否是错的
    // ——两者不是同一情形。上一轮引用的是 `SelectivePrivacySettingsPage.cj:71-76`（该注释准确，
    // 但指的是**另一个**目的屏：明写 "messages" 不进这张 kind 表），却据此断言
    // "set_privacy_and_security_root 的 Messages 行 onClick 也不应指向本页"，未去核实那一行
    // onClick **实际**去了哪。`pages/PrivacySettingsPage.cj:1163-1165`（本 feature target_files
    // 内）的 "Messages" 行早已改指 `routerPush("IncomingMessagePrivacyPage", "")`（见该处注释：
    // set_selective_privacy 在更早一轮已把该行接回 `pages/IncomingMessagePrivacyPage.cj`，不再
    // 误触 SelectivePrivacySettingsPage 的 kind 兜底分支）——这是一个已注册进
    // `route_map.json:309`（`entry/src/main/resources/base/profile/route_map.json`）、且全文件
    // 零 `takePending`/`itemTag` 消费（仅 `onAppear` 里 `refresh()` 拉服务端真值，不解析路由参
    // 数）的独立目的屏，属「到达即完成」1:1 落点，按 supervisor_rulings[ruling-tc0505-e2-
    // granularity] 判据第二支（1:1 目的屏扩展，round7 已有 `passport`/`privacy/open-links` 等
    // 先例）E-2 PASS。paramJson 留空（同 `privacy/open-links` 写法，无 item/category 需要消费）。
    kw = ArrayList<String>()
    kw.add("last"); kw.add("seen"); kw.add("online"); kw.add("status")
    idx.add(makeEntry("privacy/last-seen", "Last Seen & Online", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "last_seen"))
    kw = ArrayList<String>()
    kw.add("profile"); kw.add("photo"); kw.add("photos"); kw.add("picture")
    idx.add(makeEntry("privacy/profile-photos", "Profile Photos", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "profile_photo"))
    kw = ArrayList<String>()
    kw.add("forwards"); kw.add("forwarded"); kw.add("messages")
    idx.add(makeEntry("privacy/forwards", "Forwarded Messages", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "forwards"))
    kw = ArrayList<String>()
    kw.add("calls"); kw.add("who"); kw.add("can")
    idx.add(makeEntry("privacy/calls", "Calls", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "calls"))
    kw = ArrayList<String>()
    kw.add("invites"); kw.add("groups"); kw.add("channels"); kw.add("add")
    idx.add(makeEntry("privacy/invites", "Groups and Channels", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "groups"))
    kw = ArrayList<String>()
    kw.add("bio")
    idx.add(makeEntry("privacy/bio", "Bio", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "bio"))
    kw = ArrayList<String>()
    kw.add("birthday")
    idx.add(makeEntry("privacy/birthday", "Birthday", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "birthday"))
    kw = ArrayList<String>()
    kw.add("gifts")
    idx.add(makeEntry("privacy/gifts", "Gifts", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "gifts"))
    kw = ArrayList<String>()
    kw.add("phone"); kw.add("number")
    idx.add(makeEntry("privacy/phone-number", "Phone Number", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "phone_number"))
    kw = ArrayList<String>()
    kw.add("saved"); kw.add("music"); kw.add("audio")
    idx.add(makeEntry("privacy/saved-music", "Saved Music", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "saved_music"))
    kw = ArrayList<String>()
    kw.add("voice"); kw.add("messages")
    idx.add(makeEntry("privacy/voice", "Voice Messages", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security"], paramJson: "voice_messages"))

    // round7 修法：privacy/open-links——目的屏 `pages/WebBrowserSettingsPage.cj` 已存在且已被
    // `PrivacySettingsPage.cj:1275 routerPush("WebBrowserSettingsPage")` 常态导航（无 item 参数
    // 需求，整页即该叶子），E-2 判据 PASS。
    kw = ArrayList<String>()
    kw.add("open"); kw.add("links"); kw.add("browser"); kw.add("web")
    idx.add(makeEntry("privacy/open-links", "Open Links In", "WebBrowserSettingsPage", kw,
        breadcrumbs: ["Privacy and Security"]))

    kw = ArrayList<String>()
    kw.add("messages"); kw.add("who"); kw.add("can"); kw.add("send")
    idx.add(makeEntry("privacy/messages", "Messages", "IncomingMessagePrivacyPage", kw,
        breadcrumbs: ["Privacy and Security"]))

    // round7 修法：以上 11 种 kind 各自的 E-3 深链哨兵子项（源侧 title 为空/isVisible:false 的
    // 三档/两档选项行），目的屏就是同 kind 已交付的 SelectivePrivacySettingsPage，不受门禁约束。
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/last-seen/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Last Seen & Online"], isVisible: false, paramJson: "last_seen"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/last-seen/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Last Seen & Online"], isVisible: false, paramJson: "last_seen"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/last-seen/hide-read-time", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Last Seen & Online"], isVisible: false, paramJson: "last_seen"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/profile-photos/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Profile Photos"], isVisible: false, paramJson: "profile_photo"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/profile-photos/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Profile Photos"], isVisible: false, paramJson: "profile_photo"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/profile-photos/set-public", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Profile Photos"], isVisible: false, paramJson: "profile_photo"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/profile-photos/update-public", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Profile Photos"], isVisible: false, paramJson: "profile_photo"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/profile-photos/remove-public", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Profile Photos"], isVisible: false, paramJson: "profile_photo"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/forwards/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Forwarded Messages"], isVisible: false, paramJson: "forwards"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/forwards/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Forwarded Messages"], isVisible: false, paramJson: "forwards"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/calls/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Calls"], isVisible: false, paramJson: "calls"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/calls/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Calls"], isVisible: false, paramJson: "calls"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/calls/p2p", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Calls"], isVisible: false, paramJson: "calls"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/calls/p2p/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Calls"], isVisible: false, paramJson: "calls"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/calls/p2p/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Calls"], isVisible: false, paramJson: "calls"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/calls/ios-integration", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Calls"], isVisible: false, paramJson: "calls"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/invites/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Groups and Channels"], isVisible: false, paramJson: "groups"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/invites/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Groups and Channels"], isVisible: false, paramJson: "groups"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/bio/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Bio"], isVisible: false, paramJson: "bio"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/bio/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Bio"], isVisible: false, paramJson: "bio"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/birthday/add", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Birthday"], isVisible: false, paramJson: "birthday"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/birthday/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Birthday"], isVisible: false, paramJson: "birthday"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/birthday/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Birthday"], isVisible: false, paramJson: "birthday"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/gifts/show-icon", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Gifts"], isVisible: false, paramJson: "gifts"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/gifts/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Gifts"], isVisible: false, paramJson: "gifts"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/gifts/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Gifts"], isVisible: false, paramJson: "gifts"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/gifts/accepted-types", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Gifts"], isVisible: false, paramJson: "gifts"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/phone-number/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Phone Number"], isVisible: false, paramJson: "phone_number"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/phone-number/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Phone Number"], isVisible: false, paramJson: "phone_number"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/saved-music/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Saved Music"], isVisible: false, paramJson: "saved_music"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/saved-music/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Saved Music"], isVisible: false, paramJson: "saved_music"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/voice/never", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Voice Messages"], isVisible: false, paramJson: "voice_messages"))
    kw = ArrayList<String>()
    idx.add(makeEntry("privacy/voice/always", "", "SelectivePrivacySettingsPage", kw,
        breadcrumbs: ["Privacy and Security", "Voice Messages"], isVisible: false, paramJson: "voice_messages"))

    kw = ArrayList<String>()
    kw.add("data"); kw.add("storage"); kw.add("cache"); kw.add("media"); kw.add("download")
    idx.add(makeEntry("data", "Data and Storage", "DataStorageSettingsPage", kw))

    // round7 修法：data/share-sheet——目的屏 `pages/IntentsSettingsPage.cj` 已存在且已被
    // `DataStorageSettingsPage.cj:1180 routerPush("IntentsSettingsPage", "")` 常态导航（整页
    // 即该叶子，无 item 参数需求），E-2 判据 PASS；3 条 E-3 哨兵子项（源侧 :3695-3712，
    // title 为空）目的屏同页，照建。data 分类其余叶子（storage/usage/auto-download/
    // save-to-photos/proxy 等，目的屏 StorageUsagePage/DataPrivacySettingsPage/
    // ProxySettingsPage 均无 itemTag 消费，属供应商已知未就绪清单）本轮不展开。
    kw = ArrayList<String>()
    kw.add("share"); kw.add("sheet"); kw.add("suggest"); kw.add("intents")
    idx.add(makeEntry("data/share-sheet", "Share Sheet", "IntentsSettingsPage", kw,
        breadcrumbs: ["Data and Storage"]))
    kw = ArrayList<String>()
    idx.add(makeEntry("data/share-sheet/suggested-chats", "", "IntentsSettingsPage", kw,
        breadcrumbs: ["Data and Storage", "Share Sheet"], isVisible: false, paramJson: "{\"itemTag\":\"suggestedChats\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("data/share-sheet/suggest-by", "", "IntentsSettingsPage", kw,
        breadcrumbs: ["Data and Storage", "Share Sheet"], isVisible: false, paramJson: "{\"itemTag\":\"suggestBy\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("data/share-sheet/reset", "", "IntentsSettingsPage", kw,
        breadcrumbs: ["Data and Storage", "Share Sheet"], isVisible: false, paramJson: "{\"itemTag\":\"reset\"}"))

    kw = ArrayList<String>()
    kw.add("appearance"); kw.add("theme"); kw.add("dark"); kw.add("font"); kw.add("color")
    idx.add(makeEntry("appearance", "Appearance", "AppearanceSettingsPage", kw))

    // round7 修法：appearance 分类——3 条 1:1 专属目的屏叶子已被 `AppearanceSettingsPage.cj`
    // 常态导航（均无 item 参数、整页即该叶子）：`:1373 routerPush("AutoNightSettingsPage", "")`、
    // `:1399 routerPush("TextSizeSelectionPage", "")`、`:1405 routerPush("BubbleSettingsPage",
    // "")`，E-2 判据 PASS。`appearance/text-size/use-system`（源侧 :4047-4060，title 为空）
    // 目的屏同页，E-3 哨兵照建。appearance/wallpapers/themes（ChatThemesPage 无 itemTag 消费，
    // 属已知未就绪清单）与 appearance/app-icon（无对应目标页）本轮不展开。
    kw = ArrayList<String>()
    kw.add("night"); kw.add("mode"); kw.add("auto"); kw.add("dark")
    idx.add(makeEntry("appearance/auto-night-mode", "Automatic Night Mode", "AutoNightSettingsPage", kw,
        breadcrumbs: ["Appearance"]))
    kw = ArrayList<String>()
    kw.add("text"); kw.add("size"); kw.add("font")
    idx.add(makeEntry("appearance/text-size", "Text Size", "TextSizeSelectionPage", kw,
        breadcrumbs: ["Appearance"]))
    kw = ArrayList<String>()
    idx.add(makeEntry("appearance/text-size/use-system", "", "TextSizeSelectionPage", kw,
        breadcrumbs: ["Appearance", "Text Size"], isVisible: false, paramJson: "{\"itemTag\":\"useSystem\"}"))
    kw = ArrayList<String>()
    kw.add("message"); kw.add("corners"); kw.add("bubble"); kw.add("shape")
    idx.add(makeEntry("appearance/message-corners", "Message Corners", "BubbleSettingsPage", kw,
        breadcrumbs: ["Appearance"]))

    kw = ArrayList<String>()
    kw.add("power"); kw.add("saving"); kw.add("battery"); kw.add("performance")
    idx.add(makeEntry("power-saving", "Power Saving", "PowerSavingSettingsPage", kw))

    // M4 修法（diag-suite_settings_root-TC-0505-round2.md 增量 E-2/E-3）：energySaving 分类
    // 判定 PASS——源侧 energySavingSearchableItems()（SettingsSearchableItems.swift:3813-3890）
    // 除 "power-saving" 根级条目（已建，上一行）外，其余 7 条源码本身 title 为空且
    // isVisible:false（连 breadcrumbs 源码都未传，随结构体默认值取空数组——逐字节照抄源码，
    // 不代表本工程判断错误），是 E-3 定义的深链哨兵原型：目的屏统一是已存在的
    // PowerSavingSettingsPage（"power-saving" 根级条目同一路由，见
    // pages/SettingsPage.cj:1342 routerPush("PowerSavingSettingsPage", "")）。isVisible:false
    // ⇒ 不参与搜索、不构成 R47 风险，按 E-3 硬性要求"建但不搜"，不得因反正搜不到而跳过。
    // paramJson 携带 itemTag，供 PowerSavingSettingsPage 未来接入焦点定位消费，当前未解析，
    // 属已知限制（与上方 chatFolders 同一性质）。
    kw = ArrayList<String>()
    idx.add(makeEntry("power-saving/videos", "", "PowerSavingSettingsPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"autoplayVideo\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("power-saving/gifs", "", "PowerSavingSettingsPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"autoplayGif\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("power-saving/stickers", "", "PowerSavingSettingsPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"loopStickers\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("power-saving/emoji", "", "PowerSavingSettingsPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"loopEmoji\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("power-saving/effects", "", "PowerSavingSettingsPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"fullTranslucency\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("power-saving/preload", "", "PowerSavingSettingsPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"autodownloadInBackground\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("power-saving/background", "", "PowerSavingSettingsPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"extendBackgroundWork\"}"))

    kw = ArrayList<String>()
    kw.add("language"); kw.add("locale"); kw.add("translation"); kw.add("interface")
    idx.add(makeEntry("language", "Language", "LanguageSettingsPage", kw))

    kw = ArrayList<String>()
    kw.add("stickers"); kw.add("emoji"); kw.add("gifs"); kw.add("animated")
    idx.add(makeEntry("appearance/stickers-and-emoji", "Stickers and Emoji", "StickersSettingsPage", kw))

    kw = ArrayList<String>()
    kw.add("premium"); kw.add("subscription"); kw.add("upgrade"); kw.add("pro")
    idx.add(makeEntry("premium", "Telegram Premium", "PremiumPage", kw))

    // round7 修法：premium 分类的 13 条叶子（源侧 `premiumSearchableItems()` :578-745，均走
    // `presentDemo(subject, present)` → `present(.push, PremiumDemoScreen(...))`）目的屏
    // `pages/PremiumDemoPage.cj:65-241` 的 `demoList` identifier 逐条对应（`takePending(
    // "PremiumDemoPage")` 取回裸字符串，`item.identifier == param` 比对，见 :270-275），
    // E-2 判据 PASS，与 `pages/PremiumPage.cj:372 routerPush("PremiumDemoPage",
    // item.identifier)` 既有先例同一路由/同一取值口径。paramJson 为裸 identifier 字面量，
    // 不包 `{}`（同 SelectivePrivacySettingsPage 的裸串消费惯例）。business/stars/ton/
    // send-gift 子分类（源侧同函数内，:748-953）目的屏 PremiumBusinessPage 不存在、
    // makeStarsTransactionsScreen 无目标侧对应页，判否，本轮不展开。
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("doubled"); kw.add("limits")
    idx.add(makeEntry("premium/doubled-limits", "Doubled Limits", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "double_limits"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("upload"); kw.add("cloud"); kw.add("storage")
    idx.add(makeEntry("premium/unlimited-cloud-storage", "Larger File Size Limit", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "more_upload"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("faster"); kw.add("download"); kw.add("speed")
    idx.add(makeEntry("premium/faster-download-speed", "Faster Download Speed", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "faster_download"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("voice"); kw.add("text")
    idx.add(makeEntry("premium/voice-to-text", "Voice to Text Conversion", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "voice_to_text"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("no"); kw.add("ads")
    idx.add(makeEntry("premium/no-ads", "No Ads", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "no_ads"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("emoji"); kw.add("status")
    idx.add(makeEntry("premium/emoji-statuses", "Emoji Status", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "emoji_status"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("unique"); kw.add("reactions")
    idx.add(makeEntry("premium/unique-reactions", "Unique Reactions", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "infinite_reactions"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("stickers")
    idx.add(makeEntry("premium/premium-stickers", "Premium Stickers", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "premium_stickers"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("animated"); kw.add("emoji")
    idx.add(makeEntry("premium/animated-emoji", "Animated Emoji", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "animated_emoji"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("chat"); kw.add("management")
    idx.add(makeEntry("premium/advanced-chat-management", "Advanced Chat Management", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "advanced_chat_management"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("profile"); kw.add("badge")
    idx.add(makeEntry("premium/profile-badge", "Profile Badge", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "profile_badge"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("animated"); kw.add("profile"); kw.add("pictures")
    idx.add(makeEntry("premium/animated-profile-pictures", "Animated Profile Pictures", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "animated_userpics"))
    kw = ArrayList<String>()
    kw.add("premium"); kw.add("app"); kw.add("icons")
    idx.add(makeEntry("premium/app-icons", "App Icon", "PremiumDemoPage", kw,
        breadcrumbs: ["Telegram Premium"], paramJson: "app_icons"))

    // 分类依据（diag-suite_settings_root-TC-0505.md M3 分类表）：源侧 :4472-4483
    // `present(.modal, SecureIdAuthController(context: context, mode: .list))`——本工程 23
    // 条根级条目里唯一的 .modal。目的路由须登记进模态路由集合（entry/src/main/ets/router/
    // CustomTransition.ets MODAL_ROUTES + entry/src/main/cangjie/router/router.cj
    // isModalRoute()），两个文件都不在本 feature allowlist 内，已 emit
    // emitted_integration_contracts[ic_passport_modal_route_registration]（target=
    // shell_settings_misc，该 feature 已持有这两个文件，见 router.cj:102-106 同款先例
    // ChatQrCodeSharePage 的 owner 记法）。
    kw = ArrayList<String>()
    kw.add("passport"); kw.add("identity"); kw.add("document"); kw.add("verification")
    idx.add(makeEntry("passport", "Telegram Passport", "PassportPage", kw, presentation: SettingsSearchPresentation.Modal))

    // diag-suite_settings_root-TC-0083.md round4 M-2-d.3：目的地改为说明前置屏。proceed
    // 为 "push"（SettingsSearchableItems.swift:202 present(.push, ChangePhoneNumberController)，
    // 与 PeerInfo 两处入口的 replace_top 不同，源侧本身如此，不得统一）。itemId 取源侧
    // "edit/change-number"（SettingsSearchableItems.swift:80）——outer present 是
    // .push（:92），presentation 仍 Push。
    kw = ArrayList<String>()
    kw.add("phone"); kw.add("change"); kw.add("number"); kw.add("mobile")
    idx.add(makeEntry("edit/change-number", "Change Phone Number", "ChangePhoneIntroPage", kw, paramJson: "{\"proceed\":\"push\"}"))

    // round7 修法：profile 分类（源侧 `profileSearchableItems()` :110-455）3 条 1:1 专属目的屏
    // 叶子——`edit/username`（源侧 :208-220，`present(.modal, usernameSetupController(...))`）
    // 目的屏 `pages/UsernameSettingsPage.cj` 已注册进 `route_map.json` 且已在 `MODAL_ROUTES`
    // （`ets/router/CustomTransition.ets:13`）；`edit/your-color`（源侧 :222-234，
    // `UserAppearanceScreen`）目的屏 `pages/ProfileColorPage.cj` 已被
    // `AppearanceSettingsPage.cj:1314`/`EditProfilePage.cj:584` 常态导航（`routerPush(
    // "ProfileColorPage", "")`）；`edit/log-out`（源侧 :362-381，
    // `present(.modal, logoutOptionsController(...))`）目的屏 `pages/LogoutOptionsPage.cj`
    // 同样已注册 + 已在 MODAL_ROUTES。三者均无 item 参数需求（整页即该叶子），E-2 判据 PASS。
    // `edit/channel`（源侧 :236-274）目的屏 `PeerSelectionScreen` 不存在，判否；`edit/birthday`
    // （presentSetupBirthday）、`edit/add-account`（beginNewAuth 登录流程）、`emoji-status`/
    // `profile-photo`/`profile-photo/use-emoji`（均是在 SettingsPage 自身内联展开的覆盖层，非
    // 独立可路由页）本轮找不到可确认对齐的目标侧专属页，不臆造，判否。
    kw = ArrayList<String>()
    kw.add("username"); kw.add("handle"); kw.add("link")
    idx.add(makeEntry("edit/username", "Username", "UsernameSettingsPage", kw,
        presentation: SettingsSearchPresentation.Modal, breadcrumbs: ["Edit Profile"]))
    kw = ArrayList<String>()
    kw.add("color"); kw.add("profile"); kw.add("appearance")
    idx.add(makeEntry("edit/your-color", "Your Color", "ProfileColorPage", kw,
        breadcrumbs: ["Edit Profile"]))
    kw = ArrayList<String>()
    kw.add("log"); kw.add("out"); kw.add("logout"); kw.add("sign")
    idx.add(makeEntry("edit/log-out", "Log Out", "LogoutOptionsPage", kw,
        presentation: SettingsSearchPresentation.Modal, breadcrumbs: ["Edit Profile"]))

    // round7 修法：以上两条目的屏各自的 E-3 深链哨兵。`edit`/`edit/first-name`/`edit/last-name`/
    // `edit/bio`（源侧 :133-184，均 `openSettings(edit: true)`，即打开本人资料编辑态）映射到
    // 目标侧同构概念 `EditProfilePage`（该页不消费 itemTag，哨兵不受影响）。`profile-color`
    // 子树（源侧 :383-452，均 `UserAppearanceScreen` 的不同 `focusOnItemTag`）映射到
    // `ProfileColorPage`（同样不消费 itemTag）。
    kw = ArrayList<String>()
    idx.add(makeEntry("edit", "", "EditProfilePage", kw, isVisible: false))
    kw = ArrayList<String>()
    idx.add(makeEntry("edit/first-name", "", "EditProfilePage", kw,
        breadcrumbs: ["Edit Profile"], isVisible: false, paramJson: "{\"itemTag\":\"firstName\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("edit/last-name", "", "EditProfilePage", kw,
        breadcrumbs: ["Edit Profile"], isVisible: false, paramJson: "{\"itemTag\":\"lastName\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("edit/bio", "", "EditProfilePage", kw,
        breadcrumbs: ["Edit Profile"], isVisible: false, paramJson: "{\"itemTag\":\"bio\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("profile-color", "", "ProfileColorPage", kw, isVisible: false))
    kw = ArrayList<String>()
    idx.add(makeEntry("profile-color/profile", "", "ProfileColorPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"profile\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("profile-color/profile/add-icons", "", "ProfileColorPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"profileAddIcons\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("profile-color/profile/use-gift", "", "ProfileColorPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"profileUseGift\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("profile-color/name", "", "ProfileColorPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"name\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("profile-color/name/add-icons", "", "ProfileColorPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"nameAddIcons\"}"))
    kw = ArrayList<String>()
    idx.add(makeEntry("profile-color/name/use-gift", "", "ProfileColorPage", kw,
        isVisible: false, paramJson: "{\"itemTag\":\"nameUseGift\"}"))

    // 目标侧自造入口：source SettingsSearchableItems.swift 全文件无 "archive" 图标枚举成员、
    // 无对应可搜索条目（已通读 devicesSearchableItems/privacySearchableItems 等全部 15 个
    // 分类 builder 核实）——本条与下方 Check for Updates/Sync and Backend/Permissions/
    // Telegram VoIP 同属目标侧自造，presentation 沿用现状 Push，无源侧行为可对齐。
    kw = ArrayList<String>()
    kw.add("archive"); kw.add("archived"); kw.add("hidden")
    idx.add(makeEntry("archive", "Archive", "ArchiveSettingsPage", kw))

    // diag-session-loss-investigation R-2：此前指向 QrLoginPage（登录转移页），已登录态命中
    // 会在共享已授权连接上发起 auth.exportLoginToken，触发 401 拦截清空本机凭据。改为本地
    // sentinel "profile_qr"（与 SettingsPage.navigateToSearchResult 的 help_* 同款处理），
    // 展示本人资料 QR，零 auth.* 调用。对位 SettingsSearchableItems.swift:973 "qr-code" 条目
    // -> makeChatQrCodeScreen（只读展示，非登录转移）；itemId 取源侧 id 原文 "qr-code"，
    // 目的路由改走 sentinel，presentation 与源侧一致仍是 Push（源侧该条 present(.push,...)）。
    kw = ArrayList<String>()
    kw.add("qr"); kw.add("code"); kw.add("profile"); kw.add("link"); kw.add("share")
    idx.add(makeEntry("qr-code", "QR Code", "profile_qr", kw))

    // 目标侧自造入口（无源侧对应条目，见上方 Archive 注释）。
    kw = ArrayList<String>()
    kw.add("update"); kw.add("version"); kw.add("upgrade"); kw.add("check")
    idx.add(makeEntry("check-for-updates", "Check for Updates", "UpdateInfoPage", kw))

    // help_* 三个 sentinel：presentation 按任务分派指示恒填 Push（当前行为不变，本轮不碰
    // openUrl 分支）。itemId 取源侧对应条目 id 原文——"ask-question"/"faq"/"features"
    // （SettingsSearchableItems.swift helpSearchableItems():4210-4260），仅 "features"
    // 一条源侧实际是 .immediate（Settings_Tips，异步 resolvePeerByName 后跳转）；本轮不改
    // sentinel 行为，presentation 按分派指示固定 Push——即 help_features 与其源侧对应条目的
    // 呈现语义存在已知偏差，留给该 sentinel 行为本身被重新评估的场次处理，不在本轮范围。
    kw = ArrayList<String>()
    kw.add("help"); kw.add("support"); kw.add("question"); kw.add("contact")
    idx.add(makeEntry("ask-question", "Ask a Question", "help_ask", kw))

    kw = ArrayList<String>()
    kw.add("faq"); kw.add("help"); kw.add("frequently"); kw.add("guide")
    idx.add(makeEntry("faq", "Telegram FAQ", "help_faq", kw))

    kw = ArrayList<String>()
    kw.add("features"); kw.add("tips"); kw.add("new"); kw.add("blog")
    idx.add(makeEntry("features", "Telegram Features", "help_features", kw))

    // 目标侧自造入口（无源侧对应条目，见上方 Archive 注释）。
    kw = ArrayList<String>()
    kw.add("sync"); kw.add("backend"); kw.add("server"); kw.add("connection")
    idx.add(makeEntry("sync-and-backend", "Sync and Backend", "SettingsBackendPage", kw))

    kw = ArrayList<String>()
    kw.add("permissions"); kw.add("access"); kw.add("camera"); kw.add("microphone"); kw.add("contacts")
    idx.add(makeEntry("permissions", "Permissions", "PermissionPage", kw))

    kw = ArrayList<String>()
    kw.add("voip"); kw.add("calls"); kw.add("p2p"); kw.add("video")
    idx.add(makeEntry("telegram-voip", "Telegram VoIP", "TelegramVoipPage", kw))

    // round7 修法：顶层自建条目（源侧 `settingsSearchableItems()` :4500-4513，非属任何 15
    // 分类 builder）——`delete-account` 目的屏 `pages/DeleteAccountOptionsScreen.cj` 已注册进
    // `route_map.json` 且已被 `PrivacySettingsPage.cj:991 routerPush(
    // "DeleteAccountOptionsScreen", "")` 常态导航（无 item 参数需求），E-2 判据 PASS。
    // `privacy-policy`（源侧 :4283-4299，`openResolvedUrl` 动态解析帮助页 URL）无对应目标侧
    // 专属页可确认对齐，判否。
    kw = ArrayList<String>()
    kw.add("delete"); kw.add("account"); kw.add("remove")
    idx.add(makeEntry("delete-account", "Delete My Account", "DeleteAccountOptionsScreen", kw))

    return idx.toArray()
}

// ==================== 最近设置搜索 id 列表持久化辅助（TC-0075 修法 M4a） ====================

/**
 * 同步读取最近设置搜索 id 列表（Preferences.getPreferences 是同步 API，与
 * services/EmojiRecentService.cj getRecentEmojis() 同款读取范式）。
 */
private func readRecentSettingsSearchIds(): Array<String> {
    let ctxOpt = getGlobalAbilityContext()
    match (ctxOpt) {
        case None => return Array<String>(0, repeat: "")
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, SETTINGS_RECENT_SEARCH_PREFS)
                let val = prefs.get(SETTINGS_RECENT_SEARCH_KEY, PreferencesValueType.StringData(""))
                let raw = match (val) {
                    case PreferencesValueType.StringData(s) => s
                    case _ => ""
                }
                if (raw.size == 0) {
                    return Array<String>(0, repeat: "")
                }
                return parseSettingsSearchIds(raw)
            } catch (e: BusinessException) {
                return Array<String>(0, repeat: "")
            }
    }
}

/**
 * 解析 Preferences 存储的 id 列表（管道符分隔，同 EmojiRecentService 序列化格式）。
 */
private func parseSettingsSearchIds(raw: String): Array<String> {
    let parts = raw.split(SETTINGS_RECENT_SEARCH_SEP)
    let result = ArrayList<String>()
    for (part in parts) {
        if (part.size > 0) {
            result.add(part)
        }
    }
    return result.toArray()
}

/**
 * 序列化 id 列表为存储格式。
 */
private func serializeSettingsSearchIds(ids: Array<String>): String {
    var s: String = ""
    var i: Int64 = 0
    while (i < Int64(ids.size)) {
        if (i > 0) {
            s = s + SETTINGS_RECENT_SEARCH_SEP
        }
        s = s + ids[i]
        i = i + 1
    }
    return s
}

/**
 * 插入 id 到最近列表头部（去重，裁剪到 SETTINGS_RECENT_SEARCH_MAX），对位
 * SettingsSearchRecentQueries.swift:39-54。
 */
private func insertRecentSettingsSearchId(existing: Array<String>, newId: String): Array<String> {
    let list = ArrayList<String>()
    list.add(newId)
    for (e in existing) {
        if (e != newId && Int32(list.size) < SETTINGS_RECENT_SEARCH_MAX) {
            list.add(e)
        }
    }
    return list.toArray()
}

/**
 * F3 修法（diag-suite_settings_root-TC-0076.md 修法 M3-a）：从最近列表按 id 删一条，对位
 * SettingsSearchRecentQueries.swift:47-53。id 不存在时原样返回（幂等）。
 */
private func removeRecentSettingsSearchId(existing: Array<String>, id: String): Array<String> {
    let list = ArrayList<String>()
    for (e in existing) {
        if (e != id) {
            list.add(e)
        }
    }
    return list.toArray()
}

/**
 * id 是否全为 ASCII 字符——对位 SettingsSearchRecentQueries.swift:39-54「id 非 ASCII 时
 * 静默不写入」。用码点判断（LocationPage.cj:293-295 UInt32(ch) 已验证同码点转换用法），
 * 不引入未经验证的 Rune 方法。
 */
private func isAsciiSettingsSearchId(id: String): Bool {
    for (ch in id.toRuneArray()) {
        if (UInt32(ch) >= 128) {
            return false
        }
    }
    return true
}

private var _settingsPageServiceInstance: Option<SettingsPageService> = None

public func getSettingsPageService(): SettingsPageService {
    match (_settingsPageServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SettingsPageService()
            _settingsPageServiceInstance = Some(inst)
            return inst
    }
}
