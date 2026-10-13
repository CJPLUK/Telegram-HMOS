package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.AbilityKit.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import ohos.i18n.System as I18nSystem
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import std.collection.ArrayList
import std.time.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.components.*

private let AVATAR_EMOJI_SEARCH_INPUT_ID: String = "avatarEmojiSearchInput"

public class AvatarEmojiSection {
    public var id: Int64 = 0
    public var title: String = ""
    public var items: Array<StickerItem> = Array<StickerItem>(0, repeat: StickerItem())
    public var collapsedLineCount: Int64 = 0

    public init() {}
}

public class AvatarEmojiSectionSource <: IDataSource<AvatarEmojiSection> {
    private var sections: Array<AvatarEmojiSection> =
        Array<AvatarEmojiSection>(0, repeat: AvatarEmojiSection())
    private var listeners: ArrayList<DataChangeListener> = ArrayList<DataChangeListener>()

    public func totalCount(): Int64 { return Int64(this.sections.size) }
    public func getData(index: Int64): AvatarEmojiSection {
        if (index < 0 || index >= Int64(this.sections.size)) { return AvatarEmojiSection() }
        return this.sections[index]
    }
    public func registerDataChangeListener(listener: DataChangeListener): Unit {
        for (existing in this.listeners) { if (refEq(existing, listener)) { return } }
        this.listeners.add(listener)
    }
    public func unregisterDataChangeListener(listener: DataChangeListener): Unit {
        let kept = ArrayList<DataChangeListener>()
        for (existing in this.listeners) { if (!refEq(existing, listener)) { kept.add(existing) } }
        this.listeners = kept
    }
    public func setSections(values: Array<AvatarEmojiSection>): Unit {
        this.sections = values
        for (listener in this.listeners) { listener.onDataReloaded() }
    }
}

/**
 * P2-304: Premium Emoji Status Picker Page（混合工程迁移版）
 *
 * iOS 对照: EmojiStatusSelectionController (PremiumUI/EmojiStatusController.swift)
 *
 * 功能:
 *   1. 展示精选 emoji 作为 Premium 状态入口（Unicode emoji + custom-emoji 占位）
 *   2. 点击 emoji 调用 SettingsService.updateEmojiStatus(documentId, until)
 *      - 真实 TL: account.updateEmojiStatus#fbd3de6b (ctor verified)
 *      - documentId=0 → emojiStatusEmpty#2de11aae（清除状态）
 *      - documentId!=0 → emojiStatus#e7ff068a（设置状态，本页用 Telegram sticker id）
 *   3. 状态本地镜像写入 AuthStorage（key: profile_emoji_status_doc_id / _until）
 *   4. "Clear" 入口显示（清除现有状态）
 *
 * 导航: EditProfilePage / SettingsPage → routerPush("EmojiStatusPickerPage")
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - aboutToAppear 有实逻辑（读 storage）→ ensureLoaded() + .onAppear
 */
@HybridComponentEntry
@Component
public class EmojiStatusPickerPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var isLoading: Bool = false
    @State var successMessage: String = ""
    @State var errorMessage: String = ""
    @State var currentStatusDocId: Int64 = 0
    @State var selectedEmoji: String = ""
    @State var avatarEmojiItem: StickerItem = StickerItem()
    @State var avatarEmojiDocumentId: Int64 = 0
    @State var avatarEmojiItems: Array<StickerItem> = Array<StickerItem>(0, repeat: StickerItem())
    @State var avatarEmojiSections: Array<AvatarEmojiSection> =
        Array<AvatarEmojiSection>(0, repeat: AvatarEmojiSection())
    @State var avatarEmojiNavigationItems: Array<StickerItem> =
        Array<StickerItem>(0, repeat: StickerItem())
    @State var expandedAvatarEmojiSectionId: Int64 = 0
    @State var avatarSearchCategories: Array<EmojiGroupInfo> =
        Array<EmojiGroupInfo>(0, repeat: EmojiGroupInfo())
    @State var avatarSearchText: String = ""
    @State var avatarSearchInputActive: Bool = false
    @State var avatarSearchInFlight: Bool = false
    @State var avatarSearchShowsBack: Bool = false
    @State var selectedAvatarSearchCategoryId: Int64 = 0
    @State var avatarSearchItems: Array<StickerItem> =
        Array<StickerItem>(0, repeat: StickerItem())
    @State var avatarEmojiKeywords: Array<EmojiKeywordEntry> =
        Array<EmojiKeywordEntry>(0, repeat: EmojiKeywordEntry())
    @State var avatarBackgroundIndex: Int64 = 0
    @State var isAvatarMode: Bool = false
    @State var isSavingAvatar: Bool = false
    @State var emojiItems: Array<EmojiStatusItem> = Array<EmojiStatusItem>(0, { _i: Int64 => EmojiStatusItem(emoji: "", docId: 0, label: "") })
    @State var loaded: Bool = false
    private var avatarSnapshotToken: String = ""
    private var avatarEmojiSnapshotListenerId: Int64 = -1
    private var avatarFeaturedDetailPrefetchStarted: Bool = false
    private let avatarSectionSource: AvatarEmojiSectionSource = AvatarEmojiSectionSource()
    private var avatarSearchGeneration: Int64 = 0

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let routeParam = takePending("EmojiStatusPickerPage")
        if (routeParam == "avatar") {
            this.isAvatarMode = true
            this.loadAvatarEmojiItems()
            this.startAvatarEmojiSnapshot()
            this.loadAvatarSearchMetadata()
        }
        let storage = getAuthStorage()
        let docId = storage.getProfileEmojiStatusDocId()
        let items = this.buildEmojiStatusItems()
        launch {
            this.currentStatusDocId = docId
            this.emojiItems = items
        }
    }

    private func startAvatarEmojiSnapshot(): Unit {
        let store = getEntityKeyboardStore()
        store.actualizeEmojiKeyboard()
        this.avatarEmojiSnapshotListenerId = store.subscribeEmojiSnapshot(
            { snapshot: EmojiKeyboardSnapshot =>
                launch { this.applyAvatarEmojiSnapshot(snapshot) }
            })
    }

    private func applyAvatarEmojiSnapshot(snapshot: EmojiKeyboardSnapshot): Unit {
        if (!this.isAvatarMode || this.avatarEmojiSections.isEmpty()) { return }
        this.prefetchAvatarFeaturedDetails(snapshot)
        let sections = ArrayList<AvatarEmojiSection>()
        sections.add(this.avatarEmojiSections[0])
        let navigationItems = ArrayList<StickerItem>()
        let seedItems = ArrayList<StickerItem>()

        // iOS EmojiPagerContentSignals keeps CloudEmojiPacks in their server order,
        // followed by featured packs which are not installed yet.
        for (pack in snapshot.installedPacks) {
            let sectionItems = ArrayList<StickerItem>()
            for (detail in snapshot.installedDetails) {
                if (detail.info.id == pack.id && detail.success) {
                    for (item in detail.stickers) {
                        if (item.isCustomEmoji) {
                            sectionItems.add(item)
                            seedItems.add(item)
                        }
                    }
                    break
                }
            }
            if (sectionItems.isEmpty()) { continue }
            let section = AvatarEmojiSection()
            section.id = pack.id
            section.title = pack.title
            section.items = sectionItems.toArray()
            sections.add(section)
            let cover = if (pack.cover.documentId != 0) { pack.cover } else { sectionItems[0] }
            navigationItems.add(cover)
            seedItems.add(cover)
        }

        for (pack in snapshot.featuredPacks) {
            var installed = false
            for (installedPack in snapshot.installedPacks) {
                if (installedPack.id == pack.id) { installed = true; break }
            }
            if (installed) { continue }
            let sectionItems = ArrayList<StickerItem>()
            for (detail in snapshot.installedDetails) {
                if (detail.info.id == pack.id && detail.success) {
                    for (item in detail.stickers) {
                        if (item.isCustomEmoji) { sectionItems.add(item) }
                    }
                    break
                }
            }
            if (sectionItems.isEmpty()) {
                for (item in pack.topItems) {
                    if (item.isCustomEmoji) { sectionItems.add(item) }
                }
            }
            if (sectionItems.isEmpty()) { continue }
            let section = AvatarEmojiSection()
            section.id = pack.id
            section.title = pack.title
            section.collapsedLineCount = 3
            section.items = sectionItems.toArray()
            sections.add(section)
            let cover = if (pack.cover.documentId != 0) { pack.cover } else { sectionItems[0] }
            navigationItems.add(cover)
            seedItems.add(cover)
            for (item in sectionItems) { seedItems.add(item) }
        }
        seedCustomEmojiDocuments(seedItems)
        let nextSections = sections.toArray()
        this.avatarEmojiSections = nextSections
        this.avatarEmojiNavigationItems = navigationItems.toArray()
        if (this.avatarSearchText.isEmpty() && this.selectedAvatarSearchCategoryId == 0) {
            this.avatarSectionSource.setSections(nextSections)
        }
    }

    private func prefetchAvatarFeaturedDetails(snapshot: EmojiKeyboardSnapshot): Unit {
        if (this.avatarFeaturedDetailPrefetchStarted || snapshot.featuredPacks.isEmpty()) { return }
        this.avatarFeaturedDetailPrefetchStarted = true
        let packs = snapshot.featuredPacks
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let _ = spawn {
            let allDetails = loadFeaturedEmojiDetailsCache()
            if (!allDetails.isEmpty()) { store.publishEmojiPackDetails(token, allDetails) }
            var batch = ArrayList<StickerPackDetail>()
            for (pack in packs) {
                var found = false
                for (detail in allDetails) {
                    if (detail.info.id == pack.id) { found = true; break }
                }
                if (found || Int64(pack.topItems.size) >= 24) { continue }
                let detail = getStickersService().getStickerSet(pack.id, pack.accessHash)
                if (!detail.success || detail.stickers.isEmpty()) { continue }
                allDetails.add(detail)
                batch.add(detail)
                if (batch.size >= 8) {
                    store.publishEmojiPackDetails(token, batch)
                    batch = ArrayList<StickerPackDetail>()
                }
            }
            if (!batch.isEmpty()) { store.publishEmojiPackDetails(token, batch) }
            saveFeaturedEmojiDetailsCache(allDetails)
        }
    }

    private func loadAvatarSearchMetadata(): Unit {
        let _ = spawn {
            let service = getStickersService()
            let groups = service.getEmojiProfilePhotoGroups()
            if (groups.success) {
                let iconIds = ArrayList<Int64>()
                for (group in groups.groups) { iconIds.add(group.iconEmojiId) }
                prefetchCustomEmojiDocuments(iconIds)
            }
            let language = avatarEmojiSearchLanguage()
            let keywords = ArrayList<EmojiKeywordEntry>()
            let cached = service.getCachedEmojiKeywords(language)
            if (cached.success) { for (entry in cached.keywords) { keywords.add(entry) } }
            if (!language.startsWith("en")) {
                let englishCached = service.getCachedEmojiKeywords("en")
                if (englishCached.success) {
                    for (entry in englishCached.keywords) { keywords.add(entry) }
                }
            }
            launch {
                if (groups.success) { this.avatarSearchCategories = groups.groups.toArray() }
                if (!keywords.isEmpty()) { this.avatarEmojiKeywords = keywords.toArray() }
            }
            let synchronizedKeywords = service.synchronizeEmojiKeywords(language)
            let actual = ArrayList<EmojiKeywordEntry>()
            if (synchronizedKeywords.success) {
                for (entry in synchronizedKeywords.keywords) { actual.add(entry) }
            }
            if (!language.startsWith("en")) {
                let english = service.synchronizeEmojiKeywords("en")
                if (english.success) { for (entry in english.keywords) { actual.add(entry) } }
            }
            if (!actual.isEmpty()) {
                launch { this.avatarEmojiKeywords = actual.toArray() }
            }
        }
    }

    private func avatarSearchQuery(value: String): String {
        let normalized = value.toAsciiLower()
        var result = ""
        for (entry in this.avatarEmojiKeywords) {
            if (entry.isDeleted || !entry.keyword.toAsciiLower().contains(normalized)) { continue }
            for (emoji in entry.emoticons) {
                if (result.size < 128 && !result.contains(emoji)) { result = result + emoji }
            }
        }
        if (result.isEmpty() && value.size <= 16) { result = value }
        return result
    }

    private func beginAvatarTextSearch(value: String): Unit {
        this.avatarSearchText = value
        // Selecting a server category clears the text field. ArkUI reports that
        // state-driven clear through onChange as well; it must not cancel the
        // category that initiated it.
        if (value.isEmpty() && this.selectedAvatarSearchCategoryId != 0) { return }
        this.selectedAvatarSearchCategoryId = 0
        this.avatarSearchGeneration = this.avatarSearchGeneration + 1
        let generation = this.avatarSearchGeneration
        if (value.isEmpty()) {
            this.avatarSearchInFlight = false
            this.avatarSearchShowsBack = false
            this.avatarSearchItems = Array<StickerItem>(0, repeat: StickerItem())
            this.avatarSectionSource.setSections(this.avatarEmojiSections)
            return
        }
        let query = this.avatarSearchQuery(value)
        this.avatarSearchInFlight = true
        this.avatarSearchShowsBack = false
        let _ = spawn {
            sleep(Duration.millisecond * 150)
            if (this.avatarSearchGeneration != generation) { return }
            let service = getStickersService()
            let custom = service.searchCustomEmoji(query)
            let stickers = service.getStickers(query)
            launch {
                if (this.avatarSearchGeneration != generation) { return }
                this.avatarSearchInFlight = false
                this.avatarSearchShowsBack = true
                this.applyAvatarSearchResults(custom.documents, stickers.stickers)
            }
        }
    }

    private func applyAvatarSearchResults(
        emojiItems: ArrayList<StickerItem>, stickerItems: ArrayList<StickerItem>
    ): Unit {
        let sections = ArrayList<AvatarEmojiSection>()
        let allSeedItems = ArrayList<StickerItem>()
        if (!emojiItems.isEmpty()) {
            let section = AvatarEmojiSection()
            section.id = -1001
            section.title= "Emoji"
            section.items = emojiItems.toArray()
            sections.add(section)
            for (item in emojiItems) { allSeedItems.add(item) }
        }
        if (!stickerItems.isEmpty()) {
            let section = AvatarEmojiSection()
            section.id = -1002
            section.title= "Stickers"
            section.items = stickerItems.toArray()
            sections.add(section)
            for (item in stickerItems) { allSeedItems.add(item) }
        }
        seedCustomEmojiDocuments(allSeedItems)
        this.avatarSearchItems = allSeedItems.toArray()
        this.avatarSectionSource.setSections(sections.toArray())
    }

    private func selectAvatarSearchCategory(group: EmojiGroupInfo): Unit {
        this.avatarSearchText = ""
        this.avatarSearchInputActive = false
        this.selectedAvatarSearchCategoryId = group.iconEmojiId
        this.avatarSearchGeneration = this.avatarSearchGeneration + 1
        let generation = this.avatarSearchGeneration
        this.avatarSearchItems = Array<StickerItem>(0, repeat: StickerItem())
        this.avatarSectionSource.setSections(Array<AvatarEmojiSection>(0, repeat: AvatarEmojiSection()))
        var query = ""
        for (identifier in group.emoticons) { query = query + identifier }
        if (group.isPremium && query.isEmpty()) {
            for (section in this.avatarEmojiSections) {
                for (item in section.items) {
                    if (!item.isFreeEmoji && query.size < 128) { query = query + item.altEmoji }
                }
            }
        }
        this.avatarSearchInFlight = true
        this.avatarSearchShowsBack = false
        if (query.isEmpty()) {
            this.avatarSearchInFlight = false
            this.avatarSearchShowsBack = true
            return
        }
        let requestQuery = query
        let _ = spawn {
            let service = getStickersService()
            let custom = service.searchCustomEmoji(requestQuery)
            let stickers = service.getStickers(requestQuery)
            launch {
                if (this.avatarSearchGeneration != generation) { return }
                this.avatarSearchInFlight = false
                this.applyAvatarSearchResults(custom.documents, stickers.stickers)
            }
        }
    }

    private func closeAvatarSearch(): Unit {
        this.avatarSearchGeneration = this.avatarSearchGeneration + 1
        this.avatarSearchText = ""
        this.avatarSearchInputActive = false
        this.avatarSearchInFlight = false
        this.avatarSearchShowsBack = false
        this.selectedAvatarSearchCategoryId = 0
        this.avatarSearchItems = Array<StickerItem>(0, repeat: StickerItem())
        this.avatarSectionSource.setSections(this.avatarEmojiSections)
    }

    private func loadAvatarEmojiItems(): Unit {
        spawn {
            let stickers = getStickersService()
            let items = ArrayList<StickerItem>()
            let sections = ArrayList<AvatarEmojiSection>()
            let navigationItems = ArrayList<StickerItem>()
            let userId = getCurrentUserId()
            let currentInfo = getPeerInfoAvatarListService().getCurrentPhotoInfo(userId)
            var currentDocumentId: Int64 = 0
            match (currentInfo) {
                case Some(info) => currentDocumentId = info.emojiDocumentId
                case None => ()
            }
            let defaultItems = stickers.getDefaultProfilePhotoEmojis()
            if (defaultItems.success) {
                for (item in defaultItems.documents) {
                    if (items.size < 104) { items.add(item) }
                }
            }
            let defaultSection = AvatarEmojiSection()
            defaultSection.id = -1
            defaultSection.collapsedLineCount = 5
            defaultSection.items = Array<StickerItem>(items.size, { index: Int64 => items[index] })
            sections.add(defaultSection)

            // EntityKeyboard 的包明细按需实际化；头像编辑器打开时只同步读取同一份
            // 磁盘快照，不能串行请求全部包，否则默认头像组也会被网络阻塞。
            let installed = stickers.getCachedEmojiStickers()
            if (installed.success) {
                for (pack in installed.packs) {
                    let detail = stickers.getCachedStickerSet(pack.id)
                    if (!detail.success || detail.stickers.isEmpty()) { continue }
                    let sectionItems = ArrayList<StickerItem>()
                    for (item in detail.stickers) {
                        if (item.isCustomEmoji) {
                            sectionItems.add(item)
                            items.add(item)
                        }
                    }
                    if (sectionItems.isEmpty()) { continue }
                    let section = AvatarEmojiSection()
                    section.id = pack.id
                    section.title = pack.title
                    section.items = Array<StickerItem>(sectionItems.size,
                        { index: Int64 => sectionItems[index] })
                    sections.add(section)
                    let cover = if (pack.cover.documentId != 0) {
                        pack.cover
                    } else {
                        sectionItems[0]
                    }
                    navigationItems.add(cover)
                    if (cover.documentId != sectionItems[0].documentId) { items.add(cover) }
                }
            }
            if (currentDocumentId != 0) {
                var hasCurrentDocument = false
                for (item in items) {
                    if (item.documentId == currentDocumentId) {
                        hasCurrentDocument = true
                        break
                    }
                }
                if (!hasCurrentDocument) {
                    let ids = ArrayList<Int64>()
                    ids.add(currentDocumentId)
                    for (item in fetchCustomEmojiDocuments(ids)) { items.add(item) }
                }
            }
            seedCustomEmojiDocuments(items)
            Hilog.info(0, "CjTelegram", "[EmojiStatusPickerPage] avatar emoji documents=${items.size}")
            let loadedItems = Array<StickerItem>(items.size, { index: Int64 => items[index] })
            let selectedCurrentDocumentId = currentDocumentId
            launch {
                this.avatarEmojiItems = loadedItems
                let nextSections = Array<AvatarEmojiSection>(sections.size,
                    { index: Int64 => sections[index] })
                this.avatarSectionSource.setSections(nextSections)
                this.avatarEmojiSections = nextSections
                this.avatarEmojiNavigationItems = Array<StickerItem>(navigationItems.size,
                    { index: Int64 => navigationItems[index] })
                this.applyAvatarEmojiSnapshot(getEntityKeyboardStore().currentEmojiSnapshot())
                match (currentInfo) {
                    case Some(info) =>
                        if (info.emojiBackgroundColors.size >= 2) {
                            this.avatarBackgroundIndex = this.backgroundIndexFor(
                                info.emojiBackgroundColors[0], info.emojiBackgroundColors[1])
                        }
                    case None => ()
                }
                var matched = false
                if (selectedCurrentDocumentId != 0) {
                    for (item in loadedItems) {
                        if (!matched && item.documentId == selectedCurrentDocumentId) {
                            this.avatarEmojiItem = item
                            this.avatarEmojiDocumentId = item.documentId
                            matched = true
                        }
                    }
                    if (!matched) {
                        let currentItem = StickerItem()
                        currentItem.documentId = selectedCurrentDocumentId
                        currentItem.isCustomEmoji = true
                        this.avatarEmojiItem = currentItem
                        this.avatarEmojiDocumentId = selectedCurrentDocumentId
                        matched = true
                    }
                }
                if (!matched && this.avatarEmojiItem.documentId == 0 && !loadedItems.isEmpty()) {
                    this.avatarEmojiItem = loadedItems[0]
                    this.avatarEmojiDocumentId = loadedItems[0].documentId
                }
            }
        }
    }

    private func backgroundIndexFor(start: Int32, end: Int32): Int64 {
        let unsignedStart = UInt32(Int64(start) & 0xFFFFFFFF)
        let unsignedEnd = UInt32(Int64(end) & 0xFFFFFFFF)
        let pairs = this.avatarBackgroundPairs()
        for (index in 0..Int64(pairs.size)) {
            if (pairs[index].start == unsignedStart && pairs[index].end == unsignedEnd) {
                return index
            }
        }
        return 0
    }

    private func buildEmojiStatusItems(): Array<EmojiStatusItem> {
        let items = ArrayList<EmojiStatusItem>()
        items.add(EmojiStatusItem(emoji: "🌙", docId: 5420534629754314727, label: "Moon"))
        items.add(EmojiStatusItem(emoji: "🔥", docId: 5471952986970267163, label: "Fire"))
        items.add(EmojiStatusItem(emoji: "⚡", docId: 5372981952305589252, label: "Lightning"))
        items.add(EmojiStatusItem(emoji: "⭐", docId: 5420323432158514140, label: "Star"))
        items.add(EmojiStatusItem(emoji: "☁️", docId: 5368324170671202286, label: "Cloud"))
        items.add(EmojiStatusItem(emoji: "💎", docId: 5420303861943913706, label: "Diamond"))
        items.add(EmojiStatusItem(emoji: "👑", docId: 5370869767936838002, label: "Crown"))
        items.add(EmojiStatusItem(emoji: "🪐", docId: 5371560786990569360, label: "Planet"))
        items.add(EmojiStatusItem(emoji: "❤️", docId: 5420324367374745234, label: "Red Heart"))
        items.add(EmojiStatusItem(emoji: "🍀", docId: 5420534629754314700, label: "Clover"))
        items.add(EmojiStatusItem(emoji: "❄️", docId: 5420303861943913710, label: "Snowflake"))
        items.add(EmojiStatusItem(emoji: "🎆", docId: 5471952986970267100, label: "Spark"))
        return Array<EmojiStatusItem>(items.size, { i: Int64 => items[i] })
    }

    private func selectAvatarEmoji(item: StickerItem): Unit {
        this.avatarEmojiItem = item
        this.avatarEmojiDocumentId = item.documentId
        Hilog.info(0, "CjTelegram", "[EmojiStatusPickerPage] selected avatar document=${item.documentId}")
    }

    private func avatarPreviewDocumentIds(): Array<Int64> {
        if (this.avatarEmojiDocumentId == 0) { return Array<Int64>() }
        return [this.avatarEmojiDocumentId]
    }

    private func avatarSectionVisibleItems(section: AvatarEmojiSection): Array<StickerItem> {
        if (section.collapsedLineCount <= 0 ||
            this.expandedAvatarEmojiSectionId == section.id) {
            return section.items
        }
        let capacity = section.collapsedLineCount * 8
        if (section.items.size <= capacity) { return section.items }
        let visible = ArrayList<StickerItem>()
        for (item in section.items) {
            if (visible.size >= capacity - 1) { break }
            visible.add(item)
        }
        return visible.toArray()
    }

    private func avatarSectionHiddenCount(section: AvatarEmojiSection): Int64 {
        let visible = this.avatarSectionVisibleItems(section)
        if (visible.size >= section.items.size) { return 0 }
        return section.items.size - visible.size
    }

    private func avatarSectionGridHeight(section: AvatarEmojiSection): Float64 {
        let visible = this.avatarSectionVisibleItems(section)
        let cellCount = visible.size + if (visible.size < section.items.size) { 1 } else { 0 }
        if (cellCount == 0) { return 0.0 }
        return Float64((cellCount + 7) / 8) * 50.0
    }

    private func saveEmojiAvatar(): Unit {
        if (this.isSavingAvatar || this.avatarEmojiDocumentId == 0) { return }
        this.isSavingAvatar = true
        let snapshotService = getMessageContextSnapshotService()
        var token = this.avatarSnapshotToken
        if (token.size == 0) {
            token = "avatar_emoji_${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
            snapshotService.preload("avatarEmojiCanvas", token)
        }
        let selectedDocumentId = this.avatarEmojiDocumentId
        let selectedColors = this.avatarBackgroundColors()
        snapshotService.consume(token, { captured =>
            match (captured) {
                case None => launch { this.isSavingAvatar = false }
                case Some(image) =>
                    let path = image.path
                    let _ = spawn {
                        let bytes = getImageCompressionService().compressToMaxPixelSize(path, Int32(1280), UInt8(90))
                        let uploadSucceeded = if (!bytes.isEmpty()) {
                            getSettingsService().uploadAndSetProfileEmojiAvatar(
                                bytes, "emoji-avatar.jpg", selectedDocumentId, selectedColors).success
                        } else { false }
                        if (uploadSucceeded) {
                            let userId = getCurrentUserId()
                            if (userId > 0) { getUserPhotoService().setUserPhotoPath(userId, "file://" + path) }
                            getPeerInfoAvatarListService().invalidateCache(userId)
                        }
                        launch {
                            this.isSavingAvatar = false
                            if (uploadSucceeded) {
                                this.setAvatarSystemBars(false)
                                routerPop()
                            }
                        }
                    }
            }
        })
    }

    private func avatarBackgroundPairs(): Array<AvatarEmojiBackground> {
        return [
            AvatarEmojiBackground(0xFF5BD1CA, 0xFF538EDB), AvatarEmojiBackground(0xFF61DBA8, 0xFF52ABD6),
            AvatarEmojiBackground(0xFFBDCB57, 0xFF4ABE6E), AvatarEmojiBackground(0xFFD971BF, 0xFF986CE9),
            AvatarEmojiBackground(0xFFEE8C56, 0xFFEC628F), AvatarEmojiBackground(0xFFF2994F, 0xFFE76667),
            AvatarEmojiBackground(0xFFF0B948, 0xFFEF7E4B)
        ]
    }

    private func avatarBackgroundStart(): UInt32 {
        return this.avatarBackgroundPairs()[this.avatarBackgroundIndex].start
    }

    private func avatarBackgroundEnd(): UInt32 {
        return this.avatarBackgroundPairs()[this.avatarBackgroundIndex].end
    }

    private func avatarBackgroundColors(): ArrayList<Int32> {
        let pair = this.avatarBackgroundPairs()[this.avatarBackgroundIndex]
        let colors = ArrayList<Int32>()
        colors.add(Int32(Int64(pair.start) - 0x100000000))
        colors.add(Int32(Int64(pair.end) - 0x100000000))
        return colors
    }

    private func prepareAvatarSnapshot(): Unit {
        if (this.avatarEmojiDocumentId == 0 || this.isSavingAvatar) { return }
        let token = "avatar_emoji_${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
        this.avatarSnapshotToken = token
        getMessageContextSnapshotService().preload("avatarEmojiCanvas", token)
    }

    private func setAvatarSystemBars(active: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(context) =>
                let _ = spawn {
                    try {
                        let window = getLastWindow(context)
                        window.setWindowSystemBarProperties(SystemBarProperties(
                            statusBarColor: if (active) { "#FF000000" } else { "#00000000" },
                            isStatusBarLightIcon: false,
                            statusBarContentColor: if (active) { "#FFFFFFFF" } else { "#FF000000" },
                            navigationBarColor: "#00000000",
                            isNavigationBarLightIcon: false,
                            navigationBarContentColor: "#FF000000"
                        ))
                    } catch (_: Exception) {}
                }
            case None => ()
        }
    }

    private func avatarSearchCategoryStripWidth(): Float64 {
        return if (this.avatarSearchInputActive) { 96.0 } else { 218.0 }
    }

    @Builder
    func buildAvatarSearchCategory(group: EmojiGroupInfo) {
        Column {
            CustomEmojiImage(
                documentId: group.iconEmojiId,
                size: 24.0,
                placeholder: "",
                templateMode: true,
                animationEpoch: -1,
                autoplay: false
            )
        }
        .width(38).height(38)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .backgroundColor(if (this.selectedAvatarSearchCategoryId == group.iconEmojiId) {
            0x26317AFF
        } else { Color.Transparent })
        .borderRadius(19)
        .onClick({ _ => this.selectAvatarSearchCategory(group) })
    }

    @Builder
    func buildAvatarSearchRow() {
        Row {
            Row {
                if (this.avatarSearchInFlight) {
                    LoadingProgress().width(18).height(18).color(0xFF8E8E93)
                        .margin(left: 10, right: 4)
                } else if (this.avatarSearchShowsBack) {
                    Text("‹").fontSize(26).fontColor(0xFF8E8E93)
                        .width(18).textAlign(TextAlign.Center).margin(left: 8, right: 2)
                        .onClick({ _ => this.closeAvatarSearch() })
                } else {
                    Image(@r(app.media.clist_ic_search))
                        .width(15).height(15).fillColor(0xFF8E8E93)
                        .margin(left: 10, right: 4)
                }
                TextInput(text: this.avatarSearchText, placeholder: trSource("Search"))
                    .id(AVATAR_EMOJI_SEARCH_INPUT_ID)
                    .fontSize(15).fontColor(0xFF1C1C1E)
                    .placeholderColor(0xFF8E8E93).caretColor(0xFF007AFF)
                    .height(36).layoutWeight(1).backgroundColor(Color.Transparent)
                    .padding(left: 0, right: 2)
                    .onFocus({ => this.avatarSearchInputActive = true })
                    .onChange({ value: String => this.beginAvatarTextSearch(value) })
                if (!this.avatarSearchText.isEmpty()) {
                    Text("×").fontSize(15).fontColor(0xFFFFFFFF)
                        .width(18).height(18).textAlign(TextAlign.Center)
                        .backgroundColor(0xFFBFC4CC).borderRadius(9).margin(right: 4)
                        .onClick({ _ => this.beginAvatarTextSearch("") })
                }
                Scroll {
                    Row {
                        ForEach(this.avatarSearchCategories,
                            itemGenerator: { group: EmojiGroupInfo, _index: Int64 =>
                                this.buildAvatarSearchCategory(group)
                            }, keyGenerator: { group: EmojiGroupInfo, _index: Int64 =>
                                "avatar_search_category_${group.iconEmojiId}"
                            })
                    }
                }
                .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
                .width(this.avatarSearchCategoryStripWidth())
            }
            .width(100.percent).height(36).borderRadius(18)
            .backgroundColor(0xFFF0F0F0).alignItems(VerticalAlign.Center)
            .layoutWeight(1)
            if (this.avatarSearchInputActive) {
                Text(trSource("Cancel")).fontSize(15).fontColor(0xFF007AFF)
                    .height(36).padding(left: 8, right: 2)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ => this.closeAvatarSearch() })
            }
        }
        .width(100.percent).height(54).padding(left: 12, right: 12)
        .alignItems(VerticalAlign.Center)
    }

    @Builder
    func buildAvatarEditor() {
        Column {
            Row {
                Text("×")
                    .fontSize(36).fontColor(0xFF000000)
                    .width(48).height(48).textAlign(TextAlign.Center)
                    .backgroundColor(0xFFFFFFFF).borderRadius(24)
                    .onClick({ _ =>
                        this.setAvatarSystemBars(false)
                        routerPop()
                    })
                Blank()
                Column { }.width(48).height(48)
            }
            .width(100.percent).height(54).padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            Stack(alignContent: Alignment.Center) {
                Column {
                    ForEach(this.avatarPreviewDocumentIds(), itemGenerator: { documentId: Int64, _index: Int64 =>
                        CustomEmojiImage(
                            documentId: documentId,
                            size: 72.0,
                            placeholder: "",
                            animationEpoch: -1,
                            autoplay: true,
                            autoplayLoop: false
                        )
                    }, keyGenerator: { documentId: Int64, _index: Int64 =>
                        "avatar_preview_${documentId}"
                    })
                    }
                .id("avatarEmojiCanvas")
                .width(100).height(100)
                .linearGradient(angle: 180.0, colors: [
                    (Color(this.avatarBackgroundStart()), 0.0), (Color(this.avatarBackgroundEnd()), 1.0)
                ])
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            }
            .width(100).height(100).borderRadius(50).clip(true)
            .margin(top: 4, bottom: 17)

            Text(trSource("BACKGROUND"))
                .fontSize(13).fontColor(0xFF8E8E93)
                .width(100.percent).padding(left: 30, bottom: 8)
            Scroll {
                Row {
                    ForEach(this.avatarBackgroundPairs(),
                        itemGenerator: { colors: AvatarEmojiBackground, idx: Int64 =>
                            Circle()
                                .width(40).height(40)
                                .fill(colors.start)
                                .stroke(0xFFFFFFFF)
                                .strokeWidth(if (this.avatarBackgroundIndex == idx) { 3 } else { 0 })
                                .margin(left: 7, right: 7)
                                .onClick({ _ => this.avatarBackgroundIndex = idx })
                        })
                }
                .padding(left: 5, right: 5)
            }
            .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
            .width(92.percent).height(52).backgroundColor(0xFFFFFFFF).borderRadius(26)
            .margin(bottom: 20)

            Row {
                Text("EMOJI").fontSize(13).fontColor(0xFF8E8E93)
            }
            .width(100.percent).padding(left: 30, right: 30, bottom: 8)

            Column {
                Scroll {
                    Row {
                        Text("◷").fontSize(29).fontColor(0xFF8E8E93)
                            .width(40).height(40).textAlign(TextAlign.Center)
                            .margin(left: 2, right: 2)
                        ForEach(this.avatarEmojiNavigationItems,
                            itemGenerator: { item: StickerItem, _idx: Int64 =>
                            Stack(alignContent: Alignment.Center) {
                                CustomEmojiImage(
                                    documentId: item.documentId,
                                    size: 30.0,
                                    placeholder: item.altEmoji,
                                    animationEpoch: -1,
                                    templateMode: false,
                                    navigationSlot: false,
                                    autoplay: false
                                )
                            }
                            .width(40).height(40).margin(left: 2, right: 2)
                        }, keyGenerator: { item: StickerItem, idx: Int64 =>
                            "avatar_nav_${item.documentId}_${idx}"
                        })
                    }
                }
                .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
                .width(100.percent).height(44).padding(left: 10, right: 10)

                this.buildAvatarSearchRow()

                List {
                    LazyForEach(this.avatarSectionSource,
                        itemGenerator: { section: AvatarEmojiSection, _sectionIndex: Int64 =>
                            ListItem {
                            Column {
                                if (section.title.size > 0) {
                                    Text(section.title)
                                        .fontSize(13).fontColor(0xFF8E8E93)
                                        .width(100.percent).padding(left: 12, top: 8, bottom: 5)
                                }
                                Grid {
                                    ForEach(this.avatarSectionVisibleItems(section),
                                        itemGenerator: { item: StickerItem, _idx: Int64 =>
                                        GridItem {
                                            Stack(alignContent: Alignment.Center) {
                                                CustomEmojiImage(
                                                    documentId: item.documentId,
                                                    size: 36.0,
                                                    placeholder: item.altEmoji,
                                                    animationEpoch: -1,
                                                    templateMode: false,
                                                    navigationSlot: false,
                                                    autoplay: false
                                                )
                                            }
                                            .width(44).height(44).borderRadius(10)
                                            .backgroundColor(if (this.avatarEmojiDocumentId == item.documentId) { 0xFFE8F0FE } else { 0xFFFFFFFF })
                                            .onClick({ _ => this.selectAvatarEmoji(item) })
                                        }
                                    }, keyGenerator: { item: StickerItem, idx: Int64 =>
                                        "avatar_${section.id}_${item.documentId}_${idx}"
                                    })
                                    if (this.avatarSectionHiddenCount(section) > 0) {
                                        GridItem {
                                            Text("+${this.avatarSectionHiddenCount(section)}")
                                                .fontSize(16).fontWeight(FontWeight.Medium)
                                                .fontColor(0xFFFFFFFF)
                                                .width(44).height(32).textAlign(TextAlign.Center)
                                                .backgroundColor(0xFFCBCBCB).borderRadius(16)
                                                .onClick({ _ =>
                                                    this.expandedAvatarEmojiSectionId = section.id
                                                })
                                        }
                                    }
                                }
                                .columnsTemplate("1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr")
                                .width(100.percent)
                                .height(this.avatarSectionGridHeight(section))
                                .padding(left: 8, right: 8)
                                .scrollBar(BarState.Off)
                            }
                            .width(100.percent)
                            }
                        }, keyGenerator: { section: AvatarEmojiSection, _idx: Int64 =>
                            "avatar_section_${section.id}"
                        })
                }
                .width(100.percent).layoutWeight(1).cachedCount(2).scrollBar(BarState.Off)
                if (!this.avatarSearchInFlight &&
                    (!this.avatarSearchText.isEmpty() || this.selectedAvatarSearchCategoryId != 0) &&
                    this.avatarSearchItems.isEmpty()) {
                    Text(trSource("No emoji found"))
                        .fontSize(15).fontColor(0xFF8E8E93)
                        .width(100.percent).textAlign(TextAlign.Center)
                        .padding(top: 12, bottom: 12)
                }
            }
            .width(92.percent).layoutWeight(1).backgroundColor(0xFFFFFFFF).borderRadius(24)

            Text(if (this.isSavingAvatar) { "Saving…" } else { "Set as Profile Photo" })
                .fontSize(17).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
                .width(86.percent).height(52).textAlign(TextAlign.Center)
                .backgroundColor(if (this.avatarEmojiDocumentId == 0) { 0xFF8E8E93 } else { 0xFF0A84FF })
                .borderRadius(26).margin(top: 14, bottom: 10)
                .onTouch({ event: TouchEvent =>
                    if (event.eventType == TouchType.Down) { this.prepareAvatarSnapshot() }
                })
                .onClick({ _ => this.saveEmojiAvatar() })
        }
        .width(100.percent).height(100.percent)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .backgroundColor(0xFFF2F2F7)
        .alignItems(HorizontalAlign.Center)
        .onAppear({ => this.setAvatarSystemBars(true) })
    }

    private func setEmojiStatus(docId: Int64, emoji: String): Unit {
        this.isLoading = true
        this.errorMessage = ""
        this.successMessage = ""
        let d = docId
        let e = emoji
        let _ = spawn {
            let svc = getSettingsService()
            let ok = svc.updateEmojiStatus(d, 0)
            launch {
                this.isLoading = false
                if (ok) {
                    this.currentStatusDocId = d
                    this.selectedEmoji = e
                    this.successMessage = if (d == 0) { "Status cleared" } else { "Emoji status set to ${e}" }
                    Hilog.info(0, "CjTelegram", "[EmojiStatusPickerPage] setEmojiStatus ok docId=${d}")
                    let _ = spawn {
                        sleep(Duration.millisecond * 1200)
                        launch {
                            this.successMessage = ""
                        }
                    }
                } else {
                    this.errorMessage = "Failed to update status. Check connection."
                    Hilog.info(0, "CjTelegram", "[EmojiStatusPickerPage] setEmojiStatus failed docId=${d}")
                }
            }
        }
    }

    private func clearStatus(): Unit {
        this.setEmojiStatus(0, "")
    }

    private func isItemSelected(docId!: Int64): Bool {
        return this.currentStatusDocId != 0 && this.currentStatusDocId == docId
    }

    @Builder
    func buildCurrentStatusBanner() {
        if (this.currentStatusDocId != 0 || this.selectedEmoji.size > 0) {
            Row {
                Text(if (this.selectedEmoji.size > 0) { this.selectedEmoji } else { "" })
                    .fontSize(28)
                    .margin(right: 8)
                Column {
                    Text("Current Emoji Status")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                    Text(if (this.selectedEmoji.size > 0) { this.selectedEmoji } else { "Active" })
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(0x000000)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(trSource("Clear"))
                    .fontSize(15)
                    .fontColor(0xFF3B30)
                    .fontWeight(FontWeight.Medium)
                    .padding(left: 8)
                    .onClick({ _evt =>
                        this.clearStatus()
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .backgroundColor(0xFFFFFF)
            .borderRadius(10)
            .margin(left: 16, right: 16, bottom: 8)
        }
    }

    @Builder
    func buildEmojiGrid() {
        Column {
            Text("Choose Emoji Status")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 8, bottom: 8)

            Text("Premium emoji statuses are shown next to your name throughout Telegram.")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .padding(left: 16, right: 16, top: 0, bottom: 12)

            ForEach(this.emojiItems, itemGenerator: { item: EmojiStatusItem, _idx: Int64 =>
                Row {
                    Text(item.emoji)
                        .fontSize(32)
                        .width(48)
                        .textAlign(TextAlign.Center)
                    Column {
                        Text(item.label)
                            .fontSize(15)
                            .fontWeight(FontWeight.Regular)
                            .fontColor(0x000000)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    if (this.isItemSelected(docId: item.docId)) {
                        Text(trSource(""))
                            .fontSize(18)
                            .fontColor(0x007AFF)
                            .width(24)
                            .textAlign(TextAlign.Center)
                    } else {
                        Text(trSource(""))
                            .fontSize(18)
                            .fontColor(Color.Transparent)
                            .width(24)
                    }
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 12)
                .backgroundColor(if (this.isItemSelected(docId: item.docId)) { 0xE8F0FE } else { 0xFFFFFF })
                .borderRadius(10)
                .margin(left: 16, right: 16, bottom: 1)
                .onClick({ _evt =>
                    this.setEmojiStatus(item.docId, item.emoji)
                })
            })

            Row {
                Text(trSource(""))
                    .fontSize(32)
                    .width(48)
                    .textAlign(TextAlign.Center)
                Column {
                    Text("Clear Status")
                        .fontSize(15)
                        .fontWeight(FontWeight.Regular)
                        .fontColor(0xFF3B30)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 12)
            .backgroundColor(0xFFFFFF)
            .borderRadius(10)
            .margin(left: 16, right: 16, top: 8, bottom: 8)
            .onClick({ _evt =>
                this.clearStatus()
            })
        }
        .width(100.percent)
    }

    @Builder
    func buildStatusFeedback() {
        if (this.successMessage.size > 0) {
            Text(this.successMessage)
                .fontSize(14)
                .fontColor(0x34C759)
                .width(100.percent)
                .textAlign(TextAlign.Center)
                .padding(top: 8, bottom: 8)
        }
        if (this.errorMessage.size > 0) {
            Text(this.errorMessage)
                .fontSize(14)
                .fontColor(0xFF3B30)
                .width(100.percent)
                .textAlign(TextAlign.Center)
                .padding(top: 8, bottom: 8)
        }
        if (this.isLoading) {
            Text("Updating status...")
                .fontSize(14)
                .fontColor(0x8E8E93)
                .width(100.percent)
                .textAlign(TextAlign.Center)
                .padding(top: 8, bottom: 8)
        }
    }

    public func build() {
        Stack {
            if (this.isAvatarMode) {
                this.buildAvatarEditor()
            } else {
            Column {
            Row {
                Text("‹")
                    .fontSize(38).fontColor(0xFF007AFF).width(52).textAlign(TextAlign.Center)
                    .onClick({ _ =>
                        this.setAvatarSystemBars(false)
                        routerPop()
                    })
                Text(trSource("Emoji Status"))
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFF000000)
                    .layoutWeight(1).textAlign(TextAlign.Center)
                Column {}.width(52)
            }
            .width(100.percent).height(50).alignItems(VerticalAlign.Center)
            Scroll {
                Column {
                    Text(trSource("Emoji Status"))
                        .fontSize(22)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 16, bottom: 4)

                    Text("Requires Telegram Premium")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 16)

                    this.buildStatusFeedback()
                    this.buildCurrentStatusBanner()
                    this.buildEmojiGrid()

                    Row { }.height(40)
                }
                .width(100.percent)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
            }
        }
        .width(100.percent).height(100.percent)
        .onAppear({ =>
            this.ensureLoaded()
            this.setAvatarSystemBars(this.isAvatarMode)
        })
        .onDisAppear({ =>
            if (this.avatarEmojiSnapshotListenerId >= 0) {
                getEntityKeyboardStore().unsubscribeEmojiSnapshot(this.avatarEmojiSnapshotListenerId)
                this.avatarEmojiSnapshotListenerId = -1
            }
        })
    }
}

/**
 * Emoji Status Item データ型
 */
public class EmojiStatusItem {
    public var emoji: String
    public var docId: Int64
    public var label: String

    public init(emoji!: String, docId!: Int64, label!: String) {
        this.emoji = emoji
        this.docId = docId
        this.label = label
    }
}

public class AvatarEmojiBackground {
    public let start: UInt32
    public let end: UInt32

    public init(start: UInt32, end: UInt32) {
        this.start = start
        this.end = end
    }
}

private func avatarEmojiSearchLanguage(): String {
    try {
        let value = I18nSystem.getAppPreferredLanguage().toAsciiLower()
        if (!value.isEmpty()) { return value }
    } catch (_e: Exception) {}
    return "en"
}
