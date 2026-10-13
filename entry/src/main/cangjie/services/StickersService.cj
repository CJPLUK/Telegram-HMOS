package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap
import std.collection.HashSet
import std.sync.*
import std.time.*
import std.random.Random
import kit.CoreFileKit.*
import kit.ImageKit.{createImageSource, PixelMap, ImageSource, SourceOptions, InitializationOptions, Size as ImageKitSize, createPixelMap, PixelMapFormat, AlphaType}
import ohos.business_exception.BusinessException

private let availableReactionsCacheMonitor = Monitor()
private var availableReactionsMemoryCache: Option<AvailableReactionsResult> =
    None<AvailableReactionsResult>
private var availableReactionsMemoryGeneration: Int64 = -1
private let builtinStickerSetCacheMonitor = Monitor()
private let stickerPanelCacheMonitor = Monitor()
private let stickerFileLoadMonitor = Monitor()
private var stickerFileLoading = HashMap<Int64, Bool>()
private let emojiKeywordsCacheMonitor = Monitor()
private let EMOJI_KEYWORDS_CACHE_MAGIC: UInt32 = 0x454b5731
private let emojiGroupsCacheMonitor = Monitor()
private var emojiGroupsMemoryCache: Option<EmojiGroupsResult> = None<EmojiGroupsResult>
private var emojiGroupsMemoryGeneration: Int64 = -1

private func emojiKeywordsCachePath(
    langCode: String, token: EntityKeyboardAccountToken
): String {
    let filesDir = getAppFilesDir()
    let suffix = getEntityKeyboardStore().cacheFileSuffix(token)
    let safeLanguage = langCode.replace("/", "_").replace("\\", "_")
    return if (filesDir.isEmpty()) { "" } else {
        filesDir + "/emoji_keywords_" + safeLanguage + "_" + suffix + ".tlc"
    }
}

private func cloneEmojiKeywordEntry(source: EmojiKeywordEntry): EmojiKeywordEntry {
    let result = EmojiKeywordEntry()
    result.keyword = source.keyword
    result.isDeleted = false
    for (emoticon in source.emoticons) { result.emoticons.add(emoticon) }
    return result
}

private func serializeEmojiKeywords(result: EmojiKeywordsDiffResult): Array<Byte> {
    let serializer = TLSerializer()
    serializer.writeUInt32(EMOJI_KEYWORDS_CACHE_MAGIC)
    serializer.writeString(result.langCode)
    serializer.writeInt32(result.version)
    serializer.writeInt32(Int32(result.keywords.size))
    for (entry in result.keywords) {
        serializer.writeString(entry.keyword)
        serializer.writeInt32(Int32(entry.emoticons.size))
        for (emoticon in entry.emoticons) { serializer.writeString(emoticon) }
    }
    return serializer.getBytes()
}

private func parseCachedEmojiKeywords(data: Array<Byte>): EmojiKeywordsDiffResult {
    let result = EmojiKeywordsDiffResult()
    if (data.size < 16) { return result }
    try {
        let deserializer = TLDeserializer(data)
        if (deserializer.readUInt32() != EMOJI_KEYWORDS_CACHE_MAGIC) { return result }
        result.langCode = deserializer.readString()
        result.version = deserializer.readInt32()
        result.fromVersion = result.version
        let count = deserializer.readInt32()
        if (count < 0 || count > 100000) { return EmojiKeywordsDiffResult() }
        var index: Int32 = 0
        while (index < count) {
            let entry = EmojiKeywordEntry()
            entry.keyword = deserializer.readString()
            let emoticonCount = deserializer.readInt32()
            if (emoticonCount < 0 || emoticonCount > 1024) { return EmojiKeywordsDiffResult() }
            var emoticonIndex: Int32 = 0
            while (emoticonIndex < emoticonCount) {
                entry.emoticons.add(deserializer.readString())
                emoticonIndex = emoticonIndex + 1
            }
            if (!entry.keyword.isEmpty() && !entry.emoticons.isEmpty()) {
                result.keywords.add(entry)
            }
            index = index + 1
        }
        result.success = true
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[StickersService] emoji keywords cache parse failed: ${e}")
    }
    return result
}

private func writeEmojiKeywordsCache(
    cacheLanguageCode: String,
    result: EmojiKeywordsDiffResult,
    token: EntityKeyboardAccountToken
): Unit {
    if (!result.success || result.langCode.isEmpty()) { return }
    if (!getEntityKeyboardStore().isCurrent(token)) {
        Hilog.info(0, "CjTelegram", "[StickersService] drop stale emoji keywords generation=${token.generation}")
        return
    }
    let data = serializeEmojiKeywords(result)
    synchronized(emojiKeywordsCacheMonitor) {
        let path = emojiKeywordsCachePath(cacheLanguageCode, token)
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StickersService] emoji keywords cache write failed: ${e}")
        }
    }
}

private func readEmojiKeywordsCache(
    langCode: String, token: EntityKeyboardAccountToken
): EmojiKeywordsDiffResult {
    return synchronized(emojiKeywordsCacheMonitor) {
        let path = emojiKeywordsCachePath(langCode, token)
        if (path.isEmpty()) { return EmojiKeywordsDiffResult() }
        try {
            if (!FileIo.access(path)) { return EmojiKeywordsDiffResult() }
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return EmojiKeywordsDiffResult() }
            let bytes = Array<Byte>(stat.size, repeat: 0)
            let file = FileIo.open(path, mode: 0o0)
            let readCount = FileIo.read(file.fd, bytes)
            FileIo.close(file)
            if (readCount != stat.size) { return EmojiKeywordsDiffResult() }
            let result = parseCachedEmojiKeywords(bytes)
            if (result.success) {
                Hilog.info(0, "CjTelegram",
                    "[StickersService] emoji keywords disk hit lang=${langCode} version=${result.version} count=${result.keywords.size}")
            }
            return result
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StickersService] emoji keywords cache read failed: ${e}")
            return EmojiKeywordsDiffResult()
        }
    }
}

private func availableReactionsLegacyCachePath(): String {
    let filesDir = getAppFilesDir()
    return if (filesDir.isEmpty()) { "" } else { filesDir + "/available_reactions.tl" }
}

private func availableReactionsCachePath(token: EntityKeyboardAccountToken): String {
    let filesDir = getAppFilesDir()
    let suffix = getEntityKeyboardStore().cacheFileSuffix(token)
    return if (filesDir.isEmpty()) { "" } else {
        filesDir + "/available_reactions_" + suffix + ".tl"
    }
}

private func cacheAvailableReactionsResponse(
    data: Array<Byte>, result: AvailableReactionsResult, token: EntityKeyboardAccountToken
): Unit {
    if (!result.success || result.notModified || result.reactions.isEmpty() || data.isEmpty()) { return }
    if (!getEntityKeyboardStore().isCurrent(token)) {
        Hilog.info(0, "CjTelegram", "[StickersService] drop stale reactions cache generation=${token.generation}")
        return
    }
    synchronized(availableReactionsCacheMonitor) {
        availableReactionsMemoryCache = Some(result)
        availableReactionsMemoryGeneration = token.generation
        let path = availableReactionsCachePath(token)
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StickersService] available reactions cache write failed: ${e}")
        }
    }
}

private func loadCachedAvailableReactionsResponse(): AvailableReactionsResult {
    let token = getEntityKeyboardStore().currentToken()
    synchronized(availableReactionsCacheMonitor) {
        if (availableReactionsMemoryGeneration == token.generation) {
            match (availableReactionsMemoryCache) {
                case Some(result) => return result
                case None => ()
            }
        }
        var path = availableReactionsCachePath(token)
        if (path.isEmpty()) { return AvailableReactionsResult() }
        try {
            if (!FileIo.access(path) && getEntityKeyboardStore().canMigrateLegacy(token)) {
                let legacyPath = availableReactionsLegacyCachePath()
                if (!legacyPath.isEmpty() && FileIo.access(legacyPath)) {
                    path = legacyPath
                }
            }
            let file = FileIo.open(path, mode: 0o0)
            let stat = FileIo.stat(file.fd)
            if (stat.size <= 0) {
                FileIo.close(file)
                return AvailableReactionsResult()
            }
            let bytes = Array<Byte>(stat.size, repeat: 0)
            let _ = FileIo.read(file.fd, bytes)
            FileIo.close(file)
            let result = parseAvailableReactionsResponse(bytes)
            if (result.success && !result.reactions.isEmpty()) {
                availableReactionsMemoryCache = Some(result)
                availableReactionsMemoryGeneration = token.generation
                if (path == availableReactionsLegacyCachePath()) {
                    let scopedPath = availableReactionsCachePath(token)
                    let scopedFile = FileIo.open(scopedPath, mode: 0o1101)
                    FileIo.write(scopedFile.fd, bytes)
                    FileIo.close(scopedFile)
                    Hilog.info(0, "CjTelegram", "[StickersService] migrated legacy reactions cache slot=${token.slot}")
                }
                Hilog.info(0, "CjTelegram",
                    "[StickersService] available reactions disk hit count=${result.reactions.size}")
                return result
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StickersService] available reactions cache read failed: ${e}")
        }
        return AvailableReactionsResult()
    }
}

// ==================== TL Request Types ====================

/**
 * messages.getStickerSet#c8a0ec74 stickerset:InputStickerSet hash:int = messages.StickerSet
 * 获取贴纸包详情（包含贴纸列表）
 *
 * InputStickerSet 变体:
 *   inputStickerSetID#9de7a269 id:long access_hash:long
 *   inputStickerSetShortName#861cc8a0 short_name:string
 *   inputStickerSetAnimatedEmoji#28703c8 (无字段)
 */
class StickersGetStickerSet <: TLObject {
    var packId: Int64 = 0
    var accessHash: Int64 = 0
    var shortName: String = ""
    // "id" | "shortName" | "animatedEmoji" | "animatedEmojiAnimations"
    var inputType: String = "id"
    var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xc8a0ec74 }

    public func serialize(serializer: TLSerializer) {
        if (this.inputType == "shortName") {
            // inputStickerSetShortName#861cc8a0 short_name:string
            serializer.writeUInt32(0x861cc8a0)
            serializer.writeString(this.shortName)
        } else if (this.inputType == "animatedEmoji") {
            // inputStickerSetAnimatedEmoji#28703c8
            serializer.writeUInt32(0x028703c8)
        } else if (this.inputType == "animatedEmojiAnimations") {
            // inputStickerSetAnimatedEmojiAnimations#cde3739
            serializer.writeUInt32(0x0cde3739)
        } else {
            // inputStickerSetID#9de7a269 id:long access_hash:long
            serializer.writeUInt32(0x9de7a269)
            serializer.writeInt64(this.packId)
            serializer.writeInt64(this.accessHash)
        }
        serializer.writeInt32(this.hash)
    }
}

/**
 * messages.getAllStickers#b8a0a1a8 hash:long = messages.AllStickers
 * 获取所有已安装贴纸包（hash=0 强制刷新）
 * iOS Api42.swift L6566: appendInt32(-1197432408) = 0xb8a0a1a8; serializeInt64(hash)
 */
class StickersGetAllStickers <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xb8a0a1a8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/** messages.getEmojiStickers#fbfca18f hash:long = messages.AllStickers */
class StickersGetEmojiStickers <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xfbfca18f }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/** messages.searchCustomEmoji#2c11c0d7 emoticon:string hash:long = EmojiList */
class StickersSearchCustomEmoji <: TLObject {
    var emoticon: String = ""
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x2c11c0d7 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.emoticon)
        serializer.writeInt64(this.hash)
    }
}

/** account.getDefaultProfilePhotoEmojis#e2750328 hash:long = EmojiList */
class StickersGetDefaultProfilePhotoEmojis <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xe2750328 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/** messages.getCustomEmojiDocuments#d9ab0f54 document_id:Vector<long> = Vector<Document> */
class StickersGetCustomEmojiDocuments <: TLObject {
    var documentIds: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0xd9ab0f54 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.documentIds.size))
        for (documentId in this.documentIds) {
            serializer.writeInt64(documentId)
        }
    }
}

/**
 * messages.getRecentStickers#9da9403b flags:# attached:flags.0?true hash:long = messages.RecentStickers
 * 获取最近使用的贴纸列表
 */
class StickersGetRecentStickers <: TLObject {
    var attached: Bool = false
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x9da9403b }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.attached) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.getFavedStickers#04f1aaa9 hash:long = messages.FavedStickers
 * 获取收藏的贴纸列表
 */
class StickersGetFavedStickers <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x04f1aaa9 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.installStickerSet#c78fe460 stickerset:InputStickerSet archived:Bool = messages.StickerSetInstallResult
 * 安装贴纸包
 */
class StickersInstallStickerSet <: TLObject {
    var packId: Int64 = 0
    var accessHash: Int64 = 0
    var archived: Bool = false

    public func getConstructorId(): UInt32 { return 0xc78fe460 }

    public func serialize(serializer: TLSerializer) {
        // inputStickerSetID#9de7a269 id:long access_hash:long
        serializer.writeUInt32(0x9de7a269)
        serializer.writeInt64(this.packId)
        serializer.writeInt64(this.accessHash)
        // Bool (boxed)
        if (this.archived) {
            serializer.writeUInt32(TLConstructors.BOOL_TRUE)
        } else {
            serializer.writeUInt32(TLConstructors.BOOL_FALSE)
        }
    }
}

/**
 * messages.uninstallStickerSet#f96e55de stickerset:InputStickerSet = Bool
 * 卸载/移除贴纸包
 */
class StickersUninstallStickerSet <: TLObject {
    var packId: Int64 = 0
    var accessHash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xf96e55de }

    public func serialize(serializer: TLSerializer) {
        // inputStickerSetID#9de7a269 id:long access_hash:long
        serializer.writeUInt32(0x9de7a269)
        serializer.writeInt64(this.packId)
        serializer.writeInt64(this.accessHash)
    }
}

/**
 * messages.searchStickerSets#35705b8a flags:# exclude_featured:flags.0?true q:string hash:long = messages.FoundStickerSets
 * 搜索贴纸包
 */
class StickersSearchStickerSets <: TLObject {
    var excludeFeatured: Bool = false
    var q: String = ""
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x35705b8a }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.excludeFeatured) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeString(this.q)
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.getStickers#d5a5d3a1 emoticon:string hash:long = messages.Stickers
 * 通过 emoticon 获取贴纸（远程搜索）
 */
class StickersGetStickersReq <: TLObject {
    var emoticon: String = ""
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0xd5a5d3a1 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.emoticon)
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.getArchivedStickers#57f17692 flags:# masks:flags.0?true emojis:flags.1?true offset_id:long limit:int = messages.ArchivedStickers
 * 获取归档贴纸包列表
 */
class StickersGetArchivedStickers <: TLObject {
    var masks: Bool = false
    var emojis: Bool = false
    var offsetId: Int64 = 0
    var limit: Int32 = 100

    public func getConstructorId(): UInt32 { return 0x57f17692 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.masks) { flags = flags | 1 }
        if (this.emojis) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeInt64(this.offsetId)
        serializer.writeInt32(this.limit)
    }
}

/**
 * messages.reorderStickerSets#78337739 flags:# masks:flags.0?true emojis:flags.1?true order:Vector<long> = Bool
 * 重排贴纸包顺序
 */
class StickersReorderStickerSets <: TLObject {
    var masks: Bool = false
    var emojis: Bool = false
    var order: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0x78337739 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.masks) { flags = flags | 1 }
        if (this.emojis) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.order.size))
        for (id in this.order) {
            serializer.writeInt64(id)
        }
    }
}

/**
 * messages.toggleStickerSets#b5052fea flags:# unarchive:flags.0?true archive:flags.1?true
 *   stickersets:Vector<InputStickerSet> = Bool
 * 批量切换贴纸包启用/停用（archive/unarchive）
 * iOS Api42.swift: appendInt32(-1257951254) = 0xb5052fea
 * flags: bit0=unarchive(启用), bit1=archive(停用/归档)
 */
class StickersToggleStickerSets <: TLObject {
    var archive: Bool = false
    var unarchive: Bool = false
    var packIds: ArrayList<Int64> = ArrayList<Int64>()
    var accessHashes: ArrayList<Int64> = ArrayList<Int64>()

    public func getConstructorId(): UInt32 { return 0xb5052fea }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.unarchive) { flags = flags | 1 }
        if (this.archive) { flags = flags | 2 }
        serializer.writeInt32(flags)
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.packIds.size))
        var i: Int64 = 0
        while (i < this.packIds.size) {
            // inputStickerSetID#9de7a269 id:long access_hash:long
            serializer.writeUInt32(0x9de7a269)
            serializer.writeInt64(this.packIds[i])
            serializer.writeInt64(this.accessHashes[i])
            i = i + 1
        }
    }
}

/**
 * messages.clearRecentStickers#8999602d flags:# attached:flags.0?true = Bool
 * 清除最近使用的贴纸
 */
class StickersClearRecentStickers <: TLObject {
    var attached: Bool = false

    public func getConstructorId(): UInt32 { return 0x8999602d }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.attached) { flags = flags | 1 }
        serializer.writeInt32(flags)
    }
}

/**
 * messages.getEmojiKeywords#35a0e062 lang_code:string = EmojiKeywordsDifference
 * 获取 emoji 关键词（完整版）
 */
class StickersGetEmojiKeywords <: TLObject {
    var langCode: String = ""

    public func getConstructorId(): UInt32 { return 0x35a0e062 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langCode)
    }
}

/**
 * messages.getEmojiKeywordsDifference#1508b6af lang_code:string from_version:int = EmojiKeywordsDifference
 * 获取 emoji 关键词增量（带版本）
 */
class StickersGetEmojiKeywordsDiff <: TLObject {
    var langCode: String = ""
    var fromVersion: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x1508b6af }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langCode)
        serializer.writeInt32(this.fromVersion)
    }
}

/**
 * messages.getEmojiKeywordsLanguages#4e9963b2 lang_codes:Vector<string> = Vector<EmojiLanguage>
 * 获取支持的 emoji 关键词语言列表
 */
class StickersGetEmojiKeywordsLanguages <: TLObject {
    var langCodes: ArrayList<String> = ArrayList<String>()

    public func getConstructorId(): UInt32 { return 0x4e9963b2 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.langCodes.size))
        for (code in this.langCodes) {
            serializer.writeString(code)
        }
    }
}

/**
 * messages.getFeaturedStickers#64780b14 hash:long = messages.FeaturedStickers
 * 获取精选/推荐贴纸包列表
 * iOS Api42.swift L7187: appendInt32(1685588756) = 0x64780b14
 *
 * 响应:
 *   messages.featuredStickersNotModified#c6dc0c66 count:int
 *   messages.featuredStickers#be382906 flags:# premium:flags.0?true hash:long count:int
 *     sets:Vector<StickerSetCovered> unread:Vector<long>
 */
class StickersGetFeaturedStickers <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x64780b14 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/** messages.getFeaturedEmojiStickers#0ecf6736 hash:long = messages.FeaturedStickers */
class StickersGetFeaturedEmojiStickers <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x0ecf6736 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * FeaturedStickerPacksResult — getFeaturedStickers 响应
 * unreadIds: 未读（新）包的 id 列表，用于显示 unread badge（P2-378 gap）
 */
public class FeaturedStickerPacksResult {
    public var packs: ArrayList<StickerPackInfo> = ArrayList<StickerPackInfo>()
    public var unreadIds: ArrayList<Int64> = ArrayList<Int64>()
    /** messages.featuredStickers flags.0 —— iOS 用它决定标题写 Trending Premium 还是 Featured。 */
    public var isPremium: Bool = false
    public var count: Int32 = 0
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

/**
 * 解析精选贴纸包 sets:Vector<StickerSetCovered> into FeaturedStickerPacksResult
 * 内联解析，避免 parseStickerSetCoveredInto 只写 ArchivedPacksResult 的约束
 */
private func parseFeaturedStickersResponseFull(data: Array<Byte>): FeaturedStickerPacksResult {
    let result = FeaturedStickerPacksResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0xc6dc0c66) {
        result.notModified = true
        result.count = d.readInt32()
        result.success = true
        return result
    }
    if (ctor != 0xbe382906) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected featuredStickers ctor")
        return result
    }
    let flags = d.readInt32()
    result.isPremium = (flags & 1) != 0
    result.hash = d.readInt64()
    result.count = d.readInt32()
    let setVCtor = d.readUInt32()
    if (setVCtor == TLConstructors.VECTOR) {
        let setCount = d.readInt32()
        var si: Int32 = 0
        while (si < setCount) {
            // stickerSetCovered#6410a5d2 or stickerSetMultiCovered#3407e51b
            let coverCtor = d.readUInt32()
            if (coverCtor == 0x6410a5d2) {
                // stickerSetCovered: set:StickerSet cover:Document
                let setCtor2 = d.readUInt32()
                if (setCtor2 == 0x2dd14edc || setCtor2 == 0xeeb46f27) {
                    let info = parseStickerSetInfo(d)
                    info.cover = parseStickerDocument(d)
                    info.topItems.add(info.cover)
                    result.packs.add(info)
                } else {
                    let _ = parseStickerDocument(d)
                }
            } else if (coverCtor == 0x3407e51b) {
                // stickerSetMultiCovered: set:StickerSet covers:Vector<Document>
                let setCtor3 = d.readUInt32()
                var info = StickerPackInfo()
                var hasInfo = false
                if (setCtor3 == 0x2dd14edc || setCtor3 == 0xeeb46f27) {
                    info = parseStickerSetInfo(d)
                    hasInfo = true
                }
                let coversVCtor = d.readUInt32()
                if (coversVCtor == TLConstructors.VECTOR) {
                    let coversCount = d.readInt32()
                    var ci: Int32 = 0
                    while (ci < coversCount) {
                        let cover = parseStickerDocument(d)
                        if (hasInfo) {
                            if (ci == 0) { info.cover = cover }
                            info.topItems.add(cover)
                        }
                        ci = ci + 1
                    }
                }
                if (hasInfo) { result.packs.add(info) }
            } else if (coverCtor == 0x40d13c0e) {
                // stickerSetFullCovered: set packs keywords documents
                let setCtor4 = d.readUInt32()
                var info = StickerPackInfo()
                var hasInfo = false
                if (setCtor4 == 0x2dd14edc || setCtor4 == 0xeeb46f27) {
                    info = parseStickerSetInfo(d)
                    hasInfo = true
                }
                let packVCtor = d.readUInt32()
                if (packVCtor == TLConstructors.VECTOR) {
                    let packCount = d.readInt32()
                    var pi: Int32 = 0
                    while (pi < packCount) {
                        let packCtor = d.readUInt32()
                        if (packCtor == 0x12b299d4) {
                            let _ = d.readString()
                            let idsVCtor = d.readUInt32()
                            if (idsVCtor == TLConstructors.VECTOR) {
                                let idsCount = d.readInt32()
                                var idi: Int32 = 0
                                while (idi < idsCount) {
                                    let _ = d.readInt64()
                                    idi = idi + 1
                                }
                            }
                        }
                        pi = pi + 1
                    }
                }
                let keywordVCtor = d.readUInt32()
                if (keywordVCtor == TLConstructors.VECTOR) {
                    let keywordCount = d.readInt32()
                    var ki: Int32 = 0
                    while (ki < keywordCount) {
                        let keywordCtor = d.readUInt32()
                        if (keywordCtor == 0xfcfeb29c) {
                            let _ = d.readInt64()
                            let stringsVCtor = d.readUInt32()
                            if (stringsVCtor == TLConstructors.VECTOR) {
                                let stringsCount = d.readInt32()
                                var ksi: Int32 = 0
                                while (ksi < stringsCount) {
                                    let _ = d.readString()
                                    ksi = ksi + 1
                                }
                            }
                        }
                        ki = ki + 1
                    }
                }
                let documentsVCtor = d.readUInt32()
                if (documentsVCtor == TLConstructors.VECTOR) {
                    let documentsCount = d.readInt32()
                    var di: Int32 = 0
                    while (di < documentsCount) {
                        let document = parseStickerDocument(d)
                        if (hasInfo) {
                            if (di == 0) { info.cover = document }
                            if (info.topItems.size < 5) { info.topItems.add(document) }
                        }
                        di = di + 1
                    }
                }
                if (hasInfo) { result.packs.add(info) }
            } else if (coverCtor == 0x77b15d1c) {
                // stickerSetNoCovered: set:StickerSet
                let setCtor5 = d.readUInt32()
                if (setCtor5 == 0x2dd14edc || setCtor5 == 0xeeb46f27) {
                    result.packs.add(parseStickerSetInfo(d))
                }
            }
            si = si + 1
        }
    }
    // unread:Vector<long> — collect for unread badge (P2-378)
    let unreadVCtor = d.readUInt32()
    if (unreadVCtor == TLConstructors.VECTOR) {
        let unreadCount = d.readInt32()
        var ui: Int32 = 0
        while (ui < unreadCount) {
            let unreadId = d.readInt64()
            result.unreadIds.add(unreadId)
            ui = ui + 1
        }
    }
    // unread / premium 直接标到包上：Snapshot 的构造签名有十来个调用点，
    // 为两个布尔去改签名不划算，而 StickerPackInfo 本来就贯穿整条链路。
    for (pack in result.packs) {
        // stickerSetNoCovered 没有 cover document，用 set 自己的 thumb_document_id
        // 合成一个——渲染链路（CustomEmojiImage / resolveCustomEmojiDocument）
        // 只认 documentId，其余字段拿不到也不影响。
        if (pack.cover.documentId == 0 && pack.thumbDocumentId != 0) {
            let synthesized = StickerItem()
            synthesized.documentId = pack.thumbDocumentId
            pack.cover = synthesized
            // 合成项**只当封面**，绝不能混进 topItems：它没有 isCustomEmoji /
            // mimeType / accessHash，一旦进入内容流就是一个「无锁标、可点、
            // 插入空 alt 发不出去、明细一到又消失」的幽灵格子（真机实测）。
        }
        pack.featuredIsPremium = result.isPremium
        for (unreadId in result.unreadIds) {
            if (unreadId == pack.id) { pack.isUnread = true }
        }
    }
    result.success = true
    return result
}

/**
 * messages.getAvailableReactions#18dea0ac hash:int = messages.AvailableReactions
 * 获取可用 reactions（hash 增量）
 */
class StickersGetAvailableReactions <: TLObject {
    var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x18dea0ac }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/**
 * messages.getAvailableEffects#dea20a39 hash:int = messages.AvailableEffects
 * 获取可用 message effects（hash 增量）
 */
class StickersGetAvailableEffects <: TLObject {
    var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xdea20a39 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/**
 * messages.getEmojiGroups#7488ce5b hash:int = messages.EmojiGroups
 * 获取 emoji 分组（hash 增量）
 */
class StickersGetEmojiGroups <: TLObject {
    var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x7488ce5b }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/** messages.getEmojiProfilePhotoGroups#21a548f3 hash:int = messages.EmojiGroups */
class StickersGetEmojiProfilePhotoGroups <: TLObject {
    var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x21a548f3 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/** messages.getEmojiStickerGroups#1dd840f5 hash:int = messages.EmojiGroups */
class StickersGetEmojiStickerGroups <: TLObject {
    var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x1dd840f5 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/**
 * messages.setDefaultReaction#4f47a016 reaction:Reaction = Bool
 * 设置默认 reaction
 * Reaction 内联: reactionEmoji#1b2286b8 emoticon:string
 */
class StickersSetDefaultReaction <: TLObject {
    var reactionEmoticon: String = ""

    public func getConstructorId(): UInt32 { return 0x4f47a016 }

    public func serialize(serializer: TLSerializer) {
        // reactionEmoji#1b2286b8 emoticon:string
        serializer.writeUInt32(0x1b2286b8)
        serializer.writeString(this.reactionEmoticon)
    }
}

/**
 * messages.getSavedReactionTags#3637e05b flags:# peer:flags.0?InputPeer hash:long = messages.SavedReactionTags
 * 获取 savedMessages reaction 标签（不传 peer = 全局 savedMessages）
 */
class StickersGetSavedReactionTags <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x3637e05b }

    public func serialize(serializer: TLSerializer) {
        // flags = 0 (no peer)
        serializer.writeInt32(0)
        serializer.writeInt64(this.hash)
    }
}

/**
 * messages.updateSavedReactionTag#60297dec flags:# reaction:Reaction title:flags.0?string = Bool
 * 更新 savedMessages reaction 标签标题
 * Reaction 内联: reactionEmoji#1b2286b8 emoticon:string
 */
class StickersUpdateSavedReactionTag <: TLObject {
    var reactionEmoticon: String = ""
    var title: String = ""

    public func getConstructorId(): UInt32 { return 0x60297dec }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.title.size > 0) { flags = flags | 1 }
        serializer.writeInt32(flags)
        // reactionEmoji#1b2286b8 emoticon:string
        serializer.writeUInt32(0x1b2286b8)
        serializer.writeString(this.reactionEmoticon)
        if ((flags & 1) != 0) {
            serializer.writeString(this.title)
        }
    }
}

// ==================== Preferences Keys ====================

private let PREF_STORE_STICKERS_CACHE: String = "telegram_stickers_cache"
private let PREF_KEY_REACTIONS_HASH: String = "available_reactions_hash"
private let PREF_KEY_EFFECTS_HASH: String = "available_effects_hash"
private let PREF_KEY_EMOJI_GROUPS_HASH: String = "emoji_groups_hash"
private let PREF_KEY_STICKER_GROUPS_HASH: String = "sticker_groups_hash"

// ==================== Response Models ====================

/**
 * StickerItem — 单个贴纸信息
 * documentAttributeSticker#6319d612 flags:# alt:string stickerset:InputStickerSet mask_coords:flags.0?MaskCoords
 */
public class StickerItem {
    public var documentId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dcId: Int32 = 0
    public var mimeType: String = ""
    public var altEmoji: String = ""
    public var size: Int64 = 0
    public var width: Int32 = 0
    public var height: Int32 = 0
    // documentEmpty#36f8c871 标记：true 表示该 Document 字段为空文档（仅有 id，无
    // access_hash/mime_type/size 等实际内容），调用方应据此跳过对该文档的实际使用
    // （如不渲染图标/不发起下载），但不应因此丢弃整条外层记录（如 availableReaction）。
    public var isEmpty: Bool = false
    public var isCustomEmoji: Bool = false
    public var isFreeEmoji: Bool = false
    public var supportsTextColor: Bool = false
    // iOS TelegramMediaFile.isPremiumSticker: video_thumbs 中存在 type == "f"。
    public var isPremium: Bool = false
    // 所属贴纸包引用。iOS 的 TelegramMediaFile 会保留 StickerPackReference，
    // 预览、收藏和“查看贴纸包”都依赖它，不能在解析 DocumentAttributeSticker 时丢掉。
    public var packId: Int64 = 0
    public var packAccessHash: Int64 = 0
    public var packShortName: String = ""
    /** photoStrippedSize 内嵌微缩图（~300B，响应自带）：iOS immediateThumbnailData
     *  对位——零网络往返即时占位，真帧到达后替换。 */
    public var thumbStripped: Array<Byte> = Array<Byte>(0, repeat: 0)

    public init() {}
}

/** Telegram StickerPack entry: one emoji can map to one or more sticker documents. */
public class StickerEmojiPack {
    public var emoticon: String = ""
    public var documentIds: ArrayList<Int64> = ArrayList<Int64>()

    public init() {}
}

/**
 * StickerPackInfo — 贴纸包基本信息
 * stickerSet#2DD14EDC flags:# ... id:long access_hash:long title:string short_name:string count:int hash:int
 */
public class StickerPackInfo {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var title: String = ""
    public var shortName: String = ""
    public var count: Int32 = 0
    public var hash: Int32 = 0
    public var isAnimated: Bool = false
    public var isVideo: Bool = false
    public var isEmoji: Bool = false
    public var isInstalled: Bool = false
    public var isArchived: Bool = false
    /** iOS featuredStickerPacks 的 unread：包封面上的小红点。 */
    public var isUnread: Bool = false
    /** 所属 featured 响应的 flags.0；决定 trending 分组标题的措辞。 */
    public var featuredIsPremium: Bool = false
    public var cover: StickerItem = StickerItem()
    /**
     * StickerSet.thumb_document_id（flags.8）。
     *
     * 自定义表情包的 featured 列表大量返回 stickerSetNoCovered#77b15d1c——**没有**
     * cover document，封面只能靠这个 id 去取。此前这个字段被 `let _ = d.readInt64()`
     * 读掉就扔了，于是 99 个 featured 表情包里只有 3 个能拿出封面，
     * TRENDING EMOJI 一行只出 3 格（iOS 同账号是 8 格）。
     */
    public var thumbDocumentId: Int64 = 0
    /**
     * iOS FeaturedStickerPackItem.topItems：messages.getFeaturedStickers 的
     * stickerSetMultiCovered / stickerSetFullCovered 本来就带着前几个 document。
     * 此前只留了第一个当封面、其余丢弃，导致精选包分组在拉到全量明细之前是空的。
     */
    public var topItems: ArrayList<StickerItem> = ArrayList<StickerItem>()

    public init() {}
}

/**
 * StickerPackDetail — 贴纸包详情（包含贴纸列表）
 */
public class StickerPackDetail {
    public var info: StickerPackInfo = StickerPackInfo()
    public var stickers: ArrayList<StickerItem> = ArrayList<StickerItem>()
    public var emojiPacks: ArrayList<StickerEmojiPack> = ArrayList<StickerEmojiPack>()
    public var success: Bool = false

    public init() {}
}

/**
 * AllStickersResult — 所有已安装贴纸包列表
 */
public class AllStickersResult {
    public var packs: ArrayList<StickerPackInfo> = ArrayList<StickerPackInfo>()
    public var hash: Int64 = 0
    public var success: Bool = false

    public init() {}
}

/**
 * RecentStickersResult — 最近使用的贴纸
 */
public class RecentStickersResult {
    public var stickers: ArrayList<StickerItem> = ArrayList<StickerItem>()
    public var hash: Int64 = 0
    public var success: Bool = false

    public init() {}
}

/**
 * FavedStickersResult — 收藏的贴纸
 */
public class FavedStickersResult {
    public var stickers: ArrayList<StickerItem> = ArrayList<StickerItem>()
    public var hash: Int64 = 0
    public var success: Bool = false

    public init() {}
}

/**
 * StickerInstallResult — 安装操作结果
 */
public class StickerInstallResult {
    public var success: Bool = false
    public var archived: Bool = false
    public var archivedPacks: ArrayList<StickerPackInfo> = ArrayList<StickerPackInfo>()
    public var errorCode: String = ""

    public init() {}
}

/**
 * ArchivedPacksResult — 归档/搜索贴纸包结果（复用于 getArchivedStickers / searchStickerSets）
 */
public class ArchivedPacksResult {
    public var packs: ArrayList<StickerPackInfo> = ArrayList<StickerPackInfo>()
    public var totalCount: Int32 = 0
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

/**
 * EmojiStickersResult — getStickers 响应（按 emoticon 搜索贴纸）
 */
public class EmojiStickersResult {
    public var stickers: ArrayList<StickerItem> = ArrayList<StickerItem>()
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

public class CustomEmojiSearchResult {
    public var documents: ArrayList<StickerItem> = ArrayList<StickerItem>()
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

/**
 * EmojiKeywordEntry — 单个 emoji 关键词条目
 */
public class EmojiKeywordEntry {
    public var keyword: String = ""
    public var emoticons: ArrayList<String> = ArrayList<String>()
    public var isDeleted: Bool = false

    public init() {}
}

/**
 * EmojiKeywordsDiffResult — getEmojiKeywords / getEmojiKeywordsDifference 响应
 * emojiKeywordsDifference#5cc761bd lang_code:string from_version:int version:int keywords:Vector<EmojiKeyword>
 */
public class EmojiKeywordsDiffResult {
    public var langCode: String = ""
    public var fromVersion: Int32 = 0
    public var version: Int32 = 0
    public var keywords: ArrayList<EmojiKeywordEntry> = ArrayList<EmojiKeywordEntry>()
    public var success: Bool = false

    public init() {}
}

/**
 * AvailableReactionInfo — 单个可用 reaction 信息
 * availableReaction#c077ec01 flags:# inactive:flags.0?true premium:flags.2?true reaction:string title:string ...
 */
public class AvailableReactionInfo {
    public var reaction: String = ""
    public var title: String = ""
    public var isInactive: Bool = false
    public var isPremium: Bool = false
    public var staticIcon: StickerItem = StickerItem()
    public var appearAnimation: StickerItem = StickerItem()
    public var selectAnimation: StickerItem = StickerItem()
    public var activateAnimation: StickerItem = StickerItem()
    public var effectAnimation: StickerItem = StickerItem()
    public var aroundAnimation: StickerItem = StickerItem()
    public var centerIcon: StickerItem = StickerItem()

    public init() {}
}

/**
 * AvailableReactionsResult — getAvailableReactions 响应（含 hash，notModified 标志）
 */
public class AvailableReactionsResult {
    public var reactions: ArrayList<AvailableReactionInfo> = ArrayList<AvailableReactionInfo>()
    public var hash: Int32 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

/**
 * AvailableEffectInfo — 单个可用 effect 信息
 * availableEffect#93c3e27e flags:# premium_required:flags.2?true id:long emoticon:string
 *   static_icon_id:flags.0?long effect_sticker_id:long effect_animation_id:flags.1?long
 */
public class AvailableEffectInfo {
    public var id: Int64 = 0
    public var emoticon: String = ""
    public var isPremiumRequired: Bool = false
    public var effectStickerId: Int64 = 0

    public init() {}
}

/**
 * AvailableEffectsResult — getAvailableEffects 响应
 */
public class AvailableEffectsResult {
    public var effects: ArrayList<AvailableEffectInfo> = ArrayList<AvailableEffectInfo>()
    public var hash: Int32 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

/**
 * EmojiGroupInfo — 单个 emoji 分组
 * emojiGroup#7a9abda9 title:string icon_emoji_id:long emoticons:Vector<string>
 * emojiGroupGreeting#80d26cc7 (同字段)
 * emojiGroupPremium#93bcf34 title:string icon_emoji_id:long (无 emoticons)
 */
public class EmojiGroupInfo {
    public var title: String = ""
    public var iconEmojiId: Int64 = 0
    public var emoticons: ArrayList<String> = ArrayList<String>()
    public var isGreeting: Bool = false
    public var isPremium: Bool = false

    public init() {}
}

/**
 * EmojiGroupsResult — getEmojiGroups 响应
 */
public class EmojiGroupsResult {
    public var groups: ArrayList<EmojiGroupInfo> = ArrayList<EmojiGroupInfo>()
    public var hash: Int32 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

/**
 * SavedReactionTagInfo — 单个 savedReactionTag
 * savedReactionTag#cb6ff828 flags:# reaction:Reaction title:flags.0?string count:int
 */
public class SavedReactionTagInfo {
    public var reactionEmoticon: String = ""
    public var title: String = ""
    public var count: Int32 = 0

    public init() {}
}

/**
 * SavedReactionTagsResult — getSavedReactionTags 响应
 */
public class SavedReactionTagsResult {
    public var tags: ArrayList<SavedReactionTagInfo> = ArrayList<SavedReactionTagInfo>()
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

// ==================== Response Parsers ====================

/**
 * 解析 stickerSet 构造器（不含前置构造器 ID）
 * stickerSet#2dd14edc flags:# installed_date:flags.0?int archived:flags.1?true official:flags.2?true
 *   masks:flags.3?true thumbs:flags.4?Vector<PhotoSize> animated:flags.5?true videos:flags.6?true
 *   emojis:flags.7?true thumb_document_id:flags.8?long textColor:flags.9?true channelEmojiStatus:flags.10?true
 *   id:long access_hash:long title:string short_name:string
 *   thumb_dc_id:flags.4?int thumb_version:flags.4?int count:int hash:int
 */
private func parseStickerSetInfo(d: TLDeserializer): StickerPackInfo {
    let info = StickerPackInfo()
    let flags = d.readInt32()
    // flags.0 installed_date?int
    if ((flags & 1) != 0) {
        let _ = d.readInt32()
        info.isInstalled = true
    }
    info.isArchived  = (flags & 2)   != 0  // flags.1
    info.isAnimated  = (flags & 32)  != 0  // flags.5
    info.isVideo     = (flags & 64)  != 0  // flags.6
    info.isEmoji     = (flags & 128) != 0  // flags.7
    info.id = d.readInt64()
    info.accessHash = d.readInt64()
    info.title = d.readString()
    info.shortName = d.readString()
    // thumbs (flags.4 = bit 16): Vector<PhotoSize>
    if ((flags & 16) != 0) { skipBoxedVector(d) }
    // thumb_dc_id:flags.4?int, thumb_version:flags.4?int
    if ((flags & 16) != 0) {
        let _ = d.readInt32()
        let _ = d.readInt32()
    }
    // thumb_document_id:flags.8?long
    if ((flags & 256) != 0) { info.thumbDocumentId = d.readInt64() }
    info.count = d.readInt32()
    info.hash = d.readInt32()
    return info
}

/**
 * 与 core/mtproto/TLResponses.cj 的 toHex32() 同源实现（该文件未对外 public，本文件跨包
 * 无法直接调用，故按 skipInputPeer() 的既有 Hilog.info+toHex32 范本在本文件内镜像一份，
 * 供本文件的 unknown-ctor 兜底分支做可观测性日志格式化）。
 */
private func toHex32Local(v: UInt32): String {
    let hexChars = "0123456789abcdef"
    let hexRunes = hexChars.toRuneArray()
    var result = ""
    var remaining = v
    for (_i in 0..8) {
        let nibble = Int64((remaining >> 28) & 0xF)
        result = result + hexRunes[nibble].toString()
        remaining = remaining << 4
    }
    return result
}

/**
 * 跳过 InputStickerSet (boxed)，telegram_api.tl:660-670 全部 10 个变体
 *   inputStickerSetEmpty#ffb62b95                          (无字段)
 *   inputStickerSetID#9de7a269 id:long access_hash:long
 *   inputStickerSetShortName#861cc8a0 short_name:string
 *   inputStickerSetAnimatedEmoji#28703c8                   (无字段)
 *   inputStickerSetDice#e67f520e emoticon:string
 *   inputStickerSetAnimatedEmojiAnimations#cde3739         (无字段)
 *   inputStickerSetPremiumGifts#c88b3b02                   (无字段)
 *   inputStickerSetEmojiGenericAnimations#4c4d4ce          (无字段)
 *   inputStickerSetEmojiDefaultStatuses#29d0f5ee           (无字段)
 *   inputStickerSetEmojiDefaultTopicIcons#44c1f8e9         (无字段)
 *   inputStickerSetEmojiChannelDefaultStatuses#49748553    (无字段)
 */
private func skipInputStickerSet(d: TLDeserializer) {
    let ctor = d.readUInt32()
    if (ctor == 0xffb62b95 || ctor == 0x028703c8 || ctor == 0xcde3739 ||
        ctor == 0xc88b3b02 || ctor == 0x4c4d4ce || ctor == 0x29d0f5ee ||
        ctor == 0x44c1f8e9 || ctor == 0x49748553) {
        return // no fields
    }
    if (ctor == 0x9de7a269) {
        let _ = d.readInt64()  // id
        let _ = d.readInt64()  // access_hash
        return
    }
    if (ctor == 0x861cc8a0) {
        let _ = d.readString() // short_name
        return
    }
    if (ctor == 0xe67f520e) {
        let _ = d.readString() // emoticon
        return
    }
    // Unknown InputStickerSet variant — can't skip safely, but avoid crash
    Hilog.info(0, "CjTelegram", "[skipInputStickerSet] Unknown InputStickerSet ctor: 0x${toHex32Local(ctor)}, cannot safely skip")
}

/** 读取并保留 InputStickerSet 引用；未知变体仍按原有安全跳过策略处理。 */
private func parseInputStickerSetReference(d: TLDeserializer, item: StickerItem) {
    let ctor = d.readUInt32()
    if (ctor == 0x9de7a269) {
        item.packId = d.readInt64()
        item.packAccessHash = d.readInt64()
        return
    }
    if (ctor == 0x861cc8a0) {
        item.packShortName = d.readString()
        return
    }
    if (ctor == 0xe67f520e) {
        let _ = d.readString()
        return
    }
    if (ctor == 0xffb62b95 || ctor == 0x028703c8 || ctor == 0xcde3739 ||
        ctor == 0xc88b3b02 || ctor == 0x4c4d4ce || ctor == 0x29d0f5ee ||
        ctor == 0x44c1f8e9 || ctor == 0x49748553) {
        return
    }
    Hilog.info(0, "CjTelegram",
        "[parseInputStickerSetReference] unknown ctor=0x${toHex32Local(ctor)}")
}

/**
 * 跳过 PhotoSize vector（thumbs 字段）
 * PhotoSize variants: photoSizeEmpty, photoSize, photoCachedSize, photoStrippedSize, photoSizeProgressive, photoPathSize
 */
private func skipPhotoSizeVector(d: TLDeserializer) {
    let _ = collectPhotoSizeVector(d)
}

/** 走完 PhotoSize vector，带出 photoStrippedSize 的内嵌微缩图字节（无则空）。 */
private func collectPhotoSizeVector(d: TLDeserializer): Array<Byte> {
    let collectedStripped = ArrayList<Byte>()
    let ctor = d.readUInt32()
    if (ctor != TLConstructors.VECTOR) { return collectedStripped.toArray() }
    let cnt = d.readInt32()
    var i: Int32 = 0
    while (i < cnt) {
        let psCtor = d.readUInt32()
        if (psCtor == 0x0e17e23c) {
            // photoSizeEmpty type:string
            let _ = d.readString()
        } else if (psCtor == 0x75c78e60) {
            // telegram_api.tl:225 photoSize#75c78e60 type:string w:int h:int size:int
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
        } else if (psCtor == 0x021e1ad6) {
            // photoCachedSize type:string w:int h:int bytes:bytes
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readBytes()
        } else if (psCtor == 0xe0b0bc2e) {
            // photoStrippedSize type:string bytes:bytes —— 采集给调用方
            //（iOS immediateThumbnailData 对位；丢掉它 = 预览必须等下载）
            let _ = d.readString()
            let strippedBytes = d.readBytes()
            if (collectedStripped.size == 0 && strippedBytes.size > 0) {
                for (b in strippedBytes) { collectedStripped.add(b) }
            }
        } else if (psCtor == 0xfa3efb95) {
            // photoSizeProgressive type:string w:int h:int sizes:Vector<int>
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let sizesVCtor = d.readUInt32()
            if (sizesVCtor == TLConstructors.VECTOR) {
                let sCount = d.readInt32()
                var si: Int32 = 0
                while (si < sCount) {
                    let _ = d.readInt32()
                    si = si + 1
                }
            }
        } else if (psCtor == 0xd8214d41) {
            // photoPathSize type:string bytes:bytes
            let _ = d.readString()
            let _ = d.readBytes()
        } else {
            // Unknown PhotoSize variant — can't skip safely, but avoid crash
            Hilog.info(0, "CjTelegram", "[skipPhotoSizeVector] Unknown PhotoSize ctor: 0x${toHex32Local(psCtor)}, cannot safely skip")
        }
        i = i + 1
    }
    return collectedStripped.toArray()
}

/**
 * 跳过 VideoSize vector（video_thumbs 字段）
 * videoSize#de33b094 flags:# type:string w:int h:int size:int video_start_ts:flags.0?double
 * videoSizeEmojiMarkup#f85c413c emoji_id:long background_colors:Vector<int>
 */
private func skipVideoSizeVector(d: TLDeserializer): Bool {
    let ctor = d.readUInt32()
    if (ctor != TLConstructors.VECTOR) { return false }
    let cnt = d.readInt32()
    var premium = false
    var i: Int32 = 0
    while (i < cnt) {
        let vsCtor = d.readUInt32()
        if (vsCtor == 0xde33b094) {
            let vsFlags = d.readInt32()
            let sizeType = d.readString()
            if (sizeType == "f") { premium = true }
            let _ = d.readInt32()  // w
            let _ = d.readInt32()  // h
            let _ = d.readInt32()  // size
            if ((vsFlags & 1) != 0) { let _ = d.readInt64() } // video_start_ts as double
        } else if (vsCtor == 0xf85c413c) {
            let _ = d.readInt64() // emoji_id
            let colorVCtor = d.readUInt32()
            if (colorVCtor == TLConstructors.VECTOR) {
                let colorCnt = d.readInt32()
                var ci: Int32 = 0
                while (ci < colorCnt) {
                    let _ = d.readInt32()
                    ci = ci + 1
                }
            }
        }
        // else: unknown variant, stop
        i = i + 1
    }
    return premium
}

/**
 * 解析 boxed vector，跳过整个向量（对 PhotoSize 向量）
 */
private func skipBoxedVector(d: TLDeserializer) {
    skipPhotoSizeVector(d)
}

/**
 * 解析单个 Document（贴纸文件信息）
 * document#8fd4c4d8 flags:# id:long access_hash:long file_reference:bytes date:int
 *            mime_type:string size:long thumbs:flags.0?Vector<PhotoSize>
 *            video_thumbs:flags.1?Vector<VideoSize> dc_id:int attributes:Vector<DocumentAttribute>
 * documentEmpty#36f8c871 id:long = Document;
 *   （仅 4 字节 ctor + 8 字节 id，无其余字段——必须精确消费 8 字节，否则后续字节流 desync）
 */
private func parseStickerDocument(d: TLDeserializer): StickerItem {
    let item = StickerItem()
    let ctor = d.readUInt32()
    if (ctor == 0x36f8c871) {
        // documentEmpty#36f8c871 id:long = Document;
        // 只消费 8 字节 id，不读取 document#8fd4c4d8 独有字段（access_hash/file_reference/
        // mime_type/size/thumbs/dc_id/attributes 等），标记为空文档并保持字节流对齐。
        item.documentId = d.readInt64()
        item.isEmpty = true
        return item
    }
    if (ctor != 0x8fd4c4d8 && ctor != 0x1e5c1b28 && ctor != 0x9ba29cc1) {
        return item
    }
    let flags = d.readInt32()
    item.documentId = d.readInt64()
    item.accessHash = d.readInt64()
    item.fileReference = d.readBytes()
    let _ = d.readInt32() // date
    item.mimeType = d.readString()
    item.size = d.readInt64()
    // thumbs (flags.0) —— 带出内嵌微缩图（iOS immediateThumbnailData 对位）
    if ((flags & 1) != 0) { item.thumbStripped = collectPhotoSizeVector(d) }
    // video_thumbs (flags.1)
    if ((flags & 2) != 0) { item.isPremium = skipVideoSizeVector(d) }
    item.dcId = d.readInt32()
    // attributes: Vector<DocumentAttribute>
    let attrVCtor = d.readUInt32()
    if (attrVCtor == TLConstructors.VECTOR) {
        let attrCount = d.readInt32()
        var ai: Int32 = 0
        while (ai < attrCount) {
            let attrCtor = d.readUInt32()
            if (attrCtor == 0x6319d612) {
                // telegram_api.tl:617 documentAttributeSticker#6319d612
                // flags:# mask:flags.1?true alt:string stickerset:InputStickerSet mask_coords:flags.0?MaskCoords
                let attrFlags = d.readInt32()
                item.altEmoji = d.readString()
                // stickerset InputStickerSet (boxed) — 保留 pack reference
                parseInputStickerSetReference(d, item)
                // mask_coords (flags.0)
                if ((attrFlags & 1) != 0) {
                    // maskCoords#aed6dbb2: n:int x:double y:double zoom:double
                    let _ = d.readInt32()
                    let _ = d.readDouble()
                    let _ = d.readDouble()
                    let _ = d.readDouble()
                }
            } else if (attrCtor == 0x6c37c15c) {
                // telegram_api.tl:615 documentAttributeImageSize#6c37c15c w:int h:int
                item.width = d.readInt32()
                item.height = d.readInt32()
            } else if (attrCtor == 0x11b58939) {
                // telegram_api.tl:616 documentAttributeAnimated#11b58939 (无字段)
            } else if (attrCtor == 0x43c57c48) {
                // telegram_api.tl:618 documentAttributeVideo#43c57c48
                // flags:# round_message:flags.0?true supports_streaming:flags.1?true nosound:flags.3?true
                // duration:double w:int h:int preload_prefix_size:flags.2?int
                // video_start_ts:flags.4?double video_codec:flags.5?string
                let videoFlags = d.readInt32()
                let _ = d.readDouble() // duration
                item.width = d.readInt32()  // w
                item.height = d.readInt32() // h
                if ((videoFlags & 4) != 0) { let _ = d.readInt32() }   // preload_prefix_size (flags.2)
                if ((videoFlags & 16) != 0) { let _ = d.readDouble() } // video_start_ts (flags.4)
                if ((videoFlags & 32) != 0) { let _ = d.readString() } // video_codec (flags.5)
            } else if (attrCtor == 0x9852f9c6) {
                // telegram_api.tl:619 documentAttributeAudio#9852f9c6
                // flags:# voice:flags.10?true duration:int title:flags.0?string
                // performer:flags.1?string waveform:flags.2?bytes
                let audioFlags = d.readInt32()
                let _ = d.readInt32() // duration
                if ((audioFlags & 1) != 0) { let _ = d.readString() }  // title (flags.0)
                if ((audioFlags & 2) != 0) { let _ = d.readString() }  // performer (flags.1)
                if ((audioFlags & 4) != 0) { let _ = d.readBytes() }   // waveform (flags.2)
            } else if (attrCtor == 0x15590068) {
                // telegram_api.tl:620 documentAttributeFilename#15590068 file_name:string
                let _ = d.readString()
            } else if (attrCtor == 0x9801d2f7) {
                // telegram_api.tl:621 documentAttributeHasStickers#9801d2f7 (无字段)
            } else if (attrCtor == 0xfd149899) {
                // telegram_api.tl:622 documentAttributeCustomEmoji#fd149899
                // flags:# free:flags.0?true text_color:flags.1?true alt:string stickerset:InputStickerSet
                let customFlags = d.readInt32()
                item.isCustomEmoji = true
                item.isFreeEmoji = (customFlags & 1) != 0
                item.supportsTextColor = (customFlags & 2) != 0
                item.altEmoji = d.readString()
                parseInputStickerSetReference(d, item) // stickerset
            } else {
                // Unknown attribute — stop parsing attributes to avoid corruption
                Hilog.info(0, "CjTelegram", "[parseStickerDocument] Unknown DocumentAttribute ctor: 0x${toHex32Local(attrCtor)}, stopping attribute parse")
                return item
            }
            ai = ai + 1
        }
    }
    return item
}

/**
 * 解析 messages.stickerSet 响应
 * messages.stickerSet#6e153f16 set:StickerSet packs:Vector<StickerPack> keywords:Vector<StickerKeyword> documents:Vector<Document>
 * messages.stickerSetNotModified#d3f924eb  (hash 未变时返回)
 */
private func parseStickerSetResponse(data: Array<Byte>): StickerPackDetail {
    let result = StickerPackDetail()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    return parseBoxedStickerSet(d)
}

/**
 * Parse a boxed messages.StickerSet from an existing update container. Keeping
 * this parser shared with messages.getStickerSet prevents updateNewStickerSet
 * from being treated as an opaque update that forces a getDifference replay.
 */
public func parseStickerSetUpdate(d: TLDeserializer): StickerPackDetail {
    return parseBoxedStickerSet(d)
}

private func parseBoxedStickerSet(d: TLDeserializer): StickerPackDetail {
    let result = StickerPackDetail()
    let ctor = d.readUInt32()
    // messages.stickerSetNotModified
    if (ctor == 0xd3f924eb) {
        result.success = true
        return result
    }
    // messages.stickerSet#6e153f16
    if (ctor != 0x6e153f16) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected stickerSet ctor")
        return result
    }
    // set: StickerSet (boxed)
    let setCtor = d.readUInt32()
    if (setCtor == 0x2dd14edc || setCtor == 0xeeb46f27) {
        result.info = parseStickerSetInfo(d)
    }
    // packs: Vector<StickerPack> — authoritative emoji→document mapping
    let packVCtor = d.readUInt32()
    if (packVCtor == TLConstructors.VECTOR) {
        let packCount = d.readInt32()
        var pi: Int32 = 0
        while (pi < packCount) {
            // stickerPack#12b299d4 emoticon:string documents:Vector<long>
            let packCtor = d.readUInt32()
            if (packCtor == 0x12b299d4) {
                let emojiPack = StickerEmojiPack()
                emojiPack.emoticon = d.readString()
                let docVCtor = d.readUInt32()
                if (docVCtor == TLConstructors.VECTOR) {
                    let docCount = d.readInt32()
                    var di: Int32 = 0
                    while (di < docCount) {
                        emojiPack.documentIds.add(d.readInt64())
                        di = di + 1
                    }
                }
                result.emojiPacks.add(emojiPack)
            }
            pi = pi + 1
        }
    }
    // keywords: Vector<StickerKeyword> — skip
    // stickerKeyword#fcfeb29c document_id:long keyword:Vector<string>
    let kwVCtor = d.readUInt32()
    if (kwVCtor == TLConstructors.VECTOR) {
        let kwCount = d.readInt32()
        var ki: Int32 = 0
        while (ki < kwCount) {
            let kwCtor = d.readUInt32()
            if (kwCtor == 0xfcfeb29c) {
                let _ = d.readInt64() // document_id
                // keywords: Vector<string>
                let kwStrVCtor = d.readUInt32()
                if (kwStrVCtor == TLConstructors.VECTOR) {
                    let kwStrCount = d.readInt32()
                    var ks: Int32 = 0
                    while (ks < kwStrCount) {
                        let _ = d.readString()
                        ks = ks + 1
                    }
                }
            }
            ki = ki + 1
        }
    }
    // documents: Vector<Document>
    let docVCtor = d.readUInt32()
    if (docVCtor == TLConstructors.VECTOR) {
        let docCount = d.readInt32()
        var di: Int32 = 0
        while (di < docCount) {
            let item = parseStickerDocument(d)
            if (item.documentId != 0 && !item.isEmpty) {
                // 部分服务端 Document 使用 inputStickerSetEmpty；包详情本身仍能提供
                // 权威引用，补回后长按菜单可直接打开对应贴纸包。
                if (item.packId == 0) {
                    item.packId = result.info.id
                    item.packAccessHash = result.info.accessHash
                    item.packShortName = result.info.shortName
                }
                result.stickers.add(item)
            }
            di = di + 1
        }
    }
    result.success = true
    return result
}

/**
 * Persist Telegram's built-in animated-emoji indexes as their original TL
 * response. iOS reads these packs from Postbox immediately and actualizes them
 * later; keeping the lossless response gives Harmony the same cold-start path
 * without inventing a second serializer for StickerPackDetail.
 */
private func builtinStickerSetLegacyCachePath(cacheName: String): String {
    let filesDir = getAppFilesDir()
    return if (filesDir.isEmpty()) { "" } else {
        filesDir + "/builtin_sticker_set_" + cacheName + ".tl"
    }
}

private func builtinStickerSetCachePath(
    cacheName: String, token: EntityKeyboardAccountToken
): String {
    let filesDir = getAppFilesDir()
    let suffix = getEntityKeyboardStore().cacheFileSuffix(token)
    return if (filesDir.isEmpty()) { "" } else {
        filesDir + "/builtin_sticker_set_" + cacheName + "_" + suffix + ".tl"
    }
}

private func cacheBuiltinStickerSetResponse(
    cacheName: String,
    data: Array<Byte>,
    result: StickerPackDetail,
    token: EntityKeyboardAccountToken
): Unit {
    if (!result.success || result.stickers.isEmpty() || data.isEmpty()) { return }
    if (!getEntityKeyboardStore().isCurrent(token)) {
        Hilog.info(0, "CjTelegram", "[StickersService] drop stale built-in set name=${cacheName} generation=${token.generation}")
        return
    }
    synchronized(builtinStickerSetCacheMonitor) {
        let path = builtinStickerSetCachePath(cacheName, token)
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] built-in set cache write failed name=${cacheName}: ${e}")
        }
    }
}

private func loadBuiltinStickerSetResponse(cacheName: String): StickerPackDetail {
    let token = getEntityKeyboardStore().currentToken()
    synchronized(builtinStickerSetCacheMonitor) {
        var path = builtinStickerSetCachePath(cacheName, token)
        if (path.isEmpty()) { return StickerPackDetail() }
        try {
            if (!FileIo.access(path) && getEntityKeyboardStore().canMigrateLegacy(token)) {
                let legacyPath = builtinStickerSetLegacyCachePath(cacheName)
                if (!legacyPath.isEmpty() && FileIo.access(legacyPath)) {
                    path = legacyPath
                }
            }
            if (!FileIo.access(path)) { return StickerPackDetail() }
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return StickerPackDetail() }
            let bytes = Array<Byte>(stat.size, repeat: 0)
            let file = FileIo.open(path, mode: 0o0)
            let readCount = FileIo.read(file.fd, bytes)
            FileIo.close(file)
            if (readCount <= 0) { return StickerPackDetail() }
            let payload = if (readCount == stat.size) { bytes } else {
                Array<Byte>(readCount, { index: Int64 => bytes[index] })
            }
            let result = parseStickerSetResponse(payload)
            if (result.success && !result.stickers.isEmpty()) {
                if (path == builtinStickerSetLegacyCachePath(cacheName)) {
                    let scopedPath = builtinStickerSetCachePath(cacheName, token)
                    let scopedFile = FileIo.open(scopedPath, mode: 0o1101)
                    FileIo.write(scopedFile.fd, payload)
                    FileIo.close(scopedFile)
                    Hilog.info(0, "CjTelegram", "[StickersService] migrated legacy built-in set name=${cacheName} slot=${token.slot}")
                }
                Hilog.info(0, "CjTelegram",
                    "[StickersService] built-in set disk hit name=${cacheName} stickers=${result.stickers.size}")
                return result
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] built-in set cache read failed name=${cacheName}: ${e}")
        }
        return StickerPackDetail()
    }
}

/**
 * 解析 messages.allStickers 响应
 * messages.allStickersNotModified#e86602c3
 * messages.allStickers#cdbbcebb hash:long sets:Vector<StickerSet>
 */
private func parseAllStickersResponse(data: Array<Byte>): AllStickersResult {
    let result = AllStickersResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0xe86602c3) {
        // not modified
        result.success = true
        return result
    }
    if (ctor != 0xcdbbcebb) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected allStickers ctor")
        return result
    }
    result.hash = d.readInt64()
    let setVCtor = d.readUInt32()
    if (setVCtor == TLConstructors.VECTOR) {
        let setCount = d.readInt32()
        var si: Int32 = 0
        while (si < setCount) {
            let setCtor2 = d.readUInt32()
            if (setCtor2 == 0x2dd14edc || setCtor2 == 0xeeb46f27) {
                let info = parseStickerSetInfo(d)
                result.packs.add(info)
            }
            si = si + 1
        }
    }
    result.success = true
    return result
}

/**
 * 解析 messages.recentStickers 响应
 * messages.recentStickersNotModified#b17f890
 * messages.recentStickers#88d37c56 hash:long packs:Vector<StickerPack> stickers:Vector<Document> dates:Vector<int>
 */
private func parseRecentStickersResponse(data: Array<Byte>): RecentStickersResult {
    let result = RecentStickersResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x0b17f890) {
        result.success = true
        return result
    }
    if (ctor != 0x88d37c56) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected recentStickers ctor")
        return result
    }
    result.hash = d.readInt64()
    // packs: Vector<StickerPack> — skip
    let packVCtor = d.readUInt32()
    if (packVCtor == TLConstructors.VECTOR) {
        let packCount = d.readInt32()
        var pi: Int32 = 0
        while (pi < packCount) {
            let packCtor = d.readUInt32()
            if (packCtor == 0x12b299d4) {
                let _ = d.readString()
                let docVCtor = d.readUInt32()
                if (docVCtor == TLConstructors.VECTOR) {
                    let cnt = d.readInt32()
                    var di: Int32 = 0
                    while (di < cnt) {
                        let _ = d.readInt64()
                        di = di + 1
                    }
                }
            }
            pi = pi + 1
        }
    }
    // stickers: Vector<Document>
    let stickerVCtor = d.readUInt32()
    if (stickerVCtor == TLConstructors.VECTOR) {
        let stickerCount = d.readInt32()
        var si: Int32 = 0
        while (si < stickerCount) {
            let item = parseStickerDocument(d)
            if (item.documentId != 0 && !item.isEmpty) {
                result.stickers.add(item)
            }
            si = si + 1
        }
    }
    result.success = true
    return result
}

/**
 * 解析 messages.favedStickers 响应
 * messages.favedStickersNotModified#9e8fa6d3
 * messages.favedStickers#2cb51097 hash:long packs:Vector<StickerPack> stickers:Vector<Document>
 */
private func parseFavedStickersResponse(data: Array<Byte>): FavedStickersResult {
    let result = FavedStickersResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x9e8fa6d3) {
        result.success = true
        return result
    }
    if (ctor != 0x2cb51097) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected favedStickers ctor")
        return result
    }
    result.hash = d.readInt64()
    // packs: Vector<StickerPack> — skip
    let packVCtor = d.readUInt32()
    if (packVCtor == TLConstructors.VECTOR) {
        let packCount = d.readInt32()
        var pi: Int32 = 0
        while (pi < packCount) {
            let packCtor = d.readUInt32()
            if (packCtor == 0x12b299d4) {
                let _ = d.readString()
                let docVCtor = d.readUInt32()
                if (docVCtor == TLConstructors.VECTOR) {
                    let cnt = d.readInt32()
                    var di: Int32 = 0
                    while (di < cnt) {
                        let _ = d.readInt64()
                        di = di + 1
                    }
                }
            }
            pi = pi + 1
        }
    }
    // stickers: Vector<Document>
    let stickerVCtor = d.readUInt32()
    if (stickerVCtor == TLConstructors.VECTOR) {
        let stickerCount = d.readInt32()
        var si: Int32 = 0
        while (si < stickerCount) {
            let item = parseStickerDocument(d)
            if (item.documentId != 0 && !item.isEmpty) {
                result.stickers.add(item)
            }
            si = si + 1
        }
    }
    result.success = true
    return result
}

// ==================== 贴纸面板本地索引缓存 ====================
//
// iOS 的 EmojiPagerContentComponent 先订阅 Postbox 的本地有序列表，再异步
// actualize 云端数据。这里保存原始 TL 响应，既避免重复定义序列化格式，也保证
// Document.file_reference 等字段无损，冷打开面板时可直接解析并显示。

private func stickerPanelLegacyCachePath(cacheName: String): String {
    let filesDir = getAppFilesDir()
    return if (filesDir.isEmpty()) { "" } else { filesDir + "/sticker_panel_" + cacheName + ".tl" }
}

private func stickerPanelCachePath(
    cacheName: String, token: EntityKeyboardAccountToken
): String {
    let filesDir = getAppFilesDir()
    let suffix = getEntityKeyboardStore().cacheFileSuffix(token)
    return if (filesDir.isEmpty()) { "" } else {
        filesDir + "/sticker_panel_" + cacheName + "_" + suffix + ".tl"
    }
}

private func writeStickerPanelCache(
    cacheName: String, data: Array<Byte>, token: EntityKeyboardAccountToken
): Unit {
    if (data.isEmpty()) { return }
    if (!getEntityKeyboardStore().isCurrent(token)) {
        Hilog.info(0, "CjTelegram", "[StickersService] drop stale panel cache ${cacheName} generation=${token.generation}")
        return
    }
    synchronized(stickerPanelCacheMonitor) {
        let path = stickerPanelCachePath(cacheName, token)
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StickersService] panel cache write failed ${cacheName}: ${e}")
        }
    }
}

private func readStickerPanelCache(cacheName: String): Array<Byte> {
    let token = getEntityKeyboardStore().currentToken()
    synchronized(stickerPanelCacheMonitor) {
        var path = stickerPanelCachePath(cacheName, token)
        if (path.isEmpty()) { return Array<Byte>(0, repeat: 0) }
        try {
            if (!FileIo.access(path) && getEntityKeyboardStore().canMigrateLegacy(token)) {
                let legacyPath = stickerPanelLegacyCachePath(cacheName)
                if (!legacyPath.isEmpty() && FileIo.access(legacyPath)) {
                    path = legacyPath
                }
            }
            if (!FileIo.access(path)) { return Array<Byte>(0, repeat: 0) }
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return Array<Byte>(0, repeat: 0) }
            let bytes = Array<Byte>(stat.size, repeat: 0)
            let file = FileIo.open(path, mode: 0o0)
            let readCount = FileIo.read(file.fd, bytes)
            FileIo.close(file)
            if (readCount <= 0) { return Array<Byte>(0, repeat: 0) }
            let payload = if (readCount == stat.size) { bytes } else {
                Array<Byte>(readCount, { index: Int64 => bytes[index] })
            }
            if (path == stickerPanelLegacyCachePath(cacheName)) {
                let scopedPath = stickerPanelCachePath(cacheName, token)
                let scopedFile = FileIo.open(scopedPath, mode: 0o1101)
                FileIo.write(scopedFile.fd, payload)
                FileIo.close(scopedFile)
                Hilog.info(0, "CjTelegram", "[StickersService] migrated legacy panel cache ${cacheName} slot=${token.slot}")
            }
            return payload
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StickersService] panel cache read failed ${cacheName}: ${e}")
            return Array<Byte>(0, repeat: 0)
        }
    }
}

/**
 * 解析 messages.installStickerSet 响应
 * messages.stickerSetInstallResultSuccess#38641628
 * messages.stickerSetInstallResultArchive#35e410a8 sets:Vector<StickerSetCovered>
 */
private func parseStickerInstallResult(data: Array<Byte>): StickerInstallResult {
    let result = StickerInstallResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x38641628) {
        result.success = true
        return result
    }
    if (ctor == 0x35e410a8) {
        result.success = true
        result.archived = true
        let setVCtor = d.readUInt32()
        if (setVCtor == TLConstructors.VECTOR) {
            let setCount = d.readInt32()
            var si: Int32 = 0
            while (si < setCount) {
                // stickerSetCovered#6410a5d2 set:StickerSet cover:Document
                // stickerSetMultiCovered#3407e51b set:StickerSet covers:Vector<Document>
                let coverCtor = d.readUInt32()
                if (coverCtor == 0x6410a5d2) {
                    let setCtor2 = d.readUInt32()
                    if (setCtor2 == 0x2dd14edc || setCtor2 == 0xeeb46f27) {
                        let info = parseStickerSetInfo(d)
                        result.archivedPacks.add(info)
                    }
                    // cover Document — parse and discard
                    let _ = parseStickerDocument(d)
                } else if (coverCtor == 0x3407e51b) {
                    let setCtor3 = d.readUInt32()
                    if (setCtor3 == 0x2dd14edc || setCtor3 == 0xeeb46f27) {
                        let info = parseStickerSetInfo(d)
                        result.archivedPacks.add(info)
                    }
                    // covers:Vector<Document> — parse and discard
                    let coversVCtor = d.readUInt32()
                    if (coversVCtor == TLConstructors.VECTOR) {
                        let coversCount = d.readInt32()
                        var ci: Int32 = 0
                        while (ci < coversCount) {
                            let _ = parseStickerDocument(d)
                            ci = ci + 1
                        }
                    }
                }
                si = si + 1
            }
        }
        return result
    }
    // Bool response (uninstall returns Bool)
    if (ctor == TLConstructors.BOOL_TRUE) {
        result.success = true
        return result
    }
    if (ctor == TLConstructors.BOOL_FALSE) {
        result.errorCode = "INSTALL_FAILED"
        return result
    }
    Hilog.info(0, "CjTelegram", "[StickersService] Unexpected install result ctor")
    return result
}

/**
 * 从 StickerSetCovered（单/多）中解析贴纸包信息，追加到 result.packs
 * stickerSetCovered#6410a5d2 set:StickerSet cover:Document
 * stickerSetMultiCovered#3407e51b set:StickerSet covers:Vector<Document>
 */
private func parseStickerSetCoveredInto(d: TLDeserializer, result: ArchivedPacksResult) {
    let coverCtor = d.readUInt32()
    if (coverCtor == 0x6410a5d2) {
        // stickerSetCovered: set:StickerSet cover:Document
        let setCtor = d.readUInt32()
        if (setCtor == 0x2dd14edc || setCtor == 0xeeb46f27) {
            let info = parseStickerSetInfo(d)
            result.packs.add(info)
        }
        let _ = parseStickerDocument(d)
    } else if (coverCtor == 0x3407e51b) {
        // stickerSetMultiCovered: set:StickerSet covers:Vector<Document>
        let setCtor = d.readUInt32()
        if (setCtor == 0x2dd14edc || setCtor == 0xeeb46f27) {
            let info = parseStickerSetInfo(d)
            result.packs.add(info)
        }
        let coversVCtor = d.readUInt32()
        if (coversVCtor == TLConstructors.VECTOR) {
            let coversCount = d.readInt32()
            var ci: Int32 = 0
            while (ci < coversCount) {
                let _ = parseStickerDocument(d)
                ci = ci + 1
            }
        }
    }
}

/**
 * 解析 messages.foundStickerSets 响应
 * 外层 wrapper: messages.foundStickerSetsNotModified#d54b65d / messages.foundStickerSets#8af09dd2
 * 内层 sets: Vector<StickerSetCovered>
 */
private func parseFoundStickerSetsResponse(data: Array<Byte>): ArchivedPacksResult {
    let result = ArchivedPacksResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x0d54b65d) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0x8af09dd2) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected foundStickerSets ctor")
        return result
    }
    result.hash = d.readInt64()
    let setVCtor = d.readUInt32()
    if (setVCtor == TLConstructors.VECTOR) {
        let setCount = d.readInt32()
        var si: Int32 = 0
        while (si < setCount) {
            parseStickerSetCoveredInto(d, result)
            si = si + 1
        }
    }
    result.success = true
    return result
}

/**
 * 解析 messages.stickers 响应
 * 外层 wrapper: messages.stickersNotModified#f1749a22 / messages.stickers#30a6ec7e
 * 内层: stickers:Vector<Document>
 */
private func parseStickersResponse(data: Array<Byte>): EmojiStickersResult {
    let result = EmojiStickersResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0xf1749a22) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0x30a6ec7e) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected stickers ctor")
        return result
    }
    result.hash = d.readInt64()
    let stickerVCtor = d.readUInt32()
    if (stickerVCtor == TLConstructors.VECTOR) {
        let stickerCount = d.readInt32()
        var si: Int32 = 0
        while (si < stickerCount) {
            let item = parseStickerDocument(d)
            if (item.documentId != 0 && !item.isEmpty) {
                result.stickers.add(item)
            }
            si = si + 1
        }
    }
    result.success = true
    return result
}

/**
 * 解析 messages.archivedStickers 响应
 * 外层: messages.archivedStickers#4fcba9c8 count:int sets:Vector<StickerSetCovered>
 * 内层: StickerSetCovered (stickerSetCovered / stickerSetMultiCovered)
 */
private func parseArchivedStickersResponse(data: Array<Byte>): ArchivedPacksResult {
    let result = ArchivedPacksResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor != 0x4fcba9c8) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected archivedStickers ctor")
        return result
    }
    result.totalCount = d.readInt32()
    let setVCtor = d.readUInt32()
    if (setVCtor == TLConstructors.VECTOR) {
        let setCount = d.readInt32()
        var si: Int32 = 0
        while (si < setCount) {
            parseStickerSetCoveredInto(d, result)
            si = si + 1
        }
    }
    result.success = true
    return result
}

/**
 * 解析 EmojiKeywordsDifference 响应（getEmojiKeywords / getEmojiKeywordsDifference 共用）
 * 外层: emojiKeywordsDifference#5cc761bd lang_code:string from_version:int version:int keywords:Vector<EmojiKeyword>
 * 内层: emojiKeyword#d5b3b9f9 keyword:string emoticons:Vector<string>
 *       emojiKeywordDeleted#236df622 keyword:string emoticons:Vector<string>
 */
private func parseEmojiKeywordsDiff(data: Array<Byte>): EmojiKeywordsDiffResult {
    let result = EmojiKeywordsDiffResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor != 0x5cc761bd) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected emojiKeywordsDifference ctor")
        return result
    }
    result.langCode = d.readString()
    result.fromVersion = d.readInt32()
    result.version = d.readInt32()
    let kwVCtor = d.readUInt32()
    if (kwVCtor == TLConstructors.VECTOR) {
        let kwCount = d.readInt32()
        var ki: Int32 = 0
        while (ki < kwCount) {
            let kwCtor = d.readUInt32()
            if (kwCtor == 0xd5b3b9f9 || kwCtor == 0x236df622) {
                let entry = EmojiKeywordEntry()
                entry.keyword = d.readString()
                entry.isDeleted = (kwCtor == 0x236df622)
                let emojiVCtor = d.readUInt32()
                if (emojiVCtor == TLConstructors.VECTOR) {
                    let emojiCount = d.readInt32()
                    var ei: Int32 = 0
                    while (ei < emojiCount) {
                        entry.emoticons.add(d.readString())
                        ei = ei + 1
                    }
                }
                result.keywords.add(entry)
            } else {
                return result
            }
            ki = ki + 1
        }
    }
    result.success = true
    return result
}

/**
 * 按 Telegram-iOS ManagedSynchronizeEmojiKeywordsOperations 的语义合并 difference：
 * 新增项只追加不存在的 emoticon；deleted 项只减去服务端指定的 emoticon，条目为空才删除。
 */
private func mergeEmojiKeywordsDifference(
    base: EmojiKeywordsDiffResult, difference: EmojiKeywordsDiffResult
): EmojiKeywordsDiffResult {
    let result = EmojiKeywordsDiffResult()
    result.langCode = difference.langCode
    result.fromVersion = base.version
    result.version = difference.version

    let values = HashMap<String, EmojiKeywordEntry>()
    let order = ArrayList<String>()
    for (entry in base.keywords) {
        let copy = cloneEmojiKeywordEntry(entry)
        values[copy.keyword] = copy
        order.add(copy.keyword)
    }

    for (change in difference.keywords) {
        let normalizedKeyword = if (change.isDeleted) {
            change.keyword
        } else {
            change.keyword.replace(" ", "")
        }
        if (change.isDeleted) {
            if (values.contains(normalizedKeyword)) {
                let current = values[normalizedKeyword]
                let removed = HashSet<String>()
                for (emoticon in change.emoticons) { removed.add(emoticon) }
                let kept = ArrayList<String>()
                for (emoticon in current.emoticons) {
                    if (!removed.contains(emoticon)) { kept.add(emoticon) }
                }
                if (kept.isEmpty()) {
                    let _ = values.remove(normalizedKeyword)
                } else {
                    current.emoticons = kept
                    values[normalizedKeyword] = current
                }
            }
        } else if (!change.emoticons.isEmpty()) {
            if (values.contains(normalizedKeyword)) {
                let current = values[normalizedKeyword]
                let existing = HashSet<String>()
                for (emoticon in current.emoticons) { existing.add(emoticon) }
                for (emoticon in change.emoticons) {
                    if (!existing.contains(emoticon)) {
                        existing.add(emoticon)
                        current.emoticons.add(emoticon)
                    }
                }
                values[normalizedKeyword] = current
            } else {
                let appended = cloneEmojiKeywordEntry(change)
                appended.keyword = normalizedKeyword
                values[normalizedKeyword] = appended
                order.add(normalizedKeyword)
            }
        }
    }

    for (keyword in order) {
        if (values.contains(keyword)) { result.keywords.add(values[keyword]) }
    }
    result.success = true
    return result
}

/** 无网络的合并与二进制往返契约测试；Service 首次创建时执行一次。 */
private func runEmojiKeywordsContractSelfCheck(): Bool {
    let base = EmojiKeywordsDiffResult()
    base.langCode = "en-US"
    base.version = 10
    base.success = true
    let smile = EmojiKeywordEntry()
    smile.keyword = "smile"
    smile.emoticons.add("😀")
    smile.emoticons.add("😃")
    base.keywords.add(smile)
    let obsolete = EmojiKeywordEntry()
    obsolete.keyword = "obsolete"
    obsolete.emoticons.add("❌")
    base.keywords.add(obsolete)

    let difference = EmojiKeywordsDiffResult()
    difference.langCode = "en-US"
    difference.fromVersion = 10
    difference.version = 11
    difference.success = true
    let append = EmojiKeywordEntry()
    append.keyword = "smile"
    append.emoticons.add("😀")
    append.emoticons.add("😁")
    difference.keywords.add(append)
    let remove = EmojiKeywordEntry()
    remove.keyword = "obsolete"
    remove.isDeleted = true
    remove.emoticons.add("❌")
    difference.keywords.add(remove)
    let added = EmojiKeywordEntry()
    added.keyword = "fire"
    added.emoticons.add("🔥")
    difference.keywords.add(added)

    let merged = mergeEmojiKeywordsDifference(base, difference)
    if (!merged.success || merged.version != 11 || merged.keywords.size != 2) { return false }
    var smileValid = false
    var fireValid = false
    for (entry in merged.keywords) {
        if (entry.keyword == "smile") {
            var hasNew = false
            var duplicateCount: Int32 = 0
            for (emoticon in entry.emoticons) {
                if (emoticon == "😁") { hasNew = true }
                if (emoticon == "😀") { duplicateCount = duplicateCount + 1 }
            }
            smileValid = hasNew && duplicateCount == 1 && entry.emoticons.size == 3
        }
        if (entry.keyword == "fire" && entry.emoticons.size == 1) { fireValid = true }
        if (entry.keyword == "obsolete") { return false }
    }
    if (!smileValid || !fireValid) { return false }
    let decoded = parseCachedEmojiKeywords(serializeEmojiKeywords(merged))
    return decoded.success && decoded.version == merged.version &&
        decoded.langCode == merged.langCode && decoded.keywords.size == merged.keywords.size
}

/**
 * 解析 Vector<EmojiLanguage> 响应 (getEmojiKeywordsLanguages)
 * 外层: VECTOR ctor + count + 内层 emojiLanguage#b3fb5361 lang_code:string
 */
private func parseEmojiLanguagesList(data: Array<Byte>): ArrayList<String> {
    let langs = ArrayList<String>()
    if (data.size < 4) { return langs }
    let d = TLDeserializer(data)
    let vecCtor = d.readUInt32()
    if (vecCtor != TLConstructors.VECTOR) { return langs }
    let count = d.readInt32()
    var i: Int32 = 0
    while (i < count) {
        let langCtor = d.readUInt32()
        if (langCtor == 0xb3fb5361) {
            langs.add(d.readString())
        } else {
            return langs
        }
        i = i + 1
    }
    return langs
}

/**
 * 解析 availableReaction#c077ec01 单条（不含外层 ctor）
 * flags:# inactive:flags.0?true premium:flags.2?true reaction:string title:string
 *   static_icon:Document appear_animation:Document select_animation:Document activate_animation:Document effect_animation:Document
 *   around_animation:flags.1?Document center_icon:flags.1?Document
 */
private func parseAvailableReaction(d: TLDeserializer): AvailableReactionInfo {
    let info = AvailableReactionInfo()
    let flags = d.readInt32()
    info.isInactive = (flags & 1) != 0     // flags.0
    info.isPremium  = (flags & 4) != 0     // flags.2
    info.reaction = d.readString()
    info.title = d.readString()
    info.staticIcon = parseStickerDocument(d)
    info.appearAnimation = parseStickerDocument(d)
    info.selectAnimation = parseStickerDocument(d)
    info.activateAnimation = parseStickerDocument(d)
    info.effectAnimation = parseStickerDocument(d)
    // around_animation: flags.1?Document
    if ((flags & 2) != 0) { info.aroundAnimation = parseStickerDocument(d) }
    // center_icon: flags.1?Document
    if ((flags & 2) != 0) { info.centerIcon = parseStickerDocument(d) }
    return info
}

/**
 * 解析 messages.availableReactions 响应
 * 外层 wrapper: messages.availableReactionsNotModified#9f071957 / messages.availableReactions#768e3aad
 * 内层: reactions:Vector<AvailableReaction>，每项 availableReaction#c077ec01
 */
private func parseAvailableReactionsResponse(data: Array<Byte>): AvailableReactionsResult {
    let result = AvailableReactionsResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x9f071957) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0x768e3aad) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected availableReactions ctor")
        return result
    }
    result.hash = d.readInt32()
    let reactionVCtor = d.readUInt32()
    if (reactionVCtor == TLConstructors.VECTOR) {
        let reactionCount = d.readInt32()
        var ri: Int32 = 0
        while (ri < reactionCount) {
            let rCtor = d.readUInt32()
            if (rCtor == 0xc077ec01) {
                let info = parseAvailableReaction(d)
                result.reactions.add(info)
            } else {
                return result
            }
            ri = ri + 1
        }
    }
    result.success = true
    return result
}

private func parseCustomEmojiSearchResponse(data: Array<Byte>): CustomEmojiSearchResult {
    let result = CustomEmojiSearchResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x481eadfa) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0x7a1e11d1) { return result }
    result.hash = d.readInt64()
    let vectorCtor = d.readUInt32()
    if (vectorCtor != TLConstructors.VECTOR) { return result }
    let count = d.readInt32()
    let documentIds = ArrayList<Int64>()
    var i: Int32 = 0
    while (i < count) {
        documentIds.add(d.readInt64())
        i = i + 1
    }
    if (documentIds.size == 0) {
        result.success = true
        return result
    }
    let client = getMTProtoClient()
    let request = StickersGetCustomEmojiDocuments()
    request.documentIds = documentIds
    let docsData = client.sendRequest(request.toBytes())
    if (docsData.size < 8) { return result }
    let docs = TLDeserializer(docsData)
    if (docs.readUInt32() != TLConstructors.VECTOR) { return result }
    let docsCount = docs.readInt32()
    i = 0
    while (i < docsCount) {
        let item = parseStickerDocument(docs)
        if (!item.isEmpty && item.documentId != 0) { result.documents.add(item) }
        i = i + 1
    }
    result.success = true
    return result
}

/**
 * 解析 messages.availableEffects 响应
 * 外层: messages.availableEffectsNotModified#d1ed9a5b / messages.availableEffects#bddb616e
 * 内层: effects:Vector<AvailableEffect> documents:Vector<Document>
 * availableEffect#93c3e27e flags:# premium_required:flags.2?true id:long emoticon:string
 *   static_icon_id:flags.0?long effect_sticker_id:long effect_animation_id:flags.1?long
 */
private func parseAvailableEffectsResponse(data: Array<Byte>): AvailableEffectsResult {
    let result = AvailableEffectsResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0xd1ed9a5b) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0xbddb616e) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected availableEffects ctor")
        return result
    }
    result.hash = d.readInt32()
    let effVCtor = d.readUInt32()
    if (effVCtor == TLConstructors.VECTOR) {
        let effCount = d.readInt32()
        var ei: Int32 = 0
        while (ei < effCount) {
            let effCtor = d.readUInt32()
            if (effCtor == 0x93c3e27e) {
                let effInfo = AvailableEffectInfo()
                let effFlags = d.readInt32()
                effInfo.isPremiumRequired = (effFlags & 4) != 0  // flags.2
                effInfo.id = d.readInt64()
                effInfo.emoticon = d.readString()
                if ((effFlags & 1) != 0) { let _ = d.readInt64() }  // static_icon_id
                effInfo.effectStickerId = d.readInt64()
                if ((effFlags & 2) != 0) { let _ = d.readInt64() }  // effect_animation_id
                result.effects.add(effInfo)
            } else {
                return result
            }
            ei = ei + 1
        }
    }
    // documents:Vector<Document> — skip (sticker documents for effects)
    let docVCtor = d.readUInt32()
    if (docVCtor == TLConstructors.VECTOR) {
        let docCount = d.readInt32()
        var di: Int32 = 0
        while (di < docCount) {
            let _ = parseStickerDocument(d)
            di = di + 1
        }
    }
    result.success = true
    return result
}

/**
 * 解析 messages.emojiGroups 响应
 * 外层: messages.emojiGroupsNotModified#6fb4ad87 / messages.emojiGroups#881fb94b
 * 内层: groups:Vector<EmojiGroup>
 *   emojiGroup#7a9abda9 title:string icon_emoji_id:long emoticons:Vector<string>
 *   emojiGroupGreeting#80d26cc7 title:string icon_emoji_id:long emoticons:Vector<string>
 *   emojiGroupPremium#93bcf34 title:string icon_emoji_id:long (无 emoticons)
 */
private func parseEmojiGroupsResponse(data: Array<Byte>): EmojiGroupsResult {
    let result = EmojiGroupsResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x6fb4ad87) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0x881fb94b) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected emojiGroups ctor")
        return result
    }
    result.hash = d.readInt32()
    let groupVCtor = d.readUInt32()
    if (groupVCtor == TLConstructors.VECTOR) {
        let groupCount = d.readInt32()
        var gi: Int32 = 0
        while (gi < groupCount) {
            let gCtor = d.readUInt32()
            if (gCtor == 0x7a9abda9 || gCtor == 0x80d26cc7) {
                // emojiGroup / emojiGroupGreeting: title icon_emoji_id emoticons
                let grp = EmojiGroupInfo()
                grp.title = d.readString()
                grp.iconEmojiId = d.readInt64()
                grp.isGreeting = gCtor == 0x80d26cc7
                let emojiVCtor = d.readUInt32()
                if (emojiVCtor == TLConstructors.VECTOR) {
                    let emojiCount = d.readInt32()
                    var ei: Int32 = 0
                    while (ei < emojiCount) {
                        grp.emoticons.add(d.readString())
                        ei = ei + 1
                    }
                }
                result.groups.add(grp)
            } else if (gCtor == 0x093bcf34) {
                // emojiGroupPremium#93bcf34 title icon_emoji_id (no emoticons)
                let grp = EmojiGroupInfo()
                grp.title = d.readString()
                grp.iconEmojiId = d.readInt64()
                grp.isPremium = true
                result.groups.add(grp)
            } else {
                return result
            }
            gi = gi + 1
        }
    }
    result.success = true
    return result
}

private func emojiGroupsCachePath(token: EntityKeyboardAccountToken): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    return filesDir + "/emoji_groups_" +
        getEntityKeyboardStore().cacheFileSuffix(token) + ".tl"
}

private func cacheEmojiGroupsResponse(
    data: Array<Byte>, result: EmojiGroupsResult, token: EntityKeyboardAccountToken
): Unit {
    if (!result.success || result.notModified || result.groups.isEmpty() || data.isEmpty()) { return }
    if (!getEntityKeyboardStore().isCurrent(token)) {
        Hilog.info(0, "CjTelegram",
            "[StickersService] drop stale emoji groups generation=${token.generation}")
        return
    }
    synchronized(emojiGroupsCacheMonitor) {
        emojiGroupsMemoryCache = Some(result)
        emojiGroupsMemoryGeneration = token.generation
        let path = emojiGroupsCachePath(token)
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] emoji groups cache write failed: ${e}")
        }
    }
}

private func loadCachedEmojiGroupsResponse(): EmojiGroupsResult {
    let token = getEntityKeyboardStore().currentToken()
    return synchronized(emojiGroupsCacheMonitor) {
        if (emojiGroupsMemoryGeneration == token.generation) {
            match (emojiGroupsMemoryCache) {
                case Some(result) => return result
                case None => ()
            }
        }
        let path = emojiGroupsCachePath(token)
        if (path.isEmpty()) { return EmojiGroupsResult() }
        try {
            if (!FileIo.access(path)) { return EmojiGroupsResult() }
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return EmojiGroupsResult() }
            let data = Array<Byte>(stat.size, repeat: 0)
            let file = FileIo.open(path, mode: 0o0)
            let readCount = FileIo.read(file.fd, data)
            FileIo.close(file)
            if (readCount != stat.size) { return EmojiGroupsResult() }
            let result = parseEmojiGroupsResponse(data)
            if (result.success && !result.groups.isEmpty()) {
                emojiGroupsMemoryCache = Some(result)
                emojiGroupsMemoryGeneration = token.generation
                Hilog.info(0, "CjTelegram",
                    "[StickersService] emoji groups disk hit count=${result.groups.size}")
                return result
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] emoji groups cache read failed: ${e}")
        }
        return EmojiGroupsResult()
    }
}

// Sticker 搜索分类与 GIF/Emoji 分类来自不同 RPC，必须使用独立账号缓存，不能共享 hash。
private func stickerGroupsCachePath(token: EntityKeyboardAccountToken): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    return filesDir + "/sticker_groups_" +
        getEntityKeyboardStore().cacheFileSuffix(token) + ".tl"
}

private func cacheStickerGroupsResponse(
    data: Array<Byte>, result: EmojiGroupsResult, token: EntityKeyboardAccountToken
): Unit {
    if (!result.success || result.notModified || result.groups.isEmpty() || data.isEmpty()) { return }
    if (!getEntityKeyboardStore().isCurrent(token)) { return }
    synchronized(emojiGroupsCacheMonitor) {
        let path = stickerGroupsCachePath(token)
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] sticker groups cache write failed: ${e}")
        }
    }
}

private func loadCachedStickerGroupsResponse(): EmojiGroupsResult {
    let token = getEntityKeyboardStore().currentToken()
    return synchronized(emojiGroupsCacheMonitor) {
        let path = stickerGroupsCachePath(token)
        if (path.isEmpty()) { return EmojiGroupsResult() }
        try {
            if (!FileIo.access(path)) { return EmojiGroupsResult() }
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return EmojiGroupsResult() }
            let data = Array<Byte>(stat.size, repeat: 0)
            let file = FileIo.open(path, mode: 0o0)
            let readCount = FileIo.read(file.fd, data)
            FileIo.close(file)
            if (readCount != stat.size) { return EmojiGroupsResult() }
            return parseEmojiGroupsResponse(data)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] sticker groups cache read failed: ${e}")
            return EmojiGroupsResult()
        }
    }
}

/**
 * 解析 Reaction（boxed，消费外层 ctor）
 * reactionEmoji#1b2286b8 emoticon:string
 * reactionCustomEmoji#8935fc73 document_id:long
 * reactionPaid#523da4eb (无字段)
 * 返回 emoticon 字符串（customEmoji 返回空，paid 返回 "<paid>"）
 */
private func parseReaction(d: TLDeserializer): String {
    let rCtor = d.readUInt32()
    if (rCtor == 0x1b2286b8) {
        return d.readString()
    }
    if (rCtor == 0x8935fc73) {
        let _ = d.readInt64()
        return ""
    }
    if (rCtor == 0x523da4eb) {
        return "<paid>"
    }
    return ""
}

/**
 * 解析 messages.savedReactionTags 响应
 * 外层: messages.savedReactionTagsNotModified#889b59ef / messages.savedReactionTags#3259950a
 * 内层: tags:Vector<SavedReactionTag> hash:long
 * savedReactionTag#cb6ff828 flags:# reaction:Reaction title:flags.0?string count:int
 */
private func parseSavedReactionTagsResponse(data: Array<Byte>): SavedReactionTagsResult {
    let result = SavedReactionTagsResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0x889b59ef) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0x3259950a) {
        Hilog.info(0, "CjTelegram", "[StickersService] Unexpected savedReactionTags ctor")
        return result
    }
    let tagVCtor = d.readUInt32()
    if (tagVCtor == TLConstructors.VECTOR) {
        let tagCount = d.readInt32()
        var ti: Int32 = 0
        while (ti < tagCount) {
            let tagCtor = d.readUInt32()
            if (tagCtor == 0xcb6ff828) {
                let tag = SavedReactionTagInfo()
                let tagFlags = d.readInt32()
                tag.reactionEmoticon = parseReaction(d)
                if ((tagFlags & 1) != 0) {
                    tag.title = d.readString()
                }
                tag.count = d.readInt32()
                result.tags.add(tag)
            } else {
                return result
            }
            ti = ti + 1
        }
    }
    result.hash = d.readInt64()
    result.success = true
    return result
}

// ==================== P2-226: AJpeg 双图解码 + 表征缓存 ====================

/**
 * AJpegParseResult — AJpeg 格式解析结果
 *
 * AJpeg 格式（Telegram 静态贴纸专用）二进制布局（对应 iOS StickerResources.swift imageFromAJpeg）：
 *   bytes[0..3]   : Int32 LE — colorSize（彩色 JPEG 字节长度）
 *   bytes[4..(4+colorSize)-1] : 彩色 JPEG 数据
 *   bytes[(4+colorSize)..(4+colorSize+3)] : Int32 LE — alphaSize（alpha mask JPEG 字节长度）
 *   bytes[(4+colorSize+4)..(4+colorSize+4+alphaSize)-1] : alpha mask JPEG 数据（灰度 JPEG）
 *
 * 两段数据均为合法 JPEG 文件，可直接传入 createImageSource 解码。
 */
public class AJpegParseResult {
    public var colorData: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    public var alphaData: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    public var valid: Bool = false

    public init() {}
}

/**
 * 解析 AJpeg 二进制格式，拆分 colorData 与 alphaData。
 *
 * 对应 iOS imageFromAJpeg(data:) 中的字节拆分逻辑。
 * 鸿蒙侧使用纯 Cangjie 字节数组操作代替 UnsafeBytes memcpy。
 *
 * @param data AJpeg 格式的完整字节数组
 * @return AJpegParseResult，valid=true 表示解析成功
 */
public func parseAJpegBytes(data: Array<UInt8>): AJpegParseResult {
    let result = AJpegParseResult()
    if (data.size < 8) {
        Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] data too short: ${data.size}")
        return result
    }
    // 读取 colorSize（Int32 LE，bytes 0-3）
    let colorSize: Int64 =
        Int64(data[0]) |
        (Int64(data[1]) << 8) |
        (Int64(data[2]) << 16) |
        (Int64(data[3]) << 24)
    if (colorSize < 0 || colorSize > Int64(data.size) - 8) {
        Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] invalid colorSize=${colorSize}")
        return result
    }
    // 读取 alphaSize（Int32 LE，bytes (4+colorSize)..(4+colorSize+3)）
    let alphaOffset: Int64 = 4 + colorSize
    let alphaSize: Int64 =
        Int64(data[alphaOffset]) |
        (Int64(data[alphaOffset + 1]) << 8) |
        (Int64(data[alphaOffset + 2]) << 16) |
        (Int64(data[alphaOffset + 3]) << 24)
    if (alphaSize < 0 || alphaOffset + 4 + alphaSize > Int64(data.size)) {
        Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] invalid alphaSize=${alphaSize}")
        return result
    }
    // 拷贝 colorData
    let colorBuf = Array<UInt8>(colorSize, repeat: 0)
    var i: Int64 = 0
    while (i < colorSize) {
        colorBuf[i] = data[4 + i]
        i = i + 1
    }
    // 拷贝 alphaData
    let alphaBuf = Array<UInt8>(alphaSize, repeat: 0)
    let alphaDataOffset = alphaOffset + 4
    i = 0
    while (i < alphaSize) {
        alphaBuf[i] = data[alphaDataOffset + i]
        i = i + 1
    }
    result.colorData = colorBuf
    result.alphaData = alphaBuf
    result.valid = true
    Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] parsed colorSize=${colorSize} alphaSize=${alphaSize}")
    return result
}

/**
 * 将 JPEG 字节数组解码为 PixelMap。
 *
 * 使用 kit.ImageKit.createImageSource → ImageSource.createPixelMap() 完成解码。
 * 对应 iOS: UIImage(data: jpegData)
 *
 * @param jpegData JPEG 字节数组
 * @return 解码后的 PixelMap；数据无效时返回 None
 */
public func decodeJpegToPixelMap(jpegData: Array<UInt8>): Option<PixelMap> {
    if (jpegData.size == 0) {
        return None
    }
    try {
        let imageSource: ImageSource = createImageSource(jpegData, SourceOptions(0))
        let pixelMap: PixelMap = imageSource.createPixelMap()
        return Some(pixelMap)
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] decodeJpegToPixelMap failed")
        return None
    }
}

/**
 * 将彩色 PixelMap + alpha mask PixelMap 合成为含 alpha 的 BGRA PixelMap。
 *
 * 对应 iOS chatMessageSticker 中的 CGImage.masking 操作：
 *   mask = CGImage(maskWidth: ..., ...provider: alphaImage.dataProvider)
 *   cgImage.masking(mask!)
 *
 * 鸿蒙侧实现：
 *   1. readPixelsToBuffer 读取两幅图的 BGRA 像素 buffer
 *   2. alpha mask 图像为灰度 JPEG，解码后 BGRA 中 B 通道（或 R 通道）即亮度 = alpha 值
 *   3. 对每个像素：将 colorPixelMap 的 alpha 通道设置为 alphaPixelMap 对应像素的亮度值
 *   4. writeBufferToPixels 写回 colorPixelMap
 *
 * 注意：colorPixelMap 和 alphaPixelMap 尺寸可能不同（alpha 通常与 color 等宽等高，
 * Telegram 贴纸保证两者相同，但做安全边界检查）。
 *
 * @param colorPm  彩色 JPEG 解码后的 PixelMap（BGRA_8888，可编辑）
 * @param alphaPm  alpha mask JPEG 解码后的 PixelMap（灰度 → BGRA_8888）
 * @return 合成后的 PixelMap，含 alpha 通道；失败返回 None
 */
public func composeAJpegAlpha(colorPm: PixelMap, alphaPm: PixelMap): Option<PixelMap> {
    try {
        let colorInfo = colorPm.getImageInfo()
        let alphaInfo = alphaPm.getImageInfo()
        let cw = Int64(colorInfo.size.width)
        let ch = Int64(colorInfo.size.height)
        let aw = Int64(alphaInfo.size.width)
        let ah = Int64(alphaInfo.size.height)

        if (cw <= 0 || ch <= 0 || aw <= 0 || ah <= 0) {
            Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] invalid image sizes cw=${cw} ch=${ch} aw=${aw} ah=${ah}")
            return None
        }

        // 读取 color 像素 buffer (BGRA_8888: 4 bytes per pixel)
        let colorBytes: Int64 = cw * ch * 4
        let colorBuf = Array<UInt8>(colorBytes, repeat: 0)
        colorPm.readPixelsToBuffer(colorBuf)

        // 读取 alpha 像素 buffer
        let alphaPixelCount: Int64 = aw * ah
        let alphaBytes: Int64 = alphaPixelCount * 4
        let alphaBuf = Array<UInt8>(alphaBytes, repeat: 0)
        alphaPm.readPixelsToBuffer(alphaBuf)

        // 合成：逐像素设置 alpha 通道
        // 在 BGRA_8888 中：offset+0=B, offset+1=G, offset+2=R, offset+3=A
        // alpha mask 图像的每像素中 R 通道（offset+2）是灰度亮度值，作为 alpha
        var px: Int64 = 0
        while (px < cw * ch) {
            let colorOff: Int64 = px * 4
            // 映射到 alpha 图像的坐标（若尺寸不一致做简单像素映射）
            let cx: Int64 = px % cw
            let cy: Int64 = px / cw
            // 缩放映射到 alpha 图坐标
            let ax: Int64 = cx * aw / cw
            let ay: Int64 = cy * ah / ch
            let alphaOff: Int64 = (ay * aw + ax) * 4
            // alpha 值来自 alpha mask 的 R 通道（灰度 JPEG 在 BGRA 中 R=G=B=亮度）
            let alphaVal: UInt8 = alphaBuf[alphaOff + 2]
            colorBuf[colorOff + 3] = alphaVal
            px = px + 1
        }

        // 写回到 colorPixelMap
        colorPm.writeBufferToPixels(colorBuf)
        return Some(colorPm)

    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] composeAJpegAlpha failed")
        return None
    }
}

/**
 * 完整 AJpeg 解码管道：解析 → 解码 color + alpha → 合成 alpha。
 *
 * 对应 iOS chatMessageSticker 中对 AJpeg 贴纸数据的完整处理路径：
 *   imageFromAJpeg(data) → (colorImage, alphaImage)
 *   → context.draw(cgImage.masking(mask!))
 *
 * @param data AJpeg 格式原始字节（从磁盘缓存 / 网络下载）
 * @return 合成后含 alpha 的 PixelMap；解析或解码失败时返回 None
 */
public func decodeAJpeg(data: Array<UInt8>): Option<PixelMap> {
    let parsed = parseAJpegBytes(data)
    if (!parsed.valid) {
        return None
    }
    let colorOpt = decodeJpegToPixelMap(parsed.colorData)
    match (colorOpt) {
        case None =>
            Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] color JPEG decode failed")
            return None
        case Some(colorPm) =>
            let alphaOpt = decodeJpegToPixelMap(parsed.alphaData)
            match (alphaOpt) {
                case None =>
                    Hilog.info(0, "CjTelegram", "[StickersService/AJpeg] alpha JPEG decode failed, returning color-only")
                    return Some(colorPm)
                case Some(alphaPm) =>
                    return composeAJpegAlpha(colorPm, alphaPm)
            }
    }
}

// ── 表征缓存（StickerAJpegCache）─────────────────────────────────

/**
 * StickerAJpegCache — 已解码贴纸 PixelMap 的内存缓存
 *
 * 对应 iOS postbox.mediaBox.cachedResourceRepresentation 中已缓存表征的内存端。
 * 缓存键（variantKey）对应 CachedStickerAJpegRepresentation.uniqueId()：
 *   格式 "${fileId}-${sizeTag}-${fitzRaw}"
 *   sizeTag: "full" | "small" | "m160"（对应 iOS size=nil / size=(160,160)）
 *   fitzRaw: -1=无修饰, 1=Type12, 2=Type3, 3=Type4, 4=Type5, 5=Type6
 *
 * 容量上限：MAX_ENTRIES 条（超出时清空，避免 OOM）
 * 注：不是 LRU（Cangjie HashMap 无 linked 顺序），用清空策略维持有界。
 */
private let STICKER_AJPEG_CACHE_MAX: Int64 = 64

private var _stickerAJpegCache: HashMap<String, PixelMap> = HashMap<String, PixelMap>()

/**
 * 构建缓存键
 * @param fileId   TelegramMediaFile.id
 * @param sizeTag  "full" | "small" | "m160"
 * @param fitzRaw  -1=无修饰, 1-5=各肤色变体
 */
private func buildStickerVariantKey(fileId: Int64, sizeTag: String, fitzRaw: Int32): String {
    return "${fileId}-${sizeTag}-${fitzRaw}"
}

/**
 * 从内存缓存中获取已解码的贴纸 PixelMap。
 *
 * @param fileId   TelegramMediaFile.id
 * @param sizeTag  "full" | "small" | "m160"
 * @param fitzRaw  -1 = 无修饰
 * @return 命中时返回 PixelMap；未命中返回 None
 */
public func getStickerCachedEntry(fileId: Int64, sizeTag: String, fitzRaw: Int32): Option<PixelMap> {
    let key = buildStickerVariantKey(fileId, sizeTag, fitzRaw)
    match (_stickerAJpegCache.get(key)) {
        case Some(pm) =>
            Hilog.info(0, "CjTelegram", "[StickerAJpegCache] hit key=${key}")
            return Some(pm)
        case None => return None
    }
}

/**
 * 将解码结果写入内存缓存。
 *
 * @param fileId   TelegramMediaFile.id
 * @param sizeTag  "full" | "small" | "m160"
 * @param fitzRaw  -1 = 无修饰
 * @param pm       已解码的 PixelMap
 */
public func putStickerCachedEntry(fileId: Int64, sizeTag: String, fitzRaw: Int32, pm: PixelMap) {
    if (Int64(_stickerAJpegCache.size) >= STICKER_AJPEG_CACHE_MAX) {
        _stickerAJpegCache = HashMap<String, PixelMap>()
        Hilog.info(0, "CjTelegram", "[StickerAJpegCache] evicted all (capacity)")
    }
    let key = buildStickerVariantKey(fileId, sizeTag, fitzRaw)
    _stickerAJpegCache[key] = pm
    Hilog.info(0, "CjTelegram", "[StickerAJpegCache] stored key=${key}")
}

/**
 * 查询或解码贴纸 AJpeg：先查内存缓存，未命中则解码并缓存。
 *
 * 对应 iOS chatMessageStickerDatas 中的 maybeFetched → complete → imageFromAJpeg 路径。
 * 调用方负责提供 AJpeg 原始字节（从 FileDownloadService 获取）。
 *
 * 贴纸变体：
 *   sizeTag = "full"  → 完整贴纸（不缩放），对应 iOS CachedStickerAJpegRepresentation(size: nil)
 *   sizeTag = "small" → ~100x100 缩略图，对应 CachedStickerAJpegRepresentation(size: (160,160))
 *   sizeTag = "m160"  → 160x160 贴纸包封面，对应 chatMessageStickerPackThumbnailData
 *
 * Premium/fitz 变体：
 *   fitzRaw = -1          → 无修饰（普通贴纸）
 *   fitzRaw = 1..5        → 各肤色变体（Type12/3/4/5/6）
 *   变体键在缓存中独立存储，互不干扰。
 *
 * @param fileId    TelegramMediaFile.id（用于缓存键）
 * @param data      AJpeg 格式字节数据（已下载到本地）
 * @param sizeTag   "full" | "small" | "m160"
 * @param fitzRaw   -1=无修饰，1-5=肤色变体
 * @return 解码后含 alpha 的 PixelMap；解码失败返回 None
 */
public func getStickerAJpegPixelMap(
    fileId: Int64,
    data: Array<UInt8>,
    sizeTag: String,
    fitzRaw: Int32
): Option<PixelMap> {
    // 1. 查内存缓存
    let cached = getStickerCachedEntry(fileId, sizeTag, fitzRaw)
    match (cached) {
        case Some(pm) => return Some(pm)
        case None => ()
    }
    // 2. 解码
    Hilog.info(0, "CjTelegram", "[StickerAJpegCache] decode fileId=${fileId} sizeTag=${sizeTag} fitzRaw=${fitzRaw}")
    let decoded = decodeAJpeg(data)
    match (decoded) {
        case None =>
            Hilog.info(0, "CjTelegram", "[StickerAJpegCache] decodeAJpeg returned None fileId=${fileId}")
            return None
        case Some(pm) =>
            // 3. 写入缓存
            putStickerCachedEntry(fileId, sizeTag, fitzRaw, pm)
            return Some(pm)
    }
}

// ==================== Service Singleton ====================

private var _stickersServiceInstance: Option<StickersService> = None
private let _stickersServiceInstanceMonitor = Monitor()

public func getStickersService(): StickersService {
    return synchronized(_stickersServiceInstanceMonitor) {
        match (_stickersServiceInstance) {
            case Some(inst) => inst
            case None =>
                let keywordContractValid = runEmojiKeywordsContractSelfCheck()
                Hilog.info(0, "CjTelegram",
                    "[StickersService] emoji keywords contract self-check=${keywordContractValid}")
                let inst = StickersService()
                _stickersServiceInstance = Some(inst)
                inst
        }
    }
}

// ==================== StickersService ====================

/**
 * SendStickerResult — sendSticker 操作结果
 *
 * P2-385: 贴纸通过 messages.sendMedia(inputMediaDocument) 发送，
 * 响应可能是 updateShortSentMessage(含 messageId) 或 Updates 容器(无具体 messageId)。
 */
public class SendStickerResult {
    public var success: Bool = false
    public var messageId: Int32 = 0

    public init() {}
}

/**
 * StickersService — 贴纸引擎服务层
 *
 * 封装 TelegramEngine.Stickers 的全部 TL 方法调用：
 *   messages.getStickerSet     — 获取贴纸包详情
 *   messages.getAllStickers    — 获取所有已安装贴纸包
 *   messages.getRecentStickers — 获取最近使用贴纸
 *   messages.getFavedStickers  — 获取收藏贴纸
 *   messages.installStickerSet   — 安装贴纸包
 *   messages.uninstallStickerSet — 卸载贴纸包
 *   messages.sendMedia(inputMediaDocument) — 发送贴纸 (P2-385)
 *   messages.faveSticker       — 收藏/取消收藏贴纸 (P2-385)
 *
 * 调用链: StickersService → getMTProtoClient() → MTProtoClient.sendRequest() → MTProto
 */
public class StickersService {
    private var _stickerRand: Random = Random()
    private let presentationSettingsMonitor = Monitor()
    private var largeEmojiGeneration: Int64 = -1
    private var largeEmojiEnabled: Bool = true

    /**
     * 通过 ID 获取贴纸包详情（包含完整贴纸列表）
     * TL: messages.getStickerSet#c8a0ec74 stickerset:InputStickerSet hash:int
     */
    public func getStickerSet(packId: Int64, accessHash: Int64, hash!: Int32 = 0): StickerPackDetail {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetStickerSet()
        req.inputType = "id"
        req.packId = packId
        req.accessHash = accessHash
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getStickerSet id=${packId}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[StickersService] getStickerSet: empty response")
            return StickerPackDetail()
        }
        let result = parseStickerSetResponse(responseData)
        if (result.success && !result.stickers.isEmpty()) {
            writeStickerPanelCache("set_${packId}", responseData, accountToken)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getStickerSet: stickers=${result.stickers.size}, success=${result.success}")
        return result
    }

    /** 面板切包时先读本地详情；网络 getStickerSet 只负责后台刷新。 */
    public func getCachedStickerSet(packId: Int64): StickerPackDetail {
        let data = readStickerPanelCache("set_${packId}")
        if (data.isEmpty()) { return StickerPackDetail() }
        return parseStickerSetResponse(data)
    }

    /**
     * 通过短名称获取贴纸包详情
     * TL: messages.getStickerSet#c8a0ec74 stickerset:InputStickerSet hash:int
     */
    public func getStickerSetByName(shortName: String, hash!: Int32 = 0): StickerPackDetail {
        let client = getMTProtoClient()
        let req = StickersGetStickerSet()
        req.inputType = "shortName"
        req.shortName = shortName
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getStickerSet shortName=${shortName}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[StickersService] getStickerSetByName: empty response")
            return StickerPackDetail()
        }
        let result = parseStickerSetResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getStickerSetByName: stickers=${result.stickers.size}, success=${result.success}")
        return result
    }

    /**
     * 获取 Telegram 内置动态 Emoji 贴纸包。
     * 单独一个 Emoji 的文本消息由客户端在本地映射到此贴纸包中的同名文档。
     */
    public func getCachedAnimatedEmojiSet(): StickerPackDetail {
        return loadBuiltinStickerSetResponse("animated_emoji")
    }

    public func getAnimatedEmojiSet(hash!: Int32 = 0): StickerPackDetail {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetStickerSet()
        req.inputType = "animatedEmoji"
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getStickerSet animatedEmoji")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[StickersService] getAnimatedEmojiSet: empty response")
            return StickerPackDetail()
        }
        let result = parseStickerSetResponse(responseData)
        cacheBuiltinStickerSetResponse("animated_emoji", responseData, result, accountToken)
        Hilog.info(0, "CjTelegram", "[StickersService] getAnimatedEmojiSet: stickers=${result.stickers.size}, emojiPacks=${result.emojiPacks.size}, success=${result.success}")
        return result
    }

    /** Telegram's indexed, full-size effects played around a tapped emoji. */
    public func getCachedAnimatedEmojiAnimationsSet(): StickerPackDetail {
        return loadBuiltinStickerSetResponse("animated_emoji_animations")
    }

    public func getAnimatedEmojiAnimationsSet(hash!: Int32 = 0): StickerPackDetail {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetStickerSet()
        req.inputType = "animatedEmojiAnimations"
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getStickerSet animatedEmojiAnimations")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) { return StickerPackDetail() }
        let result = parseStickerSetResponse(responseData)
        cacheBuiltinStickerSetResponse("animated_emoji_animations", responseData, result, accountToken)
        Hilog.info(0, "CjTelegram", "[StickersService] animatedEmojiAnimations stickers=${result.stickers.size}, emojiPacks=${result.emojiPacks.size}, success=${result.success}")
        return result
    }

    /**
     * 获取所有已安装贴纸包列表
     * TL: messages.getAllStickers#b8a0a1a8 hash:long (iOS -1197432408, serializeInt64)
     */
    public func getAllStickers(hash!: Int64 = 0): AllStickersResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetAllStickers()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getAllStickers hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[StickersService] getAllStickers: empty response")
            return AllStickersResult()
        }
        let result = parseAllStickersResponse(responseData)
        if (result.success && !result.packs.isEmpty()) {
            writeStickerPanelCache("installed", responseData, accountToken)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getAllStickers: packs=${result.packs.size}, success=${result.success}")
        return result
    }

    public func getCachedAllStickers(): AllStickersResult {
        let data = readStickerPanelCache("installed")
        if (data.isEmpty()) { return AllStickersResult() }
        return parseAllStickersResponse(data)
    }

    /** 获取已安装的自定义 Emoji Packs。响应结构与 getAllStickers 相同。 */
    public func getEmojiStickers(hash!: Int64 = 0): AllStickersResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetEmojiStickers()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getEmojiStickers hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return AllStickersResult()
        }
        let result = parseAllStickersResponse(responseData)
        if (result.success && !result.packs.isEmpty()) {
            writeStickerPanelCache("emoji_installed", responseData, accountToken)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getEmojiStickers: packs=${result.packs.size}, success=${result.success}")
        return result
    }

    public func getCachedEmojiStickers(): AllStickersResult {
        let data = readStickerPanelCache("emoji_installed")
        if (data.isEmpty()) { return AllStickersResult() }
        return parseAllStickersResponse(data)
    }

    /** 搜索 custom emoji 并解析对应 Document，供 reaction picker 使用。 */
    public func searchCustomEmoji(emoticon: String, hash!: Int64 = 0): CustomEmojiSearchResult {
        let client = getMTProtoClient()
        let req = StickersSearchCustomEmoji()
        req.emoticon = emoticon
        req.hash = hash
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) { return CustomEmojiSearchResult() }
        let result = parseCustomEmojiSearchResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] searchCustomEmoji count=${result.documents.size}, success=${result.success}")
        return result
    }

    /**
     * AvatarEditorScreen.inputData(subject: .profilePhoto) 的服务端数据源。
     * iOS managedProfilePhotoEmoji 只消费 account.getDefaultProfilePhotoEmojis，
     * 并按 EmojiList.document_id 的原始顺序解析 Document。
     */
    public func getDefaultProfilePhotoEmojis(hash!: Int64 = 0): CustomEmojiSearchResult {
        let req = StickersGetDefaultProfilePhotoEmojis()
        req.hash = hash
        let responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.size == 0) { return CustomEmojiSearchResult() }
        let result = parseCustomEmojiSearchResponse(responseData)
        Hilog.info(0, "CjTelegram",
            "[StickersService] getDefaultProfilePhotoEmojis count=${result.documents.size} success=${result.success}")
        return result
    }

    /**
     * 获取最近使用的贴纸列表
     * TL: messages.getRecentStickers#9da9403b flags:# attached:flags.0?true hash:long
     */
    public func getRecentStickers(attached!: Bool = false, hash!: Int64 = 0): RecentStickersResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetRecentStickers()
        req.attached = attached
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getRecentStickers attached=${attached}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[StickersService] getRecentStickers: empty response")
            return RecentStickersResult()
        }
        let result = parseRecentStickersResponse(responseData)
        if (result.success) {
            writeStickerPanelCache(if (attached) { "recent_attached" } else { "recent" }, responseData, accountToken)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getRecentStickers: count=${result.stickers.size}, success=${result.success}")
        return result
    }

    public func getCachedRecentStickers(attached!: Bool = false): RecentStickersResult {
        let data = readStickerPanelCache(if (attached) { "recent_attached" } else { "recent" })
        if (data.isEmpty()) { return RecentStickersResult() }
        return parseRecentStickersResponse(data)
    }

    /**
     * 获取收藏的贴纸列表
     * TL: messages.getFavedStickers#04f1aaa9 hash:long
     */
    public func getFavedStickers(hash!: Int64 = 0): FavedStickersResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetFavedStickers()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getFavedStickers hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[StickersService] getFavedStickers: empty response")
            return FavedStickersResult()
        }
        let result = parseFavedStickersResponse(responseData)
        if (result.success && !result.stickers.isEmpty()) {
            writeStickerPanelCache("faved", responseData, accountToken)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getFavedStickers: count=${result.stickers.size}, success=${result.success}")
        return result
    }

    public func getCachedFavedStickers(): FavedStickersResult {
        let data = readStickerPanelCache("faved")
        if (data.isEmpty()) { return FavedStickersResult() }
        return parseFavedStickersResponse(data)
    }

    /**
     * 安装贴纸包
     * TL: messages.installStickerSet#c78fe460 stickerset:InputStickerSet archived:Bool
     */
    public func installStickerSet(packId: Int64, accessHash: Int64, archived!: Bool = false): StickerInstallResult {
        let client = getMTProtoClient()
        let req = StickersInstallStickerSet()
        req.packId = packId
        req.accessHash = accessHash
        req.archived = archived
        Hilog.info(0, "CjTelegram", "[StickersService] messages.installStickerSet id=${packId}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            let r = StickerInstallResult()
            r.errorCode = "NETWORK_ERROR"
            return r
        }
        let result = parseStickerInstallResult(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] installStickerSet: success=${result.success}, archived=${result.archived}")
        return result
    }

    /**
     * 卸载/移除贴纸包
     * TL: messages.uninstallStickerSet#f96e55de stickerset:InputStickerSet = Bool
     */
    public func uninstallStickerSet(packId: Int64, accessHash: Int64): StickerInstallResult {
        let client = getMTProtoClient()
        let req = StickersUninstallStickerSet()
        req.packId = packId
        req.accessHash = accessHash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.uninstallStickerSet id=${packId}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            let r = StickerInstallResult()
            r.errorCode = "NETWORK_ERROR"
            return r
        }
        let result = parseStickerInstallResult(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] uninstallStickerSet: success=${result.success}")
        return result
    }

    /**
     * 搜索贴纸包（按关键词）
     * TL: messages.searchStickerSets#35705b8a flags:# exclude_featured:flags.0?true q:string hash:long = messages.FoundStickerSets
     * 外层 wrapper: messages.foundStickerSets#8af09dd2 / foundStickerSetsNotModified#d54b65d
     */
    public func searchStickerSets(query: String, excludeFeatured!: Bool = false, hash!: Int64 = 0): ArchivedPacksResult {
        let client = getMTProtoClient()
        let req = StickersSearchStickerSets()
        req.excludeFeatured = excludeFeatured
        req.q = query
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.searchStickerSets q=${query}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return ArchivedPacksResult()
        }
        let result = parseFoundStickerSetsResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] searchStickerSets: sets=${result.packs.size}, success=${result.success}")
        return result
    }

    /**
     * 通过 emoticon 获取贴纸列表（远程搜索）
     * TL: messages.getStickers#d5a5d3a1 emoticon:string hash:long = messages.Stickers
     * 外层 wrapper: messages.stickers#30a6ec7e / stickersNotModified#f1749a22
     */
    public func getStickers(emoticon: String, hash!: Int64 = 0): EmojiStickersResult {
        let client = getMTProtoClient()
        let req = StickersGetStickersReq()
        req.emoticon = emoticon
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getStickers emoticon=${emoticon}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return EmojiStickersResult()
        }
        let result = parseStickersResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getStickers: count=${result.stickers.size}, success=${result.success}")
        return result
    }

    /**
     * 获取精选/推荐贴纸包列表
     * TL: messages.getFeaturedStickers#64780b14 hash:long = messages.FeaturedStickers
     * iOS: Api42.swift L7187, appendInt32(1685588756) = 0x64780b14
     * 响应: messages.featuredStickers#be382906 flags:# premium:flags.0?true hash:long count:int
     *       sets:Vector<StickerSetCovered> unread:Vector<long>
     *     / messages.featuredStickersNotModified#c6dc0c66 count:int
     */
    public func getFeaturedStickerPacks(hash!: Int64 = 0): FeaturedStickerPacksResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetFeaturedStickers()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getFeaturedStickers hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return FeaturedStickerPacksResult()
        }
        let result = parseFeaturedStickersResponseFull(responseData)
        if (result.success && !result.packs.isEmpty()) {
            writeStickerPanelCache("featured", responseData, accountToken)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getFeaturedStickerPacks: packs=${result.packs.size}, count=${result.count}, success=${result.success}")
        return result
    }

    public func getCachedFeaturedStickerPacks(): FeaturedStickerPacksResult {
        let data = readStickerPanelCache("featured")
        if (data.isEmpty()) { return FeaturedStickerPacksResult() }
        return parseFeaturedStickersResponseFull(data)
    }

    /** 获取 iOS reaction picker 使用的精选自定义 Emoji Packs。 */
    public func getFeaturedEmojiPacks(hash!: Int64 = 0): FeaturedStickerPacksResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetFeaturedEmojiStickers()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getFeaturedEmojiStickers hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) { return FeaturedStickerPacksResult() }
        let result = parseFeaturedStickersResponseFull(responseData)
        if (result.success && !result.packs.isEmpty()) {
            writeStickerPanelCache("emoji_featured", responseData, accountToken)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getFeaturedEmojiPacks: packs=${result.packs.size}, count=${result.count}, success=${result.success}")
        return result
    }

    public func getCachedFeaturedEmojiPacks(): FeaturedStickerPacksResult {
        let data = readStickerPanelCache("emoji_featured")
        if (data.isEmpty()) { return FeaturedStickerPacksResult() }
        return parseFeaturedStickersResponseFull(data)
    }

    /**
     * 获取归档贴纸包列表
     * TL: messages.getArchivedStickers#57f17692 flags:# masks:flags.0?true emojis:flags.1?true offset_id:long limit:int = messages.ArchivedStickers
     * 外层: messages.archivedStickers#4fcba9c8 count:int sets:Vector<StickerSetCovered>
     * 内层 StickerSetCovered: stickerSetCovered#6410a5d2 / stickerSetMultiCovered#3407e51b
     */
    public func getArchivedStickers(masks!: Bool = false, emojis!: Bool = false, offsetId!: Int64 = 0, limit!: Int32 = 100): ArchivedPacksResult {
        let client = getMTProtoClient()
        let req = StickersGetArchivedStickers()
        req.masks = masks
        req.emojis = emojis
        req.offsetId = offsetId
        req.limit = limit
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getArchivedStickers masks=${masks} emojis=${emojis}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return ArchivedPacksResult()
        }
        let result = parseArchivedStickersResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getArchivedStickers: count=${result.packs.size}, success=${result.success}")
        return result
    }

    /**
     * 重排已安装贴纸包顺序
     * TL: messages.reorderStickerSets#78337739 flags:# masks:flags.0?true emojis:flags.1?true order:Vector<long> = Bool
     */
    public func reorderStickerSets(order: ArrayList<Int64>, masks!: Bool = false, emojis!: Bool = false): Bool {
        let client = getMTProtoClient()
        let req = StickersReorderStickerSets()
        req.masks = masks
        req.emojis = emojis
        req.order = order
        Hilog.info(0, "CjTelegram", "[StickersService] messages.reorderStickerSets count=${order.size}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 批量切换贴纸包启用/停用（归档/取消归档）
     * TL: messages.toggleStickerSets#b5052fea flags:# unarchive:flags.0?true archive:flags.1?true
     *     stickersets:Vector<InputStickerSet> = Bool
     * iOS Api42.swift L10186
     * @param archive    true=归档/停用，false=取消归档/启用
     * @param packIds    贴纸包 ID 列表
     * @param accessHashes 对应的 access_hash 列表
     */
    public func toggleStickerSets(packIds: ArrayList<Int64>, accessHashes: ArrayList<Int64>, archive: Bool): Bool {
        let client = getMTProtoClient()
        let req = StickersToggleStickerSets()
        req.packIds = packIds
        req.accessHashes = accessHashes
        req.archive = archive
        req.unarchive = !archive
        Hilog.info(0, "CjTelegram", "[StickersService] messages.toggleStickerSets archive=${archive} count=${packIds.size}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 清除最近使用的贴纸
     * TL: messages.clearRecentStickers#8999602d flags:# attached:flags.0?true = Bool
     */
    public func clearRecentStickers(attached!: Bool = false): Bool {
        let client = getMTProtoClient()
        let req = StickersClearRecentStickers()
        req.attached = attached
        Hilog.info(0, "CjTelegram", "[StickersService] messages.clearRecentStickers attached=${attached}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        return ctor == TLConstructors.BOOL_TRUE
    }

    /** 把本地 Recent 的顺序同步到 Telegram 云端；构造与 iOS Api42.swift 完全一致。 */
    public func saveRecentSticker(sticker: StickerItem, unsave!: Bool = false): Bool {
        let inputDoc = InputDocument()
        inputDoc.id = sticker.documentId
        inputDoc.accessHash = sticker.accessHash
        inputDoc.fileReference = sticker.fileReference
        let req = MessagesSaveRecentSticker()
        req.id = inputDoc
        req.unsave = unsave
        let responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.size < 4) { return false }
        let d = TLDeserializer(responseData)
        return d.readUInt32() == TLConstructors.BOOL_TRUE
    }

    /**
     * 获取 emoji 关键词（完整版，带 lang）
     * TL: messages.getEmojiKeywords#35a0e062 lang_code:string = EmojiKeywordsDifference
     * 外层: emojiKeywordsDifference#5cc761bd lang_code:string from_version:int version:int keywords:Vector<EmojiKeyword>
     * 内层 EmojiKeyword: emojiKeyword#d5b3b9f9 / emojiKeywordDeleted#236df622
     */
    public func getEmojiKeywords(langCode: String): EmojiKeywordsDiffResult {
        let client = getMTProtoClient()
        let req = StickersGetEmojiKeywords()
        req.langCode = langCode
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getEmojiKeywords lang=${langCode}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return EmojiKeywordsDiffResult()
        }
        let result = parseEmojiKeywordsDiff(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getEmojiKeywords: version=${result.version}, count=${result.keywords.size}")
        return result
    }

    /**
     * 获取 emoji 关键词增量更新
     * TL: messages.getEmojiKeywordsDifference#1508b6af lang_code:string from_version:int = EmojiKeywordsDifference
     * 与 getEmojiKeywords 相同响应格式，带版本增量
     * Prefs 缓存: key="stickers_emoji_kw_version_<langCode>" → 版本号
     */
    public func getEmojiKeywordsDifference(langCode: String, fromVersion: Int32): EmojiKeywordsDiffResult {
        let client = getMTProtoClient()
        let req = StickersGetEmojiKeywordsDiff()
        req.langCode = langCode
        req.fromVersion = fromVersion
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getEmojiKeywordsDifference lang=${langCode} fromVersion=${fromVersion}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return EmojiKeywordsDiffResult()
        }
        let result = parseEmojiKeywordsDiff(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getEmojiKeywordsDifference: newVersion=${result.version}, keywords=${result.keywords.size}")
        return result
    }

    /** 只读取账号级 Emoji keywords 完整快照，不触发网络。 */
    public func getCachedEmojiKeywords(langCode: String): EmojiKeywordsDiffResult {
        let token = getEntityKeyboardStore().currentToken()
        return readEmojiKeywordsCache(langCode, token)
    }

    /**
     * iOS 同款缓存优先同步入口：无缓存请求全量，有缓存请求 difference；difference
     * 按 keyword/emoticon 事务语义合并后再原子替换磁盘快照。网络失败时返回旧快照。
     */
    public func synchronizeEmojiKeywords(langCode: String): EmojiKeywordsDiffResult {
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let cached = readEmojiKeywordsCache(langCode, token)
        if (!cached.success) {
            let full = this.getEmojiKeywords(langCode)
            if (full.success && store.isCurrent(token)) {
                writeEmojiKeywordsCache(langCode, full, token)
                this.persistHash(
                    key: "stickers_emoji_kw_version_" + langCode,
                    value: Int64(full.version),
                    token: token
                )
            }
            return full
        }

        let difference = this.getEmojiKeywordsDifference(langCode, cached.version)
        if (!difference.success) { return cached }
        if (!store.isCurrent(token)) { return EmojiKeywordsDiffResult() }
        if (difference.langCode != cached.langCode || difference.fromVersion != cached.version) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] emoji keywords difference base mismatch, requesting full lang=${langCode}")
            let full = this.getEmojiKeywords(langCode)
            if (full.success && store.isCurrent(token)) {
                writeEmojiKeywordsCache(langCode, full, token)
                this.persistHash(
                    key: "stickers_emoji_kw_version_" + langCode,
                    value: Int64(full.version),
                    token: token
                )
            }
            return if (full.success) { full } else { cached }
        }

        let merged = mergeEmojiKeywordsDifference(cached, difference)
        writeEmojiKeywordsCache(langCode, merged, token)
        this.persistHash(
            key: "stickers_emoji_kw_version_" + langCode,
            value: Int64(merged.version),
            token: token
        )
        Hilog.info(0, "CjTelegram",
            "[StickersService] emoji keywords merged lang=${langCode} version=${cached.version}->${merged.version} count=${merged.keywords.size}")
        return merged
    }

    /**
     * 获取支持的 emoji 关键词语言列表
     * TL: messages.getEmojiKeywordsLanguages#4e9963b2 lang_codes:Vector<string> = Vector<EmojiLanguage>
     * 外层: Vector<EmojiLanguage>，内层: emojiLanguage#b3fb5361 lang_code:string
     */
    public func getEmojiKeywordsLanguages(langCodes: ArrayList<String>): ArrayList<String> {
        let client = getMTProtoClient()
        let req = StickersGetEmojiKeywordsLanguages()
        req.langCodes = langCodes
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getEmojiKeywordsLanguages count=${langCodes.size}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return ArrayList<String>()
        }
        return parseEmojiLanguagesList(responseData)
    }

    /**
     * 获取可用 reactions 列表（hash 增量）
     * TL: messages.getAvailableReactions#18dea0ac hash:int = messages.AvailableReactions
     * 外层 wrapper: messages.availableReactions#768e3aad / availableReactionsNotModified#9f071957
     * 内层: availableReaction#c077ec01 flags:# inactive:flags.0?true premium:flags.2?true reaction:string title:string ...
     * Prefs 缓存: hash 用服务端返回值
     */
    public func getAvailableReactions(hash!: Int32 = 0): AvailableReactionsResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetAvailableReactions()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getAvailableReactions hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return AvailableReactionsResult()
        }
        let result = parseAvailableReactionsResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getAvailableReactions: reactions=${result.reactions.size}, notModified=${result.notModified}, success=${result.success}")
        if (result.success && !result.notModified) {
            persistHash(key: PREF_KEY_REACTIONS_HASH, value: Int64(result.hash), token: accountToken)
            cacheAvailableReactionsResponse(responseData, result, accountToken)
        }
        return result
    }

    /**
     * Return the last complete availableReactions payload without network I/O.
     * Telegram-iOS exposes this through AccountContext's replaying signal; the
     * raw TL snapshot preserves all Document access hashes/file references so
     * cold-start reaction artwork can be warmed immediately and refreshed in
     * the background afterwards.
     */
    public func getCachedAvailableReactions(): AvailableReactionsResult {
        return loadCachedAvailableReactionsResponse()
    }

    /**
     * 获取可用 message effects（hash 增量）
     * TL: messages.getAvailableEffects#dea20a39 hash:int = messages.AvailableEffects
     * 外层 wrapper: messages.availableEffects#bddb616e hash:int effects:Vector<AvailableEffect> documents:Vector<Document>
     *             / messages.availableEffectsNotModified#d1ed9a5b
     * 内层: availableEffect#93c3e27e flags:# premium_required:flags.2?true id:long emoticon:string ...
     * Prefs 缓存: hash 用服务端返回值
     */
    public func getAvailableEffects(hash!: Int32 = 0): AvailableEffectsResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let client = getMTProtoClient()
        let req = StickersGetAvailableEffects()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getAvailableEffects hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return AvailableEffectsResult()
        }
        let result = parseAvailableEffectsResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getAvailableEffects: effects=${result.effects.size}, notModified=${result.notModified}, success=${result.success}")
        if (result.success && !result.notModified) {
            persistHash(key: PREF_KEY_EFFECTS_HASH, value: Int64(result.hash), token: accountToken)
        }
        return result
    }

    /**
     * 获取 emoji 分组（hash 增量）
     * TL: messages.getEmojiGroups#7488ce5b hash:int = messages.EmojiGroups
     * 外层 wrapper: messages.emojiGroups#881fb94b / emojiGroupsNotModified#6fb4ad87
     * 内层: emojiGroup#7a9abda9 / emojiGroupGreeting#80d26cc7 / emojiGroupPremium#93bcf34
     * Prefs 缓存: hash 用服务端返回值
     */
    public func getEmojiGroups(hash!: Int32 = 0): EmojiGroupsResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let cached = loadCachedEmojiGroupsResponse()
        let client = getMTProtoClient()
        let req = StickersGetEmojiGroups()
        req.hash = if (cached.success) { cached.hash } else { hash }
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getEmojiGroups hash=${req.hash}")
        var responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return cached
        }
        var result = parseEmojiGroupsResponse(responseData)
        if (result.notModified) {
            if (cached.success) { return cached }
            // Older builds persisted only the hash. A not-modified response then
            // has no payload to display, so recover once with a full request.
            req.hash = 0
            responseData = client.sendRequest(req.toBytes())
            result = parseEmojiGroupsResponse(responseData)
        }
        Hilog.info(0, "CjTelegram", "[StickersService] getEmojiGroups: groups=${result.groups.size}, notModified=${result.notModified}, success=${result.success}")
        if (result.success && !result.notModified) {
            cacheEmojiGroupsResponse(responseData, result, accountToken)
            persistHash(key: PREF_KEY_EMOJI_GROUPS_HASH, value: Int64(result.hash), token: accountToken)
        }
        return result
    }

    /** Disk/memory-only category snapshot used before network actualization. */
    public func getCachedEmojiGroups(): EmojiGroupsResult {
        return loadCachedEmojiGroupsResponse()
    }

    /** AvatarEditorScreen uses the avatar-specific category endpoint, not getEmojiGroups. */
    public func getEmojiProfilePhotoGroups(hash!: Int32 = 0): EmojiGroupsResult {
        let req = StickersGetEmojiProfilePhotoGroups()
        req.hash = hash
        let responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.isEmpty()) { return EmojiGroupsResult() }
        let result = parseEmojiGroupsResponse(responseData)
        Hilog.info(0, "CjTelegram",
            "[StickersService] getEmojiProfilePhotoGroups groups=${result.groups.size} success=${result.success}")
        return result
    }

    /** iOS combinedChatStickers 分类：generic / greeting / premium。 */
    public func getEmojiStickerGroups(hash!: Int32 = 0): EmojiGroupsResult {
        let accountToken = getEntityKeyboardStore().currentToken()
        let cached = loadCachedStickerGroupsResponse()
        let req = StickersGetEmojiStickerGroups()
        req.hash = if (cached.success) { cached.hash } else { hash }
        Hilog.info(0, "CjTelegram",
            "[StickersService] messages.getEmojiStickerGroups hash=${req.hash}")
        var responseData = getMTProtoClient().sendRequest(req.toBytes())
        if (responseData.isEmpty()) { return cached }
        var result = parseEmojiGroupsResponse(responseData)
        if (result.notModified) {
            if (cached.success) { return cached }
            req.hash = 0
            responseData = getMTProtoClient().sendRequest(req.toBytes())
            result = parseEmojiGroupsResponse(responseData)
        }
        if (result.success && !result.notModified) {
            cacheStickerGroupsResponse(responseData, result, accountToken)
            persistHash(
                key: PREF_KEY_STICKER_GROUPS_HASH,
                value: Int64(result.hash),
                token: accountToken
            )
        }
        Hilog.info(0, "CjTelegram",
            "[StickersService] getEmojiStickerGroups groups=${result.groups.size} success=${result.success}")
        return result
    }

    public func getCachedEmojiStickerGroups(): EmojiGroupsResult {
        return loadCachedStickerGroupsResponse()
    }

    /**
     * 设置默认 reaction（快速 reaction）
     * TL: messages.setDefaultReaction#4f47a016 reaction:Reaction = Bool
     * reaction 序列化: reactionEmoji#1b2286b8 emoticon:string / reactionCustomEmoji#8935fc73 document_id:long / reactionPaid#523da4eb
     */
    public func setDefaultReaction(reactionEmoticon: String): Bool {
        let client = getMTProtoClient()
        let req = StickersSetDefaultReaction()
        req.reactionEmoticon = reactionEmoticon
        Hilog.info(0, "CjTelegram", "[StickersService] messages.setDefaultReaction reaction=${reactionEmoticon}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 获取已保存的 reaction 标签（savedMessages reaction 标签）
     * TL: messages.getSavedReactionTags#3637e05b flags:# peer:flags.0?InputPeer hash:long = messages.SavedReactionTags
     * 外层 wrapper: messages.savedReactionTags#3259950a / savedReactionTagsNotModified#889b59ef
     * 内层: savedReactionTag#cb6ff828 flags:# reaction:Reaction title:flags.0?string count:int
     */
    public func getSavedReactionTags(hash!: Int64 = 0): SavedReactionTagsResult {
        let client = getMTProtoClient()
        let req = StickersGetSavedReactionTags()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[StickersService] messages.getSavedReactionTags hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            return SavedReactionTagsResult()
        }
        let result = parseSavedReactionTagsResponse(responseData)
        Hilog.info(0, "CjTelegram", "[StickersService] getSavedReactionTags: tags=${result.tags.size}, notModified=${result.notModified}, success=${result.success}")
        return result
    }

    /**
     * 更新 savedMessage reaction 标签的标题
     * TL: messages.updateSavedReactionTag#60297dec flags:# reaction:Reaction title:flags.0?string = Bool
     */
    public func updateSavedReactionTag(reactionEmoticon: String, title: String): Bool {
        let client = getMTProtoClient()
        let req = StickersUpdateSavedReactionTag()
        req.reactionEmoticon = reactionEmoticon
        req.title = title
        Hilog.info(0, "CjTelegram", "[StickersService] messages.updateSavedReactionTag reaction=${reactionEmoticon}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        return ctor == TLConstructors.BOOL_TRUE
    }

    /**
     * 持久化本地贴纸设置开关到 Preferences（供 StickersSettingsPage 使用）
     * key 任意字符串，value: 1=enabled, -1=disabled
     */
    public func persistLocalSetting(key: String, enabled: Bool) {
        let value: Int64 = if (enabled) { 1 } else { -1 }
        persistHash(key: key, value: value, token: getEntityKeyboardStore().currentToken())
        if (key == "stickers_large_emoji") {
            let token = getEntityKeyboardStore().currentToken()
            synchronized(this.presentationSettingsMonitor) {
                this.largeEmojiGeneration = token.generation
                this.largeEmojiEnabled = enabled
            }
        }
    }

    /**
     * 从 Preferences 读取本地设置开关（供 StickersSettingsPage 使用）
     * 返回: 1=enabled, -1=disabled, 0=not set (default to enabled)
     */
    public func readLocalSetting(key: String): Bool {
        let raw = getCachedHash(key)
        return raw >= 0
    }

    /** Source PresentationData.largeEmoji equivalent, cached per active account. */
    public func isLargeEmojiEnabled(): Bool {
        let token = getEntityKeyboardStore().currentToken()
        return synchronized(this.presentationSettingsMonitor) {
            if (this.largeEmojiGeneration != token.generation) {
                this.largeEmojiEnabled = getCachedHash("stickers_large_emoji") >= 0
                this.largeEmojiGeneration = token.generation
            }
            this.largeEmojiEnabled
        }
    }

    /** Persist an account-scoped integer sticker preference. */
    public func persistLocalIntSetting(key: String, value: Int32): Unit {
        persistHash(key: key, value: Int64(value), token: getEntityKeyboardStore().currentToken())
    }

    /** Read an account-scoped integer sticker preference. Zero means unset. */
    public func readLocalIntSetting(key: String): Int32 {
        return getCachedHash(key)
    }

    public func persistLocalStringSetting(key: String, value: String): Unit {
        let store = getEntityKeyboardStore()
        let scopedKey = store.preferencesKey(key, store.currentToken())
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, PREF_STORE_STICKERS_CACHE)
                    prefs.put(scopedKey, PreferencesValueType.StringData(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[StickersService] persist string preference failed: ${e}")
                }
            case None => ()
        }
    }

    public func readLocalStringSetting(key: String, fallback: String): String {
        let store = getEntityKeyboardStore()
        let scopedKey = store.preferencesKey(key, store.currentToken())
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, PREF_STORE_STICKERS_CACHE)
                    match (prefs.get(scopedKey, PreferencesValueType.StringData(fallback))) {
                        case PreferencesValueType.StringData(value) => return value
                        case _ => return fallback
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[StickersService] read string preference failed: ${e}")
                }
            case None => ()
        }
        return fallback
    }

    /**
     * 从 Preferences 读取缓存的 hash 值（用于 hash 增量请求）
     * 降级：context 未就绪或读取失败 → 返回 0（触发完整刷新）
     */
    public func getCachedHash(key: String): Int32 {
        let store = getEntityKeyboardStore()
        let token = store.currentToken()
        let scopedKey = store.preferencesKey(key, token)
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, PREF_STORE_STICKERS_CACHE)
                    var val = prefs.get(scopedKey, PreferencesValueType.Integer(0))
                    if (!prefs.has(scopedKey) && store.canMigrateLegacy(token) && prefs.has(key)) {
                        val = prefs.get(key, PreferencesValueType.Integer(0))
                        prefs.put(scopedKey, val)
                        prefs.flush()
                        Hilog.info(0, "CjTelegram", "[StickersService] migrated legacy preference key=${key} slot=${token.slot}")
                    }
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return 0
                    }
                } catch (_: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    /**
     * 从 Preferences 读取 emoji keywords 版本号
     * key 格式: "stickers_emoji_kw_version_<langCode>"
     */
    public func getCachedEmojiKeywordsVersion(langCode: String): Int32 {
        let key = "stickers_emoji_kw_version_" + langCode
        return getCachedHash(key)
    }

    /**
     * 持久化 emoji keywords 版本号到 Preferences
     */
    public func persistEmojiKeywordsVersion(langCode: String, version: Int32) {
        let key = "stickers_emoji_kw_version_" + langCode
        persistHash(key: key, value: Int64(version), token: getEntityKeyboardStore().currentToken())
    }

    private func persistHash(
        key!: String, value!: Int64, token!: EntityKeyboardAccountToken
    ) {
        let store = getEntityKeyboardStore()
        if (!store.isCurrent(token)) {
            Hilog.info(0, "CjTelegram", "[StickersService] drop stale preference key=${key} generation=${token.generation}")
            return
        }
        let scopedKey = store.preferencesKey(key, token)
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    let prefs = Preferences.getPreferences(ctx, PREF_STORE_STICKERS_CACHE)
                    prefs.put(scopedKey, PreferencesValueType.Integer(value))
                    prefs.flush()
                } catch (_: Exception) {
                    Hilog.info(0, "CjTelegram", "[StickersService] persistHash failed key=${key}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[StickersService] persistHash: context not ready key=${key}")
        }
    }

    // ==================== P2-385: 贴纸发送 + 收藏 ====================

    private func promoteUsedPack(packId: Int64, emojis: Bool): Unit {
        if (packId == 0 || !readLocalSetting("stickers_dynamic_pack_order")) { return }
        let installed = if (emojis) { getEmojiStickers() } else { getAllStickers() }
        if (!installed.success || installed.packs.isEmpty() || installed.packs[0].id == packId) { return }
        let order = ArrayList<Int64>()
        order.add(packId)
        for (pack in installed.packs) {
            if (pack.id != packId) { order.add(pack.id) }
        }
        if (emojis) {
            let _ = reorderStickerSets(order, emojis: true)
        } else {
            let _ = reorderStickerSets(order)
        }
    }

    /**
     * 发送贴纸消息 (messages.sendMedia + inputMediaDocument)
     *
     * 调用链:
     *   sendSticker → InputDocument(id/accessHash/fileReference)
     *               → InputMediaDocument(id=InputDocument)
     *               → MessagesSendMedia(peer/media/randomId)
     *               → getMTProtoClient().sendRequest()
     *               → parseStickerSendResponse(responseData)
     *
     * TL 布局 (已对 iOS Api42.swift L9403-9413 核验):
     *   messages.sendMedia#0330e77f flags(int32=0) peer(boxed InputPeer)
     *   media(boxed inputMediaDocument#a8763ab5 flags=0 id(boxed inputDocument#1abfb575))
     *   message(string="") randomId(int64)
     *
     * 响应: Updates 四变体 (0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e)
     *       或 updateShortSentMessage#9015e101
     *
     * @param peerType  对话类型 (user/chat/channel)
     * @param peerId    对话 ID
     * @param sticker   贴纸数据 (documentId/accessHash/fileReference 取自 StickerItem)
     * @return SendStickerResult (success flag + messageId when available)
     */
    public func sendSticker(
        peerType: String,
        peerId: Int64,
        sticker: StickerItem,
        replyToMsgId!: Int32 = 0,
        silent!: Bool = false,
        scheduleDate!: Option<Int32> = None
    ): SendStickerResult {
        Hilog.info(0, "CjTelegram", "[StickersService] sendSticker: peer=${peerType}/${peerId}, docId=${sticker.documentId}")
        let client = getMTProtoClient()

        let inputDoc = InputDocument()
        inputDoc.id = sticker.documentId
        inputDoc.accessHash = sticker.accessHash
        inputDoc.fileReference = sticker.fileReference

        let inputMedia = InputMediaDocument()
        inputMedia.id = inputDoc

        let req = MessagesSendMedia()
        // 回复态下发贴纸，iOS 会把 reply_to 带上（EnqueueMessage 的 replyToMessageId）；
        // 这里此前恒为 0，回复框里选贴纸发出去就变成了普通消息
        req.replyToMsgId = replyToMsgId
        req.peer = buildStickerInputPeer(peerType, peerId)
        req.media = inputMedia
        req.message = ""
        req.randomId = generateStickerRandomId()
        // iOS peek 菜单的 sendSticker(silentPosting:schedule:) 两个参数
        req.silent = silent
        req.scheduleDate = scheduleDate

        let responseData = client.sendRequest(req.toBytes())
        let result = parseStickerSendResponse(responseData)
        if (result.success) {
            promoteUsedPack(sticker.packId, sticker.isCustomEmoji)
        }
        return result
    }

    /**
     * 收藏/取消收藏贴纸 (messages.faveSticker)
     *
     * TL 布局 (已对 iOS Api42.swift L6462-6475 核验):
     *   messages.faveSticker#b9ffc55b
     *   id(boxed inputDocument#1abfb575 id:long accessHash:long fileReference:bytes)
     *   unfave(boxed Bool: boolTrue#997275b5 / boolFalse#bc799737)
     * 响应: boxed Bool
     *
     * @param sticker  贴纸数据 (documentId/accessHash/fileReference)
     * @param unfave   true = 取消收藏，false = 加入收藏
     * @return true 表示服务端返回 boolTrue
     */
    public func faveSticker(sticker: StickerItem, unfave!: Bool = false): Bool {
        Hilog.info(0, "CjTelegram", "[StickersService] faveSticker: docId=${sticker.documentId}, unfave=${unfave}")
        let client = getMTProtoClient()

        let inputDoc = InputDocument()
        inputDoc.id = sticker.documentId
        inputDoc.accessHash = sticker.accessHash
        inputDoc.fileReference = sticker.fileReference

        let req = MessagesFaveSticker()
        req.id = inputDoc
        req.unfave = unfave

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[StickersService] faveSticker: empty response")
            return false
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.BOOL_TRUE) {
            Hilog.info(0, "CjTelegram", "[StickersService] faveSticker: success unfave=${unfave}")
            return true
        }
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[StickersService] faveSticker RPC error: ${errCode} ${errMsg}")
            return false
        }
        Hilog.info(0, "CjTelegram", "[StickersService] faveSticker: ctor=0x${ctor}")
        return false
    }

    /**
     * 构造 InputPeer (user/chat/channel) — 贴纸发送专用
     * 复用 RealMessageService 相同模式，StickersService 无独立 accessHash 缓存
     * 故先从 getPeersService() 查询，查询失败时降级为空 peer（服务端会报错）
     */
    private func buildStickerInputPeer(peerType: String, peerId: Int64): TLObject {
        if (peerType == "user") {
            let peer = InputPeerUser()
            peer.userId = peerId
            return peer
        } else if (peerType == "chat") {
            let peer = InputPeerChat()
            peer.chatId = peerId
            return peer
        } else if (peerType == "channel") {
            let peer = InputPeerChannel()
            peer.channelId = peerId
            return peer
        }
        return InputPeerEmpty()
    }

    /**
     * 生成安全 randomId（避免 UInt64 > Int64.Max 溢出）
     * 与 RealMessageService.generateRandomId() 相同逻辑，局部化避免跨服务依赖
     */
    private func generateStickerRandomId(): Int64 {
        let high = Int64(_stickerRand.nextUInt32() & 0x7FFFFFFF)
        let low = Int64(_stickerRand.nextUInt32())
        return (high << 32) | (low & 0xFFFFFFFF)
    }

    /**
     * 解析 sendSticker 响应 (Updates 四变体 + updateShortSentMessage + RPC error)
     */
    private func parseStickerSendResponse(responseData: Array<Byte>): SendStickerResult {
        let r = SendStickerResult()
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[StickersService] sendSticker: empty response")
            return r
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        if (ctor == 0x9015e101) {
            // updateShortSentMessage: flags id pts pts_count date …
            let _flags = d.readInt32()
            r.messageId = d.readInt32()
            let pts = d.readInt32()
            let ptsCount = d.readInt32()
            let _date = d.readInt32()
            r.success = true
            // 自己发出的消息同样要推进账号 pts（对齐 RealMessageService 同分支）：
            // 不推进则本地每发一条就落后一格，之后的实时 update —— 包括
            // updateReadHistoryOutbox —— 全被判成 gap 丢弃，双勾要等 getDifference
            // 兜底才亮（真机「新发贴纸不第一时间显示已读」根因）。
            getUpdatesManager().applySentMessagePts(pts, ptsCount)
            Hilog.info(0, "CjTelegram",
                "[StickersService] sendSticker: updateShortSentMessage msgId=${r.messageId} pts=${pts}")
            return r
        }
        if (ctor == 0x74ae4240 || ctor == 0x725b04c3 || ctor == 0x78d4dec1 || ctor == 0xe317af7e) {
            r.success = true
            // 与 RealMessageService.parseSendMessageResponse 同款：Updates 是变长
            // TL、遇到不认识的 update 无法跳过，只从首位尝试取 updateMessageID；
            // pts 取不到 → 必须补差，否则留下把后续所有 update 变 gap 的空洞
            //（贴纸发送返回的正是这类完整 Updates，此前直接丢弃 —— 已读迟到根因）。
            if (ctor != 0x78d4dec1) {
                try {
                    let vecCtor = d.readUInt32()
                    if (vecCtor == TLConstructors.VECTOR) {
                        let count = d.readInt32()
                        if (count > 0) {
                            let updateCtor = d.readUInt32()
                            if (updateCtor == 0x4e90bfd6) {
                                r.messageId = d.readInt32()
                                let _randomId = d.readInt64()
                            }
                        }
                    }
                } catch (_: Exception) { () }
            }
            getUpdatesManager().requestDifferenceSync()
            Hilog.info(0, "CjTelegram",
                "[StickersService] sendSticker: Updates ctor=0x${ctor} msgId=${r.messageId} -> differenceSync")
            return r
        }
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[StickersService] sendSticker RPC error: ${errCode} ${errMsg}")
            return r
        }
        r.success = true
        Hilog.info(0, "CjTelegram", "[StickersService] sendSticker: unknown ctor=0x${ctor}, assuming success")
        return r
    }
}

/**
 * 确保贴纸文件已落到本地，返回 file:// 路径（失败返回空串）。
 *
 * 目录与命名跟聊天气泡那条链路（ChatRoomViewModel.resolveStickerMessage）保持一致，
 * 键盘里下过的贴纸，消息里再出现时直接命中，不重复下载。
 * 内部是同步下载，必须在 spawn 出来的线程里调用。
 */
/**
 * 精选表情包的媒体预取 —— iOS MediaBox 行为的对位：featured 明细一到就把
 * 素材文件拉到本地、把首帧渲进磁盘帧缓存，格子上屏时纯读盘、零网络零解码。
 * 没有这层时，每格上屏才触发一次 .tgs 下载 RPC（200~500ms），6 个 worker
 * 排队消化一屏 24 格 —— 「每个主题要等好几秒陆陆续续出来」就是它。
 *
 * 同步函数，调用方须在 spawn 里。下载 6 路并行（网络等待重叠）；
 * 首帧预渲**串行**且经由渲染闸排队，避免抢在播格子的解码配额。
 */
public func prefetchEmojiPackMedia(detail: StickerPackDetail, rasterSize: Int32): Unit {
    let items = ArrayList<StickerItem>()
    for (item in detail.stickers) {
        if (items.size >= 24) { break }   // 只预取折叠态的三行（iOS 键盘也只展示这些）
        if (item.documentId != 0 && !item.isEmpty) { items.add(item) }
    }
    if (items.size == 0) { return }
    // 阶段一：6 路并行确保文件在本地（ensureStickerLocalFile 自带 single-flight）
    let lanes = 6
    let futures = ArrayList<Future<Unit>>()
    var lane = 0
    while (lane < lanes) {
        let laneIndex = lane
        futures.add(spawn {
            var i = laneIndex
            while (i < items.size) {
                let _ = ensureStickerLocalFile(items[i])
                i = i + lanes
            }
        })
        lane = lane + 1
    }
    for (f in futures) { f.get() }
    // 阶段二：缺首帧的串行预渲进磁盘缓存。
    //
    // **只在前台空闲时干活**：预渲与在播格子的 prepare 走同一个渲染闸，
    // 面板开着时抢闸就是「预取期间所有动画一起卡死」（真机实测的形态：
    // 有帧但不动）。iOS 的 AnimationCache 预渲同样在低优先级队列。
    // 面板一关（活跃流=0），这里全速补完。
    // 阶段二改为构建 AnimationCache 全帧缓存（构建器内部逐帧给前台让路，
    // 并顺带写入代表帧）。走统一的后台队列，与格子未命中时的按需构建共用去重。
    // 只预渲静帧，不再排全量动画构建 —— iOS AnimationCache 语义：动画只为
    // 上屏 item 构建（可见格子的 need| 驱动）。磁盘 GC 后全宇宙文件缺失时，
    // 这里曾一次性灌入 2300+ 构建任务，把 worker 淹死、可见格子的紧急构建
    // 排队 5~38s（真机 ChainTrace 实锤），预取全量正是风暴源。
    for (item in items) {
        let path = ensureStickerLocalFile(item)
        if (path.size > 0) {
            let _ = loadStickerStaticFrame(item.documentId, path,
                item.mimeType.contains("webm"), rasterSize, representative: true)
        }
    }
}

/**
 * TL 声明 size 与盘上尺寸差一半以上 → 视为残骸（缩略图误存/断传）。
 * item.size 未知（0）时放行 —— 宁可放过不可错杀。
 */
private func stickerFileLooksTruncated(path: String, item: StickerItem): Bool {
    try {
        let stat = FileIo.stat(path)
        let onDisk = Int64(stat.size)
        // 只认 TL 声明尺寸的硬性不符（差一半以上 = 断传/错文件）。
        // 不要按「小」猜残骸：真机解剖实锤 773B 的 .tgs 是合法单帧
        // Lottie（op=1 静态表情，iOS 同样静态显示），按大小误删会
        // 反复重下正品。
        if (item.size > 0) { return onDisk * 2 < item.size }
        return false
    } catch (_: Exception) {
        return false
    }
}

/**
 * 只查已下载的本地源文件，**绝不触发下载**（动画缓存预热用）。
 * 路径规则与 ensureStickerLocalFile 完全一致；残骸文件视为不存在。
 */
public func stickerLocalFilePeek(item: StickerItem): String {
    if (item.documentId == 0 || item.isEmpty) { return "" }
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    let isLottie = item.mimeType.contains("tgs") || item.mimeType.contains("lottie")
    let isVideo = item.mimeType.contains("webm")
    let dir = if (isLottie) { filesDir + "/anim_stickers" } else { filesDir + "/stickers" }
    let ext = if (isLottie) {
        ".tgs"
    } else if (isVideo) {
        ".webm"
    } else if (item.mimeType.contains("png")) {
        ".png"
    } else {
        ".webp"
    }
    let filePath = dir + "/sticker_${item.documentId}${ext}"
    var exists = false
    try { exists = FileIo.access(filePath) } catch (_: Exception) { exists = false }
    if (exists && !stickerFileLooksTruncated(filePath, item)) { return "file://" + filePath }
    return ""
}

public func ensureStickerLocalFile(item: StickerItem): String {
    if (item.documentId == 0 || item.isEmpty) { return "" }
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }

    let isLottie = item.mimeType.contains("tgs") || item.mimeType.contains("lottie")
    let isVideo = item.mimeType.contains("webm")
    let dir = if (isLottie) { filesDir + "/anim_stickers" } else { filesDir + "/stickers" }
    try { FileIo.mkdir(dir) } catch (_: Exception) {}
    let ext = if (isLottie) {
        ".tgs"
    } else if (isVideo) {
        ".webm"
    } else if (item.mimeType.contains("png")) {
        ".png"
    } else {
        ".webp"
    }
    let filePath = dir + "/sticker_${item.documentId}${ext}"

    var exists = false
    try { exists = FileIo.access(filePath) } catch (_: Exception) { exists = false }
    if (exists && !stickerFileLooksTruncated(filePath, item)) { return "file://" + filePath }
    if (exists) {
        // 盘上是残骸（远小于 TL 声明的 size；真机 1334 个 <8KB 的「.tgs」
        // 实为缩略图/断传尸体，lottie 打开只有 1 帧 → 整包永久静止）。
        // 删掉走重下。
        Hilog.info(0, "CjTelegram",
            "[StickersService] runt sticker file doc=${item.documentId}, redownload")
        try { FileIo.unlink(filePath) } catch (_: Exception) {}
        exists = false
    }

    // Grid、包封面和消息气泡可能同时请求同一 Document。iOS 的 MediaBox 会合并
    // 同资源订阅；这里用 documentId 做同样的 single-flight，避免重复下载与并发写文件。
    synchronized(stickerFileLoadMonitor) {
        while (stickerFileLoading.contains(item.documentId)) {
            stickerFileLoadMonitor.wait(timeout: Duration.millisecond * 50)
        }
        try { exists = FileIo.access(filePath) } catch (_: Exception) { exists = false }
        if (exists && !stickerFileLooksTruncated(filePath, item)) { return "file://" + filePath }
        stickerFileLoading[item.documentId] = true
    }

    var resolvedPath = ""
    try {
        let bytes = getFileDownloadService().downloadDocument(
            item.documentId,
            item.accessHash,
            item.fileReference,
            item.dcId,
            fileSize: item.size,
            priority: 60
        )
        if (!bytes.isEmpty()) {
            let file = FileIo.open(filePath, mode: 0o1101)
            FileIo.write(file.fd, bytes)
            FileIo.close(file)
            resolvedPath = "file://" + filePath
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram",
            "[StickersService] ensureStickerLocalFile failed id=${item.documentId}: ${e}")
    }
    synchronized(stickerFileLoadMonitor) {
        let _ = stickerFileLoading.remove(item.documentId)
        stickerFileLoadMonitor.notifyAll()
    }
    return resolvedPath
}


// ==================== 自定义表情文档解析（按 document_id） ====================
//
// 自定义表情反应（reactionCustomEmoji）只带 document_id，要显示必须先换成 Document
// 才知道 access_hash / file_reference / dc_id。同一个表情会在很多条消息上出现，
// 这里做一层进程内缓存，避免每个气泡各发一次 RPC。

private let customEmojiDocMonitor = Monitor()
private var customEmojiDocCache = HashMap<Int64, StickerItem>()
private var customEmojiDocFetching: Bool = false
// 磁盘持久化状态（对位 iOS Postbox 的 media 表，见 ensureCustomEmojiDocDiskCache）
private var customEmojiDocDiskLoaded: Bool = false
private var customEmojiDocDirty: Bool = false
private var customEmojiDocFlushScheduled: Bool = false

private let CUSTOM_EMOJI_DOC_CACHE_MAGIC: UInt32 = 0x43454431

private func customEmojiDocCachePath(): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    let suffix = getEntityKeyboardStore().cacheFileSuffix(
        getEntityKeyboardStore().currentToken())
    return filesDir + "/custom_emoji_docs_" + suffix + ".tlc"
}

/**
 * 首次触碰 doc 缓存前从磁盘回灌一次。
 *
 * iOS 的 resolveInlineStickers 先查 Postbox（磁盘）、缺的批量 RPC、结果
 * storeMediaIfNotPresent 写回磁盘（TelegramEngineStickers.swift:326-380）——
 * 冷启动零 RPC。我们此前缓存只在内存，重启后面板要重新发批量 RPC；
 * 这个文件就是 Postbox media 表的对位。
 */
private func ensureCustomEmojiDocDiskCache(): Unit {
    synchronized(customEmojiDocMonitor) {
        if (customEmojiDocDiskLoaded) { return }
        customEmojiDocDiskLoaded = true
    }
    let path = customEmojiDocCachePath()
    if (path.isEmpty()) { return }
    try {
        if (!FileIo.access(path)) { return }
        let stat = FileIo.stat(path)
        if (stat.size <= 0) { return }
        let bytes = Array<Byte>(stat.size, repeat: 0)
        let file = FileIo.open(path, mode: 0o0)
        let readCount = FileIo.read(file.fd, bytes)
        FileIo.close(file)
        if (readCount != stat.size) { return }
        let d = TLDeserializer(bytes)
        if (d.readUInt32() != CUSTOM_EMOJI_DOC_CACHE_MAGIC) { return }
        let count = d.readInt32()
        var loaded = 0
        var i: Int32 = 0
        while (i < count) {
            let item = StickerItem()
            item.documentId = d.readInt64()
            item.accessHash = d.readInt64()
            item.fileReference = d.readBytes()
            item.dcId = d.readInt32()
            item.mimeType = d.readString()
            item.altEmoji = d.readString()
            item.size = d.readInt64()
            item.width = d.readInt32()
            item.height = d.readInt32()
            item.isCustomEmoji = d.readBool()
            item.isFreeEmoji = d.readBool()
            item.supportsTextColor = d.readBool()
            synchronized(customEmojiDocMonitor) {
                if (!customEmojiDocCache.contains(item.documentId)) {
                    customEmojiDocCache[item.documentId] = item
                    loaded = loaded + 1
                }
            }
            i = i + 1
        }
        Hilog.info(0, "CjTelegram",
            "[StickersService] custom emoji doc disk hit count=${loaded}")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram",
            "[StickersService] custom emoji doc cache read failed: ${e}")
    }
}

/** 写盘做 500ms 去抖：seed / 批量 RPC 会连续灌入，攒一波一次写。 */
private func scheduleCustomEmojiDocFlush(): Unit {
    synchronized(customEmojiDocMonitor) {
        customEmojiDocDirty = true
        if (customEmojiDocFlushScheduled) { return }
        customEmojiDocFlushScheduled = true
    }
    let _ = spawn {
        sleep(Duration.millisecond * 500)
        let snapshot = ArrayList<StickerItem>()
        synchronized(customEmojiDocMonitor) {
            customEmojiDocFlushScheduled = false
            if (!customEmojiDocDirty) { return }
            customEmojiDocDirty = false
            for ((_, item) in customEmojiDocCache) { snapshot.add(item) }
        }
        let path = customEmojiDocCachePath()
        if (path.isEmpty()) { return }
        let serializer = TLSerializer()
        serializer.writeUInt32(CUSTOM_EMOJI_DOC_CACHE_MAGIC)
        serializer.writeInt32(Int32(snapshot.size))
        for (item in snapshot) {
            serializer.writeInt64(item.documentId)
            serializer.writeInt64(item.accessHash)
            serializer.writeBytes(item.fileReference)
            serializer.writeInt32(item.dcId)
            serializer.writeString(item.mimeType)
            serializer.writeString(item.altEmoji)
            serializer.writeInt64(item.size)
            serializer.writeInt32(item.width)
            serializer.writeInt32(item.height)
            serializer.writeBool(item.isCustomEmoji)
            serializer.writeBool(item.isFreeEmoji)
            serializer.writeBool(item.supportsTextColor)
        }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, serializer.getBytes())
            FileIo.close(file)
            Hilog.info(0, "CjTelegram",
                "[StickersService] custom emoji doc cache flushed count=${snapshot.size}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] custom emoji doc cache write failed: ${e}")
        }
    }
}

private func completeCustomEmojiDocumentFetch(): Unit {
    synchronized(customEmojiDocMonitor) {
        customEmojiDocFetching = false
        customEmojiDocMonitor.notifyAll()
    }
}

/** messages.getCustomEmojiDocuments 的独立入口（同步，必须在 spawn 线程里调用） */
public func fetchCustomEmojiDocuments(documentIds: ArrayList<Int64>): ArrayList<StickerItem> {
    ensureCustomEmojiDocDiskCache()
    let result = ArrayList<StickerItem>()
    let missing = ArrayList<Int64>()
    let shouldFetch = synchronized(customEmojiDocMonitor) {
        // UI 中多个 icon 可能同时出现。等待当前批次完成后重新计算 missing，
        // 等价于 iOS MediaBox 的 single-flight，避免每个 cell 单独发 RPC。
        while (customEmojiDocFetching) {
            customEmojiDocMonitor.wait(timeout: Duration.millisecond * 50)
        }
        for (id in documentIds) {
            if (customEmojiDocCache.contains(id)) {
                result.add(customEmojiDocCache[id])
            } else {
                missing.add(id)
            }
        }
        if (missing.size == 0) {
            false
        } else {
            customEmojiDocFetching = true
            true
        }
    }
    if (!shouldFetch) { return result }

    Hilog.info(0, "CjTelegram",
        "[StickersService] getCustomEmojiDocuments missing=${missing.size}")

    let client = getMTProtoClient()
    let request = StickersGetCustomEmojiDocuments()
    request.documentIds = missing
    let docsData = client.sendRequest(request.toBytes())
    if (docsData.size < 8) {
        Hilog.info(0, "CjTelegram",
            "[StickersService] getCustomEmojiDocuments empty response")
        completeCustomEmojiDocumentFetch()
        return result
    }
    let docs = TLDeserializer(docsData)
    if (docs.readUInt32() != TLConstructors.VECTOR) {
        Hilog.info(0, "CjTelegram",
            "[StickersService] getCustomEmojiDocuments unexpected response")
        completeCustomEmojiDocumentFetch()
        return result
    }
    let docsCount = docs.readInt32()
    var i: Int32 = 0
    while (i < docsCount) {
        let item = parseStickerDocument(docs)
        if (!item.isEmpty && item.documentId != 0) {
            synchronized(customEmojiDocMonitor) {
                customEmojiDocCache[item.documentId] = item
            }
            result.add(item)
        }
        i = i + 1
    }
    if (result.size > 0) { scheduleCustomEmojiDocFlush() }
    Hilog.info(0, "CjTelegram",
        "[StickersService] getCustomEmojiDocuments parsed=${result.size}")
    completeCustomEmojiDocumentFetch()
    return result
}

/** 单个 document_id → 文档（命中缓存直接返回） */
// ---- 精选表情包明细的磁盘缓存（iOS Postbox ItemCollection 的对位）----
//
// 明细只存内存快照时，每个会话都要重新对 ~90 个包各发一次 getStickerSet RPC，
// 后台跑几分钟；批量发布虽已把重建收敛到一次，但网络与时延照付。落盘后
// 冷启动零 RPC、面板结构立即完整。按账号 token 隔离。
private let FEATURED_EMOJI_DETAILS_MAGIC: UInt32 = 0x46454431
private let featuredEmojiDetailsCacheMonitor = Monitor()

private func featuredEmojiDetailsCachePath(): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    let suffix = getEntityKeyboardStore().cacheFileSuffix(
        getEntityKeyboardStore().currentToken())
    return filesDir + "/featured_emoji_details_" + suffix + ".tlc"
}

private func writeStickerItemTo(serializer: TLSerializer, item: StickerItem): Unit {
    serializer.writeInt64(item.documentId)
    serializer.writeInt64(item.accessHash)
    serializer.writeBytes(item.fileReference)
    serializer.writeInt32(item.dcId)
    serializer.writeString(item.mimeType)
    serializer.writeString(item.altEmoji)
    serializer.writeInt64(item.size)
    serializer.writeInt32(item.width)
    serializer.writeInt32(item.height)
    serializer.writeBool(item.isCustomEmoji)
    serializer.writeBool(item.isFreeEmoji)
    serializer.writeBool(item.supportsTextColor)
}

private func readStickerItemFrom(d: TLDeserializer): StickerItem {
    let item = StickerItem()
    item.documentId = d.readInt64()
    item.accessHash = d.readInt64()
    item.fileReference = d.readBytes()
    item.dcId = d.readInt32()
    item.mimeType = d.readString()
    item.altEmoji = d.readString()
    item.size = d.readInt64()
    item.width = d.readInt32()
    item.height = d.readInt32()
    item.isCustomEmoji = d.readBool()
    item.isFreeEmoji = d.readBool()
    item.supportsTextColor = d.readBool()
    return item
}

public func saveFeaturedEmojiDetailsCache(details: ArrayList<StickerPackDetail>): Unit {
    if (details.isEmpty()) { return }
    let serializer = TLSerializer()
    serializer.writeUInt32(FEATURED_EMOJI_DETAILS_MAGIC)
    serializer.writeInt32(Int32(details.size))
    for (detail in details) {
        serializer.writeInt64(detail.info.id)
        serializer.writeInt64(detail.info.accessHash)
        serializer.writeString(detail.info.title)
        serializer.writeInt32(detail.info.count)
        serializer.writeInt32(Int32(detail.stickers.size))
        for (item in detail.stickers) { writeStickerItemTo(serializer, item) }
    }
    synchronized(featuredEmojiDetailsCacheMonitor) {
        let path = featuredEmojiDetailsCachePath()
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, serializer.getBytes())
            FileIo.close(file)
            Hilog.info(0, "CjTelegram",
                "[StickersService] featured emoji details cached count=${details.size}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] featured emoji details cache write failed: ${e}")
        }
    }
}

public func loadFeaturedEmojiDetailsCache(): ArrayList<StickerPackDetail> {
    let result = ArrayList<StickerPackDetail>()
    let bytes = synchronized(featuredEmojiDetailsCacheMonitor) {
        let path = featuredEmojiDetailsCachePath()
        if (path.isEmpty()) { return result }
        try {
            if (!FileIo.access(path)) { return result }
            let stat = FileIo.stat(path)
            if (stat.size <= 8) { return result }
            let data = Array<Byte>(stat.size, repeat: 0)
            let file = FileIo.open(path, mode: 0o0)
            let readCount = FileIo.read(file.fd, data)
            FileIo.close(file)
            if (readCount != stat.size) { return result }
            data
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[StickersService] featured emoji details cache read failed: ${e}")
            return result
        }
    }
    try {
        let d = TLDeserializer(bytes)
        if (d.readUInt32() != FEATURED_EMOJI_DETAILS_MAGIC) { return result }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            let detail = StickerPackDetail()
            detail.success = true
            detail.info.id = d.readInt64()
            detail.info.accessHash = d.readInt64()
            detail.info.title = d.readString()
            detail.info.count = d.readInt32()
            let itemCount = d.readInt32()
            var j: Int32 = 0
            while (j < itemCount) {
                detail.stickers.add(readStickerItemFrom(d))
                j = j + 1
            }
            result.add(detail)
            i = i + 1
        }
        Hilog.info(0, "CjTelegram",
            "[StickersService] featured emoji details disk hit count=${result.size}")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram",
            "[StickersService] featured emoji details cache parse failed: ${e}")
    }
    return result
}

/**
 * 把已握有完整元数据的 StickerItem 直接种进 doc 缓存。
 *
 * 面板行数据（featured/installed 包的 topItems）本来就带 mimeType/accessHash/
 * fileReference —— 这些格子根本不需要 getCustomEmojiDocuments RPC。此前每个
 * CustomEmojiImage 只拿 documentId、逐个走 resolve：single-flight 让 14 个格子
 * 排成 14 次**串行** RPC，面板冷启动填满要 ~4s，正是「付费 emoji 挨个加载」。
 * iOS 的对位是 resolveInlineStickers 的批量 + Postbox 里现成的 media 记录。
 */
public func seedCustomEmojiDocuments(items: ArrayList<StickerItem>): Unit {
    ensureCustomEmojiDocDiskCache()
    var added = 0
    synchronized(customEmojiDocMonitor) {
        for (item in items) {
            if (item.documentId == 0 || item.isEmpty) { continue }
            if (item.mimeType.size == 0 || item.accessHash == 0) { continue }
            if (customEmojiDocCache.contains(item.documentId)) { continue }
            customEmojiDocCache[item.documentId] = item
            added = added + 1
        }
    }
    if (added > 0) { scheduleCustomEmojiDocFlush() }
}

/** 种不进的（如最近使用里只有 id 的）一次批量 RPC 补齐，别让格子逐个排队。 */
public func prefetchCustomEmojiDocuments(ids: ArrayList<Int64>): Unit {
    ensureCustomEmojiDocDiskCache()
    let missing = ArrayList<Int64>()
    synchronized(customEmojiDocMonitor) {
        for (id in ids) {
            if (id == 0 || customEmojiDocCache.contains(id)) { continue }
            var dup = false
            for (seen in missing) { if (seen == id) { dup = true; break } }
            if (!dup) { missing.add(id) }
        }
    }
    if (missing.size == 0) { return }
    let _ = fetchCustomEmojiDocuments(missing)
}

public func resolveCustomEmojiDocument(documentId: Int64): Option<StickerItem> {
    if (documentId == 0) { return None<StickerItem> }
    ensureCustomEmojiDocDiskCache()
    synchronized(customEmojiDocMonitor) {
        if (customEmojiDocCache.contains(documentId)) {
            return Some(customEmojiDocCache[documentId])
        }
    }
    let ids = ArrayList<Int64>()
    ids.add(documentId)
    let docs = fetchCustomEmojiDocuments(ids)
    for (doc in docs) {
        if (doc.documentId == documentId) { return Some(doc) }
    }
    return None<StickerItem>
}
