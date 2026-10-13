package ohos_app_cangjie_entry.core.storage

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{Base64, SHA256, ByteUtils}
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import std.time.DateTime
import std.convert.*
import std.collection.ArrayList

// ==================== D-177: 依赖倒置登出回调（core.storage 不得反向 import services）====================
// `services` 包已单向依赖 `core.storage`（约 23 个文件 import 本包）；任何要求本包反向直接
// import/调用 `services` 包函数的接线都会被 cjpm 判定为循环依赖拒绝构建（core/storage/AppTheme.cj
// registerPresentationExtrasProvider() 已有实证）。凡是需要在 clearAll() 登出时触发一个只存在于
// `services` 包里的失效逻辑（如 ic_wbs_cache_invalidate_on_logout 要求的
// services/SettingsService.cj.invalidateWebBrowserSettingsCache()），一律走这里的回调注册表：
// `services` 侧在自己单例的惰性构造分支里（参照 services/ThemesEngineService.cj 里向
// registerPresentationExtrasProvider 注册的既有写法）调用 registerLogoutHook(...) 把自己包装成
// 一个无参闭包传入；clearAll() 按注册顺序逐个调用，本文件全程不出现任何 `import
// ohos_app_cangjie_entry.services` 字样。
var _logoutHooks: ArrayList<() -> Unit> = ArrayList<() -> Unit>()

/**
 * 供 `services` 包的单例服务在构造时注册一个"登出时应清理/失效"的回调。
 * 典型消费者：services/SettingsService.cj 注册 invalidateWebBrowserSettingsCache()，
 * 使 telegram_web_browser_settings Preferences store 随每条 clearAll() 登出路径失效
 * （对齐 telegram_stickers_cache/telegram_themes_cache/telegram_item_cache/
 * telegram_contacts_settings 已有的同类清除）。
 */
public func registerLogoutHook(hook: () -> Unit): Unit {
    _logoutHooks.add(hook)
}

/**
 * 存储的用户数据
 */
public class StoredUserData {
    public var id: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var phone: String = ""
    public var isPremium: Bool = false
}

/**
 * 账户信息 DTO — 用于 AccountManager 对外暴露当前账户
 * 对应 iOS Account 的 user 信息
 */
public class AccountInfo {
    public var userId: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var phone: String = ""
    public var username: String = ""
}

/**
 * 存储的会话数据
 */
public class StoredSessionData {
    public var dcId: Int64 = 0
    public var authKey: String = ""       // Base64 encoded
    public var authKeyId: String = ""     // Base64 encoded
    public var serverSalt: String = ""    // Base64 encoded
    public var authKeyState: Int32 = 0
}

/**
 * 完整的认证数据
 */
public class StoredAuthData {
    public var user: Option<StoredUserData> = None
    public var session: Option<StoredSessionData> = None
    public var authState: Int32 = 0
    public var timestamp: Int64 = 0
}

/**
 * 认证存储管理器 (P2-318a: 多 slot 分区版本)
 *
 * 设计：
 *   - 所有认证数据按 account slot 分区存储，key 格式: "slot_<n>_<original_key>"
 *   - activeSlot 存储在全局 key "active_slot"（无前缀），默认 0
 *   - 所有现有 getter/setter 保持签名不变，内部路由到 activeSlot 对应的分区
 *   - 单账号用户 activeSlot=0，行为与改前完全一致（字节级回归安全）
 *   - 首次运行迁移：若旧 fixed-key 数据存在且 slot_0 空，自动迁移到 slot_0
 *
 * 对应 iOS AccountRecord/AccountManagerImpl 的 slot 概念
 *
 * 使用 HarmonyOS Preferences API (用户首选项) 进行持久化存储
 * 数据在 App 重启后仍然保留（除非卸载/清除数据）
 *
 * PreferencesValueType 枚举成员（注意大小写）：
 *   - PreferencesValueType.Integer(Int64) 存储整数
 *   - PreferencesValueType.StringData(String) 存储字符串
 *   - PreferencesValueType.BoolData(Bool)     存储布尔值
 *   - PreferencesValueType.Float64Data(Float64) 存储浮点数
 */

// ==================== 全局 slot 管理 key（无前缀） ====================

// 当前活跃 slot 编号持久化 key
let KEY_ACTIVE_SLOT = "active_slot"

// 已用 slot 记录（逗号分隔的整数字符串，如 "0,1,2"）
let KEY_SLOT_LIST = "slot_list"

// QA-3 fix: 引导/登录流程是否已开始（用户点击过 Start Messaging，但尚未完成登录）。
// 全局 key（无 slot 前缀）——在任何账号 slot 确定之前就可能被设置，且必须在 clearAll()
// (logout/reset) 时清除，使得重新登录时 intro 页正确再次出现。
let KEY_ONBOARDING_STARTED = "onboarding_started"

// TC-0086 fix: 正在进行、尚未授权的登录所占用的 slot，与 KEY_ACTIVE_SLOT（当前已授权账号）
// 完全分离的第二个指针。镜像 iOS AccountManagerMetadataTable 的
// currentAccountId(=KEY_ACTIVE_SLOT) / currentAuthAccount(=KEY_PENDING_AUTH_SLOT) 双指针模型。
// addAccount() 只写这个 key（见 beginAuthSlot），不再触碰 KEY_ACTIVE_SLOT；这样任何一次被
// 强杀/放弃的添加账号流程都不会挪动"当前账号"指针，原账号在下次冷启动仍可正常解析。
let KEY_PENDING_AUTH_SLOT = "pending_auth_slot"

// ==================== 原始 key 名（不带 slot 前缀）====================
// 迁移时用于探测旧数据

let KEY_AUTH_STATE = "auth_state"
let KEY_USER_ID = "user_id"
let KEY_USER_FIRST_NAME = "user_firstName"
let KEY_USER_LAST_NAME = "user_lastName"
let KEY_USER_USERNAME = "user_username"
let KEY_USER_PHONE = "user_phone"
let KEY_USER_IS_PREMIUM = "user_isPremium"
let KEY_RENDERED_TOTAL_UNREAD = "rendered_total_unread"
let KEY_SESSION_DC_ID = "session_dcId"
let KEY_SESSION_AUTH_KEY = "session_authKey"
let KEY_SESSION_AUTH_KEY_ID = "session_authKeyId"
let KEY_SESSION_SERVER_SALT = "session_serverSalt"
let KEY_SESSION_AUTH_KEY_STATE = "session_authKeyState"

// Phase R1: 同步状态点
let KEY_SYNC_PTS = "sync_pts"
let KEY_SYNC_QTS = "sync_qts"
let KEY_SYNC_DATE = "sync_date"
let KEY_SYNC_SEQ = "sync_seq"

// Phase T4.4: 外观设置
let KEY_APPEARANCE_THEME = "appearance_theme"
let KEY_APPEARANCE_TEXT_SIZE = "appearance_text_size"

// Phase T4.4 extended: 动画设置
let KEY_APPEARANCE_ANIMATION = "appearance_animation"

// Phase P4-10: 语言设置
let KEY_LANG_CODE = "lang_code"
let KEY_LANG_BASE_CODE = "lang_base_code"

// Phase P2-164: 本地化持久化
let KEY_LOCALIZATION_SAVED_LIST = "localization_saved_list"
let KEY_COUNTRIES_CACHE_HASH = "countries_cache_hash"
let KEY_COUNTRIES_CACHE_DATA = "countries_cache_data"

// Phase P4-9: 下载设置
let KEY_DL_PHOTOS = "download_photos"
let KEY_DL_VIDEOS = "download_videos"
let KEY_DL_FILES = "download_files"
let KEY_DL_SAVE_GALLERY = "download_save_gallery"
let KEY_DL_DATA_SAVING = "download_data_saving"

// Chat background
let KEY_CHAT_BG_PATH = "chat_bg_path"

// Settings: Archive (keep archived unmuted)
let KEY_ARCHIVE_KEEP_UNMUTED = "archive_keep_unmuted"

// Settings: Power Saving (master + threshold + per-feature energy toggles)
let KEY_POWER_SAVING = "power_saving"
let KEY_PS_THRESHOLD = "ps_threshold"
let KEY_PS_AUTOPLAY_VIDEO = "ps_autoplay_video"
let KEY_PS_AUTOPLAY_GIF = "ps_autoplay_gif"
let KEY_PS_LOOP_STICKERS = "ps_loop_stickers"
let KEY_PS_LOOP_EMOJI = "ps_loop_emoji"
let KEY_PS_FULL_TRANSLUCENCY = "ps_full_translucency"
let KEY_PS_EXTEND_BG_WORK = "ps_extend_bg_work"
let KEY_PS_AUTODOWNLOAD_BG = "ps_autodownload_bg"

// Phase P4-7: 密码锁
let KEY_PASSCODE_HASH = "passcode_hash"
let KEY_AUTO_LOCK_MINUTES = "auto_lock_minutes"
let KEY_PASSCODE_FAILED_ATTEMPTS = "passcode_failed_attempts"
let KEY_PASSCODE_LOCKOUT_UNTIL = "passcode_lockout_until"
let KEY_PASSCODE_BIOMETRIC_ENABLED = "passcode_biometric_enabled"
// P2-267: passcode type (0=digits6, 1=digits4, 2=alphanumeric)
let KEY_PASSCODE_TYPE = "passcode_type"
// P2-269: 进入后台的时间戳（秒），持久化，用于自动锁定判定（跨重启）
let KEY_PASSCODE_BACKGROUND_TS = "passcode_background_ts"

// P2-272: 失败次数阈值（达到此次数开始首次锁定）
let PASSCODE_MAX_ATTEMPTS: Int32 = 5
// P2-272: 首次硬锁定时长（兼容旧行为）
let PASSCODE_LOCKOUT_SECONDS: Int64 = 60

// P2-272: iOS 对齐滚动限速延迟表（秒）
// iOS TelegramUI PasscodeEntryControllerNode: 6次→1min, 7次→5min, 8次→15min, 9次→30min, 10次→60min
// attempts >= 10 后保持 60min（不再递增）
// 实现：recordFailedAttempt 每次递增计数，lookup lockoutSecondsForAttemptCount()
func lockoutSecondsForAttemptCount(count: Int32): Int64 {
    if (count <= 5) { return 0 }
    if (count == 6) { return 60 }
    if (count == 7) { return 300 }
    if (count == 8) { return 900 }
    if (count == 9) { return 1800 }
    return 3600
}

// Phase P2-152: 2FA cached token
let KEY_2FA_TOKEN = "2fa_cached_token"
let KEY_2FA_TOKEN_VALID_UNTIL = "2fa_token_valid_until"

// Phase P2-153: AccountData — timezones list cache
let KEY_TIMEZONES_CACHE_HASH = "timezones_cache_hash"
let KEY_TIMEZONES_CACHE_JSON = "timezones_cache_json"

// Phase P2-156: Global privacy settings cache (local mirror of globalPrivacySettings)
let KEY_GLOBAL_PRIVACY_ARCHIVE_MUTE = "gp_archive_mute"
let KEY_GLOBAL_PRIVACY_KEEP_UNMUTED = "gp_keep_unmuted"
let KEY_GLOBAL_PRIVACY_HIDE_READ_MARKS = "gp_hide_read_marks"
let KEY_GLOBAL_PRIVACY_REQUIRE_PREMIUM = "gp_require_premium"

// Phase P2-153: AccountData — profile meta (local mirror of server state)
let KEY_PROFILE_BIRTHDAY_JSON = "profile_birthday_json"
let KEY_PROFILE_NAME_COLOR = "profile_name_color"
let KEY_PROFILE_BG_EMOJI_ID = "profile_bg_emoji_id"
let KEY_PROFILE_EMOJI_STATUS_DOC_ID = "profile_emoji_status_doc_id"
let KEY_PROFILE_EMOJI_STATUS_UNTIL = "profile_emoji_status_until"
let KEY_PROFILE_PERSONAL_CHANNEL_ID = "profile_personal_channel_id"

// 本地会话列表缓存（Postbox ChatListTable，全账号共用一张表）当前归属的 slot。
// 全局 key（不带 slot 前缀）：切换账号后另一账号的缓存行不得作为首屏 / 启动基线。
let KEY_CHAT_LIST_CACHE_OWNER_SLOT = "chat_list_cache_owner_slot"

private var _authStorageInstance: Option<AuthStorage> = None

public func getAuthStorage(): AuthStorage {
    match (_authStorageInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AuthStorage()
            _authStorageInstance = Some(inst)
            return inst
    }
}

public class AuthStorage {
    private var preferences: Option<Preferences> = None
    private var initialized: Bool = false
    private var abilityContext: Option<UIAbilityContext> = None

    // In-memory activeSlot cache (loaded from prefs on initialize, default 0)
    private var _activeSlot: Int32 = 0

    // TC-0086 fix: in-memory pendingAuthSlot cache (loaded from prefs on initialize, default -1 = none in progress)
    private var _pendingAuthSlot: Int32 = -1

    // ==================== 内部 slot key 辅助方法 ====================

    /**
     * 为给定 slot 编号和原始 key 生成带前缀的 slot key。
     * 格式: "slot_<n>_<originalKey>"
     */
    private func slottedKey(originalKey: String, slot: Int32): String {
        return "slot_${slot}_${originalKey}"
    }

    /**
     * 使用当前 activeSlot 生成 slotted key（简便重载）
     */
    private func sk(originalKey: String): String {
        return this.slottedKey(originalKey, this._activeSlot)
    }

    // ==================== 迁移：旧 fixed-key 数据 → slot_0 ====================

    /**
     * 首次运行迁移检查：
     *   若 Preferences 中存在旧 fixed-key 数据（无前缀），且 slot_0 对应 key 不存在，
     *   则将所有旧数据迁移到 slot_0 命名空间，然后删除旧 key。
     *
     * 保证：现有单账号用户的登录态不丢失。
     */
    private func migrateLegacyToSlot0IfNeeded(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                // 若 slot_0 的 auth_state 已存在，说明已迁移过，直接返回
                let slot0AuthKey = this.slottedKey(KEY_AUTH_STATE, 0)
                if (prefs.has(slot0AuthKey)) {
                    return
                }
                // 若旧 auth_state 也不存在，说明是全新安装，无需迁移
                if (!prefs.has(KEY_AUTH_STATE)) {
                    return
                }
                // 执行迁移：将所有旧 fixed-key 数据复制到 slot_0 前缀
                Hilog.info(0, "CjTelegram", "[AuthStorage] Migrating legacy single-account data to slot_0")
                let legacyKeys: Array<String> = [
                    KEY_AUTH_STATE, KEY_USER_ID, KEY_USER_FIRST_NAME, KEY_USER_LAST_NAME,
                    KEY_USER_USERNAME, KEY_USER_PHONE, KEY_USER_IS_PREMIUM,
                    KEY_SESSION_DC_ID, KEY_SESSION_AUTH_KEY, KEY_SESSION_AUTH_KEY_ID,
                    KEY_SESSION_SERVER_SALT, KEY_SESSION_AUTH_KEY_STATE,
                    KEY_SYNC_PTS, KEY_SYNC_QTS, KEY_SYNC_DATE, KEY_SYNC_SEQ,
                    KEY_APPEARANCE_THEME, KEY_APPEARANCE_TEXT_SIZE, KEY_APPEARANCE_ANIMATION,
                    KEY_LANG_CODE, KEY_LANG_BASE_CODE, KEY_LOCALIZATION_SAVED_LIST,
                    KEY_COUNTRIES_CACHE_HASH, KEY_COUNTRIES_CACHE_DATA,
                    KEY_DL_PHOTOS, KEY_DL_VIDEOS, KEY_DL_FILES,
                    KEY_DL_SAVE_GALLERY, KEY_DL_DATA_SAVING,
                    KEY_CHAT_BG_PATH, KEY_ARCHIVE_KEEP_UNMUTED,
                    KEY_POWER_SAVING, KEY_PS_THRESHOLD, KEY_PS_AUTOPLAY_VIDEO, KEY_PS_AUTOPLAY_GIF,
                    KEY_PS_LOOP_STICKERS, KEY_PS_LOOP_EMOJI, KEY_PS_FULL_TRANSLUCENCY,
                    KEY_PS_EXTEND_BG_WORK, KEY_PS_AUTODOWNLOAD_BG,
                    KEY_PASSCODE_HASH, KEY_AUTO_LOCK_MINUTES, KEY_PASSCODE_FAILED_ATTEMPTS,
                    KEY_PASSCODE_LOCKOUT_UNTIL, KEY_PASSCODE_BIOMETRIC_ENABLED, KEY_PASSCODE_BACKGROUND_TS,
                    KEY_2FA_TOKEN, KEY_2FA_TOKEN_VALID_UNTIL,
                    KEY_TIMEZONES_CACHE_HASH, KEY_TIMEZONES_CACHE_JSON,
                    KEY_GLOBAL_PRIVACY_ARCHIVE_MUTE, KEY_GLOBAL_PRIVACY_KEEP_UNMUTED,
                    KEY_GLOBAL_PRIVACY_HIDE_READ_MARKS, KEY_GLOBAL_PRIVACY_REQUIRE_PREMIUM,
                    KEY_PROFILE_BIRTHDAY_JSON, KEY_PROFILE_NAME_COLOR, KEY_PROFILE_BG_EMOJI_ID,
                    KEY_PROFILE_EMOJI_STATUS_DOC_ID, KEY_PROFILE_EMOJI_STATUS_UNTIL,
                    KEY_PROFILE_PERSONAL_CHANNEL_ID
                ]
                try {
                    var i: Int64 = 0
                    while (i < legacyKeys.size) {
                        let origKey = legacyKeys[i]
                        if (prefs.has(origKey)) {
                            let oldVal = prefs.get(origKey, PreferencesValueType.Integer(0))
                            prefs.put(this.slottedKey(origKey, 0), oldVal)
                            prefs.delete(origKey)
                        }
                        i = i + 1
                    }
                    // 补迁所有动态 key（peer_mute_<peerId> 等运行时写入的非预定义 key）
                    // getAll() 返回快照，遍历中删除底层 key 安全（与 removeSlot/clearAll 相同范式）
                    let remaining = prefs.getAll()
                    for ((k, v) in remaining) {
                        if (!k.startsWith("slot_") && k != KEY_ACTIVE_SLOT && k != KEY_SLOT_LIST) {
                            prefs.put(this.slottedKey(k, 0), v)
                            prefs.delete(k)
                        }
                    }
                    // 确保 slot_list 包含 0
                    this.ensureSlotRegistered(0)
                    // activeSlot 保持 0（已经是默认值），持久化
                    prefs.put(KEY_ACTIVE_SLOT, PreferencesValueType.Integer(0))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Legacy data migrated to slot_0 successfully")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Migration error: ${e}")
                }
            case None => ()
        }
    }

    // ==================== slot_list 辅助 ====================

    /**
     * 从 Preferences 读取 slot_list 字符串，解析为整数数组。
     * 格式: "" (空) 或 "0" 或 "0,1,2"
     */
    private func readSlotList(): Array<Int32> {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(KEY_SLOT_LIST, PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) =>
                            if (s.size == 0) {
                                return Array<Int32>()
                            }
                            let parts = s.split(",")
                            var result = Array<Int32>(parts.size, repeat: 0)
                            var i: Int64 = 0
                            while (i < parts.size) {
                                let part = parts[i].trimAscii()
                                if (part.size > 0) {
                                    try {
                                        result[i] = Int32(Int64.parse(part))
                                    } catch (_: Exception) {
                                        result[i] = 0
                                    }
                                }
                                i = i + 1
                            }
                            return result
                        case _ => return Array<Int32>()
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] readSlotList error: ${e}")
                    return Array<Int32>()
                }
            case None => return Array<Int32>()
        }
    }

    /**
     * 将整数数组写回 slot_list（逗号分隔字符串）
     */
    private func writeSlotList(slots: Array<Int32>): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    var s: String = ""
                    var i: Int64 = 0
                    while (i < slots.size) {
                        if (i > 0) {
                            s = s + ","
                        }
                        s = s + "${slots[i]}"
                        i = i + 1
                    }
                    prefs.put(KEY_SLOT_LIST, PreferencesValueType.StringData(s))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] writeSlotList error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 确保 slot n 已在 slot_list 中注册
     */
    private func ensureSlotRegistered(n: Int32): Unit {
        let existing = this.readSlotList()
        var found: Bool = false
        var i: Int64 = 0
        while (i < existing.size) {
            if (existing[i] == n) {
                found = true
            }
            i = i + 1
        }
        if (!found) {
            var newList = Array<Int32>(existing.size + 1, repeat: 0)
            var j: Int64 = 0
            while (j < existing.size) {
                newList[j] = existing[j]
                j = j + 1
            }
            newList[existing.size] = n
            this.writeSlotList(newList)
        }
    }

    /**
     * 从 slot_list 中移除 slot n
     */
    private func removeSlotFromList(n: Int32): Unit {
        let existing = this.readSlotList()
        // 统计非 n 的个数
        var count: Int64 = 0
        var i: Int64 = 0
        while (i < existing.size) {
            if (existing[i] != n) {
                count = count + 1
            }
            i = i + 1
        }
        var newList = Array<Int32>(count, repeat: 0)
        var j: Int64 = 0
        var k: Int64 = 0
        while (j < existing.size) {
            if (existing[j] != n) {
                newList[k] = existing[j]
                k = k + 1
            }
            j = j + 1
        }
        this.writeSlotList(newList)
    }

    // ==================== 初始化 ====================

    /**
     * 使用 UIAbilityContext 初始化 Preferences 持久化存储
     * 必须在 MainAbility.onWindowStageCreate 中调用
     *
     * API: Preferences.getPreferences(UIAbilityContext, String)
     */
    public func initialize(context: UIAbilityContext): Unit {
        this.abilityContext = Some(context)
        try {
            let prefs = Preferences.getPreferences(context, "telegram_auth")
            this.preferences = Some(prefs)
            this.initialized = true
            // 加载持久化的 activeSlot（默认 0）
            let asVal = prefs.get(KEY_ACTIVE_SLOT, PreferencesValueType.Integer(0))
            match (asVal) {
                case PreferencesValueType.Integer(n) => this._activeSlot = Int32(n)
                case _ => this._activeSlot = 0
            }
            // TC-0086 fix: 加载持久化的 pendingAuthSlot（默认 -1 = 无进行中登录）
            let paVal = prefs.get(KEY_PENDING_AUTH_SLOT, PreferencesValueType.Integer(-1))
            match (paVal) {
                case PreferencesValueType.Integer(n) => this._pendingAuthSlot = Int32(n)
                case _ => this._pendingAuthSlot = -1
            }
            Hilog.info(0, "CjTelegram", "[AuthStorage] Initialized (activeSlot=${this._activeSlot}, pendingAuthSlot=${this._pendingAuthSlot})")
            // 执行旧数据迁移（幂等，多次调用安全）
            this.migrateLegacyToSlot0IfNeeded()
            // TC-0086 fix: 启动兜底——若 activeSlot 未指向已授权账号，回退到第一个已授权 slot。
            // 必须在这里调用（而不是 AppRoot 等消费者里），才能让 hasStoredLogin/tryRestoreLogin/
            // getMTProtoClient 等所有经由 activeSlot 的路径一次性受益。
            this.reconcileActiveSlotIfUnauthorized()
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to initialize Preferences: ${e}, falling back to memory")
            this.initialized = true
        }
    }

    public func isInitialized(): Bool {
        return this.initialized
    }

    // ==================== P2-318a: Slot 管理 API ====================

    /**
     * 返回所有已使用的 slot 编号列表。
     * 供 P2-318b AccountManagerService 构建账号列表。
     */
    public func listSlots(): Array<Int32> {
        let slots = this.readSlotList()
        // 若 slot_list 为空但存在 slot_0 数据，补填 slot 0（兼容迁移期间只有一个账号的情况）
        if (slots.size == 0) {
            match (this.preferences) {
                case Some(prefs) =>
                    if (prefs.has(this.slottedKey(KEY_AUTH_STATE, 0))) {
                        this.ensureSlotRegistered(0)
                        return Array<Int32>(1, repeat: Int32(0))
                    }
                case None => ()
            }
        }
        return slots
    }

    /**
     * 获取当前活跃 slot 编号（默认 0）
     */
    public func getActiveSlot(): Int32 {
        return this._activeSlot
    }

    /**
     * 设置活跃 slot 并持久化。
     * P2-318b 切换账号时调用。
     */
    public func setActiveSlot(n: Int32): Unit {
        this._activeSlot = n
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(KEY_ACTIVE_SLOT, PreferencesValueType.Integer(Int64(n)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] activeSlot set to ${n}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] setActiveSlot error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * TC-0086 fix: 开始一次新的、尚未授权的登录流程，占用 slot n。
     *
     * 与 setActiveSlot 的区别（关键）：只持久化 KEY_PENDING_AUTH_SLOT，绝不触碰
     * KEY_ACTIVE_SLOT——"当前已授权账号"的磁盘指针保持不动。内存中的路由 slot
     * （_activeSlot）临时切到 n，使既有的 sk() 把登录流的写入路由到新 slot；
     * 但这只是内存态，进程被杀/强退时不会落盘，下次 initialize() 重新从磁盘读到
     * 原来的 KEY_ACTIVE_SLOT，原账号完好无损。对应 iOS AccountManagerImpl.createAuth。
     *
     * 边界条件：若已有一个 pending slot 且尚未授权（用户连续两次进入添加账号流），
     * 先清理旧的空 slot 再接受新值，避免空 slot 无限增长——对齐 iOS createAuth
     * 直接覆盖 currentAuthRecord 的语义。
     */
    public func beginAuthSlot(n: Int32): Unit {
        if (this._pendingAuthSlot >= 0 && !this.slotHasAuth(this._pendingAuthSlot)) {
            this.removeSlot(this._pendingAuthSlot)
        }
        this._pendingAuthSlot = n
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(KEY_PENDING_AUTH_SLOT, PreferencesValueType.Integer(Int64(n)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] beginAuthSlot(${n}) persist error: ${e}")
                }
            case None => ()
        }
        // 内存路由切到 n；KEY_ACTIVE_SLOT 磁盘值不变。
        this._activeSlot = n
        Hilog.info(0, "CjTelegram", "[AuthStorage] beginAuthSlot: pendingAuthSlot=${n} (in-memory routing only; active_slot on disk unchanged)")
    }

    /**
     * TC-0086 fix: 结束当前进行中的登录流程（登录成功或用户取消/失败均调用）。
     * 只清 pending 指针；不改变内存中的路由 slot——调用方（completeAddAccount /
     * cancelAddAccount）随后会显式 setActiveSlot 决定路由回哪个 slot。
     * 对应 iOS AccountManagerImpl.removeAuth。
     */
    public func endAuthSlot(): Unit {
        this._pendingAuthSlot = -1
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.delete(KEY_PENDING_AUTH_SLOT)
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] endAuthSlot error: ${e}")
                }
            case None => ()
        }
        Hilog.info(0, "CjTelegram", "[AuthStorage] endAuthSlot: pendingAuthSlot cleared")
    }

    /**
     * TC-0086 fix: 返回当前进行中登录占用的 slot；-1 表示没有进行中的登录。
     */
    public func getPendingAuthSlot(): Int32 {
        return this._pendingAuthSlot
    }

    /**
     * 分配一个新的空 slot 编号（最大已用编号 + 1）。
     * 自动将新编号注册到 slot_list 并持久化。
     * 供 P2-318c 添加账号时调用。
     */
    public func createSlot(): Int32 {
        let existing = this.readSlotList()
        var maxSlot: Int32 = -1
        var i: Int64 = 0
        while (i < existing.size) {
            if (existing[i] > maxSlot) {
                maxSlot = existing[i]
            }
            i = i + 1
        }
        let newSlot: Int32 = maxSlot + 1
        this.ensureSlotRegistered(newSlot)
        Hilog.info(0, "CjTelegram", "[AuthStorage] Created new slot ${newSlot}")
        return newSlot
    }

    /**
     * 清除指定 slot 的所有认证数据并从 slot_list 注销。
     * 不影响其他 slot；不改变 activeSlot。
     * 供 P2-318d 删除账号时调用。
     */
    public func removeSlot(n: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    // 删除所有 slot_<n>_* 的键
                    let allKeys = prefs.getAll()
                    let prefix = "slot_${n}_"
                    for ((k, _) in allKeys) {
                        if (k.startsWith(prefix)) {
                            prefs.delete(k)
                        }
                    }
                    prefs.flush()
                    this.removeSlotFromList(n)
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Slot ${n} removed")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] removeSlot(${n}) error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 检查指定 slot 是否含有有效的 auth 数据（authState == 3 且有 session）。
     * 供 P2-318b 判断账号是否已登录。
     */
    public func slotHasAuth(n: Int32): Bool {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let stateKey = this.slottedKey(KEY_AUTH_STATE, n)
                    let sessionKey = this.slottedKey(KEY_SESSION_AUTH_KEY, n)
                    let userKey = this.slottedKey(KEY_USER_ID, n)
                    if (!prefs.has(stateKey)) {
                        return false
                    }
                    let stateVal = prefs.get(stateKey, PreferencesValueType.Integer(0))
                    let authState: Int32 = match (stateVal) {
                        case PreferencesValueType.Integer(v) => Int32(v)
                        case _ => 0
                    }
                    let hasSession = prefs.has(sessionKey)
                    let hasUser = prefs.has(userKey)
                    return authState == 3 && hasSession && hasUser
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] slotHasAuth(${n}) error: ${e}")
                    return false
                }
            case None => return false
        }
    }

    /**
     * TC-0086 fix: 启动兜底——若持久化的 activeSlot 未指向一个已授权账号，回退到
     * 第一个已授权 slot。镜像 iOS SharedAccountContext.swift:772-784 的 primary 兜底：
     * 只要磁盘上还存在任何已授权账号，就不会把用户送回首次登录入口，即便 current
     * 指针本身解析失败（例如一次被强杀的添加账号流程把 activeSlot 留在空 slot 上）。
     *
     * 由 initialize() 在 migrateLegacyToSlot0IfNeeded() 之后调用一次；不要把它放进
     * AppRoot 等消费者——写在这里才能让 hasStoredLogin/tryRestoreLogin/getMTProtoClient
     * 等所有经由 activeSlot 的路径一次性受益。
     *
     * 单账号常态零行为变化：slotHasAuth(activeSlot) 为真时直接返回，不做任何改动。
     */
    private func reconcileActiveSlotIfUnauthorized(): Unit {
        if (this.slotHasAuth(this._activeSlot)) {
            return
        }
        let slots = this.listSlots()
        var i: Int64 = 0
        while (i < slots.size) {
            let candidate = slots[i]
            if (this.slotHasAuth(candidate)) {
                let previous = this._activeSlot
                this._activeSlot = candidate
                match (this.preferences) {
                    case Some(prefs) =>
                        try {
                            prefs.put(KEY_ACTIVE_SLOT, PreferencesValueType.Integer(Int64(candidate)))
                            prefs.flush()
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[AuthStorage] reconcileActiveSlotIfUnauthorized persist error: ${e}")
                        }
                    case None => ()
                }
                Hilog.info(0, "CjTelegram", "[AuthStorage] reconcileActiveSlotIfUnauthorized: activeSlot=${previous} had no auth, recovered to slot=${candidate}")
                return
            }
            i = i + 1
        }
        // 没有任何已授权 slot：保持现状（真正的未登录 / 全新安装）
        Hilog.info(0, "CjTelegram", "[AuthStorage] reconcileActiveSlotIfUnauthorized: activeSlot=${this._activeSlot} has no auth and no authorized slot exists, leaving as-is")
    }

    // ==================== Auth State ====================

    public func saveAuthState(state: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_AUTH_STATE), PreferencesValueType.Integer(Int64(state)))
                    prefs.flush()
                    // 若保存为已登录状态，确保当前 slot 已在 slot_list 中
                    if (state == 3) {
                        this.ensureSlotRegistered(this._activeSlot)
                    }
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Auth state saved (slot=${this._activeSlot}): ${state}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save auth state: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthStorage] Preferences not initialized, cannot save auth state")
        }
    }

    public func getAuthState(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_AUTH_STATE), PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to get auth state: ${e}")
                    return 0
                }
            case None => return 0
        }
    }

    // ==================== User Data ====================

    public func saveUserData(user: StoredUserData): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_USER_ID), PreferencesValueType.Integer(user.id))
                    prefs.put(this.sk(KEY_USER_FIRST_NAME), PreferencesValueType.StringData(user.firstName))
                    prefs.put(this.sk(KEY_USER_LAST_NAME), PreferencesValueType.StringData(user.lastName))
                    prefs.put(this.sk(KEY_USER_USERNAME), PreferencesValueType.StringData(user.username))
                    prefs.put(this.sk(KEY_USER_PHONE), PreferencesValueType.StringData(user.phone))
                    prefs.put(this.sk(KEY_USER_IS_PREMIUM), PreferencesValueType.BoolData(user.isPremium))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] User data saved (slot=${this._activeSlot}): ${user.firstName}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save user data: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthStorage] Preferences not initialized, cannot save user data")
        }
    }

    public func getUserData(): Option<StoredUserData> {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    if (!prefs.has(this.sk(KEY_USER_ID))) {
                        return None
                    }
                    let user = StoredUserData()

                    let idVal = prefs.get(this.sk(KEY_USER_ID), PreferencesValueType.Integer(0))
                    match (idVal) {
                        case PreferencesValueType.Integer(n) => user.id = n
                        case _ => ()
                    }

                    let fnVal = prefs.get(this.sk(KEY_USER_FIRST_NAME), PreferencesValueType.StringData(""))
                    match (fnVal) {
                        case PreferencesValueType.StringData(s) => user.firstName = s
                        case _ => ()
                    }

                    let lnVal = prefs.get(this.sk(KEY_USER_LAST_NAME), PreferencesValueType.StringData(""))
                    match (lnVal) {
                        case PreferencesValueType.StringData(s) => user.lastName = s
                        case _ => ()
                    }

                    let unVal = prefs.get(this.sk(KEY_USER_USERNAME), PreferencesValueType.StringData(""))
                    match (unVal) {
                        case PreferencesValueType.StringData(s) => user.username = s
                        case _ => ()
                    }

                    let phVal = prefs.get(this.sk(KEY_USER_PHONE), PreferencesValueType.StringData(""))
                    match (phVal) {
                        case PreferencesValueType.StringData(s) => user.phone = s
                        case _ => ()
                    }

                    let premVal = prefs.get(this.sk(KEY_USER_IS_PREMIUM), PreferencesValueType.BoolData(false))
                    match (premVal) {
                        case PreferencesValueType.BoolData(b) => user.isPremium = b
                        case _ => ()
                    }

                    return Some(user)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to get user data: ${e}")
                    return None
                }
            case None => return None
        }
    }

    /**
     * Read one authorized slot without changing either the in-memory routing slot or
     * the persisted active slot. Multi-account lookups must use this API: temporarily
     * calling setActiveSlot() for a read can redirect an in-progress auth flow and also
     * writes the temporary value to disk.
     */
    public func getUserDataForSlot(slot: Int32): Option<StoredUserData> {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    if (!prefs.has(this.slottedKey(KEY_USER_ID, slot))) {
                        return None
                    }
                    let user = StoredUserData()

                    match (prefs.get(this.slottedKey(KEY_USER_ID, slot), PreferencesValueType.Integer(0))) {
                        case PreferencesValueType.Integer(n) => user.id = n
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_USER_FIRST_NAME, slot), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => user.firstName = s
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_USER_LAST_NAME, slot), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => user.lastName = s
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_USER_USERNAME, slot), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => user.username = s
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_USER_PHONE, slot), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => user.phone = s
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_USER_IS_PREMIUM, slot), PreferencesValueType.BoolData(false))) {
                        case PreferencesValueType.BoolData(b) => user.isPremium = b
                        case _ => ()
                    }
                    return Some(user)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to get user data for slot=${slot}: ${e}")
                    return None
                }
            case None => return None
        }
    }

    /**
     * Persist the rendered total unread count for one authorized account without
     * changing activeSlot. The value uses the same 9999 cap as BadgeAggregator.
     */
    public func setRenderedTotalUnreadForSlot(slot: Int32, count: Int32): Unit {
        let bounded: Int32 = if (count < 0) { Int32(0) } else if (count > 9999) { Int32(9999) } else { count }
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(
                        this.slottedKey(KEY_RENDERED_TOTAL_UNREAD, slot),
                        PreferencesValueType.Integer(Int64(bounded))
                    )
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] rendered total unread saved slot=${slot} count=${bounded}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram",
                        "[AuthStorage] failed to save rendered total unread slot=${slot}: ${e}")
                }
            case None => ()
        }
    }

    /**
     * Read one account's rendered total unread count without changing activeSlot.
     * New accounts and accounts that have not completed a chat-list sync return 0.
     */
    /** 记录本地会话列表缓存归属的 slot（storeChats 成功后由 ChatListStore 调用）。 */
    public func setChatListCacheOwnerSlot(slot: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(KEY_CHAT_LIST_CACHE_OWNER_SLOT, PreferencesValueType.Integer(Int64(slot)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] setChatListCacheOwnerSlot error: ${e}")
                }
            case None => ()
        }
    }

    /** 本地会话列表缓存归属的 slot；-1 = 未记录（升级前的存量缓存，视为当前账号）。 */
    public func getChatListCacheOwnerSlot(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    match (prefs.get(KEY_CHAT_LIST_CACHE_OWNER_SLOT, PreferencesValueType.Integer(-1))) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return -1
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] getChatListCacheOwnerSlot error: ${e}")
                    return -1
                }
            case None => return -1
        }
    }

    public func getRenderedTotalUnreadForSlot(slot: Int32): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let value = prefs.get(
                        this.slottedKey(KEY_RENDERED_TOTAL_UNREAD, slot),
                        PreferencesValueType.Integer(0)
                    )
                    match (value) {
                        case PreferencesValueType.Integer(n) =>
                            if (n <= 0) { return 0 }
                            if (n > 9999) { return 9999 }
                            return Int32(n)
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram",
                        "[AuthStorage] failed to read rendered total unread slot=${slot}: ${e}")
                    return 0
                }
            case None => return 0
        }
    }

    // ==================== Session Data ====================

    public func saveSessionData(session: StoredSessionData): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_SESSION_DC_ID), PreferencesValueType.Integer(session.dcId))
                    prefs.put(this.sk(KEY_SESSION_AUTH_KEY), PreferencesValueType.StringData(session.authKey))
                    prefs.put(this.sk(KEY_SESSION_AUTH_KEY_ID), PreferencesValueType.StringData(session.authKeyId))
                    prefs.put(this.sk(KEY_SESSION_SERVER_SALT), PreferencesValueType.StringData(session.serverSalt))
                    prefs.put(this.sk(KEY_SESSION_AUTH_KEY_STATE), PreferencesValueType.Integer(Int64(session.authKeyState)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Session data saved (slot=${this._activeSlot}) for DC${session.dcId}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save session data: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthStorage] Preferences not initialized, cannot save session data")
        }
    }

    public func getSessionData(): Option<StoredSessionData> {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    if (!prefs.has(this.sk(KEY_SESSION_AUTH_KEY))) {
                        return None
                    }
                    let session = StoredSessionData()

                    let dcVal = prefs.get(this.sk(KEY_SESSION_DC_ID), PreferencesValueType.Integer(0))
                    match (dcVal) {
                        case PreferencesValueType.Integer(n) => session.dcId = n
                        case _ => ()
                    }

                    let akVal = prefs.get(this.sk(KEY_SESSION_AUTH_KEY), PreferencesValueType.StringData(""))
                    match (akVal) {
                        case PreferencesValueType.StringData(s) => session.authKey = s
                        case _ => ()
                    }

                    let akIdVal = prefs.get(this.sk(KEY_SESSION_AUTH_KEY_ID), PreferencesValueType.StringData(""))
                    match (akIdVal) {
                        case PreferencesValueType.StringData(s) => session.authKeyId = s
                        case _ => ()
                    }

                    let ssVal = prefs.get(this.sk(KEY_SESSION_SERVER_SALT), PreferencesValueType.StringData(""))
                    match (ssVal) {
                        case PreferencesValueType.StringData(s) => session.serverSalt = s
                        case _ => ()
                    }

                    let aksVal = prefs.get(this.sk(KEY_SESSION_AUTH_KEY_STATE), PreferencesValueType.Integer(0))
                    match (aksVal) {
                        case PreferencesValueType.Integer(n) => session.authKeyState = Int32(n)
                        case _ => ()
                    }

                    return Some(session)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to get session data: ${e}")
                    return None
                }
            case None => return None
        }
    }

    /**
     * Read one slot's persisted MTProto session without changing activeSlot.
     * Account records are keyed by slot just like iOS AccountRecordId contexts;
     * inspecting another record must never redirect the live storage router.
     */
    public func getSessionDataForSlot(slot: Int32): Option<StoredSessionData> {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    if (!prefs.has(this.slottedKey(KEY_SESSION_AUTH_KEY, slot))) {
                        return None
                    }
                    let session = StoredSessionData()
                    match (prefs.get(this.slottedKey(KEY_SESSION_DC_ID, slot), PreferencesValueType.Integer(0))) {
                        case PreferencesValueType.Integer(n) => session.dcId = n
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_SESSION_AUTH_KEY, slot), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => session.authKey = s
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_SESSION_AUTH_KEY_ID, slot), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => session.authKeyId = s
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_SESSION_SERVER_SALT, slot), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => session.serverSalt = s
                        case _ => ()
                    }
                    match (prefs.get(this.slottedKey(KEY_SESSION_AUTH_KEY_STATE, slot), PreferencesValueType.Integer(0))) {
                        case PreferencesValueType.Integer(n) => session.authKeyState = Int32(n)
                        case _ => ()
                    }
                    return Some(session)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to get session data for slot=${slot}: ${e}")
                    return None
                }
            case None => return None
        }
    }

    // ==================== Full Auth Data ====================

    public func saveFullAuthData(data: StoredAuthData): Unit {
        match (data.user) {
            case Some(user) => this.saveUserData(user)
            case None => ()
        }
        match (data.session) {
            case Some(session) => this.saveSessionData(session)
            case None => ()
        }
        this.saveAuthState(data.authState)
        Hilog.info(0, "CjTelegram", "[AuthStorage] Full auth data saved (slot=${this._activeSlot})")
    }

    public func getFullAuthData(): Option<StoredAuthData> {
        let authState = this.getAuthState()
        if (authState == 0) {
            return None
        }
        let data = StoredAuthData()
        data.authState = authState
        data.user = this.getUserData()
        data.session = this.getSessionData()
        return Some(data)
    }

    // ==================== Phase R1: Sync State ====================

    /**
     * 保存更新同步状态 (pts, qts, date, seq)
     * 作为增量更新 (getDifference) 的基准点
     */
    public func saveSyncState(pts: Int32, qts: Int32, date: Int32, seq: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_SYNC_PTS), PreferencesValueType.Integer(Int64(pts)))
                    prefs.put(this.sk(KEY_SYNC_QTS), PreferencesValueType.Integer(Int64(qts)))
                    prefs.put(this.sk(KEY_SYNC_DATE), PreferencesValueType.Integer(Int64(date)))
                    prefs.put(this.sk(KEY_SYNC_SEQ), PreferencesValueType.Integer(Int64(seq)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Sync state saved (slot=${this._activeSlot}): pts=${pts}, qts=${qts}, date=${date}, seq=${seq}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save sync state: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthStorage] Preferences not initialized, cannot save sync state")
        }
    }

    /**
     * 读取同步状态
     * 返回 (pts, qts, date, seq) 四元组，全为 0 表示无存储状态
     */
    public func getSyncState(): (Int32, Int32, Int32, Int32) {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    var pts: Int32 = 0
                    var qts: Int32 = 0
                    var date: Int32 = 0
                    var seq: Int32 = 0

                    let ptsVal = prefs.get(this.sk(KEY_SYNC_PTS), PreferencesValueType.Integer(0))
                    match (ptsVal) {
                        case PreferencesValueType.Integer(n) => pts = Int32(n)
                        case _ => ()
                    }
                    let qtsVal = prefs.get(this.sk(KEY_SYNC_QTS), PreferencesValueType.Integer(0))
                    match (qtsVal) {
                        case PreferencesValueType.Integer(n) => qts = Int32(n)
                        case _ => ()
                    }
                    let dateVal = prefs.get(this.sk(KEY_SYNC_DATE), PreferencesValueType.Integer(0))
                    match (dateVal) {
                        case PreferencesValueType.Integer(n) => date = Int32(n)
                        case _ => ()
                    }
                    let seqVal = prefs.get(this.sk(KEY_SYNC_SEQ), PreferencesValueType.Integer(0))
                    match (seqVal) {
                        case PreferencesValueType.Integer(n) => seq = Int32(n)
                        case _ => ()
                    }

                    return (pts, qts, date, seq)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to get sync state: ${e}")
                    return (0, 0, 0, 0)
                }
            case None => return (0, 0, 0, 0)
        }
    }

    /**
     * 检查是否有保存的同步状态
     */
    public func hasSyncState(): Bool {
        let (pts, _, _, _) = this.getSyncState()
        return pts > 0
    }

    // ==================== Utility ====================

    public func hasStoredLogin(): Bool {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let authState = this.getAuthState()
                    // authState == 3 means Authorized
                    let hasUser = prefs.has(this.sk(KEY_USER_ID))
                    let hasSession = prefs.has(this.sk(KEY_SESSION_AUTH_KEY))
                    let result = authState == 3 && hasUser && hasSession
                    Hilog.info(0, "CjTelegram", "[AuthStorage] hasStoredLogin (slot=${this._activeSlot}): ${result} (state=${authState}, user=${hasUser}, session=${hasSession})")
                    return result
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to check stored login: ${e}")
                    return false
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthStorage] Preferences not initialized")
                return false
        }
    }

    /**
     * QA-3 fix: 标记引导/登录流程已开始（用户在 SplashPage 点击 "Start Messaging"）。
     * 全局 key（不带 slot 前缀）：在完成登录、账号 slot 尚未确定前就需要能读到这个标记。
     * 供 AppRoot.decideInitialRoute 判断"应恢复到 PhoneInputPage 还是回退展示 intro"。
     */
    public func setOnboardingStarted(started: Bool): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v: Int64 = if (started) { 1 } else { 0 }
                    prefs.put(KEY_ONBOARDING_STARTED, PreferencesValueType.Integer(v))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] onboardingStarted set to ${started}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save onboardingStarted: ${e}")
                }
            case None => ()
        }
    }

    /**
     * QA-3 fix: 是否已经开始过引导/登录流程（尚未必然完成登录）。
     */
    public func hasOnboardingStarted(): Bool {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(KEY_ONBOARDING_STARTED, PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return false
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to read onboardingStarted: ${e}")
                    return false
                }
            case None => return false
        }
    }

    // ==================== Phase T4.4: Appearance Settings ====================

    public func saveAppearanceTheme(theme: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_APPEARANCE_THEME), PreferencesValueType.Integer(Int64(theme)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save theme: ${e}")
                }
            case None => ()
        }
    }

    public func getAppearanceTheme(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_APPEARANCE_THEME), PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    public func saveAppearanceTextSize(size: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_APPEARANCE_TEXT_SIZE), PreferencesValueType.Integer(Int64(size)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save text size: ${e}")
                }
            case None => ()
        }
    }

    public func getAppearanceTextSize(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_APPEARANCE_TEXT_SIZE), PreferencesValueType.Integer(16))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 16
                    }
                } catch (e: Exception) {
                    return 16
                }
            case None => return 16
        }
    }

    public func saveAnimationEnabled(enabled: Bool): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v: Int64 = if (enabled) { 1 } else { 0 }
                    prefs.put(this.sk(KEY_APPEARANCE_ANIMATION), PreferencesValueType.Integer(v))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Saved animationEnabled: ${enabled}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save animation: ${e}")
                }
            case None => ()
        }
    }

    public func getAnimationEnabled(): Bool {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_APPEARANCE_ANIMATION), PreferencesValueType.Integer(1))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return true
                    }
                } catch (e: Exception) {
                    return true
                }
            case None => return true
        }
    }

    // ==================== Chat Background ====================

    public func saveChatBackground(path: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_CHAT_BG_PATH), PreferencesValueType.StringData(path))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Chat background saved (slot=${this._activeSlot}): ${path}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save chat background: ${e}")
                }
            case None => ()
        }
    }

    public func getChatBackground(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_CHAT_BG_PATH), PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return ""
                    }
                } catch (e: Exception) {
                    return ""
                }
            case None => return ""
        }
    }

    // ==================== Settings: Archive ====================

    public func saveArchiveKeepUnmuted(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_ARCHIVE_KEEP_UNMUTED), enabled)
    }
    public func getArchiveKeepUnmuted(): Bool {
        return this.getBoolPref(this.sk(KEY_ARCHIVE_KEEP_UNMUTED), false)
    }

    // ==================== Settings: Power Saving ====================

    public func savePowerSaving(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_POWER_SAVING), enabled)
    }
    public func getPowerSaving(): Bool {
        return this.getBoolPref(this.sk(KEY_POWER_SAVING), false)
    }

    // Energy usage threshold (0-100): <=4 always off, >=96 always on, else conditional
    public func savePsThreshold(value: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PS_THRESHOLD), PreferencesValueType.Integer(Int64(value)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save ps_threshold: ${e}")
                }
            case None => ()
        }
    }
    public func getPsThreshold(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_PS_THRESHOLD), PreferencesValueType.Integer(15))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 15
                    }
                } catch (e: Exception) { return 15 }
            case None => return 15
        }
    }

    // Per-feature energy toggles (default true = feature enabled/not reduced)
    public func savePsAutoplayVideo(v: Bool): Unit { this.saveBoolPref(this.sk(KEY_PS_AUTOPLAY_VIDEO), v) }
    public func getPsAutoplayVideo(): Bool { return this.getBoolPref(this.sk(KEY_PS_AUTOPLAY_VIDEO), true) }

    public func savePsAutoplayGif(v: Bool): Unit { this.saveBoolPref(this.sk(KEY_PS_AUTOPLAY_GIF), v) }
    public func getPsAutoplayGif(): Bool { return this.getBoolPref(this.sk(KEY_PS_AUTOPLAY_GIF), true) }

    public func savePsLoopStickers(v: Bool): Unit { this.saveBoolPref(this.sk(KEY_PS_LOOP_STICKERS), v) }
    public func getPsLoopStickers(): Bool { return this.getBoolPref(this.sk(KEY_PS_LOOP_STICKERS), true) }

    public func savePsLoopEmoji(v: Bool): Unit { this.saveBoolPref(this.sk(KEY_PS_LOOP_EMOJI), v) }
    public func getPsLoopEmoji(): Bool { return this.getBoolPref(this.sk(KEY_PS_LOOP_EMOJI), true) }

    public func savePsFullTranslucency(v: Bool): Unit { this.saveBoolPref(this.sk(KEY_PS_FULL_TRANSLUCENCY), v) }
    public func getPsFullTranslucency(): Bool { return this.getBoolPref(this.sk(KEY_PS_FULL_TRANSLUCENCY), true) }

    public func savePsExtendBgWork(v: Bool): Unit { this.saveBoolPref(this.sk(KEY_PS_EXTEND_BG_WORK), v) }
    public func getPsExtendBgWork(): Bool { return this.getBoolPref(this.sk(KEY_PS_EXTEND_BG_WORK), true) }

    public func savePsAutodownloadBg(v: Bool): Unit { this.saveBoolPref(this.sk(KEY_PS_AUTODOWNLOAD_BG), v) }
    public func getPsAutodownloadBg(): Bool { return this.getBoolPref(this.sk(KEY_PS_AUTODOWNLOAD_BG), true) }

    // ==================== Phase P4-10: Language Settings ====================

    public func saveLangCode(code: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_LANG_CODE), PreferencesValueType.StringData(code))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Saved langCode (slot=${this._activeSlot}): ${code}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save langCode: ${e}")
                }
            case None => ()
        }
    }

    public func getLangCode(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_LANG_CODE), PreferencesValueType.StringData("en"))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return "en"
                    }
                } catch (e: Exception) {
                    return "en"
                }
            case None => return "en"
        }
    }

    public func saveLangBaseCode(code: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_LANG_BASE_CODE), PreferencesValueType.StringData(code))
                    prefs.flush()
                } catch (_e: Exception) {}
            case None => ()
        }
    }

    public func getLangBaseCode(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    match (prefs.get(this.sk(KEY_LANG_BASE_CODE), PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return ""
                    }
                } catch (_e: Exception) { return "" }
            case None => return ""
        }
    }

    // ==================== Phase P4-9: Download Settings ====================

    private func saveBoolPref(key: String, value: Bool): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v: Int64 = if (value) { 1 } else { 0 }
                    prefs.put(key, PreferencesValueType.Integer(v))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save ${key}: ${e}")
                }
            case None => ()
        }
    }

    private func getBoolPref(key: String, defaultVal: Bool): Bool {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let dv: Int64 = if (defaultVal) { 1 } else { 0 }
                    let val = prefs.get(key, PreferencesValueType.Integer(dv))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return defaultVal
                    }
                } catch (e: Exception) {
                    return defaultVal
                }
            case None => return defaultVal
        }
    }

    public func saveDownloadPhotos(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_DL_PHOTOS), enabled)
    }
    public func getDownloadPhotos(): Bool {
        return this.getBoolPref(this.sk(KEY_DL_PHOTOS), true)
    }

    public func saveDownloadVideos(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_DL_VIDEOS), enabled)
    }
    public func getDownloadVideos(): Bool {
        // 默认 true 对齐 iOS：MediaAutoDownloadSettings.defaultSettings 里
        // cellular(medium 档) 和 wifi(high 档) 都是 enabled: true，视频/GIF 自动下载
        // 默认开启，靠尺寸上限兜底（蜂窝 2.5MB / wifi 10MB，shouldAutoDownload 已实现）。
        // 此前默认 false，聊天里的 GIF 在新装机上永远只有缩略图。
        return this.getBoolPref(this.sk(KEY_DL_VIDEOS), true)
    }

    public func saveDownloadFiles(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_DL_FILES), enabled)
    }
    public func getDownloadFiles(): Bool {
        return this.getBoolPref(this.sk(KEY_DL_FILES), false)
    }

    public func saveSaveToGallery(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_DL_SAVE_GALLERY), enabled)
    }
    public func getSaveToGallery(): Bool {
        return this.getBoolPref(this.sk(KEY_DL_SAVE_GALLERY), false)
    }

    public func saveDataSaving(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_DL_DATA_SAVING), enabled)
    }
    public func getDataSaving(): Bool {
        return this.getBoolPref(this.sk(KEY_DL_DATA_SAVING), false)
    }

    // ==================== Phase P4-7: Passcode Lock ====================

    public func savePasscodeHash(hash: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PASSCODE_HASH), PreferencesValueType.StringData(hash))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Passcode hash saved (slot=${this._activeSlot})")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save passcode: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 从明文密码保存：计算 hash 后调用 savePasscodeHash
     */
    public func savePasscodeFromPlain(plainPasscode: String): Unit {
        let hash = this.hashPasscode(plainPasscode)
        this.savePasscodeHash(hash)
    }

    public func getPasscodeHash(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_PASSCODE_HASH), PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return ""
                    }
                } catch (e: Exception) {
                    return ""
                }
            case None => return ""
        }
    }

    public func hasPasscode(): Bool {
        return this.getPasscodeHash().size > 0
    }

    public func saveAutoLockMinutes(minutes: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_AUTO_LOCK_MINUTES), PreferencesValueType.Integer(Int64(minutes)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save auto-lock: ${e}")
                }
            case None => ()
        }
    }

    public func getAutoLockMinutes(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_AUTO_LOCK_MINUTES), PreferencesValueType.Integer(5))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 5
                    }
                } catch (e: Exception) {
                    return 5
                }
            case None => return 5
        }
    }

    public func clearPasscode(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.delete(this.sk(KEY_PASSCODE_HASH))
                    prefs.delete(this.sk(KEY_AUTO_LOCK_MINUTES))
                    prefs.delete(this.sk(KEY_PASSCODE_FAILED_ATTEMPTS))
                    prefs.delete(this.sk(KEY_PASSCODE_LOCKOUT_UNTIL))
                    prefs.delete(this.sk(KEY_PASSCODE_BIOMETRIC_ENABLED))
                    prefs.delete(this.sk(KEY_PASSCODE_TYPE))
                    prefs.delete(this.sk(KEY_PASSCODE_BACKGROUND_TS))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Passcode cleared (slot=${this._activeSlot})")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to clear passcode: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 验证密码：计算 hash 与存储比对，成功时重置失败次数
     */
    public func verifyPasscode(code: String): Bool {
        let hash = this.hashPasscode(code)
        let stored = this.getPasscodeHash()
        if (hash == stored) {
            this.resetFailedAttempts()
            return true
        }
        return false
    }

    private func hashPasscode(code: String): String {
        let bytes = this.passcodeToBytes(code)
        let hash = SHA256.hash(bytes)
        return ByteUtils.toHex(hash)
    }

    private func passcodeToBytes(code: String): Array<Byte> {
        let runes = code.toRuneArray()
        let result = Array<Byte>(runes.size, repeat: 0)
        var i: Int64 = 0
        while (i < runes.size) {
            result[i] = UInt8(UInt32(runes[i]) & 0xFF)
            i = i + 1
        }
        return result
    }

    /**
     * P2-272: 记录一次失败尝试，超过阈值后进入滚动限速锁定
     *
     * iOS 对应：PasscodeEntryController 中 attemptCount 递增 + 延迟表查找。
     * 实现：
     *   1. 累加失败次数（持久化，跨重启）
     *   2. 按 lockoutSecondsForAttemptCount(count) 查延迟表
     *   3. lockoutUntil = DateTime.now().toUnixTimeStamp().toSeconds() + delaySec
     *      （DateTime.now() 用于时间戳存储；系统时间防绕过依赖
     *       HarmonyOS 沙箱无法修改系统时钟，用户层改时间需重启 App 才能绑过）
     *   4. 持久化 lockout_until（Preferences flush 跨重启保存）
     *
     * 防墙钟绕过说明：
     *   lockoutUntil 以持久化时间戳存储。getLockoutRemainingSeconds() 每次取当前
     *   DateTime.now() 与存储值对比。若用户向前改系统时间，now() 变小，remaining 变大，
     *   锁定反而加长——改时间无法绕过限速。
     *   向后改时间（提前到"解锁时间"后）：HarmonyOS 标准 App 沙箱中普通用户无权限
     *   在 App 运行时修改系统时钟，此路径在标准鸿蒙设备上实际不可达。
     *   极端 root 场景超出本安全模型范围。
     */
    public func recordFailedAttempt(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    var count = this.getFailedAttempts()
                    count = count + 1
                    prefs.put(this.sk(KEY_PASSCODE_FAILED_ATTEMPTS), PreferencesValueType.Integer(Int64(count)))
                    // P2-272: 查延迟表，count >= 6 时进入滚动限速
                    let delaySec = lockoutSecondsForAttemptCount(count)
                    if (delaySec > 0) {
                        let now = DateTime.now().toUnixTimeStamp().toSeconds()
                        let lockoutUntil = now + delaySec
                        prefs.put(this.sk(KEY_PASSCODE_LOCKOUT_UNTIL), PreferencesValueType.Integer(lockoutUntil))
                        Hilog.info(0, "CjTelegram", "[AuthStorage] P2-272 lockout attempt=${count} delaySec=${delaySec} until=${lockoutUntil} (slot=${this._activeSlot})")
                    } else if (count >= PASSCODE_MAX_ATTEMPTS) {
                        // 第 5 次：首次进入 60s 锁定（兼容旧行为 PASSCODE_MAX_ATTEMPTS=5）
                        let now = DateTime.now().toUnixTimeStamp().toSeconds()
                        let lockoutUntil = now + PASSCODE_LOCKOUT_SECONDS
                        prefs.put(this.sk(KEY_PASSCODE_LOCKOUT_UNTIL), PreferencesValueType.Integer(lockoutUntil))
                        Hilog.info(0, "CjTelegram", "[AuthStorage] Passcode lockout until ${lockoutUntil} (slot=${this._activeSlot})")
                    }
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to record failed attempt: ${e}")
                }
            case None => ()
        }
    }

    public func getFailedAttempts(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_PASSCODE_FAILED_ATTEMPTS), PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    public func resetFailedAttempts(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.delete(this.sk(KEY_PASSCODE_FAILED_ATTEMPTS))
                    prefs.delete(this.sk(KEY_PASSCODE_LOCKOUT_UNTIL))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to reset failed attempts: ${e}")
                }
            case None => ()
        }
    }

    public func isLockedOut(): Bool {
        return this.getLockoutRemainingSeconds() > 0
    }

    public func getLockoutRemainingSeconds(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_PASSCODE_LOCKOUT_UNTIL), PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(until) =>
                            let now = DateTime.now().toUnixTimeStamp().toSeconds()
                            let remaining = until - now
                            return if (remaining > 0) { Int32(remaining) } else { 0 }
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    public func saveBiometricEnabled(enabled: Bool): Unit {
        this.saveBoolPref(this.sk(KEY_PASSCODE_BIOMETRIC_ENABLED), enabled)
    }

    public func getBiometricEnabled(): Bool {
        return this.getBoolPref(this.sk(KEY_PASSCODE_BIOMETRIC_ENABLED), false)
    }

    // ==================== P2-269: Auto-lock background timestamp ====================

    /**
     * P2-269: 持久化"进入后台时间戳"（秒），供跨重启自动锁定判定。
     * AppLockStateService.notifyAppWentToBackground() 调用本方法持久化时间戳，
     * shouldLockOnForeground() 从本方法读取，与 DateTime.now() 对比。
     */
    public func saveBackgroundTimestamp(ts: Int64): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PASSCODE_BACKGROUND_TS), PreferencesValueType.Integer(ts))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveBackgroundTimestamp error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * P2-269: 读取持久化"进入后台时间戳"（秒）。0 表示无记录（首次启动或未设置）。
     */
    public func getBackgroundTimestamp(): Int64 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_PASSCODE_BACKGROUND_TS), PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] getBackgroundTimestamp error: ${e}")
                    return 0
                }
            case None => return 0
        }
    }

    /**
     * P2-269: 清除后台时间戳（解锁成功或密码禁用后调用，避免下次启动误触发）。
     */
    public func clearBackgroundTimestamp(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.delete(this.sk(KEY_PASSCODE_BACKGROUND_TS))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] clearBackgroundTimestamp error: ${e}")
                }
            case None => ()
        }
    }

    // ==================== P2-267: Passcode Type ====================

    /**
     * 保存密码类型（0=digits6, 1=digits4, 2=alphanumeric）
     */
    public func savePasscodeType(passcodeType: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PASSCODE_TYPE), PreferencesValueType.Integer(Int64(passcodeType)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Passcode type saved: ${passcodeType}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save passcode type: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 读取密码类型（0=digits6, 1=digits4, 2=alphanumeric），默认 0（6位）
     */
    public func getPasscodeType(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_PASSCODE_TYPE), PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(v) => return Int32(v)
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to get passcode type: ${e}")
                }
                return 0
            case None => return 0
        }
    }

    // ==================== Phase P2-164: Localization Persistence ====================

    /**
     * 持久化 availableSavedLocalizations JSON 字符串
     */
    public func saveLocalizationSavedList(json: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_LOCALIZATION_SAVED_LIST), PreferencesValueType.StringData(json))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Saved localization list (${json.size} bytes)")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save localization list: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 读取 availableSavedLocalizations JSON 字符串；无数据时返回空字符串
     */
    public func getLocalizationSavedList(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_LOCALIZATION_SAVED_LIST), PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return ""
                    }
                } catch (e: Exception) {
                    return ""
                }
            case None => return ""
        }
    }

    /**
     * 持久化 countries cache hash（Int32 存为 Int64）
     */
    public func saveCountriesCacheHash(hash: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_COUNTRIES_CACHE_HASH), PreferencesValueType.Integer(Int64(hash)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save countries hash: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 读取 countries cache hash
     */
    public func getCountriesCacheHash(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_COUNTRIES_CACHE_HASH), PreferencesValueType.Integer(0))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    /**
     * 持久化 countries cache JSON 字符串
     */
    public func saveCountriesCacheData(json: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_COUNTRIES_CACHE_DATA), PreferencesValueType.StringData(json))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Saved countries cache (${json.size} bytes)")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to save countries cache: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 读取 countries cache JSON 字符串
     */
    public func getCountriesCacheData(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(KEY_COUNTRIES_CACHE_DATA), PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return ""
                    }
                } catch (e: Exception) {
                    return ""
                }
            case None => return ""
        }
    }

    /**
     * 清除当前 activeSlot 的所有认证及设置数据（登出语义）。
     *
     * 多账号语义：
     *   - 只清当前 slot 的数据，不影响其他 slot
     *   - 从 slot_list 中注销当前 slot
     *   - activeSlot 在调用后不变（由上层 AccountManagerService 决定切换到哪个 slot）
     *
     * 单账号回归安全：
     *   - 单账号场景下 activeSlot=0，清除 slot_0 的所有数据，等效于旧 clearAll() 清除全部认证
     *   - 其他 Preferences store（stickers/themes/item/contacts）仍按原有逻辑清除
     */
    public func clearAll(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let currentSlot = this._activeSlot
                    let slotPrefix = "slot_${currentSlot}_"
                    // 删除当前 slot 所有 slotted keys
                    let allKeys = prefs.getAll()
                    for ((k, _) in allKeys) {
                        if (k.startsWith(slotPrefix)) {
                            prefs.delete(k)
                        }
                    }
                    // 从 slot_list 注销当前 slot
                    this.removeSlotFromList(currentSlot)
                    prefs.flush()
                    // P2-154: clear stickers cache independent store on logout (multi-account isolation)
                    match (this.abilityContext) {
                        case Some(ctx) =>
                            try {
                                let sp = Preferences.getPreferences(ctx, "telegram_stickers_cache")
                                sp.clear()
                                sp.flush()
                            } catch (_: Exception) {}
                        case None => ()
                    }
                    // P2-160: clear themes/wallpapers hash cache on logout
                    match (this.abilityContext) {
                        case Some(ctx) =>
                            try {
                                let tp = Preferences.getPreferences(ctx, "telegram_themes_cache")
                                tp.clear()
                                tp.flush()
                            } catch (_: Exception) {}
                        case None => ()
                    }
                    // P2-159: clear item cache (notices/suggestions/entries) on logout.
                    // ic_notices_logout_clear: ip.clear() wipes the whole telegram_item_cache
                    // store, which is where services/NoticesService.cj persists every notices
                    // key family (see its own header comment) — notices_dismissed_ids,
                    // notices_peer_dismissed_<peerId>, notices_peer_suggestions_<peerId>,
                    // notice_entry_<key>, glo_<rawValue>, peer_<ns>_<peerId>_<subKey>. A
                    // whole-store clear is a superset of deleting that key list individually,
                    // so no separate per-key deletion is needed here.
                    match (this.abilityContext) {
                        case Some(ctx) =>
                            try {
                                let ip = Preferences.getPreferences(ctx, "telegram_item_cache")
                                ip.clear()
                                ip.flush()
                            } catch (_: Exception) {}
                        case None => ()
                    }
                    // ic_wbs_cache_invalidate_on_logout: D-177 dependency-inversion callbacks
                    // (see registerLogoutHook() above). services/SettingsService.cj registers
                    // invalidateWebBrowserSettingsCache() here so telegram_web_browser_settings
                    // is wiped on every logout path alongside the stores cleared above.
                    for (hook in _logoutHooks) {
                        try {
                            hook()
                        } catch (_: Exception) {}
                    }
                    // P2-157: clear contacts sync settings on logout
                    match (this.abilityContext) {
                        case Some(ctx) =>
                            try {
                                let cp = Preferences.getPreferences(ctx, "telegram_contacts_settings")
                                cp.clear()
                                cp.flush()
                            } catch (_: Exception) {}
                        case None => ()
                    }
                    // QA-3 fix: 登出/重置账号后清除 onboardingStarted，使得下次启动重新展示 intro
                    // （对齐 iOS：登出后回到未认证的初始引导态，不应"恢复"到手机号输入页）。
                    prefs.delete(KEY_ONBOARDING_STARTED)
                    // TC-0086 fix: 一并清 pendingAuthSlot——登出/重置账号不应留下一个陈旧的
                    // "进行中登录"指针。
                    prefs.delete(KEY_PENDING_AUTH_SLOT)
                    this._pendingAuthSlot = -1
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Slot ${currentSlot} cleared (logout)")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Failed to clear auth data: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthStorage] Preferences not initialized, cannot clear")
        }
    }

    // ==================== P2-151: Generic key-value helpers ====================

    /**
     * 读取任意整数值（用于 per-peer 静音设置等动态 key）
     * 注意：动态 key 属于当前 slot 的命名空间
     *
     * @param key       存储 key（会自动加 slot 前缀）
     * @param default_  找不到时的默认值
     * @return Int64 存储值
     */
    public func getIntValue(key: String, default_!: Int64 = 0): Int64 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let val = prefs.get(this.sk(key), PreferencesValueType.Integer(default_))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n
                        case _ => return default_
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] getIntValue(${key}) error: ${e}")
                    return default_
                }
            case None => return default_
        }
    }

    /**
     * 写入任意整数值（用于 per-peer 静音设置等动态 key）
     * 注意：动态 key 属于当前 slot 的命名空间
     *
     * @param key   存储 key（会自动加 slot 前缀）
     * @param value 存储值
     */
    public func setIntValue(key: String, value: Int64): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(key), PreferencesValueType.Integer(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] setIntValue(${key}) error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthStorage] setIntValue(${key}) skipped: no prefs")
        }
    }

    // ==================== Phase P2-152: 2FA Cached Token ====================

    /**
     * 持久化 2FA 临时密码 token
     * iOS 对应: _internal_cacheTwoStepPasswordToken (TwoStepVerification.swift:348-358)
     * Stored as base64(tmpPassword) + validUntil timestamp (Int64 seconds)
     */
    public func saveCachedTwoStepToken(tmpPassword: Array<Byte>, validUntil: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let encoded = Base64.encode(tmpPassword)
                    prefs.put(this.sk(KEY_2FA_TOKEN), PreferencesValueType.StringData(encoded))
                    prefs.put(this.sk(KEY_2FA_TOKEN_VALID_UNTIL), PreferencesValueType.Integer(Int64(validUntil)))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] 2FA token cached (slot=${this._activeSlot}) until ${validUntil}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveCachedTwoStepToken error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 读取已缓存的 2FA 临时密码 token
     * iOS 对应: _internal_cachedTwoStepPasswordToken (TwoStepVerification.swift:340-346)
     * 若 token 过期或不存在，返回 None
     */
    public func getCachedTwoStepToken(): Option<Array<Byte>> {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let untilVal = prefs.get(this.sk(KEY_2FA_TOKEN_VALID_UNTIL), PreferencesValueType.Integer(0))
                    let validUntil: Int64 = match (untilVal) {
                        case PreferencesValueType.Integer(n) => n
                        case _ => 0
                    }
                    let now = DateTime.now().toUnixTimeStamp().toSeconds()
                    if (validUntil <= now) {
                        Hilog.info(0, "CjTelegram", "[AuthStorage] 2FA token expired or missing")
                        return None
                    }
                    let tokenVal = prefs.get(this.sk(KEY_2FA_TOKEN), PreferencesValueType.StringData(""))
                    match (tokenVal) {
                        case PreferencesValueType.StringData(encoded) =>
                            if (encoded.size == 0) { return None }
                            let decoded = Base64.decode(encoded)
                            return Some(decoded)
                        case _ => return None
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] getCachedTwoStepToken error: ${e}")
                    return None
                }
            case None => return None
        }
    }

    /**
     * 清除 2FA 临时密码 token 缓存
     */
    public func clearCachedTwoStepToken(): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.delete(this.sk(KEY_2FA_TOKEN))
                    prefs.delete(this.sk(KEY_2FA_TOKEN_VALID_UNTIL))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] 2FA token cache cleared (slot=${this._activeSlot})")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] clearCachedTwoStepToken error: ${e}")
                }
            case None => ()
        }
    }

    // ==================== Phase P2-153: timezones list cache ====================

    /**
     * Save timezones list (JSON-encoded) + its hash for incremental updates.
     * iOS ref: TimezoneService.cacheList (help.getTimezonesList incremental).
     */
    public func saveTimezonesCache(hash: Int32, json: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_TIMEZONES_CACHE_HASH), PreferencesValueType.Integer(Int64(hash)))
                    prefs.put(this.sk(KEY_TIMEZONES_CACHE_JSON), PreferencesValueType.StringData(json))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveTimezonesCache error: ${e}")
                }
            case None => ()
        }
    }

    public func getTimezonesCacheHash(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v = prefs.get(this.sk(KEY_TIMEZONES_CACHE_HASH), PreferencesValueType.Integer(0))
                    match (v) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (_e: Exception) { return 0 }
            case None => return 0
        }
    }

    public func getTimezonesCacheJson(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v = prefs.get(this.sk(KEY_TIMEZONES_CACHE_JSON), PreferencesValueType.StringData(""))
                    match (v) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return ""
                    }
                } catch (_e: Exception) { return "" }
            case None => return ""
        }
    }

    // ==================== Phase P2-153: profile meta (local mirror) ====================

    public func saveProfileBirthday(json: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PROFILE_BIRTHDAY_JSON), PreferencesValueType.StringData(json))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveProfileBirthday error: ${e}")
                }
            case None => ()
        }
    }

    public func getProfileBirthday(): String {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v = prefs.get(this.sk(KEY_PROFILE_BIRTHDAY_JSON), PreferencesValueType.StringData(""))
                    match (v) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return ""
                    }
                } catch (_e: Exception) { return "" }
            case None => return ""
        }
    }

    public func saveProfileNameColor(color: Int32, bgEmojiId: Int64): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PROFILE_NAME_COLOR), PreferencesValueType.Integer(Int64(color)))
                    prefs.put(this.sk(KEY_PROFILE_BG_EMOJI_ID), PreferencesValueType.Integer(bgEmojiId))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveProfileNameColor error: ${e}")
                }
            case None => ()
        }
    }

    public func getProfileNameColor(): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v = prefs.get(this.sk(KEY_PROFILE_NAME_COLOR), PreferencesValueType.Integer(-1))
                    match (v) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return -1
                    }
                } catch (_e: Exception) { return -1 }
            case None => return -1
        }
    }

    public func getProfileBgEmojiId(): Int64 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v = prefs.get(this.sk(KEY_PROFILE_BG_EMOJI_ID), PreferencesValueType.Integer(0))
                    match (v) {
                        case PreferencesValueType.Integer(n) => return n
                        case _ => return 0
                    }
                } catch (_e: Exception) { return 0 }
            case None => return 0
        }
    }

    public func saveProfileEmojiStatus(docId: Int64, until: Int32): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PROFILE_EMOJI_STATUS_DOC_ID), PreferencesValueType.Integer(docId))
                    prefs.put(this.sk(KEY_PROFILE_EMOJI_STATUS_UNTIL), PreferencesValueType.Integer(Int64(until)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveProfileEmojiStatus error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * P2-304: 获取当前已设置的 emoji status document ID
     * 0 = 无状态（emojiStatusEmpty）
     */
    public func getProfileEmojiStatusDocId(): Int64 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v = prefs.get(this.sk(KEY_PROFILE_EMOJI_STATUS_DOC_ID), PreferencesValueType.Integer(0))
                    match (v) {
                        case PreferencesValueType.Integer(n) => return n
                        case _ => return 0
                    }
                } catch (_e: Exception) { return 0 }
            case None => return 0
        }
    }

    public func saveProfilePersonalChannelId(channelId: Int64): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    prefs.put(this.sk(KEY_PROFILE_PERSONAL_CHANNEL_ID), PreferencesValueType.Integer(channelId))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveProfilePersonalChannelId error: ${e}")
                }
            case None => ()
        }
    }

    public func getProfilePersonalChannelId(): Int64 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v = prefs.get(this.sk(KEY_PROFILE_PERSONAL_CHANNEL_ID), PreferencesValueType.Integer(0))
                    match (v) {
                        case PreferencesValueType.Integer(n) => return n
                        case _ => return 0
                    }
                } catch (_e: Exception) { return 0 }
            case None => return 0
        }
    }

    // ==================== Phase P2-156: Global Privacy Settings Cache ====================

    /**
     * Save global privacy settings mirror (archive/mute, keep unmuted, hide read marks, require premium).
     * iOS ref: TelegramUI globalPrivacySettings -> mirror in AccountSpecificPreferencesManager.
     * Used so UI can display current values without a network round-trip.
     * Cleared on logout via clearAll().
     */
    public func saveGlobalPrivacyCache(archiveMute: Bool, keepUnmuted: Bool, hideReadMarks: Bool, requirePremium: Bool): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v1: Int64 = if (archiveMute) { 1 } else { 0 }
                    let v2: Int64 = if (keepUnmuted) { 1 } else { 0 }
                    let v3: Int64 = if (hideReadMarks) { 1 } else { 0 }
                    let v4: Int64 = if (requirePremium) { 1 } else { 0 }
                    prefs.put(this.sk(KEY_GLOBAL_PRIVACY_ARCHIVE_MUTE), PreferencesValueType.Integer(v1))
                    prefs.put(this.sk(KEY_GLOBAL_PRIVACY_KEEP_UNMUTED), PreferencesValueType.Integer(v2))
                    prefs.put(this.sk(KEY_GLOBAL_PRIVACY_HIDE_READ_MARKS), PreferencesValueType.Integer(v3))
                    prefs.put(this.sk(KEY_GLOBAL_PRIVACY_REQUIRE_PREMIUM), PreferencesValueType.Integer(v4))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[AuthStorage] Global privacy cache saved (slot=${this._activeSlot}): archiveMute=${archiveMute} keepUnmuted=${keepUnmuted} hideReads=${hideReadMarks} requirePremium=${requirePremium}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[AuthStorage] saveGlobalPrivacyCache error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * Read global privacy cache. Returns (archiveMute, keepUnmuted, hideReadMarks, requirePremium).
     */
    public func getGlobalPrivacyCache(): (Bool, Bool, Bool, Bool) {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let v1 = prefs.get(this.sk(KEY_GLOBAL_PRIVACY_ARCHIVE_MUTE), PreferencesValueType.Integer(0))
                    let v2 = prefs.get(this.sk(KEY_GLOBAL_PRIVACY_KEEP_UNMUTED), PreferencesValueType.Integer(0))
                    let v3 = prefs.get(this.sk(KEY_GLOBAL_PRIVACY_HIDE_READ_MARKS), PreferencesValueType.Integer(0))
                    let v4 = prefs.get(this.sk(KEY_GLOBAL_PRIVACY_REQUIRE_PREMIUM), PreferencesValueType.Integer(0))
                    let b1: Bool = match (v1) { case PreferencesValueType.Integer(n) => n != 0; case _ => false }
                    let b2: Bool = match (v2) { case PreferencesValueType.Integer(n) => n != 0; case _ => false }
                    let b3: Bool = match (v3) { case PreferencesValueType.Integer(n) => n != 0; case _ => false }
                    let b4: Bool = match (v4) { case PreferencesValueType.Integer(n) => n != 0; case _ => false }
                    return (b1, b2, b3, b4)
                } catch (_e: Exception) { return (false, false, false, false) }
            case None => return (false, false, false, false)
        }
    }
}
