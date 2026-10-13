package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getStickersService, StickersService}
import ohos_app_cangjie_entry.services.{StickerPackInfo, StickerPackDetail, StickerItem}
import ohos_app_cangjie_entry.services.{AllStickersResult, RecentStickersResult, FavedStickersResult, StickerInstallResult}
import ohos_app_cangjie_entry.services.{ArchivedPacksResult, EmojiStickersResult, EmojiKeywordsDiffResult, EmojiKeywordEntry}
import ohos_app_cangjie_entry.services.{AvailableReactionsResult, AvailableReactionInfo, AvailableEffectsResult, AvailableEffectInfo}
import ohos_app_cangjie_entry.services.{EmojiGroupsResult, EmojiGroupInfo, SavedReactionTagsResult, SavedReactionTagInfo}
import std.collection.ArrayList

// ==================== UI ViewModel Types ====================

/**
 * StickerPackViewModel — 贴纸包的 UI 展示模型
 */
public class StickerPackViewModel {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var title: String = ""
    public var shortName: String = ""
    public var stickerCount: Int32 = 0
    public var isInstalled: Bool = false
    public var isAnimated: Bool = false
    public var isVideo: Bool = false
    public var isEmoji: Bool = false
    public var hash: Int32 = 0

    public init() {}

    /** 从 StickerPackInfo 构建 ViewModel */
    public static func fromInfo(info: StickerPackInfo): StickerPackViewModel {
        let vm = StickerPackViewModel()
        vm.id = info.id
        vm.accessHash = info.accessHash
        vm.title = info.title
        vm.shortName = info.shortName
        vm.stickerCount = info.count
        vm.isInstalled = info.isInstalled
        vm.isAnimated = info.isAnimated
        vm.isVideo = info.isVideo
        vm.isEmoji = info.isEmoji
        vm.hash = info.hash
        return vm
    }
}

/**
 * StickerItemViewModel — 单个贴纸的 UI 展示模型
 */
public class StickerItemViewModel {
    public var documentId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dcId: Int32 = 0
    public var mimeType: String = ""
    // 对应表情（用于在贴纸面板中分组展示）
    public var altEmoji: String = ""
    public var width: Int32 = 512
    public var height: Int32 = 512

    public init() {}

    /** 从 StickerItem 构建 ViewModel */
    public static func fromItem(item: StickerItem): StickerItemViewModel {
        let vm = StickerItemViewModel()
        vm.documentId = item.documentId
        vm.accessHash = item.accessHash
        vm.fileReference = item.fileReference
        vm.dcId = item.dcId
        vm.mimeType = item.mimeType
        vm.altEmoji = item.altEmoji
        if (item.width > 0) { vm.width = item.width }
        if (item.height > 0) { vm.height = item.height }
        return vm
    }
}

/**
 * StickerPackDetailViewModel — 贴纸包详情（含贴纸列表）的 UI 展示模型
 */
public class StickerPackDetailViewModel {
    public var pack: StickerPackViewModel = StickerPackViewModel()
    public var stickers: ArrayList<StickerItemViewModel> = ArrayList<StickerItemViewModel>()
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * InstalledPacksViewModel — 已安装贴纸包列表的 UI 展示模型
 */
public class InstalledPacksViewModel {
    public var packs: ArrayList<StickerPackViewModel> = ArrayList<StickerPackViewModel>()
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * RecentStickersViewModel — 最近使用贴纸的 UI 展示模型
 */
public class RecentStickersViewModel {
    public var stickers: ArrayList<StickerItemViewModel> = ArrayList<StickerItemViewModel>()
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * FavedStickersViewModel — 收藏贴纸的 UI 展示模型
 */
public class FavedStickersViewModel {
    public var stickers: ArrayList<StickerItemViewModel> = ArrayList<StickerItemViewModel>()
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * StickerActionViewModel — 安装/卸载操作结果的 UI 展示模型
 */
public class StickerActionViewModel {
    public var success: Bool = false
    public var archived: Bool = false
    public var archivedPackTitles: ArrayList<String> = ArrayList<String>()
    public var errorMessage: String = ""

    public init() {}

    /** 从 StickerInstallResult 构建 ViewModel */
    public static func fromResult(r: StickerInstallResult): StickerActionViewModel {
        let vm = StickerActionViewModel()
        vm.success = r.success
        vm.archived = r.archived
        for (p in r.archivedPacks) {
            vm.archivedPackTitles.add(p.title)
        }
        if (!r.success) {
            vm.errorMessage = if (r.errorCode == "NETWORK_ERROR") {
                "网络错误，请重试"
            } else if (r.errorCode == "INSTALL_FAILED") {
                "安装失败"
            } else if (r.errorCode.size > 0) {
                r.errorCode
            } else {
                "未知错误"
            }
        }
        return vm
    }
}

/**
 * ArchivedPacksViewModel — 归档/搜索贴纸包列表的 UI 展示模型
 */
public class ArchivedPacksViewModel {
    public var packs: ArrayList<StickerPackViewModel> = ArrayList<StickerPackViewModel>()
    public var totalCount: Int32 = 0
    public var notModified: Bool = false
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * EmojiStickersViewModel — 按 emoticon 搜索贴纸结果的 UI 展示模型
 */
public class EmojiStickersViewModel {
    public var stickers: ArrayList<StickerItemViewModel> = ArrayList<StickerItemViewModel>()
    public var notModified: Bool = false
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * EmojiKeywordViewModel — 单个 emoji 关键词条目
 */
public class EmojiKeywordViewModel {
    public var keyword: String = ""
    public var emoticons: ArrayList<String> = ArrayList<String>()
    public var isDeleted: Bool = false

    public init() {}
}

/**
 * EmojiKeywordsDiffViewModel — emoji 关键词差异结果
 */
public class EmojiKeywordsDiffViewModel {
    public var langCode: String = ""
    public var fromVersion: Int32 = 0
    public var version: Int32 = 0
    public var keywords: ArrayList<EmojiKeywordViewModel> = ArrayList<EmojiKeywordViewModel>()
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * AvailableReactionViewModel — 单个可用 reaction
 */
public class AvailableReactionViewModel {
    public var reaction: String = ""
    public var title: String = ""
    public var isInactive: Bool = false
    public var isPremium: Bool = false

    public init() {}

    public static func fromInfo(info: AvailableReactionInfo): AvailableReactionViewModel {
        let vm = AvailableReactionViewModel()
        vm.reaction = info.reaction
        vm.title = info.title
        vm.isInactive = info.isInactive
        vm.isPremium = info.isPremium
        return vm
    }
}

/**
 * AvailableReactionsViewModel — getAvailableReactions 结果
 */
public class AvailableReactionsViewModel {
    public var reactions: ArrayList<AvailableReactionViewModel> = ArrayList<AvailableReactionViewModel>()
    public var hash: Int32 = 0
    public var notModified: Bool = false
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * AvailableEffectViewModel — 单个可用 effect
 */
public class AvailableEffectViewModel {
    public var id: Int64 = 0
    public var emoticon: String = ""
    public var isPremiumRequired: Bool = false
    public var effectStickerId: Int64 = 0

    public init() {}

    public static func fromInfo(info: AvailableEffectInfo): AvailableEffectViewModel {
        let vm = AvailableEffectViewModel()
        vm.id = info.id
        vm.emoticon = info.emoticon
        vm.isPremiumRequired = info.isPremiumRequired
        vm.effectStickerId = info.effectStickerId
        return vm
    }
}

/**
 * AvailableEffectsViewModel — getAvailableEffects 结果
 */
public class AvailableEffectsViewModel {
    public var effects: ArrayList<AvailableEffectViewModel> = ArrayList<AvailableEffectViewModel>()
    public var hash: Int32 = 0
    public var notModified: Bool = false
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * EmojiGroupViewModel — 单个 emoji 分组
 */
public class EmojiGroupViewModel {
    public var title: String = ""
    public var iconEmojiId: Int64 = 0
    public var emoticons: ArrayList<String> = ArrayList<String>()
    public var isGreeting: Bool = false
    public var isPremium: Bool = false

    public init() {}

    public static func fromInfo(info: EmojiGroupInfo): EmojiGroupViewModel {
        let vm = EmojiGroupViewModel()
        vm.title = info.title
        vm.iconEmojiId = info.iconEmojiId
        vm.isGreeting = info.isGreeting
        vm.isPremium = info.isPremium
        for (e in info.emoticons) {
            vm.emoticons.add(e)
        }
        return vm
    }
}

/**
 * EmojiGroupsViewModel — getEmojiGroups 结果
 */
public class EmojiGroupsViewModel {
    public var groups: ArrayList<EmojiGroupViewModel> = ArrayList<EmojiGroupViewModel>()
    public var hash: Int32 = 0
    public var notModified: Bool = false
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * SavedReactionTagViewModel — 单个 savedReactionTag
 */
public class SavedReactionTagViewModel {
    public var reactionEmoticon: String = ""
    public var title: String = ""
    public var count: Int32 = 0

    public init() {}

    public static func fromInfo(info: SavedReactionTagInfo): SavedReactionTagViewModel {
        let vm = SavedReactionTagViewModel()
        vm.reactionEmoticon = info.reactionEmoticon
        vm.title = info.title
        vm.count = info.count
        return vm
    }
}

/**
 * SavedReactionTagsViewModel — getSavedReactionTags 结果
 */
public class SavedReactionTagsViewModel {
    public var tags: ArrayList<SavedReactionTagViewModel> = ArrayList<SavedReactionTagViewModel>()
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

// ==================== DataProvider Singleton ====================

private var _stickersDataProviderInstance: Option<StickersDataProvider> = None

public func getStickersDataProvider(): StickersDataProvider {
    match (_stickersDataProviderInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = StickersDataProvider()
            _stickersDataProviderInstance = Some(inst)
            return inst
    }
}

// ==================== StickersDataProvider ====================

/**
 * StickersDataProvider — 贴纸引擎数据接口层
 *
 * 将 StickersService 的 API 数据转为 UI 可用的 ViewModel，
 * 封装所有贴纸包/最近/收藏/推荐贴纸的引擎层 API。
 *
 * 调用链: UI → StickersDataProvider → StickersService → getMTProtoClient() → MTProto
 */
public class StickersDataProvider {

    /**
     * 获取贴纸包详情（含完整贴纸列表）
     * 通过包 ID 和 accessHash 调用 messages.getStickerSet
     */
    public func getStickerPackDetail(packId: Int64, accessHash: Int64): StickerPackDetailViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getStickerPackDetail id=${packId}")
        let service = getStickersService()
        let result = service.getStickerSet(packId, accessHash)
        let vm = StickerPackDetailViewModel()
        if (!result.success) {
            vm.errorMessage = "获取贴纸包失败"
            return vm
        }
        vm.pack = StickerPackViewModel.fromInfo(result.info)
        for (item in result.stickers) {
            vm.stickers.add(StickerItemViewModel.fromItem(item))
        }
        vm.success = true
        return vm
    }

    /**
     * 通过短名称获取贴纸包详情
     * TL: messages.getStickerSet stickerset:InputStickerSetShortName
     */
    public func getStickerPackByName(shortName: String): StickerPackDetailViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getStickerPackByName name=${shortName}")
        let service = getStickersService()
        let result = service.getStickerSetByName(shortName)
        let vm = StickerPackDetailViewModel()
        if (!result.success) {
            vm.errorMessage = "获取贴纸包失败"
            return vm
        }
        vm.pack = StickerPackViewModel.fromInfo(result.info)
        for (item in result.stickers) {
            vm.stickers.add(StickerItemViewModel.fromItem(item))
        }
        vm.success = true
        return vm
    }

    /**
     * 获取所有已安装贴纸包列表
     * TL: messages.getAllStickers hash:long
     */
    public func getInstalledPacks(): InstalledPacksViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getInstalledPacks")
        let service = getStickersService()
        let result = service.getAllStickers()
        let vm = InstalledPacksViewModel()
        if (!result.success) {
            vm.errorMessage = "获取贴纸包列表失败"
            return vm
        }
        for (info in result.packs) {
            vm.packs.add(StickerPackViewModel.fromInfo(info))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getInstalledPacks: count=${vm.packs.size}")
        return vm
    }

    /**
     * 获取最近使用的贴纸（不含附加贴纸）
     * TL: messages.getRecentStickers flags:# attached:flags.0?true hash:long
     */
    public func getRecentStickers(): RecentStickersViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getRecentStickers")
        let service = getStickersService()
        let result = service.getRecentStickers()
        let vm = RecentStickersViewModel()
        if (!result.success) {
            vm.errorMessage = "获取最近贴纸失败"
            return vm
        }
        for (item in result.stickers) {
            vm.stickers.add(StickerItemViewModel.fromItem(item))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getRecentStickers: count=${vm.stickers.size}")
        return vm
    }

    /**
     * 获取附加贴纸（attached stickers，附加到媒体消息的贴纸）
     * TL: messages.getRecentStickers flags:# attached:flags.0?true hash:long
     */
    public func getAttachedStickers(): RecentStickersViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getAttachedStickers")
        let service = getStickersService()
        let result = service.getRecentStickers(attached: true)
        let vm = RecentStickersViewModel()
        if (!result.success) {
            vm.errorMessage = "获取附加贴纸失败"
            return vm
        }
        for (item in result.stickers) {
            vm.stickers.add(StickerItemViewModel.fromItem(item))
        }
        vm.success = true
        return vm
    }

    /**
     * 获取收藏的贴纸列表
     * TL: messages.getFavedStickers hash:long
     */
    public func getFavedStickers(): FavedStickersViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getFavedStickers")
        let service = getStickersService()
        let result = service.getFavedStickers()
        let vm = FavedStickersViewModel()
        if (!result.success) {
            vm.errorMessage = "获取收藏贴纸失败"
            return vm
        }
        for (item in result.stickers) {
            vm.stickers.add(StickerItemViewModel.fromItem(item))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getFavedStickers: count=${vm.stickers.size}")
        return vm
    }

    /**
     * 安装贴纸包
     * TL: messages.installStickerSet stickerset:InputStickerSet archived:Bool
     * @param archived true 则存档（不显示在已安装列表最前，但仍保留）
     */
    public func installPack(packId: Int64, accessHash: Int64, archived!: Bool = false): StickerActionViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] installPack id=${packId} archived=${archived}")
        let service = getStickersService()
        let result = service.installStickerSet(packId, accessHash, archived: archived)
        let vm = StickerActionViewModel.fromResult(result)
        if (vm.success) {
            Hilog.info(0, "CjTelegram", "[StickersDP] installPack success, archived=${vm.archived}")
        } else {
            Hilog.info(0, "CjTelegram", "[StickersDP] installPack failed: ${vm.errorMessage}")
        }
        return vm
    }

    /**
     * 卸载/移除贴纸包
     * TL: messages.uninstallStickerSet stickerset:InputStickerSet = Bool
     */
    public func uninstallPack(packId: Int64, accessHash: Int64): StickerActionViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] uninstallPack id=${packId}")
        let service = getStickersService()
        let result = service.uninstallStickerSet(packId, accessHash)
        let vm = StickerActionViewModel.fromResult(result)
        if (vm.success) {
            Hilog.info(0, "CjTelegram", "[StickersDP] uninstallPack success")
        } else {
            Hilog.info(0, "CjTelegram", "[StickersDP] uninstallPack failed: ${vm.errorMessage}")
        }
        return vm
    }

    /**
     * 搜索贴纸包（按关键词）
     * TL: messages.searchStickerSets#35705b8a
     */
    public func searchStickerSets(query: String, excludeFeatured!: Bool = false): ArchivedPacksViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] searchStickerSets q=${query}")
        let service = getStickersService()
        let result = service.searchStickerSets(query, excludeFeatured: excludeFeatured)
        let vm = ArchivedPacksViewModel()
        if (!result.success) {
            vm.errorMessage = "搜索贴纸包失败"
            return vm
        }
        vm.notModified = result.notModified
        for (info in result.packs) {
            vm.packs.add(StickerPackViewModel.fromInfo(info))
        }
        vm.success = true
        return vm
    }

    /**
     * 通过 emoticon 获取贴纸（远程搜索）
     * TL: messages.getStickers#d5a5d3a1
     */
    public func getStickers(emoticon: String): EmojiStickersViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getStickers emoticon=${emoticon}")
        let service = getStickersService()
        let result = service.getStickers(emoticon)
        let vm = EmojiStickersViewModel()
        if (!result.success) {
            vm.errorMessage = "获取贴纸失败"
            return vm
        }
        vm.notModified = result.notModified
        for (item in result.stickers) {
            vm.stickers.add(StickerItemViewModel.fromItem(item))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getStickers: count=${vm.stickers.size}")
        return vm
    }

    /**
     * 获取归档贴纸包列表
     * TL: messages.getArchivedStickers#57f17692
     */
    public func getArchivedStickers(masks!: Bool = false, emojis!: Bool = false): ArchivedPacksViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getArchivedStickers masks=${masks} emojis=${emojis}")
        let service = getStickersService()
        let result = service.getArchivedStickers(masks: masks, emojis: emojis)
        let vm = ArchivedPacksViewModel()
        if (!result.success) {
            vm.errorMessage = "获取归档贴纸包失败"
            return vm
        }
        vm.totalCount = result.totalCount
        for (info in result.packs) {
            vm.packs.add(StickerPackViewModel.fromInfo(info))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getArchivedStickers: count=${vm.packs.size}")
        return vm
    }

    /**
     * 重排已安装贴纸包顺序
     * TL: messages.reorderStickerSets#78337739
     */
    public func reorderStickerSets(order: ArrayList<Int64>, masks!: Bool = false, emojis!: Bool = false): Bool {
        Hilog.info(0, "CjTelegram", "[StickersDP] reorderStickerSets count=${order.size}")
        let service = getStickersService()
        return service.reorderStickerSets(order, masks: masks, emojis: emojis)
    }

    /**
     * 清除最近使用的贴纸
     * TL: messages.clearRecentStickers#8999602d
     */
    public func clearRecentStickers(attached!: Bool = false): Bool {
        Hilog.info(0, "CjTelegram", "[StickersDP] clearRecentStickers attached=${attached}")
        let service = getStickersService()
        return service.clearRecentStickers(attached: attached)
    }

    /**
     * 获取 emoji 关键词（完整版）
     * TL: messages.getEmojiKeywords#35a0e062
     * 调用后自动持久化版本号到 Preferences
     */
    public func getEmojiKeywords(langCode: String): EmojiKeywordsDiffViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getEmojiKeywords lang=${langCode}")
        let service = getStickersService()
        let result = service.synchronizeEmojiKeywords(langCode)
        let vm = EmojiKeywordsDiffViewModel()
        if (!result.success) {
            vm.errorMessage = "获取 emoji 关键词失败"
            return vm
        }
        vm.langCode = result.langCode
        vm.fromVersion = result.fromVersion
        vm.version = result.version
        for (entry in result.keywords) {
            let kvm = EmojiKeywordViewModel()
            kvm.keyword = entry.keyword
            kvm.isDeleted = entry.isDeleted
            for (e in entry.emoticons) { kvm.emoticons.add(e) }
            vm.keywords.add(kvm)
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getEmojiKeywords: version=${result.version} count=${vm.keywords.size}")
        return vm
    }

    /**
     * 获取 emoji 关键词增量更新（带版本）
     * TL: messages.getEmojiKeywordsDifference#1508b6af
     * 自动读取缓存版本号，更新后持久化新版本号
     */
    public func getEmojiKeywordsDifference(langCode: String): EmojiKeywordsDiffViewModel {
        let service = getStickersService()
        let cachedVersion = service.getCachedEmojiKeywordsVersion(langCode)
        Hilog.info(0, "CjTelegram", "[StickersDP] getEmojiKeywordsDifference lang=${langCode} fromVersion=${cachedVersion}")
        let result = service.synchronizeEmojiKeywords(langCode)
        let vm = EmojiKeywordsDiffViewModel()
        if (!result.success) {
            vm.errorMessage = "获取 emoji 关键词增量失败"
            return vm
        }
        vm.langCode = result.langCode
        vm.fromVersion = result.fromVersion
        vm.version = result.version
        for (entry in result.keywords) {
            let kvm = EmojiKeywordViewModel()
            kvm.keyword = entry.keyword
            kvm.isDeleted = entry.isDeleted
            for (e in entry.emoticons) { kvm.emoticons.add(e) }
            vm.keywords.add(kvm)
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getEmojiKeywordsDifference: newVersion=${result.version} count=${vm.keywords.size}")
        return vm
    }

    /**
     * 获取支持的 emoji 关键词语言列表
     * TL: messages.getEmojiKeywordsLanguages#4e9963b2
     */
    public func getEmojiKeywordsLanguages(langCodes: ArrayList<String>): ArrayList<String> {
        Hilog.info(0, "CjTelegram", "[StickersDP] getEmojiKeywordsLanguages count=${langCodes.size}")
        let service = getStickersService()
        return service.getEmojiKeywordsLanguages(langCodes)
    }

    /**
     * 获取可用 reactions（hash 增量，自动读取和持久化 hash）
     * TL: messages.getAvailableReactions#18dea0ac
     */
    public func getAvailableReactions(): AvailableReactionsViewModel {
        let service = getStickersService()
        let cachedHash = service.getCachedHash("available_reactions_hash")
        Hilog.info(0, "CjTelegram", "[StickersDP] getAvailableReactions hash=${cachedHash}")
        let result = service.getAvailableReactions(hash: cachedHash)
        let vm = AvailableReactionsViewModel()
        if (!result.success) {
            vm.errorMessage = "获取可用 reactions 失败"
            return vm
        }
        vm.hash = result.hash
        vm.notModified = result.notModified
        for (info in result.reactions) {
            vm.reactions.add(AvailableReactionViewModel.fromInfo(info))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getAvailableReactions: count=${vm.reactions.size} notModified=${vm.notModified}")
        return vm
    }

    /**
     * 获取可用 message effects（hash 增量，自动读取和持久化 hash）
     * TL: messages.getAvailableEffects#dea20a39
     */
    public func getAvailableEffects(): AvailableEffectsViewModel {
        let service = getStickersService()
        let cachedHash = service.getCachedHash("available_effects_hash")
        Hilog.info(0, "CjTelegram", "[StickersDP] getAvailableEffects hash=${cachedHash}")
        let result = service.getAvailableEffects(hash: cachedHash)
        let vm = AvailableEffectsViewModel()
        if (!result.success) {
            vm.errorMessage = "获取可用 effects 失败"
            return vm
        }
        vm.hash = result.hash
        vm.notModified = result.notModified
        for (info in result.effects) {
            vm.effects.add(AvailableEffectViewModel.fromInfo(info))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getAvailableEffects: count=${vm.effects.size} notModified=${vm.notModified}")
        return vm
    }

    /**
     * 获取 emoji 分组（hash 增量，自动读取和持久化 hash）
     * TL: messages.getEmojiGroups#7488ce5b
     */
    public func getEmojiGroups(): EmojiGroupsViewModel {
        let service = getStickersService()
        let cachedHash = service.getCachedHash("emoji_groups_hash")
        Hilog.info(0, "CjTelegram", "[StickersDP] getEmojiGroups hash=${cachedHash}")
        let result = service.getEmojiGroups(hash: cachedHash)
        let vm = EmojiGroupsViewModel()
        if (!result.success) {
            vm.errorMessage = "获取 emoji 分组失败"
            return vm
        }
        vm.hash = result.hash
        vm.notModified = result.notModified
        for (info in result.groups) {
            vm.groups.add(EmojiGroupViewModel.fromInfo(info))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getEmojiGroups: count=${vm.groups.size} notModified=${vm.notModified}")
        return vm
    }

    /**
     * 设置默认 reaction（快速 reaction）
     * TL: messages.setDefaultReaction#4f47a016
     */
    public func setDefaultReaction(reactionEmoticon: String): Bool {
        Hilog.info(0, "CjTelegram", "[StickersDP] setDefaultReaction reaction=${reactionEmoticon}")
        let service = getStickersService()
        return service.setDefaultReaction(reactionEmoticon)
    }

    /**
     * 获取已保存的 reaction 标签
     * TL: messages.getSavedReactionTags#3637e05b
     */
    public func getSavedReactionTags(): SavedReactionTagsViewModel {
        Hilog.info(0, "CjTelegram", "[StickersDP] getSavedReactionTags")
        let service = getStickersService()
        let result = service.getSavedReactionTags()
        let vm = SavedReactionTagsViewModel()
        if (!result.success) {
            vm.errorMessage = "获取 reaction 标签失败"
            return vm
        }
        vm.hash = result.hash
        vm.notModified = result.notModified
        for (info in result.tags) {
            vm.tags.add(SavedReactionTagViewModel.fromInfo(info))
        }
        vm.success = true
        Hilog.info(0, "CjTelegram", "[StickersDP] getSavedReactionTags: count=${vm.tags.size}")
        return vm
    }

    /**
     * 更新 savedMessage reaction 标签标题
     * TL: messages.updateSavedReactionTag#60297dec
     */
    public func updateSavedReactionTag(reactionEmoticon: String, title: String): Bool {
        Hilog.info(0, "CjTelegram", "[StickersDP] updateSavedReactionTag reaction=${reactionEmoticon}")
        let service = getStickersService()
        return service.updateSavedReactionTag(reactionEmoticon, title)
    }
}
