package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{
    PresentationSnapshot, PresentationStringsSnapshot,
    currentPresentation, currentPresentationStrings
}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.unicode.*
import ohos_app_cangjie_entry.services.{
    getStickersService,
    getEntityKeyboardStore,
    getArchivedStickerPacksNoticeService,
    getFeaturedStickersScreenService,
    getTelegramCoreSettingsService,
    getShareControllerService,
    showToast,
    StickerItem, StickerPackInfo
}
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.getSafeAreaTop

/**
 * StickersSettingsPage — 贴纸/Emoji/Masks 管理页（P2-378+379+380 合一）（混合工程迁移版）
 *
 * iOS 对应: InstalledStickerPacksController.swift + ArchivedStickerPacksController.swift
 *           + FeaturedStickerPacksController.swift (SettingsUI)
 *
 * 三功能合页实现（P2-380 要求 emoji/masks 子 tab）
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（原 .hideTitleBar(true)）
 *  - pageStack.pop() → routerPop()
 *  - aboutToAppear 有实逻辑 → ensureLoaded()+.onAppear
 */
@HybridComponentEntry
@Component
public class StickersSettingsPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ---- Sub-tab (P2-380) ----
    // 0=Stickers 1=Emoji 2=Masks
    @State var currentTabIdx: Int32 = 0

    // ---- 已安装贴纸包列表（Stickers tab）----
    @State var installedPacks: Array<StickerPackInfo> = Array<StickerPackInfo>()
    @State var installedPackCovers: Array<StickerItem> = Array<StickerItem>()
    @State var isLoadingInstalled: Bool = true

    // ---- Emoji 贴纸包列表（Emoji tab，filter isEmoji=true from getAllStickers）----
    @State var emojiPacks: Array<StickerPackInfo> = Array<StickerPackInfo>()
    @State var isLoadingEmoji: Bool = true

    // ---- Masks 贴纸包（Masks tab，getArchivedStickers masks=true）----
    @State var masksPacks: Array<StickerPackInfo> = Array<StickerPackInfo>()
    @State var isLoadingMasks: Bool = true

    // ---- 归档贴纸包（底部 Archived 行）----
    @State var archivedCount: Int32 = 0
    @State var isLoadingArchived: Bool = true

    // ---- 精选贴纸包（Featured 段）----
    @State var featuredPacks: Array<StickerPackInfo> = Array<StickerPackInfo>()
    @State var isLoadingFeatured: Bool = true
    // S7-114：Trending Stickers 行右侧的未读精选包计数（iOS InstalledStickerPacksController
    // .trending(count) ← featured unread ids）。
    @State var featuredUnreadCount: Int64 = 0

    // ---- 本地设置开关 ----
    @State var suggestByEmoji: Bool = true
    @State var loopAnimatedStickers: Bool = true
    @State var suggestAnimatedEmoji: Bool = true
    // 0=All Sets, 1=Added Sets, 2=None. Mirrors EmojiStickerSuggestionMode.
    @State var suggestionMode: Int32 = 0
    @State var largeEmoji: Bool = true
    @State var dynamicPackOrder: Bool = true
    @State var showSuggestionMenu: Bool = false
    @State var editing: Bool = false
    @State var selectedPackIds: Array<Int64> = Array<Int64>()

    // ---- 操作状态 ----
    @State var isOperating: Bool = false
    @State var operatingId: Int64 = 0

    @State var dragFromIdx: Int64 = -1
    @State var dragStartScreenY: Float64 = 0.0
    @State var dragMoved: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.quickReaction = getTelegramCoreSettingsService().getQuickReaction()
        this.loadInstalledPacks()
        this.loadArchivedCount()
        this.loadFeaturedPacks()
        this.loadLocalSettings()
    }

    // ==================== 数据加载 ====================

    /**
     * 从 StickersService.getAllStickers() 加载所有已安装贴纸包
     * 并按 isEmoji 分流到 emojiPacks（P2-380 Emoji tab 数据源）
     */
    private func loadInstalledPacks(): Unit {
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] loadInstalledPacks start")
            let svc = getStickersService()
            let result = svc.getAllStickers()
            let emojiResult = svc.getEmojiStickers()
            let allPacks = result.packs
            let total = allPacks.size
            let stickerBuf = ArrayList<StickerPackInfo>()
            var i: Int64 = 0
            while (i < total) {
                let p = allPacks[i]
                stickerBuf.add(p)
                i = i + 1
            }
            let stickerArr = Array<StickerPackInfo>(stickerBuf.size, { j: Int64 => stickerBuf[j] })
            let initialCovers = Array<StickerItem>(stickerArr.size, { j: Int64 => stickerArr[j].cover })
            let emojiArr = Array<StickerPackInfo>(emojiResult.packs.size, { j: Int64 => emojiResult.packs[j] })
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] stickers=${stickerBuf.size} emoji=${emojiResult.packs.size}")
            launch {
                if (result.success) {
                    this.installedPacks = stickerArr
                    this.installedPackCovers = initialCovers
                }
                if (emojiResult.success) {
                    this.emojiPacks = emojiArr
                }
                this.isLoadingInstalled = false
                this.isLoadingEmoji = false
            }
            let resolvedCovers = ArrayList<StickerItem>()
            for (pack in stickerArr) {
                var cover = pack.cover
                if (cover.documentId == 0) {
                    let detail = svc.getStickerSet(pack.id, pack.accessHash)
                    if (detail.success && !detail.stickers.isEmpty()) {
                        cover = detail.stickers[0]
                    }
                }
                resolvedCovers.add(cover)
            }
            launch {
                if (result.success) {
                    this.installedPackCovers = resolvedCovers.toArray()
                }
            }
        }
    }

    /**
     * 从 getArchivedStickers masks=true 加载 masks 贴纸包列表（Masks tab）
     * S-001: spawn → launch
     */
    private func loadMasksPacks(): Unit {
        if (!this.isLoadingMasks) { return }
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] loadMasksPacks start")
            let svc = getStickersService()
            let result = svc.getArchivedStickers(masks: true)
            let total = result.packs.size
            let arr = Array<StickerPackInfo>(total, { i: Int64 => result.packs[i] })
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] masksPacks=${total}")
            launch {
                if (result.success) {
                    this.masksPacks = arr
                }
                this.isLoadingMasks = false
            }
        }
    }

    /**
     * 从 ArchivedStickerPacksNoticeService 加载归档贴纸包数量
     * S-001: spawn → launch
     */
    private func loadArchivedCount(): Unit {
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] loadArchivedCount start")
            let svc = getArchivedStickerPacksNoticeService()
            let result = svc.getArchivedStickers()
            let cnt = result.totalCount
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] archivedCount=${cnt}")
            launch {
                if (result.success) {
                    this.archivedCount = cnt
                }
                this.isLoadingArchived = false
            }
        }
    }

    /**
     * 从 FeaturedStickersScreenService.getFeaturedStickerSets() 加载精选贴纸包（真 TL）
     * S-001: spawn → launch
     */
    private func loadFeaturedPacks(): Unit {
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] loadFeaturedPacks start")
            let svc = getFeaturedStickersScreenService()
            let result = svc.getFeaturedStickerSets()
            let total = result.packs.size
            let arr = Array<StickerPackInfo>(total, { i: Int64 => result.packs[i] })
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] featuredPacks=${total}")
            let unread = result.unreadIds.size
            launch {
                if (result.success && !result.notModified) {
                    this.featuredPacks = arr
                    this.featuredUnreadCount = unread
                }
                this.isLoadingFeatured = false
            }
        }
    }

    /**
     * 从 Preferences 读取本地设置开关
     */
    private func loadLocalSettings(): Unit {
        let _ = spawn {
            let svc = getStickersService()
            let suggest = svc.readLocalSetting("stickers_suggest_by_emoji")
            let loopAnim = svc.readLocalSetting("stickers_loop_animated")
            let animEmoji = svc.readLocalSetting("stickers_suggest_anim_emoji")
            let storedSuggestionMode = svc.readLocalIntSetting("stickers_suggestion_mode")
            let storedLargeEmoji = svc.readLocalIntSetting("stickers_large_emoji")
            let storedDynamicOrder = svc.readLocalIntSetting("stickers_dynamic_pack_order")
            let storedQuickReaction = svc.readLocalStringSetting("quick_reaction", "❤️")
            launch {
                this.suggestByEmoji = suggest
                this.loopAnimatedStickers = loopAnim
                this.suggestAnimatedEmoji = animEmoji
                this.suggestionMode = if (storedSuggestionMode >= 1 && storedSuggestionMode <= 3) {
                    storedSuggestionMode - 1
                } else if (suggest) { 0 } else { 2 }
                this.largeEmoji = storedLargeEmoji >= 0
                this.dynamicPackOrder = storedDynamicOrder >= 0
                this.quickReaction = storedQuickReaction
            }
        }
    }

    // SegmentedControl onChange 回调（显式 Unit，处理 Int64→Int32 转换 + masks 懒加载）
    private func onTabChanged(idx: Int64): Unit {
        this.currentTabIdx = Int32(idx)
        // Masks tab 懒加载（与原 Tabs.onChange 逻辑等价）
        if (idx == 2 && this.isLoadingMasks) {
            this.loadMasksPacks()
        }
    }

    // ==================== 本地设置持久化 ====================

    // S3-02: quick reaction (iOS QuickReactionSetupController candidates).
    @State var quickReaction: String = "👍"
    @State var quickReactionExpanded: Bool = false
    let quickReactionChoices: Array<String> = ["👍", "❤️", "🔥", "🎉", "😁", "👎"]

    private func persistSuggestByEmoji(enabled: Bool): Unit {
        let _ = spawn {
            getStickersService().persistLocalSetting("stickers_suggest_by_emoji", enabled)
        }
    }

    private func persistLoopAnimated(enabled: Bool): Unit {
        let _ = spawn {
            getStickersService().persistLocalSetting("stickers_loop_animated", enabled)
        }
    }

    private func persistSuggestAnimEmoji(enabled: Bool): Unit {
        let _ = spawn {
            getStickersService().persistLocalSetting("stickers_suggest_anim_emoji", enabled)
        }
    }

    private func setSuggestionMode(mode: Int32): Unit {
        this.suggestionMode = mode
        this.showSuggestionMenu = false
        let stored = mode + 1
        let _ = spawn {
            getStickersService().persistLocalIntSetting("stickers_suggestion_mode", stored)
        }
    }

    private func persistLargeEmoji(enabled: Bool): Unit {
        this.largeEmoji = enabled
        let _ = spawn {
            getStickersService().persistLocalSetting("stickers_large_emoji", enabled)
        }
    }

    private func persistDynamicPackOrder(enabled: Bool): Unit {
        this.dynamicPackOrder = enabled
        let _ = spawn {
            getStickersService().persistLocalSetting("stickers_dynamic_pack_order", enabled)
        }
    }

    // ==================== 贴纸包操作（P2-379）====================

    /**
     * 卸载贴纸包（messages.uninstallStickerSet — swipe 删除）
     * S-001: spawn → launch
     */
    private func uninstallPack(packId: Int64, accessHash: Int64): Unit {
        let previousLocal = this.installedPacks
        let local = ArrayList<StickerPackInfo>()
        for (pack in previousLocal) {
            if (pack.id != packId) { local.add(pack) }
        }
        this.installedPacks = local.toArray()
        launch {
            this.isOperating = true
            this.operatingId = packId
        }
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let previousSnapshot = store.currentStickerSnapshot()
        let optimisticVersion = store.optimisticallyRemoveStickerPack(accountToken, packId)
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] uninstallPack id=${packId}")
            let svc = getStickersService()
            let result = svc.uninstallStickerSet(packId, accessHash)
            if (result.success) {
                // 重新拉列表
                let allResult = svc.getAllStickers()
                let total = allResult.packs.size
                let stickerBuf2 = ArrayList<StickerPackInfo>()
                var i: Int64 = 0
                while (i < total) {
                    if (!allResult.packs[i].isEmoji) {
                        stickerBuf2.add(allResult.packs[i])
                    }
                    i = i + 1
                }
                let stickerArr2 = Array<StickerPackInfo>(stickerBuf2.size, { j: Int64 => stickerBuf2[j] })
                if (allResult.success) {
                    store.publishInstalledPacks(accountToken, allResult.packs.toArray())
                }
                launch {
                    if (allResult.success) {
                        this.installedPacks = stickerArr2
                    }
                    this.isOperating = false
                    this.operatingId = 0
                }
            } else {
                let _ = store.restoreStickerSnapshotIfVersion(
                    accountToken, previousSnapshot, optimisticVersion)
                launch {
                    this.installedPacks = previousLocal
                    this.isOperating = false
                    this.operatingId = 0
                }
            }
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] uninstallPack done id=${packId}")
        }
    }

    /**
     * 归档/恢复贴纸包（messages.toggleStickerSets — swipe 启停）
     * archive=true 停用(归档), archive=false 启用(取消归档)
     * S-001: spawn → launch
     */
    private func togglePackArchive(packId: Int64, accessHash: Int64, archive: Bool): Unit {
        let previousLocal = this.installedPacks
        if (archive) {
            let local = ArrayList<StickerPackInfo>()
            for (pack in previousLocal) {
                if (pack.id != packId) { local.add(pack) }
            }
            this.installedPacks = local.toArray()
        }
        launch {
            this.isOperating = true
            this.operatingId = packId
        }
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let previousSnapshot = store.currentStickerSnapshot()
        let optimisticVersion = if (archive) {
            store.optimisticallyRemoveStickerPack(accountToken, packId)
        } else { -1 }
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] togglePack id=${packId} archive=${archive}")
            let svc = getStickersService()
            let ids = ArrayList<Int64>()
            ids.add(packId)
            let hashes = ArrayList<Int64>()
            hashes.add(accessHash)
            let ok = svc.toggleStickerSets(ids, hashes, archive)
            if (ok) {
                // 重新拉已安装列表
                let allResult = svc.getAllStickers()
                let total = allResult.packs.size
                let stickerBuf3 = ArrayList<StickerPackInfo>()
                var i: Int64 = 0
                while (i < total) {
                    if (!allResult.packs[i].isEmoji) {
                        stickerBuf3.add(allResult.packs[i])
                    }
                    i = i + 1
                }
                let stickerArr3 = Array<StickerPackInfo>(stickerBuf3.size, { j: Int64 => stickerBuf3[j] })
                if (allResult.success) {
                    store.publishInstalledPacks(accountToken, allResult.packs.toArray())
                }
                launch {
                    if (allResult.success) {
                        this.installedPacks = stickerArr3
                    }
                    this.isOperating = false
                    this.operatingId = 0
                }
            } else {
                if (archive) {
                    let _ = store.restoreStickerSnapshotIfVersion(
                        accountToken, previousSnapshot, optimisticVersion)
                }
                launch {
                    this.installedPacks = previousLocal
                    this.isOperating = false
                    this.operatingId = 0
                }
            }
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] togglePack done")
        }
    }

    /**
     * tap-to-pick-and-place 重排：将 packs[fromIdx] 移到 packs[toIdx]（P2-379）
     * 使用 index shift（同 MediaPickerScreen.reorderSelectedUris 模式）
     * @State 集合突变规则：temp ArrayList → Array 整重赋值
     * 重排后发送 messages.reorderStickerSets TL（spawn）
     */
    private func movePack(fromIdx: Int64, toIdx: Int64): Unit {
        let currentPacks = this.installedPacks
        let currentCovers = this.installedPackCovers
        let sz = currentPacks.size
        if (fromIdx < 0 || toIdx < 0 || fromIdx >= sz || toIdx >= sz || fromIdx == toIdx) {
            return
        }
        // 构建可变副本（ArrayList 允许下标赋值）
        let buf = ArrayList<StickerPackInfo>()
        var i: Int64 = 0
        while (i < sz) {
            buf.add(currentPacks[i])
            i = i + 1
        }
        let moved = buf[fromIdx]
        let coverBuf = ArrayList<StickerItem>()
        let canMoveCover = this.installedPackCovers.size == sz
        if (canMoveCover) {
            for (cover in this.installedPackCovers) { coverBuf.add(cover) }
        }
        // 平移中间元素（同 reorderSelectedUris 模式）
        if (fromIdx < toIdx) {
            var j: Int64 = fromIdx
            while (j < toIdx) {
                buf[j] = buf[j + 1]
                j = j + 1
            }
        } else {
            var j: Int64 = fromIdx
            while (j > toIdx) {
                buf[j] = buf[j - 1]
                j = j - 1
            }
        }
        buf[toIdx] = moved
        if (canMoveCover) {
            let movedCover = coverBuf[fromIdx]
            if (fromIdx < toIdx) {
                var j: Int64 = fromIdx
                while (j < toIdx) {
                    coverBuf[j] = coverBuf[j + 1]
                    j = j + 1
                }
            } else {
                var j: Int64 = fromIdx
                while (j > toIdx) {
                    coverBuf[j] = coverBuf[j - 1]
                    j = j - 1
                }
            }
            coverBuf[toIdx] = movedCover
        }
        // 整体重赋值（@State 集合突变必须整重赋值）
        let newArr = Array<StickerPackInfo>(buf.size, { j: Int64 => buf[j] })
        launch {
            this.installedPacks = newArr
            if (canMoveCover) { this.installedPackCovers = coverBuf.toArray() }
        }
        // 构建 order id 列表发送 TL（spawn 异步）
        let orderIds = ArrayList<Int64>()
        var k: Int64 = 0
        while (k < buf.size) {
            orderIds.add(buf[k].id)
            k = k + 1
        }
        let store = getEntityKeyboardStore()
        let accountToken = store.currentToken()
        let previousSnapshot = store.currentStickerSnapshot()
        let optimisticVersion = store.optimisticallyReorderStickerPacks(
            accountToken, orderIds.toArray())
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] reorderStickerSets from=${fromIdx} to=${toIdx}")
            let svc = getStickersService()
            let ok = svc.reorderStickerSets(orderIds)
            if (!ok) {
                let _ = store.restoreStickerSnapshotIfVersion(
                    accountToken, previousSnapshot, optimisticVersion)
                launch {
                    this.installedPacks = currentPacks
                    this.installedPackCovers = currentCovers
                }
            } else if (this.dynamicPackOrder) {
                launch {
                    this.persistDynamicPackOrder(false)
                    showToast("Dynamic Pack Order Turned Off")
                }
            }
            Hilog.info(0, "CjTelegram", "[StickersSettingsPage] reorderStickerSets done ok=${ok}")
        }
    }

    private func handlePackReorderTouch(event: TouchEvent, index: Int64): Unit {
        match (event.eventType) {
            case TouchType.Down =>
                if (event.touches.size > 0) {
                    this.dragFromIdx = index
                    this.dragStartScreenY = event.touches[0].screenY
                    this.dragMoved = false
                }
            case TouchType.Move =>
                if (this.dragFromIdx == index && event.touches.size > 0) {
                    let delta = event.touches[0].screenY - this.dragStartScreenY
                    if (delta > 12.0 || delta < -12.0) { this.dragMoved = true }
                }
            case TouchType.Up =>
                if (this.dragFromIdx == index && event.changedTouches.size > 0) {
                    let delta = event.changedTouches[0].screenY - this.dragStartScreenY
                    var rowOffset: Int64 = 0
                    if (delta >= 90.0) { rowOffset = Int64((delta + 90.0) / 180.0) }
                    else if (delta <= -90.0) { rowOffset = Int64((delta - 90.0) / 180.0) }
                    var target = index + rowOffset
                    if (target < 0) { target = 0 }
                    if (target >= Int64(this.installedPacks.size)) { target = Int64(this.installedPacks.size) - 1 }
                    if (this.dragMoved && target != index) { this.movePack(index, target) }
                }
                this.dragFromIdx = -1
                this.dragMoved = false
            case TouchType.Cancel =>
                this.dragFromIdx = -1
                this.dragMoved = false
            case _ => ()
        }
    }

    // ==================== Helper 方法 ====================

    private func packTypeLabel(pack: StickerPackInfo): String {
        if (pack.isEmoji) { return "Emoji" }
        if (pack.isAnimated) { return "Animated" }
        if (pack.isVideo) { return "Video" }
        return "Static"
    }

    private func suggestionModeTitle(): String {
        if (this.suggestionMode == 1) { return "Added Sets" }
        if (this.suggestionMode == 2) { return "None" }
        return "All Sets"
    }

    private func quickReactionLabel(): String {
        if (!this.quickReaction.startsWith("custom|")) { return this.quickReaction }
        let parts = this.quickReaction.split("|")
        if (parts.size >= 3 && !parts[2].isEmpty()) { return parts[2] }
        return "🙂"
    }

    private func isPackSelected(packId: Int64): Bool {
        for (id in this.selectedPackIds) {
            if (id == packId) { return true }
        }
        return false
    }

    private func togglePackSelected(packId: Int64): Unit {
        let values = ArrayList<Int64>()
        var found = false
        for (id in this.selectedPackIds) {
            if (id == packId) { found = true } else { values.add(id) }
        }
        if (!found) { values.add(packId) }
        this.selectedPackIds = values.toArray()
    }

    private func finishEditing(): Unit {
        this.editing = false
        this.selectedPackIds = Array<Int64>()
    }

    private func operateOnSelected(archive: Bool): Unit {
        if (this.selectedPackIds.isEmpty() || this.isOperating) { return }
        let ids = ArrayList<Int64>()
        let hashes = ArrayList<Int64>()
        for (pack in this.installedPacks) {
            if (this.isPackSelected(pack.id)) {
                ids.add(pack.id)
                hashes.add(pack.accessHash)
            }
        }
        if (ids.isEmpty()) { return }
        this.isOperating = true
        let _ = spawn {
            if (archive) {
                let _ = getStickersService().toggleStickerSets(ids, hashes, true)
            } else {
                var i: Int64 = 0
                while (i < Int64(ids.size)) {
                    let _ = getStickersService().uninstallStickerSet(ids[i], hashes[i])
                    i = i + 1
                }
            }
            let refreshed = getStickersService().getAllStickers()
            let values = ArrayList<StickerPackInfo>()
            if (refreshed.success) {
                for (pack in refreshed.packs) {
                    if (!pack.isEmoji) { values.add(pack) }
                }
            }
            let array = values.toArray()
            launch {
                if (refreshed.success) { this.installedPacks = array }
                this.isOperating = false
                this.finishEditing()
                this.loadArchivedCount()
            }
        }
    }

    private func confirmSelectedOperation(archive: Bool): Unit {
        let count = this.selectedPackIds.size
        if (count == 0 || this.isOperating) { return }
        let noun = if (count == 1) { "Sticker Pack" } else { "Sticker Packs" }
        let action = if (archive) { "Archive" } else { "Delete" }
        let operation = SheetInfo(
            title: "${action} ${count} ${noun}",
            action: { => this.operateOnSelected(archive) }
        )
        let cancel = ActionSheetButtonOptions(value: "Cancel", action: { => () })
        getUIContext().showActionSheet(ActionSheetOptions(
            title: None,
            message: None,
            confirm: cancel,
            sheets: [operation],
            autoCancel: true
        ))
    }

    private func shareSelected(): Unit {
        if (this.selectedPackIds.isEmpty()) { return }
        var links = ""
        for (pack in this.installedPacks) {
            if (this.isPackSelected(pack.id) && !pack.shortName.isEmpty()) {
                if (!links.isEmpty()) { links = links + "\n" }
                links = links + "https://t.me/addstickers/" + pack.shortName
            }
        }
        if (!links.isEmpty()) {
            let _ = getShareControllerService().shareInviteLinkViaSystem(links)
        }
    }

    // ==================== Build 方法 ====================

    @Builder
    func buildSectionHeader(title: String) {
        Text(title)
            .fontSize(13)
            .fontColor(0xFF8E8E93)
            .margin(left: 16, top: 24, bottom: 8)
            .width(100.percent)
    }

    @Builder
    func buildToggleRow(label: String, isOn: Bool, onChange: (Bool) -> Unit) {
        Row() {
            Text(label)
                .fontSize(17)
                .fontColor(0xFF000000)
                .layoutWeight(1)
            Toggle(ToggleType.Switch, isOn: isOn)
                .selectedColor(0xFF317AFF)
                .onChange({ val: Bool =>
                    onChange(val)
                })
        }
        .width(100.percent)
        .height(48)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(0xFFFFFFFF)
    }

    /**
     * buildSwipeDeleteButton — swipe end 操作按钮（删除/卸载）
     * 必须传入已捕获的 immutable 局部值（不能捕获 pack 直接，pack 来自 @State 数组）
     */
    @Builder
    func buildSwipeDeleteButton(packId: Int64, accessHash: Int64) {
        Button(trSource("Remove"))
            .fontSize(14)
            .fontColor(0xFFFFFFFF)
            .backgroundColor(0xFFFF3B30)
            .borderRadius(0)
            .width(80)
            .height(100.percent)
            .onClick({ _ =>
                this.uninstallPack(packId, accessHash)
            })
    }

    /**
     * buildSwipeArchiveButton — swipe start 操作按钮（归档/停用）
     */
    @Builder
    func buildSwipeArchiveButton(packId: Int64, accessHash: Int64, isArchived: Bool) {
        Button(if (isArchived) { "Enable" } else { "Archive" })
            .fontSize(14)
            .fontColor(0xFFFFFFFF)
            .backgroundColor(if (isArchived) { 0xFF34C759 } else { 0xFFFF9500 })
            .borderRadius(0)
            .width(80)
            .height(100.percent)
            .onClick({ _ =>
                this.togglePackArchive(packId, accessHash, !isArchived)
            })
    }

    /**
     * buildInstalledPackRow — 已安装贴纸包行（含 swipe delete/archive + tap-to-pick-and-place 重排）
     * P2-379 swipeAction: end=删除, start=归档/启用
     *
     * 拖动重排（P2-379 tap-to-pick-and-place）:
     *   HarmonyOS ListItem 不提供 onDragStart/onDrop API（同 MediaPickerScreen 注释）；
     *   改用"点击选取 + 点击目标移动"方案。
     *
     * 注: 真缩略图缺底座，用 "🎞" 占位
     */
    @Builder
    func buildInstalledPackRow(pack: StickerPackInfo, idx: Int64) {
        Row() {
            // 缩略图占位
            Stack(alignContent: Alignment.Center) {
                Text("🎞")
                    .fontSize(22)
            }
            .width(44)
            .height(44)
            .borderRadius(8)
            .backgroundColor(0xFFF2F2F7)
            .margin(right: 12)

            Column() {
                Text(pack.title)
                    .fontSize(17)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text("${pack.count} stickers · ${this.packTypeLabel(pack)}")
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // 重排手柄（tap-to-pick-and-place — HarmonyOS ListItem 无 onDragStart）
            Stack(alignContent: Alignment.Center) {
                Text("⠿")
                    .fontSize(20)
                    .fontColor(if (this.dragFromIdx == idx) { 0xFF007AFF } else { 0xFFCCCCCC })
            }
            .width(32)
            .height(44)
            .onClick({ _ =>
                if (this.dragFromIdx < 0) {
                    // 第一次点手柄：选取
                    launch { this.dragFromIdx = idx }
                } else if (this.dragFromIdx == idx) {
                    // 再次点同一行：取消
                    launch { this.dragFromIdx = -1 }
                } else {
                    // 点不同行：执行移动
                    let fromIdx = this.dragFromIdx
                    launch { this.dragFromIdx = -1 }
                    this.movePack(fromIdx, idx)
                }
            })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(if (this.dragFromIdx == idx) { 0xFFE8F3FF } else { 0xFFFFFFFF })
        .enabled(!this.isOperating)
        .onClick({ _ =>
            // S7-148: iOS InstalledStickerPacksController openStickerPack — tapping a pack row
            // presents StickerPackScreen (preview with "…" → Share). While a reorder pick is
            // active, a row tap places the picked pack instead (same as tapping its handle).
            if (this.dragFromIdx < 0) {
                this.openPackPreview(idx)
            } else if (this.dragFromIdx == idx) {
                this.dragFromIdx = -1
            } else {
                let fromIdx = this.dragFromIdx
                this.dragFromIdx = -1
                this.movePack(fromIdx, idx)
            }
        })
    }

    private func openPackPreview(idx: Int64): Unit {
        if (idx < 0 || idx >= this.installedPacks.size) { return }
        let pack = this.installedPacks[idx]
        let args = StickerPreviewPagePresentationArguments(pack.id, pack.accessHash, pack.shortName)
        routerPush("StickerPackPreviewPage", args.toRouteParam())
    }

    /**
     * buildFeaturedPackRow — 精选贴纸包行（P2-378）
     */
    @Builder
    func buildFeaturedPackRow(pack: StickerPackInfo) {
        Row() {
            Stack(alignContent: Alignment.Center) {
                Text("🎞")
                    .fontSize(22)
            }
            .width(44)
            .height(44)
            .borderRadius(8)
            .backgroundColor(0xFFF2F2F7)
            .margin(right: 12)

            Column() {
                Text(pack.title)
                    .fontSize(17)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text("${pack.count} stickers · ${this.packTypeLabel(pack)}")
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (pack.isInstalled) {
                Text("Installed")
                    .fontSize(13)
                    .fontColor(0xFF317AFF)
                    .margin(left: 8)
            } else {
                Button(trSource("Add"))
                    .fontSize(14)
                    .fontColor(0xFFFFFFFF)
                    .buttonStyle(ButtonStyleMode.Normal)
                    .backgroundColor(0xFF317AFF)
                    .borderRadius(8)
                    .height(32)
                    .padding(left: 12, right: 12)
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(0xFFFFFFFF)
    }

    // ==================== Tab 内容构建 ====================

    /**
     * buildStickersTab — Stickers 子 tab 内容（P2-379 已安装包行 + P2-380 设置+精选）
     */
    @Builder
    func buildStickersTab() {
        Scroll() {
            Column() {
                // ---- S7-114：iOS InstalledStickerPacksController 第一段 —— Trending Stickers /
                // Archived Stickers / Emoji / Masks 四行（StickerPacksSettings.FeaturedPacks /
                // ArchivedPacks / Emoji / Masks），再往下才是开关与 MY STICKERS 列表。----
                Column() {
                    Row() {
                        Text(trSource("Trending Stickers"))
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .layoutWeight(1)
                        if (this.featuredUnreadCount > 0) {
                            Text("${this.featuredUnreadCount}")
                                .fontSize(13)
                                .fontColor(0xFFFFFFFF)
                                .padding(left: 7, right: 7, top: 2, bottom: 2)
                                .backgroundColor(0xFF007AFF)
                                .borderRadius(10)
                                .margin(right: 6)
                        }
                        Text(" ›")
                            .fontSize(17)
                            .fontColor(0xFFC7C7CC)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        Hilog.info(0, "CjTelegram", "[StickersSettingsPage] open FeaturedStickersScreen")
                        routerPush("FeaturedStickersScreen", "")
                    })
                    Divider().height(0.5).color(0xFFE5E5EA).margin(left: 16)
                    Row() {
                        Text(trSource("Archived Stickers"))
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .layoutWeight(1)
                        if (this.isLoadingArchived) {
                            Text("...")
                                .fontSize(17)
                                .fontColor(0xFF8E8E93)
                        } else {
                            Text(this.archivedCount.toString())
                                .fontSize(17)
                                .fontColor(0xFF8E8E93)
                        }
                        Text(" ›")
                            .fontSize(17)
                            .fontColor(0xFFC7C7CC)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ =>
                        Hilog.info(0, "CjTelegram", "[StickersSettingsPage] Navigate archived packs")
                        routerPush("ArchivedStickerPacksPage", "")
                    })
                    Divider().height(0.5).color(0xFFE5E5EA).margin(left: 16)
                    Row() {
                        Text(trSource("Emoji"))
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .layoutWeight(1)
                        Text(" ›")
                            .fontSize(17)
                            .fontColor(0xFFC7C7CC)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.onTabChanged(1) })
                    Divider().height(0.5).color(0xFFE5E5EA).margin(left: 16)
                    Row() {
                        Text(trSource("Masks"))
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .layoutWeight(1)
                        Text(" ›")
                            .fontSize(17)
                            .fontColor(0xFFC7C7CC)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.onTabChanged(2) })
                }
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(10)
                .margin(left: 16, right: 16, top: 16)

                // ---- S3-02: iOS Settings → Stickers and Emoji → Quick Reaction
                //      (Settings.QuickReactionSetup.Title; double-tap a message sends it) ----
                Column() {
                    Row() {
                        Text("Quick Reaction")
                            .fontSize(17)
                            .fontColor(0xFF000000)
                            .layoutWeight(1)
                        Text(this.quickReaction)
                            .fontSize(22)
                        Text(" ›")
                            .fontSize(17)
                            .fontColor(0xFFC7C7CC)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ _ => this.quickReactionExpanded = !this.quickReactionExpanded })
                    if (this.quickReactionExpanded) {
                        Divider().height(0.5).color(0xFFE5E5EA).margin(left: 16)
                        Row(space: 10) {
                            ForEach(this.quickReactionChoices, itemGenerator: { emoji: String, _idx: Int64 =>
                                Text(emoji)
                                    .fontSize(26)
                                    .padding(6)
                                    .borderRadius(8)
                                    .backgroundColor(if (emoji == this.quickReaction) { 0x33317AFF } else { Color.Transparent })
                                    .onClick({ _ =>
                                        this.quickReaction = emoji
                                        this.quickReactionExpanded = false
                                        getTelegramCoreSettingsService().saveQuickReaction(emoji)
                                        // MessageBubble 双击反应与 QuickReactionSetupPage 读的是 StickersService 本地设置，两处同步写
                                        getStickersService().persistLocalStringSetting("quick_reaction", emoji)
                                    })
                            }, keyGenerator: { emoji: String, _idx: Int64 => emoji })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                    }
                }
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(10)
                .margin(left: 16, right: 16, top: 12)
                Text("Choose your favorite emoji to react to messages with a double tap.")
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .width(100.percent)
                    .padding(left: 32, right: 32, top: 6, bottom: 4)

                // ---- 本地设置开关 ----
                this.buildSectionHeader("STICKER SETTINGS")
                Column() {
                    this.buildToggleRow(
                        "Suggest Stickers by Emoji",
                        this.suggestByEmoji,
                        { val: Bool =>
                            this.suggestByEmoji = val
                            this.persistSuggestByEmoji(val)
                        }
                    )
                    Divider().height(0.5).color(0xFFE5E5EA).margin(left: 16)
                    this.buildToggleRow(
                        "Loop Animated Stickers",
                        this.loopAnimatedStickers,
                        { val: Bool =>
                            this.loopAnimatedStickers = val
                            this.persistLoopAnimated(val)
                        }
                    )
                }
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(10)
                .margin(left: 16, right: 16)

                // ---- 已安装贴纸包列表（P2-379：拖动重排 + swipe 删除/启停）----
                // S7-114：分区名对位 iOS StickerPacksSettings.MyStickers = "MY STICKERS"
                this.buildSectionHeader(trSource("MY STICKERS"))
                if (this.isLoadingInstalled) {
                    Column() {
                        Text("Loading sticker packs...")
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 16, bottom: 16)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                } else if (this.installedPacks.size == 0) {
                    Column() {
                        Text("No sticker packs installed")
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 16, bottom: 16)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                } else {
                    // List with swipeAction（swipe 删除/启停）
                    // 注: swipeAction closure 内不能调用 @Builder 方法（macro 展开 ObservedProperty 类型不匹配）
                    //     直接内联 UI，从 pack 捕获 plain value（非 @State）
                    List {
                        ForEach(
                            this.installedPacks,
                            itemGeneratorFunc: { pack: StickerPackInfo, idx: Int64 =>
                                ListItem {
                                    this.buildInstalledPackRow(pack, idx)
                                }
                                .swipeAction(
                                    start: { =>
                                        // 归档/启用按钮（swipe start/右滑）
                                        Button(if (pack.isArchived) { "Enable" } else { "Archive" })
                                            .fontSize(14)
                                            .fontColor(0xFFFFFFFF)
                                            .backgroundColor(if (pack.isArchived) { 0xFF34C759 } else { 0xFFFF9500 })
                                            .borderRadius(0)
                                            .width(80)
                                            .height(100.percent)
                                            .onClick({ _ =>
                                                this.togglePackArchive(pack.id, pack.accessHash, !pack.isArchived)
                                            })
                                    },
                                    end: { =>
                                        // 删除/卸载按钮（swipe end/左滑）
                                        Button(trSource("Remove"))
                                            .fontSize(14)
                                            .fontColor(0xFFFFFFFF)
                                            .backgroundColor(0xFFFF3B30)
                                            .borderRadius(0)
                                            .width(80)
                                            .height(100.percent)
                                            .onClick({ _ =>
                                                this.uninstallPack(pack.id, pack.accessHash)
                                            })
                                    }
                                )
                            }
                        )
                    }
                    .width(100.percent)
                    .divider(ListDividerOptions(strokeWidth: 0.5, color: 0xFFE5E5EA, startMargin: 72, endMargin: 0))
                    .scrollBar(BarState.Off)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                }

                // ---- 精选贴纸包（P2-378）----
                this.buildSectionHeader("FEATURED STICKER PACKS")
                if (this.isLoadingFeatured) {
                    Column() {
                        Text("Loading featured packs...")
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 16, bottom: 16)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                } else if (this.featuredPacks.size == 0) {
                    Column() {
                        Text("No featured packs available")
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 16, bottom: 16)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                } else {
                    Column() {
                        ForEach(this.featuredPacks, itemGenerator: { pack: StickerPackInfo, idx: Int64 =>
                            this.buildFeaturedPackRow(pack)
                            if (idx < Int64(this.featuredPacks.size) - 1) {
                                Divider()
                                    .height(0.5)
                                    .color(0xFFE5E5EA)
                                    .margin(left: 72)
                            }
                        })
                    }
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                }

                Column() {}.height(32)
            }
            .width(100.percent)
        }
        .layoutWeight(1)
        .backgroundColor(0xFFF2F2F7)
    }

    /**
     * buildEmojiTab — Emoji 子 tab 内容（P2-380，filter isEmoji=true）
     */
    @Builder
    func buildEmojiTab() {
        Scroll() {
            Column() {
                // ---- 本地设置 ----
                this.buildSectionHeader("EMOJI SETTINGS")
                Column() {
                    this.buildToggleRow(
                        "Suggest Animated Emoji",
                        this.suggestAnimatedEmoji,
                        { val: Bool =>
                            this.suggestAnimatedEmoji = val
                            this.persistSuggestAnimEmoji(val)
                        }
                    )
                }
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(10)
                .margin(left: 16, right: 16)

                // ---- Emoji 贴纸包列表（来自 getAllStickers 中 isEmoji=true 的包）----
                this.buildSectionHeader("MY EMOJI PACKS")
                if (this.isLoadingEmoji) {
                    Column() {
                        Text("Loading emoji packs...")
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 16, bottom: 16)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                } else if (this.emojiPacks.size == 0) {
                    Column() {
                        Text("No emoji packs installed")
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                            .margin(top: 16, bottom: 16)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                } else {
                    Column() {
                        ForEach(this.emojiPacks, itemGenerator: { pack: StickerPackInfo, idx: Int64 =>
                            Row() {
                                Stack(alignContent: Alignment.Center) {
                                    Text("😀")
                                        .fontSize(22)
                                }
                                .width(44)
                                .height(44)
                                .borderRadius(8)
                                .backgroundColor(0xFFF2F2F7)
                                .margin(right: 12)
                                Column() {
                                    Text(pack.title)
                                        .fontSize(17)
                                        .fontColor(0xFF000000)
                                        .maxLines(1)
                                    Text("${pack.count} emoji · Animated")
                                        .fontSize(13)
                                        .fontColor(0xFF8E8E93)
                                        .margin(top: 2)
                                }
                                .alignItems(HorizontalAlign.Start)
                                .layoutWeight(1)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 10, bottom: 10)
                            .alignItems(VerticalAlign.Center)
                            .backgroundColor(0xFFFFFFFF)
                            if (idx < Int64(this.emojiPacks.size) - 1) {
                                Divider()
                                    .height(0.5)
                                    .color(0xFFE5E5EA)
                                    .margin(left: 72)
                            }
                        })
                    }
                    .backgroundColor(0xFFFFFFFF)
                    .borderRadius(10)
                    .margin(left: 16, right: 16)
                }

                Column() {}.height(32)
            }
            .width(100.percent)
        }
        .layoutWeight(1)
        .backgroundColor(0xFFF2F2F7)
    }

    /**
     * buildMasksTab — Masks 子 tab 内容（P2-380，getArchivedStickers masks=true）
     */
    @Builder
    func buildMasksTab() {
        Column() {
            if (this.isLoadingMasks) {
                Column() {
                    Text("Loading masks...")
                        .fontSize(15)
                        .fontColor(0xFF8E8E93)
                }
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .width(100.percent)
            } else if (this.masksPacks.size == 0) {
                Column() {
                    Text("No mask packs available")
                        .fontSize(15)
                        .fontColor(0xFF8E8E93)
                        .textAlign(TextAlign.Center)
                }
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .width(100.percent)
            } else {
                Scroll() {
                    Column() {
                        this.buildSectionHeader("MASK PACKS")
                        Column() {
                            ForEach(this.masksPacks, itemGenerator: { pack: StickerPackInfo, idx: Int64 =>
                                Row() {
                                    Stack(alignContent: Alignment.Center) {
                                        Text("🎭")
                                            .fontSize(22)
                                    }
                                    .width(44)
                                    .height(44)
                                    .borderRadius(8)
                                    .backgroundColor(0xFFF2F2F7)
                                    .margin(right: 12)
                                    Column() {
                                        Text(pack.title)
                                            .fontSize(17)
                                            .fontColor(0xFF000000)
                                            .maxLines(1)
                                        Text("${pack.count} masks")
                                            .fontSize(13)
                                            .fontColor(0xFF8E8E93)
                                            .margin(top: 2)
                                    }
                                    .alignItems(HorizontalAlign.Start)
                                    .layoutWeight(1)
                                }
                                .width(100.percent)
                                .padding(left: 16, right: 16, top: 10, bottom: 10)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(0xFFFFFFFF)
                                if (idx < Int64(this.masksPacks.size) - 1) {
                                    Divider()
                                        .height(0.5)
                                        .color(0xFFE5E5EA)
                                        .margin(left: 72)
                                }
                            })
                        }
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(10)
                        .margin(left: 16, right: 16)

                        Column() {}.height(32)
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
    }

    private func openStickerPack(pack: StickerPackInfo): Unit {
        let param = pack.id.toString() + "|" + pack.accessHash.toString() + "|" + pack.shortName
        setPending("StickerPackPreviewPage", param)
        routerPush("StickerPackPreviewPage")
    }

    @Builder
    func suggestionMenuContent() {
        Column {
            this.buildSuggestionMenuRow("All Sets", 0)
            ItemListSeparator(leftInset: 16)
            this.buildSuggestionMenuRow("Added Sets", 1)
            ItemListSeparator(leftInset: 16)
            this.buildSuggestionMenuRow("None", 2)
        }
        .width(210)
        .backgroundColor(this.presentation.cardColor)
        .borderRadius(14)
        .clip(true)
        .shadow(radius: 18.0, color: 0x28000000, offsetX: 0.0, offsetY: 6.0)
    }

    @Builder
    func buildSuggestionMenuRow(title: String, mode: Int32) {
        Row {
            Text(title).fontSize(16).fontColor(this.presentation.textColor).layoutWeight(1)
            if (this.suggestionMode == mode) {
                Text("✓").fontSize(18).fontColor(this.presentation.accentColor)
            }
        }
        .height(48).width(100.percent).padding(left: 16, right: 16)
        .onClick({ _ => this.setSuggestionMode(mode) })
    }

    @Builder
    func buildSuggestionRow() {
        Row {
            Text("Suggest by Emoji")
                .fontSize(17).fontColor(this.presentation.textColor).layoutWeight(1)
            Text(this.suggestionModeTitle())
                .fontSize(17).fontColor(this.presentation.secondaryTextColor).margin(right: 6)
            Image(@r(app.media.item_list_context_disclosure_arrow))
                .width(12).height(16).fillColor(this.presentation.disclosureArrowColor)
        }
        .height(52).width(100.percent).padding(left: 16, right: 16)
        .onClick({ _ => this.showSuggestionMenu = true })
        .bindPopup(
            this.showSuggestionMenu,
            CustomPopupOptions(
                builder: bind(this.suggestionMenuContent, this),
                placement: Placement.Bottom,
                popupColor: Color.Transparent,
                enableArrow: false,
                autoCancel: true,
                radius: 14.vp,
                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                    if (!evt.isVisible) { this.showSuggestionMenu = false }
                })
            )
        )
    }

    @Builder
    func buildSourcePackRow(pack: StickerPackInfo, index: Int64) {
        Row {
            Row {
                if (this.editing) {
                    Stack(alignContent: Alignment.Center) {
                        if (this.isPackSelected(pack.id)) {
                            Column { Text("✓").fontSize(16).fontColor(0xFFFFFFFF) }
                                .width(28).height(28).borderRadius(14)
                                .backgroundColor(this.presentation.accentColor)
                                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        } else {
                            Column {}.width(28).height(28).borderRadius(14)
                                .border(width: 1.5, color: this.presentation.secondaryTextColor)
                        }
                    }.width(36).height(44).margin(right: 4)
                }
                if (index < Int64(this.installedPackCovers.size) && this.installedPackCovers[index].documentId != 0) {
                    StickerGridCell(item: this.installedPackCovers[index], size: 44.0)
                } else {
                    Column {
                        Text(if (pack.title.isEmpty()) { "S" } else { pack.title.toRuneArray()[0].toString() })
                            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.presentation.accentColor)
                    }
                    .width(44).height(44).borderRadius(10).backgroundColor(this.presentation.backgroundColor)
                    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                }
                Column {
                    Text(pack.title).fontSize(17).fontWeight(FontWeight.Medium)
                        .fontColor(this.presentation.textColor).maxLines(1)
                    Text("${pack.count} stickers").fontSize(15)
                        .fontColor(this.presentation.secondaryTextColor).margin(top: 1)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start).margin(left: 12)
            }
            .layoutWeight(1).height(60).alignItems(VerticalAlign.Center)
            .onClick({ _ =>
                if (this.editing) { this.togglePackSelected(pack.id) }
                else { this.openStickerPack(pack) }
            })
            if (this.editing) {
                Stack(alignContent: Alignment.Center) {
                    Text("☰").fontSize(20).fontColor(this.presentation.secondaryTextColor)
                }
                .width(44).height(60)
                .backgroundColor(if (this.dragFromIdx == index) { 0x12007AFF } else { Color.Transparent })
                .onTouch({ event: TouchEvent => this.handlePackReorderTouch(event, index) })
            }
        }
        .width(100.percent).height(60).padding(left: 12, right: 16)
        .alignItems(VerticalAlign.Center)
        if (index + 1 < Int64(this.installedPacks.size)) { ItemListSeparator(leftInset: 72) }
    }

    @Builder
    func editToolbar() {
        Row {
            Button("Delete")
                .fontSize(16).fontColor(if (this.selectedPackIds.isEmpty()) { this.presentation.secondaryTextColor } else { ITEM_LIST_DESTRUCTIVE })
                .height(44).backgroundColor(this.presentation.cardColor).borderRadius(22)
                .enabled(!this.selectedPackIds.isEmpty()).onClick({ _ => this.confirmSelectedOperation(false) })
            Blank().layoutWeight(1)
            Button("Archive")
                .fontSize(16).fontColor(if (this.selectedPackIds.isEmpty()) { this.presentation.secondaryTextColor } else { this.presentation.accentColor })
                .height(44).backgroundColor(this.presentation.cardColor).borderRadius(22)
                .enabled(!this.selectedPackIds.isEmpty()).onClick({ _ => this.confirmSelectedOperation(true) })
            Blank().layoutWeight(1)
            Button("Share")
                .fontSize(16).fontColor(if (this.selectedPackIds.isEmpty()) { this.presentation.secondaryTextColor } else { this.presentation.accentColor })
                .height(44).backgroundColor(this.presentation.cardColor).borderRadius(22)
                .enabled(!this.selectedPackIds.isEmpty()).onClick({ _ => this.shareSelected() })
        }
        .width(100.percent).height(72).padding(left: 20, right: 20)
        .backgroundColor(this.presentation.navBarColor)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func categoryRows() {
        if (!this.isLoadingFeatured && this.featuredPacks.size > 0) {
            ItemListDisclosureRow(
                title: "Trending Stickers", value: "",
                icon: @r(app.media.settings_sticker_trending),
                badgeText: this.featuredPacks.size.toString(),
                badgeColor: this.presentation.accentColor,
                onClick: { => routerPush("FeaturedStickersScreen", "") }
            )
            ItemListSeparator(leftInset: 61)
        }
        if (!this.isLoadingArchived && this.archivedCount > 0) {
            ItemListDisclosureRow(
                title: "Archived Stickers", value: this.archivedCount.toString(),
                icon: @r(app.media.settings_sticker_archived),
                onClick: { => routerPush("ArchivedStickerPacksPage", "stickers") }
            )
            ItemListSeparator(leftInset: 61)
        }
        if (!this.isLoadingEmoji && this.emojiPacks.size > 0) {
            ItemListDisclosureRow(
                title: "Emoji", value: this.emojiPacks.size.toString(),
                icon: @r(app.media.settings_sticker_emoji),
                onClick: { => routerPush("EmojiStickerPacksPage", "") }
            )
            ItemListSeparator(leftInset: 61)
        }
        ItemListDisclosureRow(
            title: "Quick Reaction", value: this.quickReactionLabel(),
            icon: @r(app.media.settings_sticker_reaction),
            onClick: { => routerPush("QuickReactionSetupPage", "") }
        )
    }

    @Builder
    func sourceContent() {
        Scroll {
            Column {
                Column { this.categoryRows() }
                    .backgroundColor(this.presentation.cardColor).borderRadius(10).clip(true)
                    .margin(left: 16, right: 16, top: 18)

                Column { this.stickerOptionsRows() }
                    .backgroundColor(this.presentation.cardColor).borderRadius(10).clip(true)
                    .margin(left: 16, right: 16, top: 20)
                ItemListSectionFooter(
                    text: "Recently used sticker sets will be displayed above the older ones.",
                    topPad: 7
                )

                ItemListSectionHeader(title: "MY STICKERS")
                if (this.isLoadingInstalled) {
                    Column { LoadingProgress().width(28).height(28).color(this.presentation.accentColor) }
                        .height(72).width(100.percent).justifyContent(FlexAlign.Center)
                } else if (!this.installedPacks.isEmpty()) {
                    Column {
                        ForEach(this.installedPacks, itemGenerator: { pack: StickerPackInfo, index: Int64 =>
                            this.buildSourcePackRow(pack, index)
                        })
                    }
                    .backgroundColor(this.presentation.cardColor).borderRadius(10).clip(true)
                    .margin(left: 16, right: 16)
                }
                ItemListSectionFooter(
                    text: "Artists are welcome to add their own sticker sets using our @stickers bot.\n\nTap on a sticker to view and add the whole set.",
                    topPad: 8
                )
                Column {}.height(if (this.editing) { 86 } else { 24 })
            }.width(100.percent)
        }.width(100.percent).height(100.percent).scrollBar(BarState.Off)
    }

    public func build() {
        Column {
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back)).width(8).height(14)
                        .fillColor(this.presentation.accentColor).margin(right: 4)
                    Text("Back").fontSize(16).fontColor(this.presentation.accentColor)
                }.width(78).onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text("Stickers and Emoji").fontSize(18).fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Text(if (this.editing) { "Done" } else { "Edit" })
                    .fontSize(16).fontWeight(if (this.editing) { FontWeight.Bold } else { FontWeight.Normal })
                    .fontColor(this.presentation.accentColor).width(78).textAlign(TextAlign.End)
                    .onClick({ _ =>
                        if (this.editing) { this.finishEditing() }
                        else { this.editing = true }
                    })
            }
            .height(56.0 + getSafeAreaTop()).width(100.percent)
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            Stack(alignContent: Alignment.Bottom) {
                this.sourceContent()
                if (this.editing) { this.editToolbar() }
            }.layoutWeight(1).width(100.percent)
        }
        .width(100.percent).height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .onAppear({ =>
            this.ensureLoaded()
            this.loadLocalSettings()
        })
    }

    @Builder
    func stickerOptionsRows() {
        this.buildSuggestionRow()
        ItemListSeparator(leftInset: 16)
        ItemListToggleRow(
            title: "Large Emoji", isOn: this.largeEmoji,
            onChange: { value => this.persistLargeEmoji(value) }
        )
        ItemListSeparator(leftInset: 16)
        ItemListToggleRow(
            title: "Dynamic Pack Order", isOn: this.dynamicPackOrder,
            onChange: { value => this.persistDynamicPackOrder(value) }
        )
    }
}
