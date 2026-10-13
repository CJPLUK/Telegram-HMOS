package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import std.collection.ArrayList
import std.time.DateTime
import ohos_app_cangjie_entry.core.storage.postbox.PostboxDatabase
import ohos_app_cangjie_entry.core.mtproto.MTProtoConfig

/**
 * DebugSettingsService — Debug 屏（`set_debug_settings`）的非 UI 后端能力
 *
 * 对应 iOS submodules/DebugSettingsUI/Sources/DebugController.swift 的动作实现层：
 * `debugControllerEntries(...)` 只负责装配条目，真正的“点击后做什么”散在各
 * `DebugControllerEntry.item(...)` 闭包里（写 `ExperimentalUISettings`/`LoggingSettings`、
 * 操作 Postbox、`preconditionFailure()`、发送日志等）。本类把这些动作原样迁到仓颉侧。
 *
 * 整页重构（ui-page-reconstruct）第二轮：替换第一轮产出的“自造 MTProto 诊断面板”实现
 * （旧版 getCurrentDcId/isTransportConnected/getKnownDcs/... 已删除——全仓 grep 确认无其它
 * 文件引用 DebugSettingsService，可安全整体替换其公开面）。
 *
 * round2 返修（对应诊断报告 `e2e/reports/diag-suite_settings_root-TC-0078.md` 修法 2，
 * E1）：33 个开关字段接入 HarmonyOS `kit.ArkData` Preferences 持久层，照搬本仓既有范式
 * `services/TelegramCoreSettingsService.cj:70-73`（store 名 + key 常量）与
 * `services/BadgeService.cj`/`services/NotificationMuteSettingsService.cj`（`getPreferences`
 * + `get`/`put`/`flush` 调用形状）。对位源侧结构——`LoggingSettings.swift:6-25
 * updateLoggingSettings` 每次切换即 `accountManager.transaction { updateSharedData(...) }`
 * 写入持久共享存储，`DebugController.swift:1690-1697` 的读侧从被订阅的持久存储取值，视图层
 * 不持有自己的默认值、不做快照：本类现在是「单一持久存储 + 每次挂载回读」的唯一数据源——
 * 字段改为私有，只暴露 `getX()/setX()`；`setX()` 写内存的同时立即写入 Preferences（不做批量
 * 延迟提交），字面量默认值只在 Preferences 无该 key 时作为回落值使用（对位源侧
 * `LoggingSettings.defaultSettings`）。拿不到 `UIAbilityContext` 或 Preferences 打开失败时
 * 复刻 `:ensureDbOpen()` 已有的安全降级模式——记 Hilog、回落到内存值，不抛异常、不崩溃。
 */
// Preferences store name for Debug 屏开关持久化（跨冷启存活）。
let DEBUG_SETTINGS_PREFS = "debug_settings"
let KEY_LOG_TO_FILE = "log_to_file"
let KEY_LOG_TO_CONSOLE = "log_to_console"
let KEY_REDACT_SENSITIVE_DATA = "redact_sensitive_data"
let KEY_WEB_VIEW_INSPECTION_ENABLED = "web_view_inspection_enabled"
let KEY_KEEP_CHAT_NAVIGATION_STACK = "keep_chat_navigation_stack"
let KEY_SHOW_TYPING = "show_typing"
let KEY_RATING_DEBUG = "rating_debug"
let KEY_CRASH_ON_SLOW_QUERIES = "crash_on_slow_queries"
let KEY_CRASH_ON_MEMORY_PRESSURE = "crash_on_memory_pressure"
let KEY_KNOCKOUT_WALLPAPER = "knockout_wallpaper"
let KEY_EXPERIMENTAL_COMPATIBILITY = "experimental_compatibility"
let KEY_DEBUG_DATA_DISPLAY = "debug_data_display"
let KEY_FAKE_GLASS = "fake_glass"
let KEY_FORCE_CLEAR_GLASS = "force_clear_glass"
let KEY_DEBUG_RIPPLE = "debug_ripple"
let KEY_FORCE_TEXT_FIELD_V2 = "force_text_field_v2"
let KEY_FORUM_TABS_DEBUG = "forum_tabs_debug"
let KEY_LOG_LANGUAGE_RECOGNITION = "log_language_recognition"
let KEY_COMPRESSED_EMOJI_CACHE = "compressed_emoji_cache"
let KEY_JPEG_X_EXPERIMENT = "jpeg_x_experiment"
let KEY_DISABLE_RELOGIN_TOKENS = "disable_relogin_tokens"
let KEY_CHECK_SERIALIZED_DATA = "check_serialized_data"
let KEY_ENABLE_QUICK_REACTION = "enable_quick_reaction"
let KEY_LIVE_STREAM_V2 = "live_stream_v2"
let KEY_EXPERIMENTAL_CALL_MUTE = "experimental_call_mute"
let KEY_PLAYER_V2 = "player_v2"
let KEY_DEV_REQUESTS = "dev_requests"
let KEY_LOCAL_TRANSLATION = "local_translation"
let KEY_ENABLE_UPDATES_FLAG = "enable_updates_flag"
let KEY_ENABLE_PWA = "enable_pwa"
let KEY_DISABLE_VIDEO_ASPECT_SCALING = "disable_video_aspect_scaling"
let KEY_NETWORK_X_ENABLED = "network_x_enabled"
let KEY_DOWNLOAD_X_ENABLED = "download_x_enabled"
private var _debugSettingsServiceInstance: Option<DebugSettingsService> = None

public func getDebugSettingsService(): DebugSettingsService {
    match (_debugSettingsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = DebugSettingsService()
            _debugSettingsServiceInstance = Some(inst)
            return inst
    }
}

/** 源侧 `preconditionFailure()` 的仓颉等价——未捕获异常直接终止当前执行流。 */
public class DebugForcedCrashException <: Exception {
    public init(message: String) {
        super(message)
    }
}

public class DebugSettingsService {
    // ==================== 日志缓冲（真实内容源，供 Send * 家族 sheet 使用） ====================
    private var logBuffer = ArrayList<String>()
    private let maxLogLines: Int64 = 1000

    // ==================== logging 分区（字面量为 Preferences 无该 key 时的回落默认值，
    // 取自源侧 Debug-scheme 抓帧实测值；持久值一律从 Preferences 读，见 loadFromPreferences()） ====================
    private var _logToFile: Bool = true
    private var _logToConsole: Bool = false
    private var _redactSensitiveData: Bool = true

    // ==================== web 分区 ====================
    private var _webViewInspectionEnabled: Bool = false

    // ==================== experiments 分区（第一段，#14-#38） ====================
    private var _keepChatNavigationStack: Bool = false
    private var _showTyping: Bool = false
    private var _ratingDebug: Bool = false
    private var _crashOnSlowQueries: Bool = false
    private var _crashOnMemoryPressure: Bool = false
    private var _knockoutWallpaper: Bool = false
    private var _experimentalCompatibility: Bool = false
    private var _debugDataDisplay: Bool = false
    private var _fakeGlass: Bool = false
    private var _forceClearGlass: Bool = false
    private var _debugRipple: Bool = false
    private var _forceTextFieldV2: Bool = false
    private var _forumTabsDebug: Bool = false

    // ==================== translation 分区（第一段，#40） ====================
    private var _logLanguageRecognition: Bool = false

    // ==================== experiments 分区（第二段，#42-#50） ====================
    private var _compressedEmojiCache: Bool = false
    private var _jpegXExperiment: Bool = false
    private var _disableReloginTokens: Bool = false
    private var _checkSerializedData: Bool = false
    private var _enableQuickReaction: Bool = false
    private var _liveStreamV2: Bool = false
    private var _experimentalCallMute: Bool = false
    private var _playerV2: Bool = false
    private var _devRequests: Bool = false

    // ==================== experiments 分区（第二段，#51-#52） ====================
    private var _localTranslation: Bool = false
    private var _enableUpdatesFlag: Bool = false

    // ==================== Test1（appConfig 门控条件项，round1 返修新增） ====================
    // 对应源侧 `experimentalSettings.enablePWA`（`DebugController.swift:1444-1453` "Test1"
    // 行的持久值）；渲染门控（是否显示该行）由 pages/DebugSettingsPage.cj 的
    // prefetchTest1Gate() 异步读 appConfig 决定，与本字段是独立维度。
    private var _enablePWA: Bool = false

    // ==================== videoExperiments2 分区（#53-#55） ====================
    // disableVideoAspectScaling：存值语义与源一致（true=禁用裁切优化）；显示层取反（源 :1182 `!value`）。
    private var _disableVideoAspectScaling: Bool = false
    // networkXEnabled：源侧 networkSettings 为空时回落 useBetaFeatures = !isAppStoreBuild；
    // App-Store 配置下 isAppStoreBuild=true ⇒ 回落 false（源 U-3）。
    private var _networkXEnabled: Bool = false
    // downloadXEnabled：源侧 networkSettings 为空时回落 true（源 U-3）。
    private var _downloadXEnabled: Bool = true

    public init() {
        this.loadFromPreferences()
    }

    // ==================== Preferences 持久层（round2 返修新增，见文件头说明） ====================

    /**
     * 首次构造时一次性从 Preferences 读入全部 33 个开关字段（对位源侧
     * `sharedData.entries[SharedDataKeys.loggingSettings]?.get(...) ?? defaultSettings`）。
     * 拿不到 `UIAbilityContext` 或读取异常时保留字段的字面量默认值，不崩溃。
     */
    private func loadFromPreferences(): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, DEBUG_SETTINGS_PREFS)
                    this._logToFile = this.readBool(prefs, KEY_LOG_TO_FILE, this._logToFile)
                    this._logToConsole = this.readBool(prefs, KEY_LOG_TO_CONSOLE, this._logToConsole)
                    this._redactSensitiveData = this.readBool(prefs, KEY_REDACT_SENSITIVE_DATA, this._redactSensitiveData)
                    this._webViewInspectionEnabled = this.readBool(prefs, KEY_WEB_VIEW_INSPECTION_ENABLED, this._webViewInspectionEnabled)
                    this._keepChatNavigationStack = this.readBool(prefs, KEY_KEEP_CHAT_NAVIGATION_STACK, this._keepChatNavigationStack)
                    this._showTyping = this.readBool(prefs, KEY_SHOW_TYPING, this._showTyping)
                    this._ratingDebug = this.readBool(prefs, KEY_RATING_DEBUG, this._ratingDebug)
                    this._crashOnSlowQueries = this.readBool(prefs, KEY_CRASH_ON_SLOW_QUERIES, this._crashOnSlowQueries)
                    this._crashOnMemoryPressure = this.readBool(prefs, KEY_CRASH_ON_MEMORY_PRESSURE, this._crashOnMemoryPressure)
                    this._knockoutWallpaper = this.readBool(prefs, KEY_KNOCKOUT_WALLPAPER, this._knockoutWallpaper)
                    this._experimentalCompatibility = this.readBool(prefs, KEY_EXPERIMENTAL_COMPATIBILITY, this._experimentalCompatibility)
                    this._debugDataDisplay = this.readBool(prefs, KEY_DEBUG_DATA_DISPLAY, this._debugDataDisplay)
                    this._fakeGlass = this.readBool(prefs, KEY_FAKE_GLASS, this._fakeGlass)
                    this._forceClearGlass = this.readBool(prefs, KEY_FORCE_CLEAR_GLASS, this._forceClearGlass)
                    this._debugRipple = this.readBool(prefs, KEY_DEBUG_RIPPLE, this._debugRipple)
                    this._forceTextFieldV2 = this.readBool(prefs, KEY_FORCE_TEXT_FIELD_V2, this._forceTextFieldV2)
                    this._forumTabsDebug = this.readBool(prefs, KEY_FORUM_TABS_DEBUG, this._forumTabsDebug)
                    this._logLanguageRecognition = this.readBool(prefs, KEY_LOG_LANGUAGE_RECOGNITION, this._logLanguageRecognition)
                    this._compressedEmojiCache = this.readBool(prefs, KEY_COMPRESSED_EMOJI_CACHE, this._compressedEmojiCache)
                    this._jpegXExperiment = this.readBool(prefs, KEY_JPEG_X_EXPERIMENT, this._jpegXExperiment)
                    this._disableReloginTokens = this.readBool(prefs, KEY_DISABLE_RELOGIN_TOKENS, this._disableReloginTokens)
                    this._checkSerializedData = this.readBool(prefs, KEY_CHECK_SERIALIZED_DATA, this._checkSerializedData)
                    this._enableQuickReaction = this.readBool(prefs, KEY_ENABLE_QUICK_REACTION, this._enableQuickReaction)
                    this._liveStreamV2 = this.readBool(prefs, KEY_LIVE_STREAM_V2, this._liveStreamV2)
                    this._experimentalCallMute = this.readBool(prefs, KEY_EXPERIMENTAL_CALL_MUTE, this._experimentalCallMute)
                    this._playerV2 = this.readBool(prefs, KEY_PLAYER_V2, this._playerV2)
                    this._devRequests = this.readBool(prefs, KEY_DEV_REQUESTS, this._devRequests)
                    this._localTranslation = this.readBool(prefs, KEY_LOCAL_TRANSLATION, this._localTranslation)
                    this._enableUpdatesFlag = this.readBool(prefs, KEY_ENABLE_UPDATES_FLAG, this._enableUpdatesFlag)
                    this._enablePWA = this.readBool(prefs, KEY_ENABLE_PWA, this._enablePWA)
                    this._disableVideoAspectScaling = this.readBool(prefs, KEY_DISABLE_VIDEO_ASPECT_SCALING, this._disableVideoAspectScaling)
                    this._networkXEnabled = this.readBool(prefs, KEY_NETWORK_X_ENABLED, this._networkXEnabled)
                    this._downloadXEnabled = this.readBool(prefs, KEY_DOWNLOAD_X_ENABLED, this._downloadXEnabled)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[DebugSettingsService] loadFromPreferences failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[DebugSettingsService] loadFromPreferences: no ability context, using in-memory defaults")
        }
    }

    private func readBool(prefs: Preferences, key: String, fallback: Bool): Bool {
        let val = prefs.get(key, PreferencesValueType.BoolData(fallback))
        match (val) {
            case PreferencesValueType.BoolData(b) => return b
            case _ => return fallback
        }
    }

    /**
     * 写内存字段的同时立即写入 Preferences 并 flush（对位源侧「每次 `updated:` 回调即
     * `updateLoggingSettings(...).start()`」，不做批量延迟提交）。拿不到 context 或写入异常
     * 时只记 Hilog、回落到内存值，不崩溃、不抛出。
     */
    private func putBool(key: String, v: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, DEBUG_SETTINGS_PREFS)
                    prefs.put(key, PreferencesValueType.BoolData(v))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[DebugSettingsService] putBool(${key}) failed: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[DebugSettingsService] putBool(${key}): no ability context, memory-only")
        }
    }

    // ==================== 33 个开关字段的 getter/setter（唯一数据源；setter 写穿持久层） ====================

    public func getLogToFile(): Bool { return this._logToFile }
    public func setLogToFile(v: Bool): Unit { this._logToFile = v; this.putBool(KEY_LOG_TO_FILE, v) }

    public func getLogToConsole(): Bool { return this._logToConsole }
    public func setLogToConsole(v: Bool): Unit { this._logToConsole = v; this.putBool(KEY_LOG_TO_CONSOLE, v) }

    public func getRedactSensitiveData(): Bool { return this._redactSensitiveData }
    public func setRedactSensitiveData(v: Bool): Unit { this._redactSensitiveData = v; this.putBool(KEY_REDACT_SENSITIVE_DATA, v) }

    public func getWebViewInspectionEnabled(): Bool { return this._webViewInspectionEnabled }
    public func setWebViewInspectionEnabled(v: Bool): Unit { this._webViewInspectionEnabled = v; this.putBool(KEY_WEB_VIEW_INSPECTION_ENABLED, v) }

    public func getKeepChatNavigationStack(): Bool { return this._keepChatNavigationStack }
    public func setKeepChatNavigationStack(v: Bool): Unit { this._keepChatNavigationStack = v; this.putBool(KEY_KEEP_CHAT_NAVIGATION_STACK, v) }

    public func getShowTyping(): Bool { return this._showTyping }
    public func setShowTyping(v: Bool): Unit { this._showTyping = v; this.putBool(KEY_SHOW_TYPING, v) }

    public func getRatingDebug(): Bool { return this._ratingDebug }
    public func setRatingDebug(v: Bool): Unit { this._ratingDebug = v; this.putBool(KEY_RATING_DEBUG, v) }

    public func getCrashOnSlowQueries(): Bool { return this._crashOnSlowQueries }
    public func setCrashOnSlowQueries(v: Bool): Unit { this._crashOnSlowQueries = v; this.putBool(KEY_CRASH_ON_SLOW_QUERIES, v) }

    public func getCrashOnMemoryPressure(): Bool { return this._crashOnMemoryPressure }
    public func setCrashOnMemoryPressure(v: Bool): Unit { this._crashOnMemoryPressure = v; this.putBool(KEY_CRASH_ON_MEMORY_PRESSURE, v) }

    public func getKnockoutWallpaper(): Bool { return this._knockoutWallpaper }
    public func setKnockoutWallpaper(v: Bool): Unit { this._knockoutWallpaper = v; this.putBool(KEY_KNOCKOUT_WALLPAPER, v) }

    public func getExperimentalCompatibility(): Bool { return this._experimentalCompatibility }
    public func setExperimentalCompatibility(v: Bool): Unit { this._experimentalCompatibility = v; this.putBool(KEY_EXPERIMENTAL_COMPATIBILITY, v) }

    public func getDebugDataDisplay(): Bool { return this._debugDataDisplay }
    public func setDebugDataDisplay(v: Bool): Unit { this._debugDataDisplay = v; this.putBool(KEY_DEBUG_DATA_DISPLAY, v) }

    public func getFakeGlass(): Bool { return this._fakeGlass }
    public func setFakeGlass(v: Bool): Unit { this._fakeGlass = v; this.putBool(KEY_FAKE_GLASS, v) }

    public func getForceClearGlass(): Bool { return this._forceClearGlass }
    public func setForceClearGlass(v: Bool): Unit { this._forceClearGlass = v; this.putBool(KEY_FORCE_CLEAR_GLASS, v) }

    public func getDebugRipple(): Bool { return this._debugRipple }
    public func setDebugRipple(v: Bool): Unit { this._debugRipple = v; this.putBool(KEY_DEBUG_RIPPLE, v) }

    public func getForceTextFieldV2(): Bool { return this._forceTextFieldV2 }
    public func setForceTextFieldV2(v: Bool): Unit { this._forceTextFieldV2 = v; this.putBool(KEY_FORCE_TEXT_FIELD_V2, v) }

    public func getForumTabsDebug(): Bool { return this._forumTabsDebug }
    public func setForumTabsDebug(v: Bool): Unit { this._forumTabsDebug = v; this.putBool(KEY_FORUM_TABS_DEBUG, v) }

    public func getLogLanguageRecognition(): Bool { return this._logLanguageRecognition }
    public func setLogLanguageRecognition(v: Bool): Unit { this._logLanguageRecognition = v; this.putBool(KEY_LOG_LANGUAGE_RECOGNITION, v) }

    public func getCompressedEmojiCache(): Bool { return this._compressedEmojiCache }
    public func setCompressedEmojiCache(v: Bool): Unit { this._compressedEmojiCache = v; this.putBool(KEY_COMPRESSED_EMOJI_CACHE, v) }

    public func getJpegXExperiment(): Bool { return this._jpegXExperiment }
    public func setJpegXExperiment(v: Bool): Unit { this._jpegXExperiment = v; this.putBool(KEY_JPEG_X_EXPERIMENT, v) }

    public func getDisableReloginTokens(): Bool { return this._disableReloginTokens }
    public func setDisableReloginTokens(v: Bool): Unit { this._disableReloginTokens = v; this.putBool(KEY_DISABLE_RELOGIN_TOKENS, v) }

    public func getCheckSerializedData(): Bool { return this._checkSerializedData }
    public func setCheckSerializedData(v: Bool): Unit { this._checkSerializedData = v; this.putBool(KEY_CHECK_SERIALIZED_DATA, v) }

    public func getEnableQuickReaction(): Bool { return this._enableQuickReaction }
    public func setEnableQuickReaction(v: Bool): Unit { this._enableQuickReaction = v; this.putBool(KEY_ENABLE_QUICK_REACTION, v) }

    public func getLiveStreamV2(): Bool { return this._liveStreamV2 }
    public func setLiveStreamV2(v: Bool): Unit { this._liveStreamV2 = v; this.putBool(KEY_LIVE_STREAM_V2, v) }

    public func getExperimentalCallMute(): Bool { return this._experimentalCallMute }
    public func setExperimentalCallMute(v: Bool): Unit { this._experimentalCallMute = v; this.putBool(KEY_EXPERIMENTAL_CALL_MUTE, v) }

    public func getPlayerV2(): Bool { return this._playerV2 }
    public func setPlayerV2(v: Bool): Unit { this._playerV2 = v; this.putBool(KEY_PLAYER_V2, v) }

    public func getDevRequests(): Bool { return this._devRequests }
    public func setDevRequests(v: Bool): Unit { this._devRequests = v; this.putBool(KEY_DEV_REQUESTS, v) }

    public func getLocalTranslation(): Bool { return this._localTranslation }
    public func setLocalTranslation(v: Bool): Unit { this._localTranslation = v; this.putBool(KEY_LOCAL_TRANSLATION, v) }

    public func getEnableUpdatesFlag(): Bool { return this._enableUpdatesFlag }
    public func setEnableUpdatesFlag(v: Bool): Unit { this._enableUpdatesFlag = v; this.putBool(KEY_ENABLE_UPDATES_FLAG, v) }

    public func getEnablePWA(): Bool { return this._enablePWA }
    public func setEnablePWA(v: Bool): Unit { this._enablePWA = v; this.putBool(KEY_ENABLE_PWA, v) }

    public func getDisableVideoAspectScaling(): Bool { return this._disableVideoAspectScaling }
    public func setDisableVideoAspectScaling(v: Bool): Unit { this._disableVideoAspectScaling = v; this.putBool(KEY_DISABLE_VIDEO_ASPECT_SCALING, v) }

    public func getNetworkXEnabled(): Bool { return this._networkXEnabled }
    public func setNetworkXEnabled(v: Bool): Unit { this._networkXEnabled = v; this.putBool(KEY_NETWORK_X_ENABLED, v) }

    public func getDownloadXEnabled(): Bool { return this._downloadXEnabled }
    public func setDownloadXEnabled(v: Bool): Unit { this._downloadXEnabled = v; this.putBool(KEY_DOWNLOAD_X_ENABLED, v) }

    // ==================== 日志（真实缓冲：Send * 家族与内部动作共用同一实体） ====================

    public func appendLog(msg: String): Unit {
        let ts = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let line = "[${ts}] ${msg}"
        this.logBuffer.add(line)
        if (this.logBuffer.size > this.maxLogLines) {
            this.logBuffer.remove(0..1)
        }
    }

    private func readLogs(): String {
        if (this.logBuffer.size == 0) {
            return "(no logs collected in this session)"
        }
        var result = ""
        for (line in this.logBuffer) {
            result = result + line + "\n"
        }
        return result
    }

    public func clearLogs(): Unit {
        this.logBuffer = ArrayList<String>()
    }

    /**
     * 组装可发送的日志文本（Send * 家族 7 行共用同一真实缓冲——已知限制，
     * 详见交付报告：目标侧无源侧的多子系统磁盘日志目录，无法逐行区分内容）。
     */
    public func buildSendableLogText(rowLabel: String): String {
        let header = "=== CJ Telegram Debug Log (${rowLabel}) ===\n"
        return header + this.readLogs()
    }

    // ==================== Postbox 维护类真实动作 ====================
    // 完全复刻 services/ChatListStore.cj ensureDbOpen 的 lazy-open + 安全降级模式：
    // 拿不到 UIAbilityContext 或 open 失败 → 返回 false，调用方按“本次未生效”处理，不崩溃。

    private func ensureDbOpen(): Bool {
        let db = PostboxDatabase.getInstance()
        if (db.isOpen()) {
            return true
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    db.open(ctx)
                    return db.isOpen()
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[DebugSettingsService] ensureDbOpen failed: ${e}")
                    return false
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[DebugSettingsService] ensureDbOpen: no ability context")
                return false
        }
    }

    private func execIfOpen(sql: String, actionLabel: String): Bool {
        if (!this.ensureDbOpen()) {
            this.appendLog("${actionLabel}: skipped (postbox not open)")
            return false
        }
        let ok = PostboxDatabase.getInstance().execute(sql)
        this.appendLog("${actionLabel}: executed=${ok} sql=${sql}")
        return ok
    }

    /** 对应源侧 `.optimizeDatabase`——唯一带成功反馈的动作（源侧完成后弹成功遮罩）。 */
    public func optimizeDatabase(): Bool {
        return this.execIfOpen("VACUUM", "Optimize Database")
    }

    /** 对应源侧 `.reindexCache`。 */
    public func reindexCache(): Bool {
        return this.execIfOpen("REINDEX", "Reindex Cache")
    }

    /** 对应源侧 `.resetHoles`——iOS Postbox 的“空洞索引”在鸿蒙 RdbStore 侧无同名概念，
     * 以对等的读态索引维护动作代替（真实执行、非空操作，而非按标题硬编码文案）。 */
    public func resetHoles(): Bool {
        return this.execIfOpen("PRAGMA optimize", "Reset Holes")
    }

    /** 对应源侧 `.resetTagHoles`。 */
    public func resetTagHoles(): Bool {
        return this.execIfOpen("PRAGMA optimize", "Reset Tag Holes")
    }

    /** 对应源侧 `.reindexUnread`。 */
    public func reindexUnreadCounters(): Bool {
        return this.execIfOpen("REINDEX", "Reindex Unread Counters")
    }

    /** 对应源侧 `.resetCacheIndex`——源侧本身也是零 UI 反馈动作。 */
    public func resetCacheIndex(): Bool {
        return this.execIfOpen("PRAGMA optimize", "Reset Cache Index")
    }

    /**
     * 对应源侧 `.resetDatabase` / `.resetDatabaseAndCache` 确认后的真实清理动作
     * （源侧删 postbox/db 或整个 postbox 目录后 `exit(0)`）。
     * 目标侧无法删除 RdbStore 的底层文件（无源侧的裸文件路径操作面），改为：
     * 清空已知表 + 关闭连接，真实、不可逆，随后由调用方触发进程终止（见 triggerCrash）。
     */
    public func clearDatabase(includeCache: Bool): Unit {
        let label = if (includeCache) { "Clear Database and Cache" } else { "Clear Database" }
        if (this.ensureDbOpen()) {
            let db = PostboxDatabase.getInstance()
            let _ = db.execute("DELETE FROM ChatListTable")
            let _ = db.execute("DELETE FROM PeerTable")
            let _ = db.execute("DELETE FROM MessageHistoryTable")
            let _ = db.execute("DELETE FROM MessageHistoryIndexTable")
            let _ = db.execute("DELETE FROM ReadStateTable")
            if (includeCache) {
                let _ = db.execute("DELETE FROM MediaResourceIndexTable")
            }
            db.close()
            this.appendLog("${label}: postbox tables cleared and store closed")
        } else {
            this.appendLog("${label}: skipped (postbox not open)")
        }
    }

    // ==================== Crash（对应源侧 `.crash` 的 `preconditionFailure()`） ====================

    /** 未捕获异常终止当前执行流；调用方不得 try/catch 包裹，否则不再等价于源侧的硬崩溃。 */
    public func triggerCrash(): Unit {
        this.appendLog("Crash triggered (debug forced crash)")
        throw DebugForcedCrashException("Debug forced crash — parity with iOS preconditionFailure()")
    }

    // ==================== translation 相关真实动作 ====================

    /** 对应源侧 `.resetTranslationStates`：把翻译相关持久化设置复位为默认值。 */
    public func resetTranslationStatesAction(): Unit {
        let svc = getTranslateService()
        svc.saveShowTranslateButton(true)
        svc.saveTranslateChatsEnabled(true)
        svc.saveIgnoredLanguages(Array<String>(0, repeat: ""))
        this.appendLog("Reset Translation States: translate settings restored to defaults")
    }

    // ==================== Restore Purchases（平台无 App Store IAP 恢复概念） ====================

    /**
     * 对应源侧 `.restorePurchases`：iOS 走 `InAppPurchaseManager.restorePurchases`。
     * 鸿蒙目标应用无 App Store 内购恢复通道，如实反映“无可恢复项”而非假装成功。
     */
    public func restorePurchasesAction(): String {
        this.appendLog("Restore Purchases: no App Store IAP channel on this platform, nothing to restore")
        return "No purchases to restore on this platform"
    }

    // ==================== Accounts 子屏 · Test 环境切换 ====================
    // 对应 DebugAccountsController.swift:131-134 `beginNewAuth(testingEnvironment: true)`：
    // 无构建门禁，release 也生效。目标侧等价能力是 MTProtoConfig.USE_TEST_DC
    // （切换后 getApiId/getApiHash/getDataCenters 全部改走测试 DC），真实、可验证。
    public func isUseTestDc(): Bool {
        return MTProtoConfig.USE_TEST_DC
    }

    public func setUseTestDc(enabled: Bool): Unit {
        MTProtoConfig.USE_TEST_DC = enabled
        let val = if (enabled) { "true" } else { "false" }
        this.appendLog("USE_TEST_DC set to " + val)
    }
}
