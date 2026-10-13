package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.ArkData.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import kit.ImageKit.{createImageSource, PixelMap}
import ohos_app_cangjie_entry.services.getAppFilesDir
import ohos_app_cangjie_entry.services.getTelegramEngineItemCacheService
import ohos_app_cangjie_entry.services.{getResourcesService, StorageCategoryKey, StorageUsageStats}
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.getRealChatListService
import ohos_app_cangjie_entry.services.getMessageHistoryStore
import ohos_app_cangjie_entry.services.getUserPhotoService
import ohos_app_cangjie_entry.services.getCurrentUserId
import ohos_app_cangjie_entry.services.JsonParser
import ohos_app_cangjie_entry.services.AvatarItem
import ohos_app_cangjie_entry.models.{Chat, Message}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSectionFooter,
    ItemListSeparator,
    AnimatedAvatarSetComponent,
    Avatar
}
import ohos_app_cangjie_entry.router.*
import std.collection.{ArrayList, HashSet}
import std.math.*
import std.sort.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.interop.{subscribe, callArkAsync}

/**
 * StorageUsagePage — source `StorageUsageScreen.swift` counterpart.
 * diag-suite_settings_data_storage-TC-0438-round2.md 修法方向 §0/§1 (TC-0438 return): the
 * `Storage Usage` row on `DataStorageSettingsPage` used to be a false-affordance
 * `scrollTo` — this is the real destination screen, this feature's first hop-1 build.
 * Also cross-checked against diag-suite_settings_data_storage-TC-0430.md §M1 (the fuller
 * source-baseline that round2 itself deferred to — that report shipped after round2 and
 * gives the exact preset/label/gating facts used below, e.g. the `.stories` 3-item / no-
 * "Never" menu split at StorageUsageScreen.swift:3106-3290).
 *
 * Scope actually built this round (see this feature's `.md` Hand-off for the parts
 * deliberately deferred — this file's allowlist is `pages/StorageUsagePage.cj` +
 * `ets/pages/StorageUsagePage.ets` + one `route_map.json` entry; it does **not** include
 * `pages/StorageUsageExceptionsPage.cj` (TC-0430 M2/hop-3, TC-0431's entire judgment
 * surface), so the "add exception" trailing item that the real per-category menu carries
 * is not built here — there is nowhere real to send it yet:
 *   - Title bar + real `routerPush` destination (closes TC-0438 B1 — this case only judges
 *     that the tap navigates, not this screen's content, see TC-0438 case §5 step 7).
 *   - Cache breakdown: reuses the exact same directory convention + `getAppFilesDir()` as
 *     `DataStorageSettingsPage.calculateCacheSize()` (photos/videos/documents/voice/
 *     stickers/gifs/thumbs + ItemCacheService) — a *new* scan function living in this file
 *     (not modifying that protected method), per round2 修法方向 §1's explicit instruction.
 *     Rendered as a real Canvas-drawn pie (same technique as GraphPage.pieChartCanvas) +
 *     a category legend list (StorageCategoriesComponent counterpart).
 *   - `AUTO-REMOVE CACHED MEDIA`: 4 real Keep-Media rows (Private Chats/Group Chats/
 *     Channels/Stories) with a functioning per-category duration menu (reuses the shared
 *     `components/ContextMenu.cj` overlay, same pattern as `WebSessionsPage`'s bottom
 *     action sheet) — selecting a duration persists to a dedicated Preferences store in
 *     this file (mirrors `MiscSettingsStore`'s pattern, not that class itself — that file
 *     isn't in this feature's `target_files`).
 *   - `Clear Entire Cache <size>` (source StorageCategoriesComponent button → requestClear
 *     action sheet → commitClear): the deletion loop lives once in `clearLocalMediaCache()`
 *     below and is shared with `DataStorageSettingsPage.clearCache()`; after clearing, the
 *     categorized scan re-runs so the total and legend drop immediately.
 *
 * Icons: `setroot_ds_private/group/channel` (already-converted catalog assets, matching
 * source's `PresentationResourcesSettings.privateChats/groups/channels`). No converted
 * "Stories" badge exists in this catalog family — reuses `autodl_ic_stories` (a real,
 * already-catalogued vector for the same "Stories" concept from the autodownload category
 * rows) rather than inventing a substitute; flagged in Hand-off as a resource front-run gap
 * for a proper `setroot_ds_stories` badge.
 */

// Preferences store for this screen's own state (self-contained — RaiseToListenService.cj's
// MiscSettingsStore isn't in this feature's target_files, so this is a separate small store
// following the exact same read/write pattern, not a shared import).
let STORAGE_USAGE_PREFS_NAME: String = "telegram_storage_usage"
let KEY_KEEP_PRIVATE: String = "keep_media_private_chats_seconds"
let KEY_KEEP_GROUP: String = "keep_media_group_chats_seconds"
let KEY_KEEP_CHANNEL: String = "keep_media_channels_seconds"
let KEY_KEEP_STORIES: String = "keep_media_stories_seconds"
let KEY_MAX_CACHE_GB: String = "maximum_cache_size_gigabytes"

// diag-suite_settings_data_storage-TC-0430-round5.md 修法方向 S-0：例外计数的唯一真实数据
// 源是 StorageUsageExceptionsPage 写入的那份 store —— 本页从不拥有它，只读。store 名字
// 逐字取自 pages/StorageUsageExceptionsPage.cj:169 storeName()；key 形状
// "${category}_exceptions" 取自同文件 :170 exceptionsKey()。两侧各持一份同名字面量、互相
// 注释交叉引用（与 DataStorageSettingsPage.ets/.cj 事件名字面量双持的既有先例同形）。
// 不得改 StorageUsageExceptionsPage.cj（不在本 feature allowlist）。
let STORAGE_USAGE_EXCEPTIONS_PREFS_NAME: String = "telegram_storage_usage_exceptions"

// Sentinel for "Never" (source: Int32.max via CacheStorageSettings.categoryStorageTimeout).
// A dedicated negative sentinel is used instead of Int32.max so every stored value fits
// comfortably in the same Int64 column as the real day-based durations below.
let NEVER_SECONDS: Int64 = -1
let SECONDS_1_MONTH: Int64 = 2678400   // 31 days — StorageUsageScreen.swift:3216
let SECONDS_1_WEEK: Int64 = 604800     // 7 days
let SECONDS_2_DAYS: Int64 = 172800     // 2 days — `.stories`-only preset
let SECONDS_1_DAY: Int64 = 86400       // 1 day

// Exact source assets from TelegramUI/Images.xcassets/Settings/Storage/Particle*.imageset,
// rasterized at their authored 72×72 canvas for the target resource pipeline.
private var storageParticlesLoaded: Bool = false
private var storageParticlePhotos: Option<PixelMap> = None
private var storageParticleVideos: Option<PixelMap> = None
private var storageParticleDocuments: Option<PixelMap> = None
private var storageParticleMusic: Option<PixelMap> = None
private var storageParticleStickers: Option<PixelMap> = None
private var storageParticleAvatars: Option<PixelMap> = None
private var storageParticleOther: Option<PixelMap> = None

private func loadStorageParticle(name: String): Option<PixelMap> {
    match (getGlobalAbilityContext()) {
        case None => return None
        case Some(ctx) =>
            try {
                return Some(createImageSource(ctx.resourceManager.getMediaByName(name)).createPixelMap())
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[StorageUsage] particle ${name} decode failed: ${e}")
                return None
            }
    }
}

private func ensureStorageParticlesLoaded(): Unit {
    if (storageParticlesLoaded) { return }
    storageParticlesLoaded = true
    storageParticlePhotos = loadStorageParticle("storage_particle_photos")
    storageParticleVideos = loadStorageParticle("storage_particle_videos")
    storageParticleDocuments = loadStorageParticle("storage_particle_documents")
    storageParticleMusic = loadStorageParticle("storage_particle_music")
    storageParticleStickers = loadStorageParticle("storage_particle_stickers")
    storageParticleAvatars = loadStorageParticle("storage_particle_avatars")
    storageParticleOther = loadStorageParticle("storage_particle_other")
}

private func storageParticleForIndex(idx: Int64): Option<PixelMap> {
    if (idx == 0) { return storageParticlePhotos }
    if (idx == 1) { return storageParticleVideos }
    if (idx == 2) { return storageParticleDocuments }
    if (idx == 3) { return storageParticleMusic }
    if (idx == 4) { return storageParticleStickers }
    if (idx == 5) { return storageParticleAvatars }
    return storageParticleOther
}

public class StorageDisplayCategory {
    public let category: Int64
    public let sizeBytes: Int64
    public let isMergedOther: Bool
    public let isChild: Bool

    public init(category: Int64, sizeBytes: Int64, isMergedOther!: Bool = false, isChild!: Bool = false) {
        this.category = category
        this.sizeBytes = sizeBytes
        this.isMergedOther = isMergedOther
        this.isChild = isChild
    }
}

public class StoragePeerCacheItem {
    public let peerId: Int64
    public let peerType: String
    public let title: String
    public let avatarPath: String
    public let avatarColor: Int64
    public let avatarText: String
    public let sizeBytes: Int64

    public init(peerId: Int64, peerType: String, title: String, avatarPath: String,
        avatarColor: Int64, avatarText: String, sizeBytes: Int64) {
        this.peerId = peerId
        this.peerType = peerType
        this.title = title
        this.avatarPath = avatarPath
        this.avatarColor = avatarColor
        this.avatarText = avatarText
        this.sizeBytes = sizeBytes
    }
}

/**
 * 清理本地媒体缓存（本页 Clear Entire Cache 与 DataStorageSettingsPage 的 Clear Cache 共用）。
 * 对齐 iOS StorageUsageScreen.commitClear：只删可重新下载的媒体缓存文件，
 * 会话、消息与账号数据不在这些目录里，不受影响。目录集合与本页 / DataStorageSettingsPage
 * 统计大小所扫的目录一致，清理后显示的大小才会随之下降。
 * @return 删除的文件数
 */
public func clearLocalMediaCache(): Int64 {
    let filesDir = getAppFilesDir()
    if (filesDir.size == 0) { return 0 }
    var deletedCount: Int64 = 0
    let subDirs = ["photos", "videos", "documents", "voice", "stickers", "gifs", "thumbs"]
    for (subDir in subDirs) {
        let dirPath = "${filesDir}/${subDir}"
        try {
            let entries = FileIo.listFile(dirPath)
            for (entry in entries) {
                try {
                    FileIo.unlink("${dirPath}/${entry}")
                    deletedCount = deletedCount + 1
                } catch (_e: Exception) {}
            }
        } catch (_e: Exception) {
            // Directory may not exist
        }
    }
    getTelegramEngineItemCacheService().clear()
    Hilog.info(0, "CjTelegram", "[StorageUsage] media cache cleared: ${deletedCount} files")
    return deletedCount
}

@HybridComponentEntry
@Component
public class StorageUsagePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false

    // ── cache breakdown (bytes per category, real scan — same 7-dir convention as
    // DataStorageSettingsPage.calculateCacheSize()) ──
    @State var totalBytes: Int64 = 0
    @State var catPhotosBytes: Int64 = 0
    @State var catVideosBytes: Int64 = 0
    @State var catFilesBytes: Int64 = 0     // source "documents" dir
    @State var catMusicBytes: Int64 = 0
    @State var catStickersBytes: Int64 = 0
    @State var catAvatarsBytes: Int64 = 0
    @State var catMiscBytes: Int64 = 0
    @State var selectedCategories: Int64 = 127
    @State var isOtherCategoryExpanded: Bool = false
    @State var isClearingCache: Bool = false
    @State var freeDiskBytes: Int64 = 0
    @State var totalDiskBytes: Int64 = 0
    @State var diskUsageFraction: Float64 = 0.0
    @State var diskUsageLabel: String = " "
    @State var maximumCacheIndex: Int64 = 3
    @State var peerCacheItems: ArrayList<StoragePeerCacheItem> = ArrayList<StoragePeerCacheItem>()

    // ── AUTO-REMOVE CACHED MEDIA: per-category keep-duration (seconds; NEVER_SECONDS
    // sentinel). Defaults per-category, matching source's `CacheStorageSettings.
    // defaultSettings` (SyncCore_CacheStorageSettings.swift:22-33) — NOT a uniform
    // `?? Int32.max` fallback for every category; that read was wrong
    // (diag-suite_settings_data_storage-TC-0430-round2.md 失效点2): the four keys always
    // exist in source's default map, so the `??` never actually fires. Real per-category
    // defaults: privateChats=Never, groups=1 month, channels=1 week, stories=2 days
    // (source dynamically appends the out-of-preset current value to that menu the first
    // time it's opened — see menuItemsForCategory()) ──
    @State var keepPrivateSeconds: Int64 = NEVER_SECONDS
    @State var keepGroupSeconds: Int64 = SECONDS_1_MONTH
    @State var keepChannelSeconds: Int64 = SECONDS_1_WEEK
    @State var keepStoriesSeconds: Int64 = SECONDS_2_DAYS

    // Deviation from diag-suite_settings_data_storage-TC-0430-round2.md M-1a's literal
    // instruction ("四个 *Label 的初值用 labelForSeconds(...) 求，不要手写字符串"): calling
    // `this.labelForSeconds(...)` here does not compile — Cangjie rejects instance-method
    // calls in a `@Component`'s `@State` field initializers ("'labelForSeconds' is not
    // allowed to be accessed before all member variables are initialized", confirmed by
    // `build.sh full`). These four literals are the values `labelForSeconds()` itself
    // returns for the four seconds constants directly above (verified by reading that
    // function's body — not independently re-derived), and `loadKeepMediaSettings()`
    // unconditionally overwrites all four via `this.labelForSeconds(...)` on load, so this
    // is only a same-frame placeholder, not a second source of truth that can drift silently.
    @State var keepPrivateLabel: String = "Never"
    @State var keepGroupLabel: String = "1 month"
    @State var keepChannelLabel: String = "1 week"
    @State var keepStoriesLabel: String = "2 days"

    // -1 = no menu open; 0=private 1=group 2=channel 3=stories
    @State var showMenuFor: Int64 = -1

    // diag-suite_settings_data_storage-TC-0430-round5.md 修法方向 S-0：三个例外计数
    // （不含 stories —— 源侧 :1871 `mappedCategory != .stories` 是硬门，stories 永不产生
    // 例外计数，见 exceptionAvatarItems()/currentExcCountFor() 同样把它排除在外）。
    @State var excCountPrivate: Int64 = 0
    @State var excCountGroup: Int64 = 0
    @State var excCountChannel: Int64 = 0

    // TC-0430-round5 S-0b：事件名字面量须与
    // entry/src/main/ets/pages/StorageUsagePage.ets 内 dispatchEvent(...) 逐字一致（同
    // DataStorageSettingsPage.ets/.cj、PhoneInputPage.ets/.cj 既有先例 —— interop.cj 不在
    // 本 feature target_files 内，故不新增共享常量）。
    private let storageUsageShownEvent: String = "settings.storageUsage.shown"
    // 独立于 `loaded`（后者门控首屏 spinner→内容切换，只有首次异步扫描完成后才置
    // true）的一次性订阅注册守卫 —— 若复用 `loaded` 做守卫，返回本页触发 onShown 时
    // （此时扫描早已完成、`loaded` 恒为 true）反而会跳过订阅注册。
    private var subscribedShown: Bool = false

    // TC-0430-round5 M5-A：四个 Keep-Media 行本地复刻的按压高亮态（对位
    // ItemListComponents.cj:751 `@State var isPressed: Bool` 的同一套三件套，见该行下方
    // onTouch）——本地行不再走共享 ItemListDisclosureRow，故每行各自持有一份。
    @State var isPressedPrivate: Bool = false
    @State var isPressedGroup: Bool = false
    @State var isPressedChannel: Bool = false
    @State var isPressedStories: Bool = false

    // diag-suite_settings_data_storage-TC-0430-round5.md §边界条件（颜色不得回退）：本地行
    // 必须使用与共享组件相同的颜色来源，不得写字面量退化掉主题响应
    // （出处：components/ItemListComponents.cj:13 与 :754）。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    private var chartCtx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    private var _prefs: Option<Preferences> = None

    private func refreshDiskUsagePresentation(): Unit {
        if (this.totalBytes <= 0 || this.freeDiskBytes <= 0) {
            this.diskUsageFraction = 0.0
            this.diskUsageLabel = if (this.totalBytes <= 0) {
                "Telegram cache is empty."
            } else {
                "Telegram cache uses ${this.totalLabel()} on this device."
            }
            return
        }
        this.diskUsageFraction = Float64(this.totalBytes) / Float64(this.freeDiskBytes + this.totalBytes)
        let tenths = Int64(floor(this.diskUsageFraction * 1000.0))
        let whole = tenths / 10
        let fraction = tenths % 10
        let percent = if (tenths < 1) {
            "<0.1"
        } else if (fraction == 0) {
            "${whole}"
        } else {
            "${whole}.${fraction}"
        }
        this.diskUsageLabel = "Telegram uses ${percent}% of your free disk space."
    }

    private func loadFreeDiskSpace(): Unit {
        callArkAsync("storage.stats", "{}", { response: String =>
            let result = JsonParser.parseObject(response)
            if (result.getBool("ok")) {
                this.freeDiskBytes = result.getInt("freeBytes")
                this.totalDiskBytes = result.getInt("totalBytes")
                this.maximumCacheIndex = this.maximumCacheIndexForValue(this.readSeconds(KEY_MAX_CACHE_GB, -1))
                this.refreshDiskUsagePresentation()
            }
        })
    }

    // ── Preferences (self-contained store, same read/write shape as
    // services/RaiseToListenService.cj's MiscSettingsStore) ──
    private func ensurePrefs(): Unit {
        match (this._prefs) {
            case Some(_) => ()
            case None =>
                match (getGlobalAbilityContext()) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[StorageUsage] No ability context — in-memory only")
                    case Some(ctx) =>
                        try {
                            let prefs = Preferences.getPreferences(ctx, STORAGE_USAGE_PREFS_NAME)
                            this._prefs = Some(prefs)
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[StorageUsage] Prefs open failed: ${e}")
                        }
                }
        }
    }

    private func readSeconds(key: String, fallback: Int64): Int64 {
        this.ensurePrefs()
        match (this._prefs) {
            case None => return fallback
            case Some(prefs) =>
                try {
                    let val = prefs.get(key, PreferencesValueType.Integer(fallback))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n
                        case _ => return fallback
                    }
                } catch (_: Exception) { return fallback }
        }
    }

    private func writeSeconds(key: String, value: Int64): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    prefs.put(key, PreferencesValueType.Integer(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[StorageUsage] writeSeconds(${key}) err: ${e}")
                }
        }
    }

    private func loadKeepMediaSettings(): Unit {
        // Fallback args mirror the per-category defaults above (M-1a) — this is the path
        // that actually takes effect the first time a user opens this screen (no prefs
        // key written yet); changing only the @State initializers above and leaving these
        // fallbacks on NEVER_SECONDS would silently undo the fix.
        this.keepPrivateSeconds = this.readSeconds(KEY_KEEP_PRIVATE, NEVER_SECONDS)
        this.keepGroupSeconds = this.readSeconds(KEY_KEEP_GROUP, SECONDS_1_MONTH)
        this.keepChannelSeconds = this.readSeconds(KEY_KEEP_CHANNEL, SECONDS_1_WEEK)
        this.keepStoriesSeconds = this.readSeconds(KEY_KEEP_STORIES, SECONDS_2_DAYS)
        let storedMaximum = this.readSeconds(KEY_MAX_CACHE_GB, -1)
        this.maximumCacheIndex = this.maximumCacheIndexForValue(storedMaximum)
        this.keepPrivateLabel = this.labelForSeconds(this.keepPrivateSeconds)
        this.keepGroupLabel = this.labelForSeconds(this.keepGroupSeconds)
        this.keepChannelLabel = this.labelForSeconds(this.keepChannelSeconds)
        this.keepStoriesLabel = this.labelForSeconds(this.keepStoriesSeconds)
    }

    private func maximumCacheValue(index: Int64): Int64 {
        if (index >= 3) { return -1 }
        let gib: Int64 = 1024 * 1024 * 1024
        if (this.totalDiskBytes > 100 * gib) {
            if (index == 0) { return 5 }
            if (index == 1) { return 20 }
            return 50
        }
        if (this.totalDiskBytes > 50 * gib) {
            if (index == 0) { return 5 }
            if (index == 1) { return 16 }
            return 32
        }
        if (this.totalDiskBytes > 24 * gib) {
            if (index == 0) { return 2 }
            if (index == 1) { return 8 }
            return 16
        }
        if (index == 0) { return 1 }
        if (index == 1) { return 4 }
        return 8
    }

    private func maximumCacheIndexForValue(value: Int64): Int64 {
        if (value < 0) { return 3 }
        var index: Int64 = 0
        while (index < 3) {
            if (this.maximumCacheValue(index) == value) { return index }
            index++
        }
        return 0
    }

    private func maximumCacheLabel(index: Int64): String {
        let value = this.maximumCacheValue(index)
        if (value < 0) { return "No Limit" }
        return "${value} GB"
    }

    private func setMaximumCacheIndex(index: Int64): Unit {
        this.maximumCacheIndex = index
        let value = this.maximumCacheValue(index)
        this.writeSeconds(KEY_MAX_CACHE_GB, if (value >= 0 && value < 5) { 5 } else { value })
    }

    // diag-suite_settings_data_storage-TC-0430-round5.md 修法方向 S-0：读通路本身
    // （不是刷新时序问题）—— 这个页面此前完全没有打开 StorageUsageExceptionsPage 写入的
    // 那份 store。同一 category 下的原始 (peerId,value) 数组结构与
    // StorageUsageExceptionsPage.cj:197-217 readRawExceptions() 逐字对位，只读、不写。
    // 注意：这是第二个独立的 Preferences store，不复用 `this._prefs`（那是
    // `telegram_storage_usage`），每次现开现关，同 ExceptionsPage 的既有写法。
    private func readExceptionPeerIds(category: String): ArrayList<Int64> {
        let out = ArrayList<Int64>()
        match (getGlobalAbilityContext()) {
            case None => ()
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, STORAGE_USAGE_EXCEPTIONS_PREFS_NAME)
                    match (prefs.get("${category}_exceptions", PreferencesValueType.StringData(""))) {
                        case PreferencesValueType.StringData(s) =>
                            if (s.size > 0) {
                                let arr = JsonParser.parseArray(s)
                                for (obj in arr.getObjects()) {
                                    out.add(obj.getInt("peerId"))
                                }
                            }
                        case _ => ()
                    }
                } catch (_e: Exception) {}
        }
        return out
    }

    private func readExceptionCount(category: String): Int64 {
        return this.readExceptionPeerIds(category).size
    }

    // 三个类别各读一次（stories 不建字段 —— 源侧 :1871 `mappedCategory != .stories` 硬门，
    // stories 永不产生例外）。调用点：① ensureLoaded() 首次加载时同步调一次；②
    // storageUsageShownEvent 订阅 handler（S-0b，从例外屏 pop 回来时刷新）。
    private func loadExceptionCounts(): Unit {
        this.excCountPrivate = this.readExceptionCount("privateChats")
        this.excCountGroup = this.readExceptionCount("groups")
        this.excCountChannel = this.readExceptionCount("channels")
    }

    private func currentExcCountFor(idx: Int64): Int64 {
        if (idx == 0) { return this.excCountPrivate }
        if (idx == 1) { return this.excCountGroup }
        return this.excCountChannel
    }

    // Source: CacheEvictionMenu_CategoryExceptions(count) — 副标题与菜单末项二形态共用同一
    // 文案 key（StorageUsageScreen.swift:3489-3494 与 :1871-1876 逐字同源）。
    private func exceptionSubtitle(n: Int64): String {
        if (n == 1) { return "1 Exception" }
        return "${n} Exceptions"
    }

    // 逐字对位 pages/StorageUsageExceptionsPage.cj:238-277 loadExceptions() 的同一解析路径
    // （getRealChatListService/getUserPhotoService/getCurrentUserId 三个 service getter +
    // 兜底串），保证两屏对同一 peerId 显示同一个名字。只取前 3 个（AnimatedAvatarSetComponent
    // 的 maxVisible=3），不需要参与人数/自身以外的字段。
    private func exceptionAvatarItems(category: String): Array<AvatarItem> {
        let peerIds = this.readExceptionPeerIds(category)
        let svc = getRealChatListService()
        let photoSvc = getUserPhotoService()
        let selfId = getCurrentUserId()
        let out = ArrayList<AvatarItem>()
        var i: Int64 = 0
        while (i < peerIds.size && out.size < 3) {
            let peerId = peerIds[i]
            var name = "Chat ${peerId}"
            var photoUrl = ""
            if (category == "privateChats") {
                if (peerId == selfId) {
                    name = "Saved Messages"
                } else {
                    match (svc.getCachedUser(peerId)) {
                        case Some(u) =>
                            var n = u.firstName
                            if (u.lastName.size > 0) { n = "${u.firstName} ${u.lastName}" }
                            if (n.size > 0) { name = n }
                        case None => ()
                    }
                }
                photoUrl = photoSvc.getUserPhotoPath(peerId)
            } else {
                match (svc.getCachedChat(peerId)) {
                    case Some(c) =>
                        if (c.title.size > 0) { name = c.title }
                    case None => ()
                }
                photoUrl = photoSvc.getChatPhotoPath(peerId)
            }
            out.add(AvatarItem(peerId, name, photoUrl, 0))
            i = i + 1
        }
        return out.toArray()
    }

    // ── labels / presets (source: StorageUsageScreen.swift:3195-3220, Localizable.strings
    // ClearCache.Never / MessageTimer.{Months,Weeks,Days}_1 / MessageTimer.Days_any) ──
    private func labelForSeconds(sec: Int64): String {
        if (sec == NEVER_SECONDS) { return "Never" }
        if (sec == SECONDS_1_MONTH) { return "1 month" }
        if (sec == SECONDS_1_WEEK) { return "1 week" }
        if (sec == SECONDS_2_DAYS) { return "2 days" }
        if (sec == SECONDS_1_DAY) { return "1 day" }
        return "${sec / 86400} days"
    }

    private func presetsFor(idx: Int64): ArrayList<Int64> {
        let list = ArrayList<Int64>()
        if (idx == 3) {
            // `.stories` — no "Never" option (source :3216-3220).
            list.add(SECONDS_1_WEEK)
            list.add(SECONDS_2_DAYS)
            list.add(SECONDS_1_DAY)
        } else {
            list.add(NEVER_SECONDS)
            list.add(SECONDS_1_MONTH)
            list.add(SECONDS_1_WEEK)
            list.add(SECONDS_1_DAY)
        }
        return list
    }

    private func currentSecondsFor(idx: Int64): Int64 {
        if (idx == 0) { return this.keepPrivateSeconds }
        if (idx == 1) { return this.keepGroupSeconds }
        if (idx == 2) { return this.keepChannelSeconds }
        return this.keepStoriesSeconds
    }

    private func categoryTitle(idx: Int64): String {
        if (idx == 0) { return "Private Chats" }
        if (idx == 1) { return "Group Chats" }
        if (idx == 2) { return "Channels" }
        return "Stories"
    }

    private func setCategoryDuration(idx: Int64, seconds: Int64): Unit {
        let label = this.labelForSeconds(seconds)
        if (idx == 0) {
            this.keepPrivateSeconds = seconds
            this.keepPrivateLabel = label
            this.writeSeconds(KEY_KEEP_PRIVATE, seconds)
        } else if (idx == 1) {
            this.keepGroupSeconds = seconds
            this.keepGroupLabel = label
            this.writeSeconds(KEY_KEEP_GROUP, seconds)
        } else if (idx == 2) {
            this.keepChannelSeconds = seconds
            this.keepChannelLabel = label
            this.writeSeconds(KEY_KEEP_CHANNEL, seconds)
        } else {
            this.keepStoriesSeconds = seconds
            this.keepStoriesLabel = label
            this.writeSeconds(KEY_KEEP_STORIES, seconds)
        }
        this.showMenuFor = -1
        Hilog.info(0, "CjTelegram", "[StorageUsage] keepMedia idx=${idx} seconds=${seconds}")
    }

    // Source: StorageUsageScreen.swift:3223-3226 sorts the appended current value in with
    // `presetValues.sort(by: >)`. Cangjie's NEVER_SECONDS sentinel is a dedicated `-1` (see
    // the sentinel comment above `let NEVER_SECONDS`), not source's `Int32.max`, so a
    // literal numeric descending sort on the raw Int64 values would put "Never" LAST
    // instead of first. `durationRank()` maps NEVER_SECONDS to the largest rank so the
    // insertion order matches source's intent (Never first, then decreasing real
    // durations) without changing the sentinel's actual stored/persisted value.
    private func durationRank(seconds: Int64): Int64 {
        if (seconds == NEVER_SECONDS) { return Int64.Max }
        return seconds
    }

    // Source: `if currentValue != 0 && !presetValues.contains(currentValue) { append; sort
    // (by: >) }` (StorageUsageScreen.swift:3223-3226). Builds a fresh list instead of
    // mutating `presetsFor(idx)`'s list in place so the base preset order (already
    // hand-ordered descending — see presetsFor()) stays untouched when no insertion is
    // needed.
    private func presetsWithCurrent(idx: Int64): ArrayList<Int64> {
        let presets = this.presetsFor(idx)
        let current = this.currentSecondsFor(idx)
        if (current == 0 || presets.contains(current)) {
            return presets
        }
        let currentRank = this.durationRank(current)
        let merged = ArrayList<Int64>()
        var inserted = false
        for (v in presets) {
            if (!inserted && currentRank > this.durationRank(v)) {
                merged.add(current)
                inserted = true
            }
            merged.add(v)
        }
        if (!inserted) {
            merged.add(current)
        }
        return merged
    }

    // TC-0430-round5 M5-B：`ContextMenuItem` 数据模型随 `ContextMenuView` 一并废弃
    // （菜单改走 M5-A 的 bindPopup + 本地 @Builder 内容，见 keepMediaMenuContent()）——
    // 报告 §修法方向 M5-B「推荐直接删除该函数」，此处采纳。

    // TC-0430-round5 M5-B「新增私有 helper categoryParam」：形状对齐既有 categoryTitle(idx)
    // （见上方 :237-242）。取值集合出处：pages/StorageUsageExceptionsPage.cj:44-46 的契约
    // 注释与 :180-185 的解析分支——键名逐字照抄该文件 :45 的原文，不得另发明。
    private func categoryParam(idx: Int64): String {
        if (idx == 0) { return "privateChats" }
        if (idx == 1) { return "groups" }
        if (idx == 2) { return "channels" }
        return "privateChats"
    }

    // ── cache scan (new categorized scan, same dir set + getAppFilesDir() as
    // DataStorageSettingsPage.calculateCacheSize(); that method's body is untouched) ──
    private func dirSize(filesDir: String, subDir: String): Int64 {
        var total: Int64 = 0
        let dirPath = "${filesDir}/${subDir}"
        try {
            let entries = FileIo.listFile(dirPath)
            for (entry in entries) {
                let fullPath = "${dirPath}/${entry}"
                try {
                    let stat = FileIo.stat(fullPath)
                    total = total + stat.size
                } catch (_e: Exception) {}
            }
        } catch (_e: Exception) {}
        return total
    }

    private func engineCategoryBytes(stats: StorageUsageStats, ordinal: Int32): Int64 {
        match (stats.categories.get(ordinal)) {
            case Some(category) => return category.sizeBytes
            case None => return 0
        }
    }

    private func cachedPathSize(path: String, seen: HashSet<String>): Int64 {
        if (path.isEmpty()) { return 0 }
        let realPath = if (path.startsWith("file://")) { path[7..] } else { path }
        if (realPath.isEmpty() || seen.contains(realPath)) { return 0 }
        seen.add(realPath)
        try {
            if (FileIo.access(realPath)) { return FileIo.stat(realPath).size }
        } catch (_e: Exception) {}
        return 0
    }

    private func cachedMediaSizeForPeer(chat: Chat): Int64 {
        let messages = getMessageHistoryStore().loadLocalMessages(
            chat.id, 1000, 0, peerType: chat.peerType)
        let seen = HashSet<String>()
        var total: Int64 = 0
        for (message in messages) {
            total += this.cachedPathSize(message.photoLocalPath, seen)
            total += this.cachedPathSize(message.webPagePhotoLocalPath, seen)
            total += this.cachedPathSize(message.documentLocalPath, seen)
            total += this.cachedPathSize(message.documentThumbnailPath, seen)
        }
        return total
    }

    private func collectPeerCacheItems(): ArrayList<StoragePeerCacheItem> {
        let result = ArrayList<StoragePeerCacheItem>()
        let dialogs = getRealChatListService().getDialogsLocalFirst(limit: 100)
        for (chat in dialogs) {
            let size = this.cachedMediaSizeForPeer(chat)
            if (size > 0) {
                result.add(StoragePeerCacheItem(
                    chat.id, chat.peerType, chat.name, chat.avatarLocalPath,
                    chat.avatarColor, chat.avatarText, size))
            }
        }
        sort<StoragePeerCacheItem>(result, lessThan: { left: StoragePeerCacheItem, right: StoragePeerCacheItem =>
            if (left.sizeBytes != right.sizeBytes) { return left.sizeBytes > right.sizeBytes }
            return left.title < right.title
        }, stable: true)
        return result
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loadKeepMediaSettings()
        this.loadExceptionCounts()
        this.loadFreeDiskSpace()
        // TC-0430-round5 S-0b：一次性订阅注册（D6「生命周期按需通信」既有先例，形状对齐
        // DataStorageSettingsPage.cj:208）——`subscribedShown` 独立守卫，见该字段旁注释。
        if (!this.subscribedShown) {
            this.subscribedShown = true
            subscribe(this.storageUsageShownEvent, { _payload: String => this.loadExceptionCounts() })
        }
        this.scanCacheSizes()
    }

    private func scanCacheSizes(): Unit {
        let _ = spawn {
            let filesDir = getAppFilesDir()
            var photos: Int64 = 0
            var videos: Int64 = 0
            var files: Int64 = 0
            var music: Int64 = 0
            var stickers: Int64 = 0
            var avatars: Int64 = 0
            var misc: Int64 = 0
            if (filesDir.size > 0) {
                photos = dirSize(filesDir, "photos")
                videos = dirSize(filesDir, "videos")
                files = dirSize(filesDir, "documents")
                // Telegram iOS presents cached audio as `.music`. Incoming/downloaded
                // voice files use `voices`; locally recorded messages use `voice`.
                music = dirSize(filesDir, "voices") + dirSize(filesDir, "voice")
                stickers = dirSize(filesDir, "stickers")
                let gifs = dirSize(filesDir, "gifs")
                let thumbs = dirSize(filesDir, "thumbs")
                let itemCacheBytes = getTelegramEngineItemCacheService().estimateCacheSizeBytes()
                avatars = dirSize(filesDir, "avatars") + dirSize(filesDir, "avatars_full")
                misc = gifs + thumbs + itemCacheBytes
            }
            // Media fetched through TelegramEngine.Resources lives in engine_resources,
            // a separate cache from FileDownloadService's typed directories. Source
            // aggregates all backends, so fold the authoritative service result into the
            // same presentation categories instead of silently omitting those bytes.
            let engineStats = getResourcesService().collectStorageUsageStats()
            photos += this.engineCategoryBytes(engineStats, 0)
            videos += this.engineCategoryBytes(engineStats, 1)
            files += this.engineCategoryBytes(engineStats, 2)
            music += this.engineCategoryBytes(engineStats, 3)
            stickers += this.engineCategoryBytes(engineStats, 4)
            avatars += this.engineCategoryBytes(engineStats, 5)
            misc += this.engineCategoryBytes(engineStats, 6)
            let total = photos + videos + files + music + stickers + avatars + misc
            let p = photos
            let vd = videos
            let fl = files
            let mu = music
            let sk = stickers
            let av = avatars
            let mi = misc
            let tt = total
            let peers = this.collectPeerCacheItems()
            launch {
                this.catPhotosBytes = p
                this.catVideosBytes = vd
                this.catFilesBytes = fl
                this.catMusicBytes = mu
                this.catStickersBytes = sk
                this.catAvatarsBytes = av
                this.catMiscBytes = mi
                this.totalBytes = tt
                this.peerCacheItems = peers
                this.refreshDiskUsagePresentation()
                this.loaded = true
                this.drawPieChart()
            }
        }
    }

    private func formatBytes(bytes: Int64): String {
        if (bytes < 0) { return "0 B" }
        if (bytes < 1024) { return "${bytes} B" }
        if (bytes < 1024 * 1024) { return "${bytes / 1024} KB" }
        if (bytes < 1024 * 1024 * 1024) { return "${bytes / (1024 * 1024)} MB" }
        return "${bytes / (1024 * 1024 * 1024)} GB"
    }

    private func totalLabel(): String {
        return this.formatBytes(this.totalBytes)
    }

    private func categoryBytes(idx: Int64): Int64 {
        if (idx == 0) { return this.catPhotosBytes }
        if (idx == 1) { return this.catVideosBytes }
        if (idx == 2) { return this.catFilesBytes }
        if (idx == 3) { return this.catMusicBytes }
        if (idx == 4) { return this.catStickersBytes }
        if (idx == 5) { return this.catAvatarsBytes }
        return this.catMiscBytes
    }

    private func cacheCategoryTitle(idx: Int64): String {
        if (idx == 0) { return "Photos" }
        if (idx == 1) { return "Videos" }
        if (idx == 2) { return "Files" }
        if (idx == 3) { return "Music" }
        if (idx == 4) { return "Stickers" }
        if (idx == 5) { return "Avatars" }
        return "Misc"
    }

    private func cacheCategoryColor(idx: Int64): UInt32 {
        if (idx == 0) { return 0xFF5AC8FA }
        if (idx == 1) { return 0xFF3478F6 }
        if (idx == 2) { return 0xFF34C759 }
        if (idx == 3) { return 0xFFFF2D55 }
        if (idx == 4) { return 0xFF5856D6 }
        if (idx == 5) { return 0xFFAF52DE }
        return 0xFFFF9500
    }

    private func sortedCacheCategoryIndices(): ArrayList<Int64> {
        let result = ArrayList<Int64>()
        var idx: Int64 = 0
        while (idx < 7) {
            if (this.categoryBytes(idx) > 0) { result.add(idx) }
            idx++
        }
        sort<Int64>(result, lessThan: { left: Int64, right: Int64 =>
            let leftSize = this.categoryBytes(left)
            let rightSize = this.categoryBytes(right)
            if (leftSize != rightSize) { return leftSize > rightSize }
            return this.cacheCategoryTitle(left) < this.cacheCategoryTitle(right)
        }, stable: true)
        return result
    }

    private func mergedOtherBytes(): Int64 {
        let sorted = this.sortedCacheCategoryIndices()
        if (sorted.size <= 5) { return 0 }
        var result: Int64 = 0
        var idx: Int64 = 4
        while (idx < sorted.size) {
            result += this.categoryBytes(sorted[idx])
            idx++
        }
        return result
    }

    private func mergedOtherSelectedBytes(): Int64 {
        let sorted = this.sortedCacheCategoryIndices()
        if (sorted.size <= 5) { return 0 }
        var result: Int64 = 0
        var idx: Int64 = 4
        while (idx < sorted.size) {
            let category = sorted[idx]
            if (this.isCacheCategorySelected(category)) { result += this.categoryBytes(category) }
            idx++
        }
        return result
    }

    private func isMergedOtherSelected(): Bool {
        let sorted = this.sortedCacheCategoryIndices()
        if (sorted.size <= 5) { return false }
        var idx: Int64 = 4
        while (idx < sorted.size) {
            if (!this.isCacheCategorySelected(sorted[idx])) { return false }
            idx++
        }
        return true
    }

    private func toggleMergedOther(): Unit {
        let sorted = this.sortedCacheCategoryIndices()
        let shouldSelect = !this.isMergedOtherSelected()
        var idx: Int64 = 4
        while (idx < sorted.size) {
            let bit: Int64 = 1 << sorted[idx]
            if (shouldSelect) {
                this.selectedCategories = this.selectedCategories | bit
            } else if ((this.selectedCategories & bit) != 0) {
                this.selectedCategories = this.selectedCategories ^ bit
            }
            idx++
        }
        this.drawPieChart()
    }

    private func displayCacheCategories(): ArrayList<StorageDisplayCategory> {
        let sorted = this.sortedCacheCategoryIndices()
        let rows = ArrayList<StorageDisplayCategory>()
        if (sorted.size <= 5) {
            for (category in sorted) {
                rows.add(StorageDisplayCategory(category, this.categoryBytes(category)))
            }
            return rows
        }
        var idx: Int64 = 0
        while (idx < 4) {
            let category = sorted[idx]
            rows.add(StorageDisplayCategory(category, this.categoryBytes(category)))
            idx++
        }
        rows.add(StorageDisplayCategory(-1, this.mergedOtherBytes(), isMergedOther: true))
        if (this.isOtherCategoryExpanded) {
            idx = 4
            while (idx < sorted.size) {
                let category = sorted[idx]
                rows.add(StorageDisplayCategory(category, this.categoryBytes(category), isChild: true))
                idx++
            }
        }
        return rows
    }

    private func cacheCategoryPercent(idx: Int64): String {
        if (!this.isCacheCategorySelected(idx)) { return "0%" }
        return this.cachePercentForBytes(this.categoryBytes(idx))
    }

    private func cachePercentForBytes(bytes: Int64): String {
        let selected = this.selectedCacheBytes()
        if (selected <= 0 || bytes <= 0) { return "0%" }
        let tenths = bytes * 1000 / selected
        let whole = tenths / 10
        let fraction = tenths % 10
        if (fraction == 0) { return "${whole}%" }
        return "${whole}.${fraction}%"
    }

    private func hasLaterVisibleCategory(idx: Int64): Bool {
        var next = idx + 1
        while (next < 7) {
            if (this.categoryBytes(next) > 0) { return true }
            next++
        }
        return false
    }

    private func isCacheCategorySelected(idx: Int64): Bool {
        return (this.selectedCategories & (1 << idx)) != 0
    }

    private func toggleCacheCategory(idx: Int64): Unit {
        this.selectedCategories = this.selectedCategories ^ (1 << idx)
        this.drawPieChart()
    }

    private func selectedCacheBytes(): Int64 {
        var result: Int64 = 0
        var idx: Int64 = 0
        while (idx < 7) {
            if (this.isCacheCategorySelected(idx)) { result += this.categoryBytes(idx) }
            idx++
        }
        return result
    }

    private func removeFilesIn(filesDir: String, subDir: String): Unit {
        let path = "${filesDir}/${subDir}"
        try {
            let entries = FileIo.listFile(path)
            for (entry in entries) {
                try { FileIo.unlink("${path}/${entry}") } catch (_e: Exception) {}
            }
        } catch (_e: Exception) {}
    }

    private func clearSelectedCache(): Unit {
        if (this.isClearingCache || this.selectedCacheBytes() <= 0) { return }
        this.isClearingCache = true
        let mask = this.selectedCategories
        let _ = spawn {
            let filesDir = getAppFilesDir()
            if (filesDir.size > 0) {
                if ((mask & 1) != 0) { this.removeFilesIn(filesDir, "photos") }
                if ((mask & 2) != 0) { this.removeFilesIn(filesDir, "videos") }
                if ((mask & 4) != 0) { this.removeFilesIn(filesDir, "documents") }
                if ((mask & 8) != 0) {
                    this.removeFilesIn(filesDir, "voices")
                    this.removeFilesIn(filesDir, "voice")
                }
                if ((mask & 16) != 0) { this.removeFilesIn(filesDir, "stickers") }
                if ((mask & 32) != 0) {
                    this.removeFilesIn(filesDir, "avatars")
                    this.removeFilesIn(filesDir, "avatars_full")
                }
                if ((mask & 64) != 0) {
                    this.removeFilesIn(filesDir, "gifs")
                    this.removeFilesIn(filesDir, "thumbs")
                    getTelegramEngineItemCacheService().clear()
                }
            }
            let engineCategories = ArrayList<StorageCategoryKey>()
            if ((mask & 1) != 0) { engineCategories.add(StorageCategoryKey.Photos) }
            if ((mask & 2) != 0) { engineCategories.add(StorageCategoryKey.Videos) }
            if ((mask & 4) != 0) { engineCategories.add(StorageCategoryKey.Files) }
            if ((mask & 8) != 0) { engineCategories.add(StorageCategoryKey.Music) }
            if ((mask & 16) != 0) { engineCategories.add(StorageCategoryKey.Stickers) }
            if ((mask & 32) != 0) { engineCategories.add(StorageCategoryKey.Avatars) }
            if ((mask & 64) != 0) { engineCategories.add(StorageCategoryKey.Misc) }
            if (!engineCategories.isEmpty()) {
                getResourcesService().clearStorageByCategory(engineCategories)
            }
            launch {
                this.loaded = false
                this.isClearingCache = false
                this.ensureLoaded()
            }
        }
    }

    // ── pie chart (same Canvas arc-stroke technique as GraphPage.drawPieChart(), a
    // different feature's file — not imported/modified, just the same already-proven
    // ArkUI Canvas2D technique reapplied here) ──
    private func drawPieChart(): Unit {
        let cx: Float64 = 160.0
        let cy: Float64 = 110.0
        let radius: Float64 = 70.0

        this.chartCtx.fillStyle = this.presentation.backgroundColor
        this.chartCtx.fillRect(0.0, 0.0, 320.0, 220.0)

        ensureStorageParticlesLoaded()

        let selectedTotal = this.selectedCacheBytes()
        if (selectedTotal <= 0) {
            // Empty cache — draw a flat grey ring instead of a zero-division pie, still a
            // real (non-fake) rendering of "there is nothing to show yet".
            this.chartCtx.lineWidth = radius * 0.55
            this.chartCtx.strokeStyle = this.presentation.dividerColor
            this.chartCtx.beginPath()
            this.chartCtx.arc(cx, cy, radius * 0.72, 0.0, 6.2832)
            this.chartCtx.stroke()
            return
        }

        // `StorageUsageScreen.swift` derives chart items from the same size-sorted
        // categories as the list. If there are more than five categories, indices 4+
        // are one Misc-colored slice while collapsed and individual slices when open.
        let sorted = this.sortedCacheCategoryIndices()
        let chartRows = ArrayList<StorageDisplayCategory>()
        if (sorted.size <= 5 || this.isOtherCategoryExpanded) {
            for (category in sorted) {
                chartRows.add(StorageDisplayCategory(category, this.categoryBytes(category)))
            }
        } else {
            var sortedIndex: Int64 = 0
            while (sortedIndex < 4) {
                let category = sorted[sortedIndex]
                chartRows.add(StorageDisplayCategory(category, this.categoryBytes(category)))
                sortedIndex++
            }
            chartRows.add(StorageDisplayCategory(-1, this.mergedOtherBytes(), isMergedOther: true))
        }

        var startAngle: Float64 = -1.5708
        var chartIndex: Int64 = 0
        while (chartIndex < chartRows.size) {
            let chartRow = chartRows[chartIndex]
            let v = if (chartRow.isMergedOther) {
                this.mergedOtherSelectedBytes()
            } else if (this.isCacheCategorySelected(chartRow.category)) {
                chartRow.sizeBytes
            } else {
                0
            }
            if (v > 0) {
                let sliceAngle = 6.2832 * Float64(v) / Float64(selectedTotal)
                let endAngle = startAngle + sliceAngle
                this.chartCtx.lineWidth = radius * 0.55
                this.chartCtx.strokeStyle = if (chartRow.isMergedOther) {
                    0xFFFF9500
                } else {
                    this.cacheCategoryColor(chartRow.category)
                }
                this.chartCtx.beginPath()
                this.chartCtx.arc(cx, cy, radius * 0.72, startAngle, endAngle)
                this.chartCtx.stroke()

                // Source tiles the category's authored particle asset inside its section.
                // Test grid centres against the annular sector before drawing, keeping the
                // whole 12px glyph inside both radial edges so no target-side clipping
                // approximation can leak across section boundaries.
                match (storageParticleForIndex(if (chartRow.isMergedOther) { 6 } else { chartRow.category })) {
                    case None => ()
                    case Some(particle) =>
                        this.chartCtx.globalAlpha = 0.24
                        var py: Float64 = 53.0
                        var row: Int64 = 0
                        while (py <= 167.0) {
                            var px: Float64 = if ((row & 1) == 0) { 103.0 } else { 118.0 }
                            while (px <= 217.0) {
                                let dx = px - cx
                                let dy = py - cy
                                let distance = sqrt(dx * dx + dy * dy)
                                if (distance >= 39.0 && distance <= 63.0) {
                                    var pointAngle = atan2(dy, dx)
                                    while (pointAngle < startAngle) { pointAngle += 6.2832 }
                                    if (pointAngle >= startAngle + 0.08 && pointAngle <= endAngle - 0.08) {
                                        this.chartCtx.drawImage(particle, px - 6.0, py - 6.0, 12.0, 12.0)
                                    }
                                }
                                px += 30.0
                            }
                            py += 27.0
                            row += 1
                        }
                        this.chartCtx.globalAlpha = 1.0
                }

                // Source PieChartComponent places a white semibold percentage inside a
                // section only when its measured label fits. The 9% cutoff is the
                // equivalent fit gate for this fixed-radius target chart; smaller slices
                // keep their exact percentage in the list row instead of overlapping.
                let fraction = Float64(v) / Float64(selectedTotal)
                if (fraction >= 0.09) {
                    let midAngle = (startAngle + endAngle) / 2.0
                    let labelRadius = radius * 0.72
                    let tenths = v * 1000 / selectedTotal
                    let whole = tenths / 10
                    let remainder = tenths % 10
                    let label = if (remainder == 0) { "${whole}%" } else { "${whole}.${remainder}%" }
                    this.chartCtx.font = "bold 16px sans-serif"
                    this.chartCtx.fillStyle = 0xFFFFFFFF
                    this.chartCtx.textAlign = "center"
                    this.chartCtx.textBaseline = "middle"
                    this.chartCtx.fillText(label, cx + cos(midAngle) * labelRadius, cy + sin(midAngle) * labelRadius)
                }
                startAngle = endAngle
            }
            chartIndex++
        }
    }

    @Builder func pieChartCanvas(): Unit {
        Stack {
            Canvas(this.chartCtx)
                .width(320)
                .height(220)
                .onReady({ => this.drawPieChart() })
            Text(this.formatBytes(this.selectedCacheBytes()))
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.presentation.textColor)
        }
        .width(100.percent)
        .height(220)
    }

    // ── category legend row (colored dot + label + value) — 6 explicit rows, same
    // unrolled-rows convention as AutodownloadConnectionTypePage's 4 media-type rows ──
    // Category sizes are read from @State inside the builder (by index), not passed as
    // builder value args: value args are frozen at first render, so after Clear Entire
    // Cache the rows kept the pre-clear sizes while the total (read from state) dropped.
    @Builder func selectableLegendRow(idx: Int64): Unit {
        Row {
            Row {
                if (this.isCacheCategorySelected(idx)) {
                    Image(@r(app.media.media_ic_check)).width(18).height(18).fillColor(0xFFFFFFFF)
                }
            }
            .width(24).height(24).borderRadius(12)
            .backgroundColor(this.cacheCategoryColor(idx))
            .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
            .margin(right: 16)
            Text(this.cacheCategoryTitle(idx))
                .fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1)
            Text(this.cacheCategoryPercent(idx))
                .fontSize(17).fontColor(this.presentation.secondaryTextColor)
                .margin(right: 12)
            Text(this.formatBytes(this.categoryBytes(idx)))
                .fontSize(17).fontColor(this.presentation.secondaryTextColor)
        }
        .width(100.percent).height(52)
        .padding(left: 20, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.toggleCacheCategory(idx) })
    }

    @Builder func displayLegendRow(row: StorageDisplayCategory): Unit {
        if (row.isMergedOther) {
            Row {
                Row {
                    if (this.isMergedOtherSelected()) {
                        Image(@r(app.media.media_ic_check)).width(18).height(18).fillColor(0xFFFFFFFF)
                    }
                }
                .width(24).height(24).borderRadius(12)
                .backgroundColor(if (this.isOtherCategoryExpanded) { 0xFFC4C4C6 } else { 0xFFFF9500 })
                .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                .margin(right: 16)
                .onClick({ _ => this.toggleMergedOther() })
                Text("Other")
                    .fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1)
                Text(this.cachePercentForBytes(this.mergedOtherSelectedBytes()))
                    .fontSize(17).fontColor(this.presentation.secondaryTextColor)
                    .margin(right: 12)
                Text(this.formatBytes(row.sizeBytes))
                    .fontSize(17).fontColor(this.presentation.secondaryTextColor)
                Image(@r(app.media.item_list_disclosure_arrow))
                    .width(8).height(13).fillColor(this.presentation.disclosureArrowColor)
                    .rotate(angle: if (this.isOtherCategoryExpanded) { 90.0 } else { 0.0 })
                    .margin(left: 8)
            }
            .width(100.percent).height(52)
            .padding(left: 20, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ => this.isOtherCategoryExpanded = !this.isOtherCategoryExpanded })
        } else {
            Row {
                Row {
                    if (this.isCacheCategorySelected(row.category)) {
                        Image(@r(app.media.media_ic_check)).width(18).height(18).fillColor(0xFFFFFFFF)
                    }
                }
                .width(24).height(24).borderRadius(12)
                .backgroundColor(this.cacheCategoryColor(row.category))
                .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                .margin(left: if (row.isChild) { 24 } else { 0 }, right: 16)
                Text(this.cacheCategoryTitle(row.category))
                    .fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1)
                Text(this.cacheCategoryPercent(row.category))
                    .fontSize(17).fontColor(this.presentation.secondaryTextColor)
                    .margin(right: 12)
                Text(this.formatBytes(row.sizeBytes))
                    .fontSize(17).fontColor(this.presentation.secondaryTextColor)
            }
            .width(100.percent).height(52)
            .padding(left: 20, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ _ => this.toggleCacheCategory(row.category) })
        }
    }

    @Builder func peerCacheRow(item: StoragePeerCacheItem): Unit {
        Row {
            Row {
                Avatar(
                    avatarUrl: item.avatarPath,
                    displayName: item.title,
                    avatarSize: 40,
                    avatarColor: item.avatarColor,
                    peerId: item.peerId,
                    letters: item.avatarText
                )
            }
            .width(52)
            .height(48)
            .alignItems(VerticalAlign.Center)
            Text(item.title)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.presentation.textColor)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .layoutWeight(1)
            Text(this.formatBytes(item.sizeBytes))
                .fontSize(17)
                .fontColor(this.presentation.secondaryTextColor)
        }
        .width(100.percent)
        .height(52)
        .padding(left: 10, right: 16)
        .alignItems(VerticalAlign.Center)
    }

    // TC-0430-round5 M5-A/M5-B：菜单**卡片内容**——不含全屏容器、不含压暗、不含居中
    // （对位源侧 .reference 呈现下页面零施加压暗/模糊；形状出处 DevicesPage.cj:643-685
    // ttlMenuContent()，同一条源侧原语的已交付、已 PASS（TC-0137）版本）。周期项对勾列
    // 恒占位（非当前值 opacity(0.0)，不省略节点，避免非当前项文字左移）。
    // presetsWithCurrent(idx).size, factored out because `let` statements aren't legal
    // directly inside a @Builder body ("Only UI component syntax can be written in build
    // method" — confirmed by `build.sh cangjie`); called from inside the Divider gate
    // below instead of bound to a local.
    private func presetCountFor(idx: Int64): Int64 {
        return this.presetsWithCurrent(idx).size
    }

    @Builder
    private func keepMediaMenuContent() {
        // The trailing per-item Divider must never draw after the *last* preset row
        // (DevicesPage.cj:676 `if (idx < 3)` is the same guard for its fixed 4-item menu).
        // The exceptions row below gets its own 8px group-band Divider instead of a second
        // thin one — stacking both would be a double separator with no source counterpart.
        Column {
            ForEach(this.presetsWithCurrent(this.showMenuFor).toArray(), itemGenerator: { v: Int64, idx: Int64 =>
                Column {
                    Row {
                        Image(@r(app.media.media_ic_check))
                            .width(18)
                            .height(18)
                            .fillColor(0x0088CC)
                            .opacity(if (v == this.currentSecondsFor(this.showMenuFor)) { 1.0 } else { 0.0 })
                            .margin(right: 10)
                        Text(this.labelForSeconds(v))
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.setCategoryDuration(this.showMenuFor, v); this.showMenuFor = -1 })

                    if (idx < this.presetCountFor(this.showMenuFor) - 1) {
                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 16)
                    }
                }
            })

            // TC-0430-round5 M5-B：exceptions 末项——对位源侧 :3248-3279（分组带 + 末项 +
            // stories 硬门 + 悬挂分隔线处理）。分组带与末项同在 `showMenuFor != 3` 分支内，
            // stories 分类根本不进该分支 ⇒ 天然等价于源侧 removeLast()，B3 负向判据不受影响。
            if (this.showMenuFor != 3) {
                Divider().color(this.presentation.dividerColor).strokeWidth(8)
                // diag-suite_settings_data_storage-TC-0430-round5.md 修法方向 S-2（B2 有例外
                // 分支）：末项二形态，`.onClick` 逐字相同（源侧两形态点击契约相同，
                // StorageUsageScreen.swift:3262-3276）——先取 category 再置 -1，否则
                // categoryParam(-1) 取不到值。
                if (this.currentExcCountFor(this.showMenuFor) > 0) {
                    Row {
                        Text(this.exceptionSubtitle(this.currentExcCountFor(this.showMenuFor)))
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                            .layoutWeight(1)
                        AnimatedAvatarSetComponent(
                            items: this.exceptionAvatarItems(this.categoryParam(this.showMenuFor)),
                            avatarSize: 24,
                            spacing: 10,
                            maxVisible: 3
                        )
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        let cat = this.categoryParam(this.showMenuFor)
                        this.showMenuFor = -1
                        routerPush("StorageUsageExceptionsPage", "{\"category\":\"${cat}\"}")
                    })
                } else {
                    Row {
                        if (this.showMenuFor == 0) {
                            Image(@r(app.media.contact_ic_addmember))
                                .width(18)
                                .height(18)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 10)
                        } else {
                            Image(@r(app.media.location_ic_creategroup))
                                .width(18)
                                .height(18)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 10)
                        }
                        Text(trSource("Add Exception"))
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        let cat = this.categoryParam(this.showMenuFor)
                        this.showMenuFor = -1
                        routerPush("StorageUsageExceptionsPage", "{\"category\":\"${cat}\"}")
                    })
                }
            }
        }
        .width(240)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(14)
    }

    public func build() {
        Stack(alignContent: Alignment.TopStart) {
            Column {
                if (!this.loaded) {
                    // Single system spinner state, matching source's "aggregatedData == nil
                    // ⇒ whole screen is just the spinner" behaviour (TC-0430 M1 §201) — no
                    // scroll content renders before the first real scan result lands.
                    Column {
                        LoadingProgress()
                            .width(36)
                            .height(36)
                            .color(this.presentation.accentColor)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Scroll {
                        Column {
                            this.pieChartCanvas()

                            Text(trSource("Storage Usage"))
                                .fontSize(28)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.presentation.textColor)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .margin(top: 8)

                            Text(this.diskUsageLabel)
                                .fontSize(15)
                                .fontColor(this.presentation.secondaryTextColor)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .margin(top: 4, bottom: 8)

                            Stack(alignContent: Alignment.TopStart) {
                                Row {}
                                    .width(200).height(4).borderRadius(2)
                                    .backgroundColor(this.presentation.accentColor & 0x33FFFFFF)
                                Row {}
                                    .width(if (this.diskUsageFraction > 0.0) {
                                        4.0 + this.diskUsageFraction * 196.0
                                    } else { 0.0 })
                                    .height(4).borderRadius(2)
                                    .backgroundColor(this.presentation.accentColor)
                            }
                            .width(200).height(4)
                            .margin(bottom: 18)

                            Column {
                                ForEach(this.displayCacheCategories(), itemGeneratorFunc: { row: StorageDisplayCategory, idx: Int64 =>
                                    this.displayLegendRow(row)
                                    if (idx < this.displayCacheCategories().size - 1) {
                                        ItemListSeparator(leftInset: if (row.isChild) { 84 } else { 60 })
                                    }
                                }, keyGeneratorFunc: { row: StorageDisplayCategory, _idx: Int64 =>
                                    "storage_${row.category}_${row.sizeBytes}_${row.isMergedOther}_${row.isChild}_${this.isOtherCategoryExpanded}"
                                })
                                Row {
                                    Text(if (this.isClearingCache) {
                                        "Clearing Cache…"
                                    } else {
                                        "Clear Entire Cache ${this.formatBytes(this.selectedCacheBytes())}"
                                    })
                                    .fontSize(17).fontWeight(FontWeight.Bold)
                                    .fontColor(0xFFFFFFFF)
                                }
                                .width(100.percent).height(50).borderRadius(25)
                                .backgroundColor(if (this.selectedCacheBytes() > 0 && !this.isClearingCache) {
                                    0xFF18A57D
                                } else {
                                    this.presentation.dividerColor
                                })
                                .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                                .margin(left: 16, right: 16, top: 12, bottom: 16)
                                .onClick({ _ => this.clearSelectedCache() })
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(26)
                            .margin(left: 16, right: 16, top: 8)

                            ItemListSectionFooter(
                                text: "All media will stay in the Telegram cloud and can be re-downloaded if you need them again."
                            )

                            // ── AUTO-REMOVE CACHED MEDIA (source :1809/:1875-1892) ──
                            ItemListSectionHeader(title: "AUTO-REMOVE CACHED MEDIA", topPad: 28)

                            // TC-0430-round5 M5-A：四行改为本文件内本地复现（非
                            // ItemListDisclosureRow 调用——components/ItemListComponents.cj
                            // 不在本 feature allowlist，其 value/chevron 子节点不可从外部取到，
                            // 也不可给它加参数，见 dev_pattern.md D-184）。逐字节复制
                            // ItemListComponents.cj:838-941 的单行分支（useDetailLabelStyle=
                            // false、additionalDetailLabel="" 的那条路径），只做四处受控改动：
                            // 右值 + chevron 追加 opacity(菜单开合) + 右值挂 bindPopup、onClick
                            // 改写 showMenuFor、按压高亮三件套逐字保留。锚点/压暗形状出处
                            // DevicesPage.cj:1238-1273（TC-0137，已交付、已 PASS）。
                            Column {
                                Row {
                                    Image(@r(app.media.setroot_ds_private))
                                        .width(29)
                                        .height(29)
                                        .margin(right: 16)
                                    // diag-suite_settings_data_storage-TC-0430-round5.md
                                    // 修法方向 S-1（A5 正向半条）：计数 >0 时渲染第二行副标题，
                                    // 计数 0 时该 `if` 分支整体不生成节点（不留空 Text —— 否则
                                    // A5 负向半条会退化）。数值对位 StoragePeerTypeItemComponent
                                    // .swift:193（fontSize 15/secondaryTextColor）、:214（间距 1pt）。
                                    Column {
                                        Text(this.categoryTitle(0))
                                            .fontSize(17)
                                            .fontColor(this.presentation.textColor)
                                        if (this.excCountPrivate > 0) {
                                            Text(this.exceptionSubtitle(this.excCountPrivate))
                                                .fontSize(15)
                                                .fontColor(this.presentation.secondaryTextColor)
                                                .margin(top: 1)
                                        }
                                    }
                                    .layoutWeight(1)
                                    .alignItems(HorizontalAlign.Start)
                                    Text(this.keepPrivateLabel)
                                        .fontSize(17)
                                        .fontColor(this.presentation.secondaryTextColor)
                                        .margin(right: 6)
                                        .opacity(if (this.showMenuFor == 0) { 0.5 } else { 1.0 })
                                        .bindPopup(
                                            this.showMenuFor == 0,
                                            CustomPopupOptions(
                                                builder: bind(this.keepMediaMenuContent, this),
                                                placement: Placement.Bottom,
                                                popupColor: Color.Transparent,
                                                enableArrow: false,
                                                autoCancel: true,
                                                radius: 14.vp,
                                                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                                                    if (!evt.isVisible && this.showMenuFor == 0) { this.showMenuFor = -1 }
                                                })
                                            )
                                        )
                                    Image(@r(app.media.item_list_context_disclosure_arrow))
                                        .width(12)
                                        .height(16)
                                        .fillColor(this.presentation.disclosureArrowColor)
                                        .opacity(if (this.showMenuFor == 0) { 0.5 } else { 1.0 })
                                }
                                .width(100.percent)
                                .constraintSize(minHeight: if (this.excCountPrivate > 0) { 64 } else { 52 })
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(if (!this.isPressedPrivate) { Color.Transparent } else { this.presentation.itemHighlightedBackgroundColor })
                                .onClick({ _ => this.showMenuFor = 0 })
                                .onTouch({ evt =>
                                    match (evt.eventType) {
                                        case TouchType.Down => this.isPressedPrivate = true
                                        case TouchType.Up =>
                                            safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                                                this.isPressedPrivate = false
                                            })
                                        case _ => this.isPressedPrivate = false
                                    }
                                })
                                ItemListSeparator(leftInset: 61)
                                Row {
                                    Image(@r(app.media.setroot_ds_group))
                                        .width(29)
                                        .height(29)
                                        .margin(right: 16)
                                    Column {
                                        Text(this.categoryTitle(1))
                                            .fontSize(17)
                                            .fontColor(this.presentation.textColor)
                                        if (this.excCountGroup > 0) {
                                            Text(this.exceptionSubtitle(this.excCountGroup))
                                                .fontSize(15)
                                                .fontColor(this.presentation.secondaryTextColor)
                                                .margin(top: 1)
                                        }
                                    }
                                    .layoutWeight(1)
                                    .alignItems(HorizontalAlign.Start)
                                    Text(this.keepGroupLabel)
                                        .fontSize(17)
                                        .fontColor(this.presentation.secondaryTextColor)
                                        .margin(right: 6)
                                        .opacity(if (this.showMenuFor == 1) { 0.5 } else { 1.0 })
                                        .bindPopup(
                                            this.showMenuFor == 1,
                                            CustomPopupOptions(
                                                builder: bind(this.keepMediaMenuContent, this),
                                                placement: Placement.Bottom,
                                                popupColor: Color.Transparent,
                                                enableArrow: false,
                                                autoCancel: true,
                                                radius: 14.vp,
                                                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                                                    if (!evt.isVisible && this.showMenuFor == 1) { this.showMenuFor = -1 }
                                                })
                                            )
                                        )
                                    Image(@r(app.media.item_list_context_disclosure_arrow))
                                        .width(12)
                                        .height(16)
                                        .fillColor(this.presentation.disclosureArrowColor)
                                        .opacity(if (this.showMenuFor == 1) { 0.5 } else { 1.0 })
                                }
                                .width(100.percent)
                                .constraintSize(minHeight: if (this.excCountGroup > 0) { 64 } else { 52 })
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(if (!this.isPressedGroup) { Color.Transparent } else { this.presentation.itemHighlightedBackgroundColor })
                                .onClick({ _ => this.showMenuFor = 1 })
                                .onTouch({ evt =>
                                    match (evt.eventType) {
                                        case TouchType.Down => this.isPressedGroup = true
                                        case TouchType.Up =>
                                            safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                                                this.isPressedGroup = false
                                            })
                                        case _ => this.isPressedGroup = false
                                    }
                                })
                                ItemListSeparator(leftInset: 61)
                                Row {
                                    Image(@r(app.media.setroot_ds_channel))
                                        .width(29)
                                        .height(29)
                                        .margin(right: 16)
                                    Column {
                                        Text(this.categoryTitle(2))
                                            .fontSize(17)
                                            .fontColor(this.presentation.textColor)
                                        if (this.excCountChannel > 0) {
                                            Text(this.exceptionSubtitle(this.excCountChannel))
                                                .fontSize(15)
                                                .fontColor(this.presentation.secondaryTextColor)
                                                .margin(top: 1)
                                        }
                                    }
                                    .layoutWeight(1)
                                    .alignItems(HorizontalAlign.Start)
                                    Text(this.keepChannelLabel)
                                        .fontSize(17)
                                        .fontColor(this.presentation.secondaryTextColor)
                                        .margin(right: 6)
                                        .opacity(if (this.showMenuFor == 2) { 0.5 } else { 1.0 })
                                        .bindPopup(
                                            this.showMenuFor == 2,
                                            CustomPopupOptions(
                                                builder: bind(this.keepMediaMenuContent, this),
                                                placement: Placement.Bottom,
                                                popupColor: Color.Transparent,
                                                enableArrow: false,
                                                autoCancel: true,
                                                radius: 14.vp,
                                                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                                                    if (!evt.isVisible && this.showMenuFor == 2) { this.showMenuFor = -1 }
                                                })
                                            )
                                        )
                                    Image(@r(app.media.item_list_context_disclosure_arrow))
                                        .width(12)
                                        .height(16)
                                        .fillColor(this.presentation.disclosureArrowColor)
                                        .opacity(if (this.showMenuFor == 2) { 0.5 } else { 1.0 })
                                }
                                .width(100.percent)
                                .constraintSize(minHeight: if (this.excCountChannel > 0) { 64 } else { 52 })
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(if (!this.isPressedChannel) { Color.Transparent } else { this.presentation.itemHighlightedBackgroundColor })
                                .onClick({ _ => this.showMenuFor = 2 })
                                .onTouch({ evt =>
                                    match (evt.eventType) {
                                        case TouchType.Down => this.isPressedChannel = true
                                        case TouchType.Up =>
                                            safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                                                this.isPressedChannel = false
                                            })
                                        case _ => this.isPressedChannel = false
                                    }
                                })
                                ItemListSeparator(leftInset: 61)
                                Row {
                                    Image(@r(app.media.setroot_ds_stories))
                                        .width(29)
                                        .height(29)
                                        .margin(right: 16)
                                    Text(this.categoryTitle(3))
                                        .fontSize(17)
                                        .fontColor(this.presentation.textColor)
                                        .layoutWeight(1)
                                    Text(this.keepStoriesLabel)
                                        .fontSize(17)
                                        .fontColor(this.presentation.secondaryTextColor)
                                        .margin(right: 6)
                                        .opacity(if (this.showMenuFor == 3) { 0.5 } else { 1.0 })
                                        .bindPopup(
                                            this.showMenuFor == 3,
                                            CustomPopupOptions(
                                                builder: bind(this.keepMediaMenuContent, this),
                                                placement: Placement.Bottom,
                                                popupColor: Color.Transparent,
                                                enableArrow: false,
                                                autoCancel: true,
                                                radius: 14.vp,
                                                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                                                    if (!evt.isVisible && this.showMenuFor == 3) { this.showMenuFor = -1 }
                                                })
                                            )
                                        )
                                    Image(@r(app.media.item_list_context_disclosure_arrow))
                                        .width(12)
                                        .height(16)
                                        .fillColor(this.presentation.disclosureArrowColor)
                                        .opacity(if (this.showMenuFor == 3) { 0.5 } else { 1.0 })
                                }
                                .width(100.percent)
                                .constraintSize(minHeight: 52)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(if (!this.isPressedStories) { Color.Transparent } else { this.presentation.itemHighlightedBackgroundColor })
                                .onClick({ _ => this.showMenuFor = 3 })
                                .onTouch({ evt =>
                                    match (evt.eventType) {
                                        case TouchType.Down => this.isPressedStories = true
                                        case TouchType.Up =>
                                            safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
                                                this.isPressedStories = false
                                            })
                                        case _ => this.isPressedStories = false
                                    }
                                })
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(26)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 8)

                            ItemListSectionFooter(
                                text: "Photos, videos and other files from cloud chats that you have not accessed during this period will be removed from this device to save disk space.",
                                topPad: 8
                            )

                            ItemListSectionHeader(title: "MAXIMUM CACHE SIZE", topPad: 28)
                            Column {
                                Row {
                                    Text(this.maximumCacheLabel(0))
                                        .fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                        .layoutWeight(1)
                                    Text(this.maximumCacheLabel(1))
                                        .fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                        .layoutWeight(1).textAlign(TextAlign.Center)
                                    Text(this.maximumCacheLabel(2))
                                        .fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                        .layoutWeight(1).textAlign(TextAlign.Center)
                                    Text(this.maximumCacheLabel(3))
                                        .fontSize(13).fontColor(this.presentation.secondaryTextColor)
                                        .layoutWeight(1).textAlign(TextAlign.End)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 16)

                                Slider(
                                    value: Float64(this.maximumCacheIndex),
                                    min: 0.0,
                                    max: 3.0,
                                    step: 1.0,
                                    style: SliderStyle.OutSet
                                )
                                .selectedColor(0xFF18A57D)
                                .trackColor(this.presentation.dividerColor)
                                .showSteps(true)
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 4, bottom: 12)
                                .onChange({ value: Float64, mode: SliderChangeMode =>
                                    if (mode == SliderChangeMode.End) {
                                        this.setMaximumCacheIndex(Int64(value))
                                    }
                                })
                            }
                            .height(96)
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(26)
                            .margin(left: 16, right: 16)

                            ItemListSectionFooter(
                                text: "If your cache size exceeds this limit, the oldest unused media will be removed from the device."
                            )

                            if (!this.peerCacheItems.isEmpty()) {
                                Row {
                                    Text("Chats")
                                        .fontSize(15)
                                        .fontWeight(FontWeight.Bold)
                                        .fontColor(this.presentation.textColor)
                                }
                                .height(36)
                                .padding(left: 18, right: 18)
                                .border(width: 2, color: if (this.presentation.isDark) { 0x66FFFFFF } else { 0xCCFFFFFF })
                                .borderRadius(18)
                                .justifyContent(FlexAlign.Center)
                                .margin(top: 28, bottom: 12)

                                Column {
                                    ForEach(this.peerCacheItems, itemGeneratorFunc: { item: StoragePeerCacheItem, idx: Int64 =>
                                        this.peerCacheRow(item)
                                        if (idx < this.peerCacheItems.size - 1) {
                                            ItemListSeparator(leftInset: 62)
                                        }
                                    }, keyGeneratorFunc: { item: StoragePeerCacheItem, _idx: Int64 =>
                                        "peer_cache_${item.peerType}_${item.peerId}_${item.sizeBytes}"
                                    })
                                }
                                .backgroundColor(this.presentation.cardColor)
                                .borderRadius(26)
                                .clip(true)
                                .margin(left: 16, right: 16)
                            }

                            Text(trSource("")).height(32)
                        }
                        .padding(top: getSafeAreaTop())
                    }
                    .align(Alignment.Top)
                    .layoutWeight(1)
                    .backgroundColor(this.presentation.backgroundColor)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(this.presentation.backgroundColor)
            .padding(bottom: getSafeAreaBottom())
            .onAppear({ => this.ensureLoaded() })
            // TC-0430-round5 M5-A：整宽贴底遮罩层（原 ContextMenuView 调用）已删除——菜单改走
            // 四行各自的 bindPopup 锚定呈现，不再需要这个 Stack 兄弟节点。源侧 .reference 呈现
            // 下页面零施加压暗，恢复任何形式的全屏叠加层即等于没修 B4（见 diag-round5 §M5-A
            // 边界条件）。

            Row {
                Image(@r(app.media.callui_v2_back))
                    .width(10).height(18).fillColor(this.presentation.accentColor)
            }
            .width(44).height(44).borderRadius(22)
            .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0xCCFFFFFF })
            .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
            .margin(left: 16, top: getSafeAreaTop() + 8.0)
            .zIndex(100)
            .onClick({ _ => routerPop() })
        }
        .width(100.percent)
        .height(100.percent)
    }
}
