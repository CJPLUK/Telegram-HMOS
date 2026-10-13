package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.ArkData.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGlobalAbilityContext
import ohos_app_cangjie_entry.services.{MediaAutoSaveException, encodeMediaAutoSaveExceptions, decodeMediaAutoSaveExceptions}
import ohos_app_cangjie_entry.services.getAppFilesDir
import ohos_app_cangjie_entry.services.getSaveToCameraRollService
import ohos_app_cangjie_entry.services.getNetworkUsageService
import ohos_app_cangjie_entry.services.getTelegramEngineItemCacheService
import ohos_app_cangjie_entry.services.getResourcesService
import ohos_app_cangjie_entry.services.getCallService
import ohos_app_cangjie_entry.services.getRaiseToListenService
import ohos_app_cangjie_entry.services.getMiscSettingsStore
import ohos_app_cangjie_entry.services.getFileDownloadService
import ohos_app_cangjie_entry.services.getSettingsService
import ohos_app_cangjie_entry.services.AutoDownloadNetworkSettings
import ohos_app_cangjie_entry.services.AutoDownloadPresetKind
import ohos_app_cangjie_entry.services.MediaAutoDownloadConnection
import ohos_app_cangjie_entry.services.effectiveCategories
import ohos_app_cangjie_entry.services.autodownloadDataSizeString
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.storage.getDownloadPolicy
import ohos_app_cangjie_entry.core.storage.{
    PresentationSnapshot,
    currentPresentation,
    PresentationStringsSnapshot,
    currentPresentationStrings
}
import ohos_app_cangjie_entry.components.{
    ItemListSectionHeader,
    ItemListSeparator,
    ItemListToggleRow,
    ItemListDisclosureRow,
    ItemListButtonRow,
    AgeVerificationSheetActions,
    ageVerificationSheetContent
}
import kit.CoreFileKit.*
import std.sync.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.interop.subscribe
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * Data and Storage Settings — TC-0418 reconstruct (diag-suite_settings_data_storage-TC-0418.md)
 * + TC-0427 FIX-2 (diag-suite_settings_data_storage-TC-0427-refile.md) retargeting.
 * Full-page rebuild driven by source `DataAndStorageSettingsController.swift`
 * (`dataAndStorageControllerEntries` :606-664 + item rendering :346-440): 6 fixed section
 * cards in source `section`/`stableId` order, real leading-icon badges (Phase 2 pre-composed
 * from the 8 source vector assets), source string literals, and the 3 supervisor rulings:
 *  1. `Using Wi-Fi`/`Using Cellular` now `routerPush` to `AutodownloadConnectionTypePage`
 *     (TC-0427 FIX-2 built that destination screen this round). The `DOWNLOAD ON MOBILE
 *     DATA` / `DOWNLOAD ON WI-FI` in-page sections that used to back the Cellular/Wi-Fi
 *     rows are deleted in this round — their tap-to-cycle controls were F1's own defect
 *     (wrong control form + value domain), and keeping them would leave two working paths
 *     to the same setting with no way to tell which one a change came from.
 *     diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-C 改动 3
 *     (TC-0423/TC-0424): the 3 autosave rows no longer toggle-in-place — they now
 *     `routerPush` to `SaveIncomingMediaPage` (this round built that destination screen),
 *     matching source's `.autoSaveItem` push behaviour. The rows' `value:` label keeps
 *     reading the same underlying per-peer-type bool (`SaveToCameraRollService`
 *     getAutosaveX(); "On" when true, matching source's `photo || video` since the target
 *     model hasn't been split into independent photo/video fields yet — see
 *     `SaveIncomingMediaPage.cj`'s file header for that gap and the emitted
 *     `integration_contract` to `savetocameraroll`).
 *  2. Every `ItemListDisclosureRow.value:` call site in this file passes this component's own
 *     bare `@State` field (dev_pattern.md D-125) — never a function-call return or nested
 *     field access.
 *  3. `resetAutoDownloadSettings()` / `autoDownloadIsCustomized()` now read/write the FIX-2
 *     source-shaped model (`services.AutoDownloadNetworkSettings.cellular/wifi`) instead of
 *     the six flat MB fields F1 found wrong (cellular-video default silently truncated to
 *     2 MB where the source's real medium preset is 2.5 MB) — `confirmDestructive()` keeps
 *     its method body unchanged (task-level protected trio); `loadSettings()` lost only the
 *     P2-321 block that read the now-deleted flat fields, everything else in it is untouched.
 *
 * Net-regression guard (D4.5, same principle the report applies to `Save to Gallery` /
 * `Data Saving`): the target-only `Photos` / `Videos` / `Files` auto-download-type toggles
 * (real `AuthStorage` + `DownloadPolicy` link, consumed by `FileDownloadService` at real
 * download time — this page is their only UI surface) are kept, appended after the 3 source
 * rows in the `AUTO-DOWNLOAD MEDIA` card, exactly mirroring how `Save to Gallery`/`Data Saving`
 * are kept at the end of `OTHER`. The report's per-content disposition list didn't cover this
 * card's surplus explicitly; this follows the same stated principle to the same fact pattern.
 *
 * Anti dead-state guarantee: all @State fields back-filled from services in ensureLoaded.
 */
@HybridComponentEntry
@Component
public class DataStorageSettingsPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()

    // TC-0541 C3: subscribe to the published PresentationSnapshot so Dark All day
    // rebuilds this page's chrome (page/card/nav/row colors). Same key as SettingsPage
    // / ItemListSection — do not introduce a second snapshot field.
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var strings: PresentationStringsSnapshot = currentPresentationStrings()

    private func localized(key: String, fallback: String): String {
        return this.strings.getOr(key, fallback)
    }

    // ── auto-download toggles (AuthStorage-backed) ──
    @State var autoDownloadPhotos: Bool = false
    @State var autoDownloadVideos: Bool = false
    @State var autoDownloadFiles: Bool = false

    // ── TC-0427 FIX-2: bare @State summary mirrors for the `Using Cellular`/`Using Wi-Fi`
    // ItemListDisclosureRow.value call sites (dev_pattern.md D-125). Recomputed by
    // refreshCellularSummary()/refreshWifiSummary(); the underlying per-network model now
    // lives in services.AutoDownloadNetworkSettings (cellular/wifi connections, each with
    // its own enabled/preset/custom), not on this page. ──
    @State var cellularSummaryLabel: String = ""
    @State var wifiSummaryLabel: String = ""

    // ── autosave-to-camera-roll toggles (SaveToCameraRollService-backed) ──
    @State var autosavePrivateChats: Bool = false
    @State var autosaveGroups: Bool = false
    @State var autosaveChannels: Bool = false
    // D-125 bare-field mirrors for the 3 autosave rows' ItemListDisclosureRow.value (rows now
    // wear the source "跳转行" appearance; onClick still flips the bool in place — Ruling 1).
    @State var autosavePrivateChatsValueLabel: String = "Off"
    @State var autosaveGroupsValueLabel: String = "Off"
    @State var autosaveChannelsValueLabel: String = "Off"

    // ── TC-0423.md RC-3/FIX-C: 根屏三行副标题（对位源侧 additionalDetailLabel，四态
    // + 例外数后缀）。ItemListDisclosureRow.additionalDetailLabel 是普通 var（无装饰器，
    // 见 components/ItemListComponents.cj 类头注释），调用点的裸 @State 传参本身不会让
    // 已挂载实例回灌（dev_pattern.md D-196）——响应式改走下面 autosaveDetailRemountToggle
    // 的 D-160/D-184 双相同分支挂载守卫，不改字段装饰器（改 @Prop 会级联全仓 65+ 处调用点，
    // 超出本轮 grant 范围）。
    @State var autosavePrivateChatsDetailLabel: String = ""
    @State var autosaveGroupsDetailLabel: String = ""
    @State var autosaveChannelsDetailLabel: String = ""
    @State var autosaveDetailRemountToggle: Bool = false

    // ── other toggles (AuthStorage-backed) ──
    @State var saveToGallery: Bool = false
    @State var dataSaving: Bool = false

    // ── cache UI state ──
    @State var isClearing: Bool = false
    @State var clearResult: String = ""
    @State var cacheSize: String = ""

    // ── P2-320: Network usage (NetworkUsageService-backed) ──
    @State var networkUsageTotalLabel: String = "0 B"

    // ── P2-322: Call data saving mode (CallService-backed) ──
    // 0 = Never, 1 = Cellular only, 2 = Always
    @State var callDataSavingMode: Int32 = 0
    // TC-0418: source models this as a single boolean switch ("Use Less Data for Calls").
    // off <-> 0(never); on <-> 2(always) (point 5 of 修法方向). The `.cellular` mid-state is
    // a target-only extension with no source counterpart — its behavioural semantics stay
    // TC-0421's subject; this page only changes the control's shape.
    @State var useLessDataForCalls: Bool = false

    // ── P2-326: Misc toggles (MiscSettingsStore-backed) ──
    @State var raiseToListenEnabled: Bool = false
    @State var pauseMusicOnRecording: Bool = false
    @State var saveEditedPhotos: Bool = false

    // TC-0418: `Proxy` row value. Fixed literal per 修法方向 point 7 ("目标侧无代理配置来源，
    // 接真实值属 set_proxy_settings 的义务") — kept as a bare @State field (not a literal
    // passed inline) purely for call-site uniformity with every other disclosure row in this
    // file; it never changes.
    @State var proxyValueLabel: String = "None"

    // diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-A 改动 1:
    // `Share Sheet` row value — 恒为空串，对位源侧 `label: ""` 硬编码
    // (DataAndStorageSettingsController.swift:405). Bare @State field for call-site
    // uniformity (D-125), even though it never changes.
    @State var shareSheetValueLabel: String = ""

    // ── §F-B `Show 18+ Content` (ContentSettings-backed, account.getContentSettings /
    // account.setContentSettings). sensitiveLatch mirrors source's `canAdjustSensitiveContent`
    // Atomic (:951-953) — it's a plain field, NOT @State: it's a one-shot latch consulted
    // only from ensureLoaded's async callback, never read from build(), so it doesn't need
    // to participate in the reactive graph. ──
    @State var sensitiveSectionVisible: Bool = false
    @State var sensitiveContentOn: Bool = false
    @State var sensitiveCanAdjust: Bool = false
    private var sensitiveLatch: ?Bool = None

    // TC-0422 (ic_shell_face_scan_age_verification_sheet_hookup required_outcomes[0]):
    // bare @State field (D-125) driving the age-verification sheet's visibility.
    @State var showAgeVerificationSheet: Bool = false

    @State var loaded: Bool = false

    // TC-0420 M1: event name literal must match entry/src/main/ets/pages/
    // DataStorageSettingsPage.ets's dispatchEvent(DATA_STORAGE_SHOWN_EVENT, ...) verbatim
    // (same cross-file-literal precedent as auth/PhoneInputPage.cj's phoneInputShownEvent /
    // PhoneInputPage.ets and pages/AppearanceSettingsPage.cj's appearanceShownEvent /
    // AppearanceSettingsPage.ets — interop.cj is not in this feature's target_files, so no
    // shared constant is introduced).
    private let dataStorageShownEvent: String = "settings.dataStorage.shown"

    // TC-0420 M2 (D-125): bare @State mirror for the Reset Auto-Download Settings row's
    // colour. `.fillColor(this.resetAutoDownloadColor())` / `.fontColor(...)` never entered
    // build()'s dependency graph because Cangjie ArkUI macros only track bare `@State` field
    // reads, not function-call results (diag-suite_settings_data_storage-TC-0420-round2.md
    // §2 M2). Default matches the disabled-grey value a fresh/default account resolves to.
    @State var resetAutoDownloadColorValue: UInt32 = 0x8E8E93

    // ── TC-0418: scroller hosting the page's own Scroll (still a real consumer — see
    // build() below) ──
    private var contentScroller: Scroller = Scroller()

    // `cacheSizeRowOffsetVp` (old `Storage Usage` row scrollTo) and `networkStatsOffsetVp`
    // (old `Network Usage` row scrollTo) are both gone: `Storage Usage` now `routerPush`es
    // to StorageUsagePage (diag-suite_settings_data_storage-TC-0438-round2.md 修法方向 §2),
    // and `Network Usage` now `routerPush`es to DataUsagePage (diag-suite_settings_data_
    // storage-TC-0429-round2.md 修法方向 §0/§2 grant) — neither row scrolls in-page anymore,
    // so both best-effort offset constants are dead code and were removed with them.

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // TC-0420 M1: one-time subscription registration (D6 "生命周期按需通信" pattern, same
        // precedent as auth/PhoneInputPage.cj / pages/AppearanceSettingsPage.cj) — the `loaded`
        // guard above ensures this only registers once, so this handler never accumulates
        // duplicate subscriptions across repeated .onAppear triggers.
        subscribe(this.dataStorageShownEvent, { _payload: String => this.refreshVisibleState() })
        this.loadSettings()
        this.refreshCellularSummary()
        this.refreshWifiSummary()
        this.refreshAutosaveLabels()
        this.refreshResetGate()
        this.calculateCacheSize()
        this.loadNetworkUsage()
        this.loadCallDataSavingMode()
        this.useLessDataForCalls = this.callDataSavingMode != 0
        this.loadMiscSettings()
        this.prefetchSensitiveContentGate()
    }

    // TC-0420 M1: re-reads every root-screen mirror this page owns and re-derives the Reset
    // row's enable gate colour. Registered once (see ensureLoaded()) against the .ets shell's
    // onShown dispatch, so this runs every time this NavDestination becomes visible again —
    // including the return trip from AutodownloadConnectionTypePage/AutodownloadMediaCategoryPage
    // after the user changes a setting there, which is exactly the path the build()-time
    // `.onAppear` cannot cover on its own (this NavDestination stays mounted across that
    // push/pop, so nothing else re-triggers its build()). Deliberately scoped to the six
    // fully-synchronous read/refresh calls below: `calculateCacheSize()` is excluded (it
    // spawns a directory rescan on every call, which would slow the return trip and race
    // TC-0438's cache-size sampling window), and `loadCallDataSavingMode()` /
    // `loadMiscSettings()` are excluded because no failure evidence
    // implicates them this round — adding them would be unsupported scope creep. No writes.
    private func refreshVisibleState(): Unit {
        this.loadSettings()
        this.refreshCellularSummary()
        this.refreshWifiSummary()
        this.refreshAutosaveLabels()
        this.refreshResetGate()
        this.loadNetworkUsage()
    }

    /**
     * Back-fill all @State toggles from persistent services.
     * Runs on the UI thread (called from aboutToAppear) — no spawn needed.
     *
     * TC-0418 kept this byte-for-byte; TC-0427 FIX-2 is the first round to touch it
     * (removing the P2-321 flat-field block, which read fields that no longer exist on
     * the FIX-2 model) — `resetAutoDownloadSettings()`/`autoDownloadIsCustomized()`/
     * `confirmDestructive()` are this round's actually-protected trio (task-level
     * constraint), not this method.
     */
    private func loadSettings(): Unit {
        let storage = getAuthStorage()
        this.autoDownloadPhotos = storage.getDownloadPhotos()
        this.autoDownloadVideos = storage.getDownloadVideos()
        this.autoDownloadFiles = storage.getDownloadFiles()
        this.saveToGallery = storage.getSaveToGallery()
        this.dataSaving = storage.getDataSaving()

        let svc = getSaveToCameraRollService()
        this.autosavePrivateChats = svc.getAutosavePrivateChats()
        this.autosaveGroups      = svc.getAutosaveGroups()
        this.autosaveChannels    = svc.getAutosaveChannels()

        // TC-0427 FIX-2: per-network auto-download settings now live entirely behind
        // AutodownloadConnectionTypePage/AutodownloadMediaCategoryPage; this page only
        // shows a summary (refreshCellularSummary/refreshWifiSummary, called from
        // ensureLoaded and from refreshVisibleState() so a return-visit after editing on
        // those subpages picks up the change — TC-0420 M1 corrected the original `.onAppear`
        // re-trigger assumption below build(), see refreshVisibleState()'s doc comment).

        // Sync global download policy singleton (basic toggles only; network settings live in FileDownloadService)
        let policy = getDownloadPolicy()
        policy.autoPhotos = this.autoDownloadPhotos
        policy.autoVideos = this.autoDownloadVideos
        policy.autoFiles  = this.autoDownloadFiles
        policy.dataSaving = this.dataSaving

        Hilog.info(0, "CjTelegram", "[DataStorage] Loaded: photos=${this.autoDownloadPhotos} videos=${this.autoDownloadVideos} files=${this.autoDownloadFiles} privateAutosave=${this.autosavePrivateChats} groupsAutosave=${this.autosaveGroups} channelsAutosave=${this.autosaveChannels}")
    }

    private func saveAutoDownloadToggle(key: String, value: Bool): Unit {
        let storage = getAuthStorage()
        let policy = getDownloadPolicy()
        match (key) {
            case "photos" =>
                storage.saveDownloadPhotos(value)
                policy.autoPhotos = value
            case "videos" =>
                storage.saveDownloadVideos(value)
                policy.autoVideos = value
            case "files" =>
                storage.saveDownloadFiles(value)
                policy.autoFiles = value
            case "gallery" =>
                storage.saveSaveToGallery(value)
            case "datasaving" =>
                storage.saveDataSaving(value)
                policy.dataSaving = value
            case _ => ()
        }
        Hilog.info(0, "CjTelegram", "[DataStorage] Saved ${key}=${value}")
    }

    // ── Reset Auto-Download Settings gate (source: DataAndStorageSettingsController.swift:616-617).
    // Enable gate lives at the call site, not the row component — a disabled row stays
    // clickable and simply produces no confirmation panel (R37). ──
    // TC-0427 FIX-2: compares against the corrected FIX-2 model default (cellular=medium
    // enabled, wifi=high enabled, no `.custom` override on either) instead of the six flat
    // MB fields F1 found wrong. `.custom.isSome()` alone is decisive for "customized"
    // regardless of preset label, because every category-page edit (peer/size/predownload)
    // unconditionally sets preset=Custom + writes `.custom` (source parity).
    private func autoDownloadIsCustomized(): Bool {
        let netSettings = getFileDownloadService().getAutoDownloadNetworkSettings()
        let d = AutoDownloadNetworkSettings()
        return netSettings.cellular.enabled != d.cellular.enabled ||
            netSettings.cellular.preset != d.cellular.preset ||
            netSettings.cellular.custom.isSome() ||
            netSettings.wifi.enabled != d.wifi.enabled ||
            netSettings.wifi.preset != d.wifi.preset ||
            netSettings.wifi.custom.isSome() ||
            this.autoDownloadPhotos != true ||
            this.autoDownloadVideos != false ||
            this.autoDownloadFiles != false
    }

    // TC-0420 M2 (D-125): re-derives resetAutoDownloadColorValue and assigns it — this
    // assignment, not the predicate call itself, is what makes the Reset row's colour enter
    // build()'s dependency graph. Call sites (exactly three, see diag report §2 M2's fix
    // spec): ensureLoaded() (cold start / first entry), refreshVisibleState() (return from a
    // subpage), and the Reset onConfirm closure below (in-page reset ⇒ C3).
    private func refreshResetGate(): Unit {
        if (this.autoDownloadIsCustomized()) {
            this.resetAutoDownloadColorValue = this.presentation.accentColor
        } else {
            this.resetAutoDownloadColorValue = this.presentation.secondaryTextColor
        }
    }

    // Source: DataAndStorageSettingsController.swift:841-849 (updateMediaDownloadSettingsInteractively).
    // TC-0427 FIX-2: the per-network reset now delegates to
    // FileDownloadService.resetAutoDownloadToDefaults(), which resets to the corrected
    // model default (cellular=medium 2.5 MB video / wifi=high 10 MB video + predownload,
    // no `.custom` override) — this is the baseline fix F1 requires: the old inline
    // defaults hardcoded 2 MB, which the source never had. The photos/videos/files
    // AuthStorage-backed toggles are unrelated to the model and keep their own reset path.
    private func resetAutoDownloadSettings(): Unit {
        getFileDownloadService().resetAutoDownloadToDefaults()
        this.autoDownloadPhotos = true
        this.saveAutoDownloadToggle("photos", true)
        this.autoDownloadVideos = false
        this.saveAutoDownloadToggle("videos", false)
        this.autoDownloadFiles = false
        this.saveAutoDownloadToggle("files", false)
        Hilog.info(0, "CjTelegram", "[DataStorage] auto-download settings reset to defaults")
    }

    // diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-C 改动 3:
    // `saveAutosaveToggle()` (the former in-place-flip write path for the 3 autosave rows)
    // is deleted here — its only 3 call sites (above) are now `routerPush`, and the actual
    // write now happens in `SaveIncomingMediaPage.cj` via the same
    // `getSaveToCameraRollService()` getters/setters this method used to wrap (zero
    // dead-code tolerance).

    // ── TC-0427 FIX-2: D-125 bare-field refresh helpers for the `Using Cellular`/
    // `Using Wi-Fi` rows' summary text. Call right after any change that could affect
    // it (this page's own Reset action) and from refreshVisibleState() (TC-0420 M1 — the
    // .ets shell's onShown dispatch, not build()'s `.onAppear`, is what actually re-fires
    // on a return trip; see refreshVisibleState()'s doc comment) so a return-visit after
    // editing on AutodownloadConnectionTypePage/AutodownloadMediaCategoryPage picks up the
    // change — `ensureLoaded()` itself is one-shot-gated and would miss that. ──

    // diag-suite_settings_data_storage-TC-0418-round3.md §M1 改动 2：整体替换为对位源侧
    // `stringForAutoDownloadSetting`/`stringForAutoDownloadTypes`
    // (DataAndStorageSettingsController.swift:485-534) 的算法——按实际生效类别 + 尺寸上限
    // 合成摘要串，而非直接回显预设名。`"Disabled"` 逐字对位源串键
    // `ChatSettings.AutoDownloadSettings.OffForAll`（Telegram/Telegram-iOS/en.lproj/
    // Localizable.strings:4226；与形似但不同键的 `AutoDownloadSettings.OffForAll` =
    // "Off for all chats" 不是同一条，此处按 stringForAutoDownloadSetting 实际引用的键取值）。
    private func connectionSummaryLabel(conn: MediaAutoDownloadConnection): String {
        if (!conn.enabled) { return this.localized("ChatSettings.AutoDownloadSettings.OffForAll", "Disabled") }
        let cats = effectiveCategories(conn)
        // 对位 isAutodownloadEnabledForAnyPeerType(category:)：四个 peer 维度任一开启即算启用。
        let photo = cats.photo.contacts || cats.photo.otherPrivate || cats.photo.groups || cats.photo.channels
        let video = cats.video.contacts || cats.video.otherPrivate || cats.video.groups || cats.video.channels
        let file = cats.file.contacts || cats.file.otherPrivate || cats.file.groups || cats.file.channels
        let types = ArrayList<String>()
        // 对位 stringForAutoDownloadTypes: photo 只在 video 未启用时单列 "Photos"；
        // video 启用时按 photo 是否同时启用二选一 "Media (X)" / "Videos (X)"。
        if (photo && !video) { types.add(this.localized("ChatSettings.AutoDownloadSettings.TypePhoto", "Photos")) }
        if (video) {
            if (photo) {
                types.add(this.localized("ChatSettings.AutoDownloadSettings.TypeMedia", "Media (%@)").replace("%@", autodownloadDataSizeString(cats.video.sizeLimit)))
            } else {
                types.add(this.localized("ChatSettings.AutoDownloadSettings.TypeVideo", "Videos (%@)").replace("%@", autodownloadDataSizeString(cats.video.sizeLimit)))
            }
        }
        if (file) {
            types.add(this.localized("ChatSettings.AutoDownloadSettings.TypeFile", "Files (%@)").replace("%@", autodownloadDataSizeString(cats.file.sizeLimit)))
        }
        if (types.size == 0) { return this.localized("ChatSettings.AutoDownloadSettings.OffForAll", "Disabled") }
        // 对位 ChatSettings.AutoDownloadSettings.Delimeter = ", "（各项间统一逗号分隔，无
        // "and" 连接——不同于 stringForAutomaticDownloadPeers 的 joinTypeList，两者是不同函数）。
        var out = ""
        var idx: Int64 = 0
        for (t in types) {
            if (idx > 0) { out = out + this.localized("ChatSettings.AutoDownloadSettings.Delimeter", ", ") }
            out = out + t
            idx += 1
        }
        return out
    }

    private func refreshCellularSummary(): Unit {
        let netSettings = getFileDownloadService().getAutoDownloadNetworkSettings()
        this.cellularSummaryLabel = this.connectionSummaryLabel(netSettings.cellular)
    }

    private func refreshWifiSummary(): Unit {
        let netSettings = getFileDownloadService().getAutoDownloadNetworkSettings()
        this.wifiSummaryLabel = this.connectionSummaryLabel(netSettings.wifi)
    }

    private func refreshAutosaveLabels(): Unit {
        this.autosavePrivateChatsValueLabel = if (this.autosavePrivateChats) { "On" } else { "Off" }
        this.autosaveGroupsValueLabel = if (this.autosaveGroups) { "On" } else { "Off" }
        this.autosaveChannelsValueLabel = if (this.autosaveChannels) { "On" } else { "Off" }
        this.refreshAutosaveDetailLabels()
    }

    // ── TC-0423.md RC-3/FIX-C-2: 读 SaveIncomingMediaPage.cj 的同一个 Preferences store
    // （"telegram_autosave_media"，字面量对位该文件 storeName()——两侧各自持有同一个
    // store 名字符串，不新增共享常量，同本工程既有跨文件事件名字面量惯例）；`value:`
    // 现有算法（On/Off，读合并 Bool）不改，避免动到已 PASS 的 D1。
    private func autosaveDetailLabelFor(peerType: String): String {
        let svc = getSaveToCameraRollService()
        let photo = svc.getMediaSettingInt("${peerType}_photo", 0) != 0
        let video = svc.getMediaSettingInt("${peerType}_video", 0) != 0
        let maxSize = svc.getMediaSettingInt(
            "${peerType}_max_video_size", 100 * 1024 * 1024)
        let exceptionCount = decodeMediaAutoSaveExceptions(
            svc.getMediaSettingString("${peerType}_exceptions", "")).size
        // 对位源侧 DataAndStorageSettingsController.swift:556-604 autosaveLabelAndValue 四态。
        var label = ""
        if (photo && video) {
            label = "All Media (${autodownloadDataSizeString(maxSize)})"
        } else if (photo) {
            label= "Photos"
        } else if (video) {
            label = "Videos up to ${autodownloadDataSizeString(maxSize)}"
        }
        // FIX-B-4: 例外数 ≠ 0 时末尾追加 ", <n> exception(s)"；为 0 时不追加。
        if (exceptionCount > 0) {
            let suffix = if (exceptionCount == 1) { "1 exception" } else { "${exceptionCount} exceptions" }
            if (label.size > 0) {
                label = "${label}, ${suffix}"
            } else {
                label = suffix
            }
        }
        return label
    }

    // D-184: additionalDetailLabel 是普通 var（未获授权把 ItemListDisclosureRow 改
    // @Prop——会级联全仓 65+ 处调用点），响应式改走 D-160 双相同分支挂载守卫：每次这三个
    // detail 串被重新计算，翻转 autosaveDetailRemountToggle，强制 buildAutosaveRowsCard()
    // 的宿主 if/else 销毁重建整张卡（含三行），使新值真正回灌到已挂载的
    // ItemListDisclosureRow 实例上。
    private func refreshAutosaveDetailLabels(): Unit {
        this.autosavePrivateChatsDetailLabel = this.autosaveDetailLabelFor("private")
        this.autosaveGroupsDetailLabel = this.autosaveDetailLabelFor("groups")
        this.autosaveChannelsDetailLabel = this.autosaveDetailLabelFor("channels")
        this.autosaveDetailRemountToggle = !this.autosaveDetailRemountToggle
    }

    private func calculateCacheSize(): Unit {
        let _ = spawn {
            let filesDir = getAppFilesDir()
            var resultStr: String = "Unknown"
            if (filesDir.size > 0) {
                var totalBytes: Int64 = 0
                let subDirs = ["photos", "videos", "documents", "voice", "stickers", "gifs", "thumbs"]
                for (subDir in subDirs) {
                    let dirPath = "${filesDir}/${subDir}"
                    try {
                        let entries = FileIo.listFile(dirPath)
                        for (entry in entries) {
                            let fullPath = "${dirPath}/${entry}"
                            try {
                                let stat = FileIo.stat(fullPath)
                                totalBytes = totalBytes + stat.size
                            } catch (_e: Exception) {}
                        }
                    } catch (_e: Exception) {}
                }
                // Also include ItemCacheService estimated size
                let itemCacheBytes = getTelegramEngineItemCacheService().estimateCacheSizeBytes()
                totalBytes = totalBytes + itemCacheBytes
                totalBytes = totalBytes + getResourcesService().collectStorageUsageStats().totalBytes

                if (totalBytes < 1024) {
                    resultStr = "${totalBytes} B"
                } else if (totalBytes < 1024 * 1024) {
                    resultStr = "${totalBytes / 1024} KB"
                } else {
                    resultStr = "${totalBytes / (1024 * 1024)} MB"
                }
            }
            let rs = resultStr
            launch { this.cacheSize = rs }
        }
    }

    private func clearCache(): Unit {
        if (this.isClearing) { return }
        this.isClearing = true
        this.clearResult = ""
        let _ = spawn {
            let filesDir = getAppFilesDir()
            if (filesDir.size == 0) {
                launch {
                    this.clearResult = "Error: no files directory"
                    this.isClearing = false
                }
                return
            }
            // 与 StorageUsagePage 的 Clear Entire Cache 共用同一份删除逻辑（StorageUsagePage.cj
            // clearLocalMediaCache），目录集合与 calculateCacheSize 统计的目录一致。
            let deletedCount = clearLocalMediaCache()

            let cnt = deletedCount
            launch {
                this.clearResult = "Cleared ${cnt} cached files"
                this.isClearing = false
                this.cacheSize = "0 B"
            }
            Hilog.info(0, "CjTelegram", "[DataStorage] Cache cleared: ${deletedCount} files")
        }
    }

    // ── P2-320: Load network usage from NetworkUsageService ──
    // TC-0418: also derives networkUsageTotalLabel (D-125 bare-field value for the new
    // "Network Usage" root-page disclosure row). Not one of the protected methods (loadSettings
    // / save helpers / confirmDestructive / autoDownloadIsCustomized / resetAutoDownloadSettings)
    // — rewiring an existing load path is expected here.

    private func loadNetworkUsage(): Unit {
        let svc = getNetworkUsageService()
        let _ = spawn {
            svc.ensureInit()
            let snap = svc.getUsage()
            let totalBytes = snap.wifiSent + snap.wifiReceived + snap.cellularSent + snap.cellularReceived
            let tot = formatBytes(totalBytes)
            launch {
                this.networkUsageTotalLabel = tot
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

    // ── P2-322: Load call data saving mode from CallService ──

    private func loadCallDataSavingMode(): Unit {
        let svc = getCallService()
        let mode = svc.getCallDataSavingMode()
        this.callDataSavingMode = mode
        Hilog.info(0, "CjTelegram", "[DataStorage] callDataSavingMode loaded: ${mode}")
    }

    private func saveCallDataSavingModeToService(mode: Int32): Unit {
        let svc = getCallService()
        svc.saveCallDataSavingMode(mode)
        Hilog.info(0, "CjTelegram", "[DataStorage] callDataSavingMode saved: ${mode}")
    }

    // ── P2-326: Load misc toggles from MiscSettingsStore ──

    private func loadMiscSettings(): Unit {
        let store = getMiscSettingsStore()
        this.raiseToListenEnabled = store.getRaiseToListenEnabled()
        this.pauseMusicOnRecording = store.getPauseMusicOnRecording()
        this.saveEditedPhotos = store.getSaveEditedPhotos()
        let rtlSvc = getRaiseToListenService()
        rtlSvc.setEnabled(this.raiseToListenEnabled)
        Hilog.info(0, "CjTelegram", "[DataStorage] Misc loaded: raiseToListen=${this.raiseToListenEnabled} pauseMusic=${this.pauseMusicOnRecording} saveEdited=${this.saveEditedPhotos}")
    }

    private func saveMiscToggle(key: String, value: Bool): Unit {
        let store = getMiscSettingsStore()
        match (key) {
            case "raiseToListen" =>
                store.saveRaiseToListenEnabled(value)
                getRaiseToListenService().setEnabled(value)
            case "pauseMusic" =>
                store.savePauseMusicOnRecording(value)
            case "saveEditedPhotos" =>
                store.saveSaveEditedPhotos(value)
            case _ => ()
        }
        Hilog.info(0, "CjTelegram", "[DataStorage] Misc saved ${key}=${value}")
    }

    // ── §F-B `Show 18+ Content` section gate + toggle handling ──
    // diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-B 改动 3.
    // Network call (account.getContentSettings) runs off-thread (S-001/R-138, same
    // pattern as pages/DebugSettingsPage.cj prefetchTest1Gate) — never block onAppear.

    private func prefetchSensitiveContentGate(): Unit {
        let _ = spawn {
            let svc = getSettingsService()
            // R-117: Cangjie tuples don't support named dot-access (`cfg.sensitiveEnabled`
            // is invalid even though the return type declares labels) — destructure by
            // position instead. Order matches getContentSettingsConfiguration()'s declared
            // `(sensitiveEnabled: Bool, canAdjust: Bool)`.
            let (sensitiveEnabled, canAdjust) = svc.getContentSettingsConfiguration()
            let needAgeVerify = svc.needAgeVideoVerification()
            launch {
                this.sensitiveCanAdjust = canAdjust
                this.sensitiveContentOn = sensitiveEnabled
                // latch: 逐字对位源侧 :951-953（存的是首帧的 sensitiveContentEnabled，
                // 不是 canAdjust——源侧的命名陷阱，照搬语义不照搬命名）。
                if (this.sensitiveLatch.isNone()) {
                    this.sensitiveLatch = Some(sensitiveEnabled)
                }
                let latchValue = this.sensitiveLatch.getOrThrow()
                this.sensitiveSectionVisible = this.sensitiveCanAdjust && (latchValue || needAgeVerify)
                // S-001/R-138: onSensitiveToggle runs on the UI thread from an onClick
                // handler and must never block on a network call — cache the (network-
                // backed) age-verification result here, computed off-thread, once.
                this.needAgeVideoVerificationCache = Some(needAgeVerify)
                Hilog.info(0, "CjTelegram", "[DataStorage] sensitive gate: canAdjust=${this.sensitiveCanAdjust} on=${this.sensitiveContentOn} latch=${latchValue} needAgeVerify=${needAgeVerify} visible=${this.sensitiveSectionVisible}")
            }
        }
    }

    // 对位源侧 `toggleSensitiveContent` 分支 (:886-912). `enableInteractiveChanges: false`
    // 的对位：开关外观只由"设置真正写成功并回流"驱动，onChange 不得先翻转显示态——
    // 调用方 (ItemListToggleRow.onChange) 拿到 `isOn` 后立刻把它丢弃、只用作分支判据，
    // 从不据此直接赋值 this.sensitiveContentOn（见 build() 里的调用点）。
    private func onSensitiveToggle(isOn: Bool): Unit {
        if (!isOn) {
            // 源侧 IN-7 不对称：关方向无确认层，直接写。
            let _ = spawn {
                let ok = getSettingsService().setSensitiveContentEnabled(false)
                if (ok) {
                    launch { this.sensitiveContentOn = false }
                }
            }
            return
        }
        if (!this.needAgeVideoVerification_cached()) {
            let uiCtx = getUIContext()
            let confirmBtn = AlertDialogButtonOptions(
                value: "Confirm",
                action: {=>
                    let _ = spawn {
                        let ok = getSettingsService().setSensitiveContentEnabled(true)
                        if (ok) {
                            launch { this.sensitiveContentOn = true }
                        }
                    }
                }
            )
            let cancelBtn = AlertDialogButtonOptions(value: "Cancel", action: {=> ()})
            uiCtx.showAlertDialog(AlertDialogParamWithOptions(
                title: "18+ Content",
                message: "Confirm that you are over 18 years old and update settings to see potentially explicit and sensitive content.",
                autoCancel: true,
                buttons: [cancelBtn, confirmBtn],
                buttonDirection: DialogButtonDirection.Horizontal,
                textStyle: WordBreak.BreakWord
            ))
            return
        }
        // needAgeVideoVerification()==true: 源侧走 AgeVerificationScreen（人脸扫描）分支。
        // TC-0422 消费 shell_face_scan emit 的 ic_shell_face_scan_age_verification_sheet_
        // hookup：对位源侧 presentAgeVerification()（AgeVerificationScreen.swift:369-381）
        // 的前置检查——直接读已缓存的 this.sensitiveCanAdjust（不发新网络请求，S-001/R-138：
        // onSensitiveToggle 跑在 UI 线程）。canAdjust==false 时弹一次性不可调整提示并 return；
        // 否则拉起年龄验证 sheet（摄像头/CoreML 扫脸本轮不做，sheet 主按钮只关闭 sheet，
        // TC-0422 D1 维持 blocked(device_required)，是已裁定的交付边界）。
        Hilog.info(0, "CjTelegram", "[DataStorage] sensitive toggle -> age verification sheet")
        if (!this.sensitiveCanAdjust) {
            let uiCtx = getUIContext()
            let confirmBtn = AlertDialogButtonOptions(value: "Confirm", action: {=> ()})
            uiCtx.showAlertDialog(AlertDialogParamWithOptions(
                title: "18+",
                message: "This media may contain sensitive content suitable only for adults.",
                autoCancel: true,
                buttons: [confirmBtn],
                buttonDirection: DialogButtonDirection.Horizontal,
                textStyle: WordBreak.BreakWord
            ))
            return
        }
        this.showAgeVerificationSheet = true
        return
    }

    // TC-0422 (ic_shell_face_scan_age_verification_sheet_hookup required_outcomes[2]):
    // zero-arg wrapper for the sheet mount below — shape mirrors pages/
    // DataPrivacySettingsPage.cj's buildDraftsSheet/buildPaymentsSheet precedent. Content itself lives in
    // components/AgeVerificationSheet.cj (owned by shell_face_scan); this page only wires
    // the pull-up point.
    @Builder
    private func buildAgeVerificationSheet() {
        // R-121: AgeVerificationSheetActions.init's `onDismiss` param is not `!`-named, so
        // inside this @Component-macro-expanded method body it must be called positionally
        // (a labelled `onDismiss:` call fails macro expansion here).
        ageVerificationSheetContent(AgeVerificationSheetActions({ => this.showAgeVerificationSheet = false }))
    }

    // Cached by prefetchSensitiveContentGate() (network-backed, computed off-thread once
    // during ensureLoaded) — onSensitiveToggle only ever reads this synchronously, never
    // issues its own network call from the UI thread (S-001/R-138). If the toggle is
    // somehow activated before the prefetch resolves, `None` falls back to `false` (goes
    // down the S8 Alert-confirm branch), matching source's conservative default before
    // the age-verification signal is known — the section can't render with a stale/wrong
    // gate anyway since sensitiveSectionVisible depends on the same prefetch.
    private var needAgeVideoVerificationCache: ?Bool = None

    private func needAgeVideoVerification_cached(): Bool {
        match (this.needAgeVideoVerificationCache) {
            case Some(v) => return v
            case None => return false
        }
    }

    // ── Helper text functions (avoid let in @Builder per S-005) ──
    private func cacheSizeLabel(): String {
        if (this.cacheSize.size > 0) { return this.cacheSize }
        return this.localized("Cache.Indexing", "Telegram is calculating current cache size.\nThis can take a few minutes.")
    }

    private func clearCacheLabel(): String {
        if (this.isClearing) { return this.localized("ClearCache.NoProgress", "Clearing the Cache") }
        return this.localized("Cache.ClearCache", "Clear Cache")
    }

    private func clearCacheColor(): UInt32 {
        if (this.isClearing) { return this.presentation.secondaryTextColor } else { return 0xFF3B30 }
    }

    // ── Shared destructive-action confirmation gate (source: requestX()/commitX() split
    // in DataUsageScreen.swift:1189/1213 and StorageUsageScreen.swift:2877/2912).
    // Must be invoked synchronously from .onClick — no spawn/launch wrapping the call. ──
    // Dialog-truncation fix (this feature's ticket, filed alongside TC-0420 M1/M2):
    // AlertDialogParamWithButtons laid its two buttons out horizontally, so each got ~half
    // the dialog width — long confirm labels ("Clear Entire Cache", "Reset Statistics") were
    // clipped with an ellipsis, and `textStyle` (?WordBreak) was never passed, so the message
    // body fell back to the platform default character-boundary wrap (mid-word breaks like
    // "setting"/"s."). Switching to AlertDialogParamWithOptions with vertical button
    // stacking gives every button its own full-width row (source parity too: source's
    // ActionSheetController.setItemGroups rows are each full-width — DataUsageScreen.swift:
    // 1189/StorageUsageScreen.swift:2877) and WordBreak.BreakWord wraps the body on word
    // boundaries. Both types are @!APILevel since:"22"; this project's build-profile.json5
    // compatibleSdkVersion/targetSdkVersion are both "6.0.2(22)".
    private func confirmDestructive(
        title!: String, message!: String, confirmText!: String, onConfirm!: () -> Unit
    ): Unit {
        let uiCtx = getUIContext()
        let confirmBtn = AlertDialogButtonOptions(
            value: confirmText, fontColor: 0xFF3B30,
            action: {=> onConfirm() }
        )
        let cancelBtn = AlertDialogButtonOptions(
            value: "Cancel", action: {=> ()}
        )
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: title,
            message: message,
            autoCancel: true,
            buttons: [confirmBtn, cancelBtn],
            buttonDirection: DialogButtonDirection.Vertical,
            textStyle: WordBreak.BreakWord
        ))
    }

    // D-160「① 把子组件实例化抽到一个无参 @Builder 私有函数」半步——见调用点 build() 内
    // 的 if/else 双相同分支。三行的 additionalDetailLabel/value 都读裸 this.<@State> 字段。
    @Builder
    func buildAutosaveRowsCard() {
        Column {
            ItemListDisclosureRow(
                icon: @r(app.media.setroot_ds_private),
                title: "Private Chats",
                value: this.autosavePrivateChatsValueLabel,
                additionalDetailLabel: this.autosavePrivateChatsDetailLabel,
                onClick: { => routerPush("SaveIncomingMediaPage", "private") }
            )
            ItemListSeparator(leftInset: 61)
            ItemListDisclosureRow(
                icon: @r(app.media.setroot_ds_group),
                title: "Group Chats",
                value: this.autosaveGroupsValueLabel,
                additionalDetailLabel: this.autosaveGroupsDetailLabel,
                onClick: { => routerPush("SaveIncomingMediaPage", "groups") }
            )
            ItemListSeparator(leftInset: 61)
            ItemListDisclosureRow(
                icon: @r(app.media.setroot_ds_channel),
                title: "Channels",
                value: this.autosaveChannelsValueLabel,
                additionalDetailLabel: this.autosaveChannelsDetailLabel,
                onClick: { => routerPush("SaveIncomingMediaPage", "channels") }
            )
        }
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(26)
        .clip(true)
        .margin(left: 16, right: 16)
    }

    public func build() {
        Column {
            // TC-0541 C3: nav chrome reads PresentationSnapshot (navBarColor / textColor /
            // accentColor). Do not paint Day literals; hot theme publish rebuilds this Row.
            Row {
                Row { Image(@r(app.media.callui_v2_back)).width(10).height(18).fillColor(this.presentation.accentColor) }
                    .width(44).height(44).borderRadius(22)
                    .backgroundColor(if (this.presentation.isDark) { 0x663A3A3C } else { 0x99FFFFFF })
                    .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                    .onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(trSource("Data and Storage"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row { }.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            Scroll(this.contentScroller) {
                Column {
                    // ══════════════════════════════════════════════════════════════════
                    // CARD 1 — usage (source `section=.usage`, NO header entry in source:
                    // dataAndStorageControllerEntries never appends a header before
                    // .storageUsage/.networkUsage — DataAndStorageSettingsController.swift
                    // :609-610). New `Storage Usage` / `Network Usage` rows rebuilt with
                    // source appearance at the head of the card (修法方向 point 6); target-
                    // only `Cache Size` / `Clear Cache` (TC-0438) is kept, folded into this
                    // same card instead of its own headered card, positioned under the row
                    // it extends. The inline `NETWORK USAGE` stat block (Wi-Fi/Mobile
                    // sent/received counts + inline `Reset Statistics`) that used to live
                    // here was removed per diag-suite_settings_data_storage-TC-0418-round5.md
                    // F-1: source root screen never had it, and it became pure duplication
                    // once `pages/DataUsagePage.cj` (shell_storage_usage, TC-0429 passed)
                    // shipped the same data + reset action on its own destination screen.
                    // ══════════════════════════════════════════════════════════════════
                    Column {
                        // `Storage Usage` — source disclosure row (icon+title+value+chevron).
                        // TC-0438-round2 修法方向 §2: destination screen built this round
                        // (StorageUsagePage) — real `routerPush`, same shape as the
                        // `Network Usage` row below once its destination existed.
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_ds_storage),
                            title: "Storage Usage",
                            value: this.cacheSize,
                            onClick: { => routerPush("StorageUsagePage", "") }
                        )
                        ItemListSeparator(leftInset: 61)

                        // `Network Usage` — source disclosure row. Destination screen built
                        // this round (DataUsagePage) — real `routerPush`, same pattern as
                        // `Storage Usage` above once its destination existed
                        // (diag-suite_settings_data_storage-TC-0429-round2.md 修法方向 §2).
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_ds_network),
                            title: "Data Usage",
                            value: this.networkUsageTotalLabel,
                            onClick: { => routerPush("DataUsagePage", "") }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .clip(true)
                    .margin(left: 16, right: 16, top: 16)

                    // ══════════════════════════════════════════════════════════════════
                    // CARD 2 — AUTO-DOWNLOAD MEDIA (source `section=.autoDownload`, header
                    // "ChatSettings.AutoDownloadTitle"). Source rows in stableId order:
                    // Using Cellular(3) / Using Wi-Fi(4) / Reset Auto-Download Settings(5).
                    // Kept target-only extension (net-regression guard, see file header):
                    // Photos/Videos/Files auto-download-type toggles, appended after the 3
                    // source rows — same "kept at card end, after source items" pattern the
                    // report itself applies to Save to Gallery/Data Saving in OTHER.
                    // ══════════════════════════════════════════════════════════════════
                    ItemListSectionHeader(title: "AUTOMATIC MEDIA DOWNLOAD", topPad: 24)

                    Column {
                        // `Using Cellular` / `Using Wi-Fi` — source disclosure rows w/
                        // two-line subtitle in source; this basic's two-line value column
                        // carries the connection's enabled/preset summary. TC-0427 FIX-2
                        // built the destination screen this round, so these now `routerPush`
                        // instead of scrolling to the (now-deleted) in-page DOWNLOAD ON
                        // MOBILE DATA / DOWNLOAD ON WI-FI sections.
                        // diag-suite_settings_data_storage-TC-0418-round4.md §M1 改动 2：
                        // `value:` 传裸 @State 字段（D-125，能回灌），`useDetailLabelStyle:
                        // true` 选择两行形态——不再用不回灌的 detailText 通道。
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_ds_cellular),
                            title: "Using Cellular",
                            value: this.cellularSummaryLabel,
                            useDetailLabelStyle: true,
                            onClick: { => routerPush("AutodownloadConnectionTypePage", "cellular") }
                        )
                        ItemListSeparator(leftInset: 61)
                        ItemListDisclosureRow(
                            icon: @r(app.media.setroot_ds_wifi),
                            title: "Using Wi-Fi",
                            value: this.wifiSummaryLabel,
                            useDetailLabelStyle: true,
                            onClick: { => routerPush("AutodownloadConnectionTypePage", "wifi") }
                        )
                        ItemListSeparator(leftInset: 61)

                        // `Reset Auto-Download Settings` — source action row (icon, no
                        // chevron/value). Icon is the one non-badge asset (Phase 2): a
                        // tintable SVG (`setroot_ds_reset`, fill overridden via .fillColor(),
                        // same mechanism as components/misc_ic_premiumlock.svg) so it greys
                        // out together with the text via the shared bare-@State mirror
                        // resetAutoDownloadColorValue (TC-0420 M2, D-125).
                        // Guard stays inside onClick (R37); row is never removed/disabled.
                        Row {
                            Image(@r(app.media.setroot_ds_reset))
                                .width(29)
                                .height(29)
                                .fillColor(this.resetAutoDownloadColorValue)
                                .margin(right: 16)
                            Text(trSource("Reset Auto-Download Settings"))
                                .fontSize(17)
                                .fontColor(this.resetAutoDownloadColorValue)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .onClick({ _evt =>
                            if (this.autoDownloadIsCustomized()) {
                                this.confirmDestructive(
                                    title: "Reset Auto-Download Settings",
                                    message: "Undo all custom auto-download settings.",
                                    confirmText: "Reset",
                                    onConfirm: {=>
                                        this.resetAutoDownloadSettings()
                                        this.refreshCellularSummary()
                                        this.refreshWifiSummary()
                                        this.refreshResetGate()
                                    }
                                )
                            }
                        })
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    // ══════════════════════════════════════════════════════════════════
                    // TC-0427 FIX-2: the in-page `DOWNLOAD ON MOBILE DATA` / `DOWNLOAD ON
                    // WI-FI` sections (TC-0418's Ruling-1 stand-in, kept only until this
                    // round built the real destination) are deleted this round. `Using
                    // Cellular`/`Using Wi-Fi` above now
                    // `routerPush` to the real destination (AutodownloadConnectionTypePage
                    // -> AutodownloadMediaCategoryPage), which is where the corrected
                    // control form (continuous slider, source value domain, Preload Larger
                    // Videos gate) actually lives. Keeping both would leave two working
                    // paths to the same setting with no source counterpart for the deleted
                    // one (D4.5 dead-weight, not kept-content) — removed per this task's
                    // explicit instruction to decide their fate deliberately, not silently.
                    // ══════════════════════════════════════════════════════════════════

                    // ══════════════════════════════════════════════════════════════════
                    // CARD 3 — SAVE TO CAMERA ROLL (source `section=.autoSave`, header
                    // "Settings.SaveToCameraRollSection" — literal has NO "AUTO-" prefix).
                    // diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-C
                    // 改动 3 (TC-0423/TC-0424): these 3 rows used to flip their bool in place
                    // on click (a working-but-fake disclosure — no destination existed). This
                    // round built `SaveIncomingMediaPage`, so onClick now `routerPush`es
                    // (matching source's `.autoSaveItem` -> `openSaveIncoming(type)` -> push).
                    // `value:` label is unchanged (still the same per-peer-type bool via
                    // refreshAutosaveLabels(), already re-read on return-visit through
                    // refreshVisibleState()) — see SaveIncomingMediaPage.cj's file header for
                    // why the target model is still the single combined bool, not source's
                    // independent photo/video split.
                    // ══════════════════════════════════════════════════════════════════
                    ItemListSectionHeader(title: "SAVE TO PHOTOS", topPad: 24)

                    // D-160/D-184 双相同分支挂载守卫（见 refreshAutosaveDetailLabels() 注释）：
                    // additionalDetailLabel 是普通 var，裸 @State 调用点本身不会让已挂载
                    // 实例回灌，靠这一对 branchId 不同、内容相同的分支强制整卡销毁重建。
                    if (this.autosaveDetailRemountToggle) {
                        this.buildAutosaveRowsCard()
                    } else {
                        this.buildAutosaveRowsCard()
                    }

                    Text(trSource("Automatically save all new photos and videos from these chats to your Photos app."))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 8)
                        .padding(left: 31, right: 31)
                        .width(100.percent)

                    // ══════════════════════════════════════════════════════════════════
                    // CARD 4 — Use Less Data for Calls (source `section=.voiceCalls`, NO
                    // header entry — DataAndStorageSettingsController.swift never appends
                    // a header for this section either). Single boolean switch (source:
                    // ItemListSwitchItem, :396-399), not the 3-way Radio the target had.
                    // ══════════════════════════════════════════════════════════════════
                    Column {
                        ItemListToggleRow(
                            title: "Use Less Data for Calls",
                            isOn: this.useLessDataForCalls,
                            onChange: { isOn: Bool =>
                                this.useLessDataForCalls = isOn
                                let newMode: Int32 = if (isOn) { 2 } else { 0 }
                                this.callDataSavingMode = newMode
                                this.saveCallDataSavingModeToService(newMode)
                            }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .margin(left: 16, right: 16, top: 24)

                    Text(trSource("Using less data may improve your experience on bad networks, but will slightly decrease audio and video quality."))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 8)
                        .padding(left: 31, right: 31)
                        .width(100.percent)

                    // ══════════════════════════════════════════════════════════════════
                    // CARD 5 — OTHER (source `section=.other`, header "ChatSettings.Other").
                    // Source rows in stableId order: Share Sheet(31) / Save Edited Photos(32) /
                    // Pause Music While Recoding(33, source literal incl. its sic spelling) /
                    // Raise to Listen(34). Kept target-only extension (Save to Gallery, Data
                    // Saving) appended at the end — 修法方向 point 6 explicit disposition.
                    // MISCELLANEOUS's former 3 rows now live here (their real section).
                    // diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-A:
                    // `Share Sheet` was skipped in round1/round2 (destination screen had no
                    // feature owner) — this round builds `IntentsSettingsPage` and restores the
                    // row (first child, matching source stableId order). `.clip(true)` added
                    // to this card's modifiers now that it contains an `ItemListDisclosureRow`
                    // (D-124: cards with Disclosure/Button rows need it for the pressed-state
                    // fill; pure-Toggle cards don't).
                    // ══════════════════════════════════════════════════════════════════
                    ItemListSectionHeader(title: "OTHER", topPad: 24)

                    Column {
                        ItemListDisclosureRow(
                            title: "Share Sheet",
                            value: this.shareSheetValueLabel,
                            onClick: { => routerPush("IntentsSettingsPage", "") }
                        )
                        ItemListSeparator()
                        ItemListToggleRow(
                            title: "Save Edited Photos",
                            isOn: this.saveEditedPhotos,
                            onChange: { isOn: Bool =>
                                this.saveEditedPhotos = isOn
                                this.saveMiscToggle("saveEditedPhotos", isOn)
                            }
                        )
                        ItemListSeparator()
                        ItemListToggleRow(
                            title: "Pause Music While Recording",
                            isOn: this.pauseMusicOnRecording,
                            onChange: { isOn: Bool =>
                                this.pauseMusicOnRecording = isOn
                                this.saveMiscToggle("pauseMusic", isOn)
                            }
                        )
                        ItemListSeparator()
                        ItemListToggleRow(
                            title: "Raise to Listen",
                            isOn: this.raiseToListenEnabled,
                            onChange: { isOn: Bool =>
                                this.raiseToListenEnabled = isOn
                                this.saveMiscToggle("raiseToListen", isOn)
                            }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .clip(true)
                    .margin(left: 16, right: 16)

                    Text(trSource("Raise to Listen allows you to quickly listen and reply to incoming audio messages by raising the phone to your ear."))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .margin(top: 8)
                        .padding(left: 31, right: 31)
                        .width(100.percent)

                    // ══════════════════════════════════════════════════════════════════
                    // §F-B `Show 18+ Content` (source `section=.other`, no own header entry —
                    // source appends it right after `raiseToListenInfo` inside the same
                    // `.other` section, :643-646). Gated by `sensitiveSectionVisible`
                    // (prefetchSensitiveContentGate(), ensureLoaded) — renders nothing while
                    // the gate is false, byte-identical to today. Pure-Toggle card: no
                    // `.clip(true)` (D-124).
                    // ══════════════════════════════════════════════════════════════════
                    if (this.sensitiveSectionVisible) {
                        Column {
                            // `enableInteractiveChanges: false` (对位源侧 :422-425
                            // enableInteractiveChanges:false)：Toggle 本体的命中区被组件
                            // 内部关掉(shouldCaptureTap()==true)，`onChange` 闭包因此永远
                            // 不会被 Toggle 自身触发——真正接住点击的是组件内的捕获层，
                            // 回调走 `onActivatedWhileDisabled`(无参)，故这里用当前值取反
                            // 算出用户的目标态，交给 onSensitiveToggle 判定，不由 Toggle
                            // 自行翻转视觉态（isOn 只在写成功回流后才由 onSensitiveToggle
                            // 显式赋新值）。
                            ItemListToggleRow(
                                title: "Show 18+ Content",
                                isOn: this.sensitiveContentOn,
                                enableInteractiveChanges: false,
                                onActivatedWhileDisabled: { => this.onSensitiveToggle(!this.sensitiveContentOn) }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor)
                        .borderRadius(26)
                        .margin(left: 16, right: 16, top: 24)

                        Text(trSource("Do not hide media that contain content suitable only for adults."))
                            .fontSize(13)
                            .fontColor(this.presentation.secondaryTextColor)
                            .margin(top: 8)
                            .padding(left: 31, right: 31)
                            .width(100.percent)
                    }

                    // FIX-5（diag-suite_settings_data_storage-TC-0435.md §6.5）：目标自造的
                    // `IN-APP BROWSER` 分节（ItemListSectionHeader + ItemListToggleRow
                    // "Open Links in External Browser" + 自造页脚）在本轮删除——源侧
                    // DataAndStorageSettingsController.swift 的 Data and Storage 屏**没有**任何
                    // 浏览器分节，那三条文案在源侧也 0 引用（E3：自造文案）。该能力已归位到它在
                    // 源侧本来所在的位置：Privacy and Security ▸ Open Links in ▸ Web Browser 屏
                    // 的 `OPEN LINKS IN` 分节（pages/WebBrowserSettingsPage.cj）。
                    // 顺序约束（round2 增量 D-2，硬）：本删除必须排在 FIX-2（建屏）之后——在
                    // Web Browser 屏可达之前删掉它，会把"切换应用内/外部浏览器"这条当时唯一可达
                    // 的能力变成零可达，构成净退化。两者在本轮同一次提交内落地，约束成立。

                    // ══════════════════════════════════════════════════════════════════
                    // CARD 6 — CONNECTION TYPE (source `section=.connection`, header
                    // "ChatSettings.ConnectionType.Title"). `Proxy` destination screen
                    // already exists on target (pages/ProxySettingsPage.ets/.cj, routed
                    // from ChatListPage.cj:1020) — real routerPush, no scroll-to fallback
                    // needed (修法方向 point 7, first bullet).
                    // ══════════════════════════════════════════════════════════════════
                    ItemListSectionHeader(title: "CONNECTION TYPE", topPad: 24)

                    Column {
                        ItemListDisclosureRow(
                            title: "Proxy",
                            value: this.proxyValueLabel,
                            onClick: { => routerPush("ProxySettingsPage", "") }
                        )
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(26)
                    .clip(true)
                    .margin(left: 16, right: 16, bottom: 32)
                }
            }
            .layoutWeight(1)
            .backgroundColor(this.presentation.backgroundColor)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        // TC-0422 (ic_shell_face_scan_age_verification_sheet_hookup required_outcomes[3]):
        // literal template copied from pages/DataPrivacySettingsPage.cj's sheet-mount calls.
        // backgroundColor must be the Color.Transparent constant, not a 0x00xxxxxx numeric
        // literal (D-144: a numeric color whose leading byte is 0 gets alpha forced to FF).
        .bindSheet(this.showAgeVerificationSheet, this.buildAgeVerificationSheet, options: SheetOptions(
            backgroundColor: Color.Transparent,
            onDisappear: { => launch { this.showAgeVerificationSheet = false } },
            height: SheetSize.FitContent,
            preferType: SheetType.Bottom,
            showClose: false,
            dragBar: false
        ))
        .onAppear({ =>
            this.ensureLoaded()
            // Unconditional (not `loaded`-gated): picks up changes made on
            // AutodownloadConnectionTypePage/AutodownloadMediaCategoryPage on return.
            this.refreshCellularSummary()
            this.refreshWifiSummary()
        })
    }
}
