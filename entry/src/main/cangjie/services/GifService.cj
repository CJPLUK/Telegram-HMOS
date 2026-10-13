package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.{ArrayList, HashMap}
import std.sync.*
import ohos.business_exception.BusinessException

// ==================== GIF Service Singleton ====================

private var _gifServiceInstance: Option<GifService> = None
private let _gifServiceMonitor: Monitor = Monitor()
private let _savedGifCacheMonitor: Monitor = Monitor()

public func getGifService(): GifService {
    return synchronized(_gifServiceMonitor) {
        match (_gifServiceInstance) {
            case Some(inst) => inst
            case None =>
                let inst = GifService()
                _gifServiceInstance = Some(inst)
                inst
        }
    }
}

// ==================== GIF Response Model ====================

/**
 * GifItem — 单个 GIF 条目（对应 Telegram document with mimeType=video/mp4 or image/gif）
 * iOS: TelegramMediaFile with mimeType=video/mp4 and isAnimated attribute
 */
public class GifItem {
    /** Inline results keep their own collection identity, matching iOS contextResult. */
    public var queryId: Int64 = 0
    public var resultId: String = ""
    public var thumbnailUrl: String = ""
    public var contentUrl: String = ""
    public var documentId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dcId: Int32 = 0
    public var mimeType: String = ""
    public var size: Int64 = 0
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var duration: Float64 = 0.0
    public var altEmoji: String = ""

    public init() {}

    public func isValid(): Bool {
        return this.documentId != 0 || (this.queryId != 0 && !this.resultId.isEmpty())
    }

    public func isInlineResult(): Bool { return this.queryId != 0 && !this.resultId.isEmpty() }
}

/**
 * SavedGifsResult — messages.getSavedGifs 响应
 * messages.savedGifsNotModified#e8025ca2
 * messages.savedGifs#84a02a0d hash:long gifs:Vector<Document>
 */
public class SavedGifsResult {
    public var gifs: ArrayList<GifItem> = ArrayList<GifItem>()
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

/**
 * GifSearchResult — inline @gif result collection.
 */
public class GifSearchResult {
    public var gifs: ArrayList<GifItem> = ArrayList<GifItem>()
    public var success: Bool = false
    public var nextOffset: String = ""

    public init() {}
}

private func savedGifCachePath(token: EntityKeyboardAccountToken): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    return filesDir + "/saved_gifs_" + getEntityKeyboardStore().cacheFileSuffix(token) + ".tl"
}

private func writeSavedGifCache(data: Array<Byte>, token: EntityKeyboardAccountToken): Unit {
    if (data.isEmpty() || !getEntityKeyboardStore().isCurrent(token)) { return }
    synchronized(_savedGifCacheMonitor) {
        let path = savedGifCachePath(token)
        if (path.isEmpty()) { return }
        try {
            let file = FileIo.open(path, mode: 0o1101)
            FileIo.write(file.fd, data)
            FileIo.close(file)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[GifService] saved GIF cache write failed: ${e}")
        }
    }
}

private func readSavedGifCache(token: EntityKeyboardAccountToken): SavedGifsResult {
    return synchronized(_savedGifCacheMonitor) {
        let path = savedGifCachePath(token)
        if (path.isEmpty()) { return SavedGifsResult() }
        try {
            if (!FileIo.access(path)) { return SavedGifsResult() }
            let stat = FileIo.stat(path)
            if (stat.size <= 0) { return SavedGifsResult() }
            let bytes = Array<Byte>(stat.size, repeat: 0)
            let file = FileIo.open(path, mode: 0o0)
            let readCount = FileIo.read(file.fd, bytes)
            FileIo.close(file)
            if (readCount <= 0) { return SavedGifsResult() }
            let payload = if (readCount == stat.size) { bytes } else {
                Array<Byte>(readCount, { index: Int64 => bytes[index] })
            }
            return parseSavedGifsResponse(payload)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[GifService] saved GIF cache read failed: ${e}")
            return SavedGifsResult()
        }
    }
}

// ==================== TL Types for GIF ====================

/**
 * messages.saveGif#327a30cb id:InputDocument unsave:Bool = Bool
 * 收藏或取消收藏一个 GIF
 */
private class MessagesSaveGif <: TLObject {
    var documentId: Int64 = 0
    var accessHash: Int64 = 0
    var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    var unsave: Bool = false

    public func getConstructorId(): UInt32 { return 0x327a30cb }

    public func serialize(serializer: TLSerializer) {
        // inputDocument#1abfb575 id:long access_hash:long file_reference:bytes
        serializer.writeUInt32(0x1abfb575)
        serializer.writeInt64(this.documentId)
        serializer.writeInt64(this.accessHash)
        serializer.writeBytes(this.fileReference)
        // unsave: Bool (boxed)
        if (this.unsave) {
            serializer.writeUInt32(TLConstructors.BOOL_TRUE)
        } else {
            serializer.writeUInt32(TLConstructors.BOOL_FALSE)
        }
    }
}

// ==================== Parsers ====================

/**
 * 解析单个 GIF Document
 * document#8fd4c4d8 flags:# id:long access_hash:long file_reference:bytes date:int
 *   mime_type:string size:long thumbs:flags.0? video_thumbs:flags.1? dc_id:int
 *   attributes:Vector<DocumentAttribute>
 */
public func parseGifDocument(d: TLDeserializer): GifItem {
    let item = GifItem()
    let ctor = d.readUInt32()
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
    // thumbs flags.0
    if ((flags & 1) != 0) { skipPhotoSizeVecForGif(d) }
    // video_thumbs flags.1
    if ((flags & 2) != 0) { skipVideoSizeVecForGif(d) }
    item.dcId = d.readInt32()
    // attributes
    let attrVCtor = d.readUInt32()
    if (attrVCtor == TLConstructors.VECTOR) {
        let attrCount = d.readInt32()
        var ai: Int32 = 0
        while (ai < attrCount) {
            let attrCtor = d.readUInt32()
            if (attrCtor == 0x6c37c15c) {
                // documentAttributeImageSize w:int h:int
                item.width = d.readInt32()
                item.height = d.readInt32()
            } else if (attrCtor == 0x43c57c48 || attrCtor == 0xd38ff1c2) {
                // documentAttributeVideo flags:# duration:double w:int h:int
                let vFlags = d.readInt32()
                let durBits = d.readInt64()
                item.duration = Float64.fromBits(UInt64(durBits))
                item.width = d.readInt32()
                item.height = d.readInt32()
                if ((vFlags & 4) != 0) { let _ = d.readInt32() }
                if ((vFlags & 16) != 0) { let _ = d.readInt64() }
                if ((vFlags & 32) != 0) { let _ = d.readString() }
            } else if (attrCtor == 0x15590068) {
                // documentAttributeFilename file_name:string
                let _ = d.readString()
            } else if (attrCtor == 0x11b58939) {
                // documentAttributeAnimated — no fields
            } else if (attrCtor == 0x6319d612) {
                // documentAttributeSticker
                let attrFlags = d.readInt32()
                item.altEmoji = d.readString()
                // stickerset (boxed InputStickerSet)
                skipInputStickerSetForGif(d)
                if ((attrFlags & 1) != 0) {
                    let _ = d.readInt32()
                    let _ = d.readInt64()
                    let _ = d.readInt64()
                    let _ = d.readInt64()
                }
            } else {
                // Keep the cursor aligned for current-layer attributes rather than
                // accepting a partially parsed document that corrupts the next result.
                skipGifDocumentAttributeBody(d, attrCtor)
            }
            ai = ai + 1
        }
    }
    return item
}

private func skipGifDocumentAttributeBody(d: TLDeserializer, ctor: UInt32): Unit {
    if (ctor == 0x9801d2f7) { return } // documentAttributeHasStickers
    if (ctor == 0xfd149899) {
        let _ = d.readInt32()
        let _ = d.readString()
        skipInputStickerSetForGif(d)
        return
    }
    if (ctor == 0x9852f9c6) {
        let flags = d.readInt32()
        let _ = d.readInt32()
        if ((flags & 1) != 0) { let _ = d.readString() }
        if ((flags & 2) != 0) { let _ = d.readString() }
        if ((flags & 4) != 0) { let _ = d.readBytes() }
    }
}

/**
 * 跳过 PhotoSize vector（复用自 StickersService 的私有版本）
 */
private func skipPhotoSizeVecForGif(d: TLDeserializer) {
    let ctor = d.readUInt32()
    if (ctor != TLConstructors.VECTOR) { return }
    let cnt = d.readInt32()
    var i: Int32 = 0
    while (i < cnt) {
        let psCtor = d.readUInt32()
        if (psCtor == 0x0e17e23c) {
            let _ = d.readString()
        } else if (psCtor == 0x75c78e60 || psCtor == 0x75c831cd) {
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
        } else if (psCtor == 0x021e1ad6) {
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readBytes()
        } else if (psCtor == 0xe0b0bc2e) {
            let _ = d.readString()
            let _ = d.readBytes()
        } else if (psCtor == 0xfa3efb95) {
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let szVCtor = d.readUInt32()
            if (szVCtor == TLConstructors.VECTOR) {
                let sCnt = d.readInt32()
                var si: Int32 = 0
                while (si < sCnt) {
                    let _ = d.readInt32()
                    si = si + 1
                }
            }
        } else if (psCtor == 0xd8214d41) {
            let _ = d.readString()
            let _ = d.readBytes()
        }
        i = i + 1
    }
}

/**
 * 跳过 VideoSize vector
 */
private func skipVideoSizeVecForGif(d: TLDeserializer) {
    let ctor = d.readUInt32()
    if (ctor != TLConstructors.VECTOR) { return }
    let cnt = d.readInt32()
    var i: Int32 = 0
    while (i < cnt) {
        let vsCtor = d.readUInt32()
        if (vsCtor == 0xde33b094) {
            let vsFlags = d.readInt32()
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
            if ((vsFlags & 1) != 0) { let _ = d.readInt64() }
        } else if (vsCtor == 0xf85c413c) {
            let _ = d.readInt64()
            let colorVCtor = d.readUInt32()
            if (colorVCtor == TLConstructors.VECTOR) {
                let cCnt = d.readInt32()
                var ci: Int32 = 0
                while (ci < cCnt) {
                    let _ = d.readInt32()
                    ci = ci + 1
                }
            }
        } else if (vsCtor == 0x0da082fe) {
            skipInputStickerSetForGif(d)
            let _ = d.readInt64()
            let colorVCtor = d.readUInt32()
            if (colorVCtor == TLConstructors.VECTOR) {
                let cCnt = d.readInt32()
                var ci: Int32 = 0
                while (ci < cCnt) { let _ = d.readInt32(); ci = ci + 1 }
            }
        }
        i = i + 1
    }
}

/**
 * 跳过 InputStickerSet (boxed)
 */
private func skipInputStickerSetForGif(d: TLDeserializer) {
    let ctor = d.readUInt32()
    if (ctor == 0xffb62b95 || ctor == 0x028703c8) { return }
    if (ctor == 0x9de7a269) {
        let _ = d.readInt64()
        let _ = d.readInt64()
        return
    }
    if (ctor == 0x861cc8a0) {
        let _ = d.readString()
        return
    }
}

/**
 * 解析 messages.savedGifs 响应
 */
private func parseSavedGifsResponse(data: Array<Byte>): SavedGifsResult {
    let result = SavedGifsResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    // messages.savedGifsNotModified#e8025ca2
    if (ctor == 0xe8025ca2) {
        result.notModified = true
        result.success = true
        return result
    }
    // messages.savedGifs#84a02a0d hash:long gifs:Vector<Document>
    if (ctor != 0x84a02a0d) {
        Hilog.info(0, "CjTelegram", "[GifService] Unexpected savedGifs ctor")
        return result
    }
    result.hash = d.readInt64()
    let gifVCtor = d.readUInt32()
    if (gifVCtor == TLConstructors.VECTOR) {
        let gifCount = d.readInt32()
        var gi: Int32 = 0
        while (gi < gifCount) {
            let item = parseGifDocument(d)
            if (item.isValid()) {
                result.gifs.add(item)
            }
            gi = gi + 1
        }
    }
    result.success = true
    return result
}

// ==================== GifService ====================

/**
 * GifService — GIF 面板服务层
 *
 * 封装 GIF 面板所需的全部 TL 方法：
 *   messages.getSavedGifs  — 获取已保存(收藏)的 GIF 列表
 *   messages.getInlineBotResults — 通过服务端配置的 GIF bot 获取热门与搜索结果
 *   messages.saveGif       — 收藏 / 取消收藏 GIF
 *
 * iOS 对应: GifPaneNode (submodules/ChatListUI/Sources/GifPaneNode.swift)
 *           + TelegramEngine.Stickers.savedGifs + searchGifs
 */
public class GifService {

    private func mapInlineResult(result: InlineBotResult): GifItem {
        let item = result.document
        item.queryId = result.queryId
        item.resultId = result.id
        item.thumbnailUrl = result.thumbUrl
        item.contentUrl = result.contentUrl
        if (item.mimeType.isEmpty()) { item.mimeType = "video/mp4" }
        return item
    }

    private func mapInlineCollection(source: InlineBotResultSet): GifSearchResult {
        let result = GifSearchResult()
        for (entry in source.results) {
            if (entry.resultType == "gif" || entry.resultType == "mpeg4_gif") {
                result.gifs.add(this.mapInlineResult(entry))
            }
        }
        result.nextOffset = source.nextOffset
        result.success = source.queryId != 0 || !source.results.isEmpty()
        return result
    }

    /**
     * 获取已保存的 GIF 列表
     * TL: messages.getSavedGifs#5cf09635 hash:long = messages.SavedGifs
     */
    public func getSavedGifs(hash!: Int64 = 0): SavedGifsResult {
        let token = getEntityKeyboardStore().currentToken()
        let cached = readSavedGifCache(token)
        let client = getMTProtoClient()
        let req = MessagesGetSavedGifs()
        req.hash = if (hash != 0) { hash } else { cached.hash }
        Hilog.info(0, "CjTelegram", "[GifService] messages.getSavedGifs hash=${req.hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[GifService] getSavedGifs: network empty, use cache=${cached.success}")
            return cached
        }
        let result = parseSavedGifsResponse(responseData)
        if (result.notModified) { return cached }
        if (result.success && getEntityKeyboardStore().isCurrent(token)) {
            writeSavedGifCache(responseData, token)
        }
        Hilog.info(0, "CjTelegram", "[GifService] getSavedGifs: gifs=${result.gifs.size} success=${result.success}")
        return result
    }

    /** Synchronous disk-only read used to paint Recent before network actualization. */
    public func getCachedSavedGifsAsSearch(): GifSearchResult {
        let cached = readSavedGifCache(getEntityKeyboardStore().currentToken())
        let result = GifSearchResult()
        result.gifs = cached.gifs
        result.success = cached.success
        return result
    }

    /**
     * 搜索 GIF（关键词 / emoji → GIF 列表）
     * TL: messages.getInlineBotResults#514e999d，peer 使用 inputPeerSelf。
     * iOS: _internal_searchGifs → _internal_requestChatContextResults。
     */
    public func searchGifs(query: String, offset!: String = ""): GifSearchResult {
        Hilog.info(0, "CjTelegram", "[GifService] inline @gif q=${query} offset=${offset}")
        let result = this.mapInlineCollection(getWebSearchService().searchGif(query, offset: offset))
        Hilog.info(0, "CjTelegram", "[GifService] searchGifs: gifs=${result.gifs.size} success=${result.success}")
        return result
    }

    /**
     * 获取 trending GIF（向配置的 GIF inline bot 发送空查询）。
     * Recent 仍由账号隔离的 messages.getSavedGifs 提供。
     */
    public func getTrendingGifs(offset!: String = ""): GifSearchResult {
        // iOS obtains trending content from the configured GIF inline bot with
        // an empty query. Recent GIFs remain the account-scoped saved list.
        let result = this.searchGifs("", offset: offset)
        Hilog.info(0, "CjTelegram", "[GifService] getTrendingGifs: gifs=${result.gifs.size}")
        return result
    }

    /**
     * 获取已保存 GIF 列表，返回 GifSearchResult 格式（供 GifPanel Recent 使用）。
     */
    public func getSavedGifsAsSearch(): GifSearchResult {
        let saved = this.getSavedGifs()
        let result = GifSearchResult()
        result.gifs = saved.gifs
        result.success = saved.success
        return result
    }

    /**
     * 收藏 / 取消收藏 GIF
     * TL: messages.saveGif#327a30cb id:InputDocument unsave:Bool = Bool
     */
    public func saveGif(gif: GifItem, unsave!: Bool = false): Bool {
        let client = getMTProtoClient()
        let req = MessagesSaveGif()
        req.documentId = gif.documentId
        req.accessHash = gif.accessHash
        req.fileReference = gif.fileReference
        req.unsave = unsave
        Hilog.info(0, "CjTelegram", "[GifService] saveGif docId=${gif.documentId} unsave=${unsave}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[GifService] saveGif: empty response")
            return false
        }
        if (responseData.size >= 4) {
            let d = TLDeserializer(responseData)
            let ctor = d.readUInt32()
            return ctor == TLConstructors.BOOL_TRUE
        }
        return false
    }
}

/**
 * Materialize a saved/internal GIF for a visible grid cell. MP4 GIFs reuse the
 * universal video cache, so a later chat bubble opens the same bytes without a
 * second MTProto download.
 */
public func ensureGifLocalFile(item: GifItem): String {
    if (item.documentId == 0) { return "" }
    if (item.mimeType.contains("mp4") || item.mimeType.contains("video")) {
        let content = UniversalVideoContent()
        content.contentId = item.documentId
        content.contentType = UniversalVideoContentType.GifAnimation
        content.fileId = item.documentId
        content.accessHash = item.accessHash
        content.fileReference = item.fileReference
        content.dcId = item.dcId
        content.fileSize = item.size
        content.width = item.width
        content.height = item.height
        content.duration = item.duration
        content.enableSound = false
        content.loopVideo = true
        return getTelegramUniversalVideoContentService().downloadVideoFile(content)
    }

    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    let dir = filesDir + "/gifs"
    let path = dir + "/gif_${item.documentId}.gif"
    try {
        if (FileIo.access(path)) { return "file://" + path }
        if (!FileIo.access(dir)) { FileIo.mkdir(dir) }
        let bytes = getFileDownloadService().downloadDocument(
            item.documentId, item.accessHash, item.fileReference, item.dcId,
            fileSize: item.size, priority: 50)
        if (bytes.isEmpty()) { return "" }
        let file = FileIo.open(path, mode: 0o1101)
        FileIo.write(file.fd, bytes)
        FileIo.close(file)
        return "file://" + path
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[GifService] ensure local failed id=${item.documentId}: ${e}")
        return ""
    }
}
