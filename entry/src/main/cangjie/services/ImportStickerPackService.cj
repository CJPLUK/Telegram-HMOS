package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.fs.{File, Path}
import std.random.Random
import ohos_app_cangjie_entry.utils.mimeTypeForExtension
import ohos_app_cangjie_entry.core.mtproto.*

// ==================== Models ====================

/**
 * ImportStickerItem — 待导入贴纸条目
 * 对应 iOS ImportStickerPack.Sticker
 */
public class ImportStickerItem {
    public var localUri: String = ""
    public var emoji: String = "🎭"
    public var mimeType: String = "image/png"
    public var isVerified: Bool = false

    public init() {}
}

/**
 * ImportStickerPackState — 本地导入状态机
 * 记录当前导入会话：已选贴纸列表、包名、上传进度
 */
public class ImportStickerPackState {
    public var stickers: ArrayList<ImportStickerItem> = ArrayList<ImportStickerItem>()
    public var packTitle: String = ""
    public var isUploading: Bool = false
    public var uploadProgress: Int64 = 0
    public var uploadTotal: Int64 = 0
    public var uploadSuccess: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

// ==================== Singleton ====================

private var _importStickerPackServiceInstance: Option<ImportStickerPackService> = None

public func getImportStickerPackService(): ImportStickerPackService {
    match (_importStickerPackServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ImportStickerPackService()
            _importStickerPackServiceInstance = Some(inst)
            return inst
    }
}

// ==================== ImportStickerPackService ====================

/**
 * ImportStickerPackService — 导入第三方贴纸包服务层
 *
 * 对应 iOS ImportStickerPackUI/Sources/ImportStickerPack.swift
 *   + ImportStickerPackController 的业务逻辑层
 *
 * implementation_kind: local_state (tl_methods=[])
 *
 * 功能：
 *   1. 管理用户选中的本地图片列表
 *   2. 维护贴纸包标题
 *   3. 模拟上传进度（本地 state，无真实 MTProto 调用）
 *   4. 完成后通过路由字符串跳转到 StickerPackPreviewPage
 *
 * 调用链：
 *   ImportStickerPackPage.onConfirm
 *     → ImportStickerPackService.startImport(stickers, title)
 *       → 更新 uploadProgress / uploadSuccess 状态
 */
public class ImportStickerPackService {
    public var currentState: ImportStickerPackState = ImportStickerPackState()

    /**
     * 添加一张本地图片为待导入贴纸
     */
    public func addStickerItem(localUri: String, emoji: String): Unit {
        Hilog.info(0, "CjTelegram", "[ImportStickerPackService] addStickerItem uri=${localUri}")
        let item = ImportStickerItem()
        item.localUri = localUri
        item.emoji = emoji
        item.mimeType = mimeTypeForExtension(localUri)
        this.currentState.stickers.add(item)
        Hilog.info(0, "CjTelegram", "[ImportStickerPackService] total stickers=${this.currentState.stickers.size}")
    }

    /**
     * 移除指定索引的贴纸
     * ArrayList.remove() 接收 Range<Int64>，单元素删除用 index..index+1
     */
    public func removeStickerItem(index: Int64): Unit {
        let stickers = this.currentState.stickers
        if (index >= 0 && index < Int64(stickers.size)) {
            stickers.remove(index..index + 1)
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] removed sticker at ${index}")
        }
    }

    /**
     * 更新贴纸包标题
     */
    public func setPackTitle(title: String): Unit {
        this.currentState.packTitle = title
        Hilog.info(0, "CjTelegram", "[ImportStickerPackService] packTitle=${title}")
    }

    /**
     * 获取当前贴纸列表大小
     */
    public func getStickerCount(): Int64 {
        return Int64(this.currentState.stickers.size)
    }

    /**
     * 校验包是否可以创建（至少 1 张贴纸，标题非空）
     */
    public func canCreate(): Bool {
        return this.currentState.stickers.size > 0 &&
               this.currentState.packTitle.size > 0
    }

    /**
     * 开始真实 MTProto 导入流程（P2-381 Real Import）
     *
     * iOS 对照: TelegramCore/Sources/TelegramEngine/Stickers/ImportStickers.swift
     *
     * 调用链:
     *   startImport
     *     → MIME 验证（png/webp/tgs）+ declined 过滤
     *     → 对每张通过的贴纸: File.readFrom(Path(localUri)) → documentBytes
     *     → 构造 StickerSetInputItem（含 emoji/mimeType/documentBytes）
     *     → getStickerPackAuthorService().createStickerPack(title, shortName, items)
     *         → FileUploadService.uploadFile → messages.uploadMedia → stickers.createStickerSet
     *
     * MIME 白名单（iOS ImportStickers.swift L40-55）:
     *   image/png          — PNG 静态贴纸
     *   image/webp         — WebP 静态贴纸
     *   application/x-tgsticker — TGS 动画贴纸 (LottieJSON)
     *
     * declined 过滤: 不在白名单的贴纸跳过（isVerified=false），记日志，继续其他贴纸。
     * 若过滤后无有效贴纸 → 设置 errorMessage 并 return（不发送请求）。
     *
     * shortName 自动生成规则（iOS 默认): 8位随机字母数字 + "_by_" + 后缀（简化：纯随机8字符）
     *   iOS: randomShortName() → UUID().uuidString.lowercased().prefix(8)
     *
     * S-001: 本方法在 spawn{} 中调用（ImportStickerPackPage.doCreate），不直接操作 @State。
     */
    public func startImport(): Unit {
        if (this.currentState.isUploading) {
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] import already in progress")
            return
        }
        let totalCount = this.currentState.stickers.size
        if (totalCount == 0) {
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] no stickers to import")
            this.currentState.errorMessage = "No stickers selected"
            return
        }
        if (this.currentState.packTitle.size == 0) {
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] packTitle is empty")
            this.currentState.errorMessage = "Pack title is required"
            return
        }

        this.currentState.isUploading = true
        this.currentState.uploadProgress = 0
        this.currentState.uploadTotal = Int64(totalCount)
        this.currentState.uploadSuccess = false
        this.currentState.errorMessage = ""

        Hilog.info(0, "CjTelegram", "[ImportStickerPackService] startImport totalCount=${totalCount}")

        // MIME 白名单（iOS ImportStickers.swift L40-55）
        // image/png, image/webp, application/x-tgsticker
        let validItems = ArrayList<StickerSetInputItem>()
        var declinedCount: Int64 = 0
        var i: Int64 = 0
        while (i < Int64(totalCount)) {
            let sticker = this.currentState.stickers[i]
            let mime = sticker.mimeType
            let isValidMime = (mime == "image/png" || mime == "image/webp" || mime == "application/x-tgsticker")
            if (!isValidMime) {
                // declined filter: 不支持的 MIME 跳过
                declinedCount = declinedCount + 1
                Hilog.info(0, "CjTelegram", "[ImportStickerPackService] declined sticker ${i} mime=${mime}")
                i = i + 1
                continue
            }

            // 读取本地文件字节
            let fileBytes: Array<Byte>
            try {
                fileBytes = File.readFrom(Path(sticker.localUri))
            } catch (ex: Exception) {
                Hilog.info(0, "CjTelegram", "[ImportStickerPackService] readFile failed uri=${sticker.localUri}")
                declinedCount = declinedCount + 1
                i = i + 1
                continue
            }

            if (fileBytes.size == 0) {
                Hilog.info(0, "CjTelegram", "[ImportStickerPackService] empty file uri=${sticker.localUri}")
                declinedCount = declinedCount + 1
                i = i + 1
                continue
            }

            // 构造 StickerSetInputItem（含 emoji/mimeType/documentBytes）
            let setItem = StickerSetInputItem()
            setItem.documentBytes = fileBytes
            setItem.fileName = buildStickerFileName(sticker.localUri, mime)
            setItem.mimeType = mime
            setItem.emoji = if (sticker.emoji.size > 0) { sticker.emoji } else { "🎭" }
            validItems.add(setItem)

            // 标记为通过验证
            this.currentState.stickers[i].isVerified = true
            this.currentState.uploadProgress = Int64(validItems.size)
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] queued sticker ${i} mime=${mime}")
            i = i + 1
        }

        if (validItems.size == 0) {
            this.currentState.errorMessage = "No valid stickers (accepted: png/webp/tgs, declined=${declinedCount})"
            this.currentState.isUploading = false
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] all stickers declined, abort")
            return
        }

        Hilog.info(0, "CjTelegram", "[ImportStickerPackService] uploading validCount=${validItems.size} declined=${declinedCount}")

        // 自动生成短名（iOS: randomShortName() → 随机8字符 + "_cj"）
        let shortName = generateStickerPackShortName()
        Hilog.info(0, "CjTelegram", "[ImportStickerPackService] shortName=${shortName}")

        // 调用 StickerPackAuthorService.createStickerPack（真 MTProto 上传链）
        // stickers.createStickerSet#9021ab67
        let authorSvc = getStickerPackAuthorService()
        let createResult = authorSvc.createStickerPack(
            this.currentState.packTitle,
            shortName,
            validItems
        )

        if (createResult.success) {
            this.currentState.uploadSuccess = true
            this.currentState.uploadProgress = Int64(validItems.size)
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] createStickerPack success packId=${createResult.packId} shortName=${createResult.shortName}")
        } else {
            this.currentState.errorMessage = "Upload failed: " + createResult.errorCode
            Hilog.info(0, "CjTelegram", "[ImportStickerPackService] createStickerPack failed err=${createResult.errorCode}")
        }
        this.currentState.isUploading = false
    }

    /**
     * 从 localUri 提取文件名（basename），用于 FileUploadService.uploadFile name 字段
     * 通过搜索最后一个 '/' 字符（Rune）来分割路径
     */
    private func buildStickerFileName(localUri: String, mimeType: String): String {
        if (localUri.size == 0) {
            return "sticker.png"
        }
        // 将 URI 转为 UTF-8 字节搜索 '/' (0x2F)
        let uriBytes: Array<Byte>
        try {
            uriBytes = localUri.toArray()
        } catch (_: Exception) {
            if (mimeType == "image/webp") { return "sticker.webp" }
            if (mimeType == "application/x-tgsticker") { return "sticker.tgs" }
            return "sticker.png"
        }
        let uriLen = uriBytes.size
        var lastSlash: Int64 = -1
        var ci: Int64 = 0
        while (ci < uriLen) {
            if (uriBytes[ci] == 47) {
                lastSlash = ci
            }
            ci = ci + 1
        }
        if (lastSlash >= 0 && lastSlash + 1 < uriLen) {
            let basePart = localUri[lastSlash + 1..uriLen]
            if (basePart.size > 0) {
                return basePart
            }
        }
        if (mimeType == "image/webp") { return "sticker.webp" }
        if (mimeType == "application/x-tgsticker") { return "sticker.tgs" }
        return "sticker.png"
    }

    /**
     * 生成贴纸包短名（8位随机字母数字 + "_cj"）
     * iOS: UUID().uuidString.lowercased().prefix(8) + "_by_botname"
     * 仓颉简化版: Random().nextInt32() hex 前缀 + "_cj"
     */
    private func generateStickerPackShortName(): String {
        let rng = Random()
        let n1 = Int64(rng.nextUInt32()) & 0xFFFFFFFF
        let n2 = Int64(rng.nextUInt32()) & 0xFFFF
        let hex1 = intToHex4(n1)
        let hex2 = intToHex2(n2)
        return hex1 + hex2 + "_cj"
    }

    /**
     * 将整数转换为 4 字节十六进制字符串（小写）
     */
    private func intToHex4(value: Int64): String {
        let hexChars = "0123456789abcdef"
        var result = ""
        var v = value & 0xFFFFFFFF
        var j: Int64 = 0
        while (j < 8) {
            let nibble = (v >> 28) & 0xF
            result = result + hexChars[nibble..nibble + 1]
            v = (v << 4) & 0xFFFFFFFF
            j = j + 1
        }
        return result
    }

    /**
     * 将整数转换为 2 字节十六进制字符串（小写）
     */
    private func intToHex2(value: Int64): String {
        let hexChars = "0123456789abcdef"
        var result = ""
        var v = value & 0xFFFF
        var j: Int64 = 0
        while (j < 4) {
            let nibble = (v >> 12) & 0xF
            result = result + hexChars[nibble..nibble + 1]
            v = (v << 4) & 0xFFFF
            j = j + 1
        }
        return result
    }

    /**
     * 重置导入状态，用于开始新的导入会话
     */
    public func reset(): Unit {
        this.currentState = ImportStickerPackState()
        Hilog.info(0, "CjTelegram", "[ImportStickerPackService] reset")
    }

    /**
     * 获取指定索引的贴纸 emoji
     */
    public func getStickerEmoji(index: Int64): String {
        let stickers = this.currentState.stickers
        if (index >= 0 && index < Int64(stickers.size)) {
            return stickers[index].emoji
        }
        return "🎭"
    }

    /**
     * 获取指定索引的贴纸 URI
     */
    public func getStickerUri(index: Int64): String {
        let stickers = this.currentState.stickers
        if (index >= 0 && index < Int64(stickers.size)) {
            return stickers[index].localUri
        }
        return ""
    }

}

// ============================================================
// P2-154b: Sticker Pack Authoring — stickers.* MTProto methods
//
// 5 operations wired to real TL wire:
//   createStickerSet   — stickers.createStickerSet#9021ab67
//   addStickerToSet    — stickers.addStickerToSet#8653febe
//   removeStickerFromSet — stickers.removeStickerFromSet#f7760f51
//   renameStickerSet   — stickers.renameStickerSet#124b1c00
//   changeStickerPosition — stickers.changeStickerPosition#ffb6d4ca
//
// FileUploadService (P2-250) is reused for bytes→InputFile conversion.
// Response for all 5 is messages.StickerSet, parsed via StickersService.parseStickerSetResponse
// which is NOT public; so we inline the same response-parse logic here.
//
// TL wire cheat-sheet (verified against telegram_api.tl):
//   maskCoords#aed6dbb2             n:int x:double y:double zoom:double
//   inputStickerSetItem#32da9e9c    flags:# document:InputDocument emoji:string
//                                   mask_coords:flags.0?MaskCoords keywords:flags.1?string
//   inputStickerSetID#9de7a269      id:long access_hash:long
//   inputDocument#1abfb575          id:long access_hash:long file_reference:bytes
//   inputUserSelf#f7c1b13f          (self — used when creating own pack)
//   inputUser#f21158c6              user_id:long access_hash:long
//   Vector outer tag: 0x1cb5c415 + count (int32) + items
// ============================================================

// ==================== Models ====================

/**
 * StickerSetInputItem — 调用方传入的贴纸描述（upload 前）
 * 对应 iOS InputStickerSetItem
 */
public class StickerSetInputItem {
    public var documentBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var fileName: String = "sticker.png"
    public var mimeType: String = "image/png"
    public var emoji: String = ""
    public var hasMaskCoords: Bool = false
    public var maskCoordsN: Int32 = 0
    public var maskCoordsX: Float64 = 0.0
    public var maskCoordsY: Float64 = 0.0
    public var maskCoordsZoom: Float64 = 0.0
    public var keywords: String = ""

    public init() {}
}

/**
 * StickerSetDocumentItem — 已有文档的贴纸描述（操作 addStickerToSet）
 * document 已在 Telegram 服务器，只需 InputDocument 引用
 */
public class StickerSetDocumentItem {
    public var documentId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var emoji: String = ""
    public var hasMaskCoords: Bool = false
    public var maskCoordsN: Int32 = 0
    public var maskCoordsX: Float64 = 0.0
    public var maskCoordsY: Float64 = 0.0
    public var maskCoordsZoom: Float64 = 0.0
    public var keywords: String = ""

    public init() {}
}

/**
 * StickerPackAuthorResult — 贴纸包创建/编辑操作结果
 * 服务端返回 messages.StickerSet，解析为包信息
 */
public class StickerPackAuthorResult {
    public var success: Bool = false
    public var packId: Int64 = 0
    public var accessHash: Int64 = 0
    public var title: String = ""
    public var shortName: String = ""
    public var count: Int32 = 0
    public var errorCode: String = ""

    public init() {}
}

// ==================== TL Request Helpers ====================

/**
 * Inline-serialize InputDocument#1abfb575 onto the given serializer.
 * Fields: id:long access_hash:long file_reference:bytes
 */
private func serializeInputDocument(
    serializer: TLSerializer,
    documentId: Int64,
    accessHash: Int64,
    fileReference: Array<Byte>
): Unit {
    serializer.writeUInt32(0x1abfb575)
    serializer.writeInt64(documentId)
    serializer.writeInt64(accessHash)
    serializer.writeBytes(fileReference)
}

/**
 * Inline-serialize InputStickerSetID#9de7a269 onto the given serializer.
 * Fields: id:long access_hash:long
 */
private func serializeInputStickerSetID(
    serializer: TLSerializer,
    packId: Int64,
    accessHash: Int64
): Unit {
    serializer.writeUInt32(0x9de7a269)
    serializer.writeInt64(packId)
    serializer.writeInt64(accessHash)
}

/**
 * Inline-serialize InputStickerSetItem#32da9e9c onto the given serializer.
 * inputStickerSetItem#32da9e9c flags:# document:InputDocument emoji:string
 *   mask_coords:flags.0?MaskCoords keywords:flags.1?string
 * maskCoords#aed6dbb2 n:int x:double y:double zoom:double
 */
private func serializeInputStickerSetItem(
    serializer: TLSerializer,
    item: StickerSetDocumentItem
): Unit {
    serializer.writeUInt32(0x32da9e9c)
    var flags: Int32 = 0
    if (item.hasMaskCoords) { flags = flags | 1 }
    if (item.keywords.size > 0) { flags = flags | 2 }
    serializer.writeInt32(flags)
    serializeInputDocument(serializer, item.documentId, item.accessHash, item.fileReference)
    serializer.writeString(item.emoji)
    if (item.hasMaskCoords) {
        // maskCoords#aed6dbb2 n:int x:double y:double zoom:double
        serializer.writeUInt32(0xaed6dbb2)
        serializer.writeInt32(item.maskCoordsN)
        serializer.writeDouble(item.maskCoordsX)
        serializer.writeDouble(item.maskCoordsY)
        serializer.writeDouble(item.maskCoordsZoom)
    }
    if (item.keywords.size > 0) {
        serializer.writeString(item.keywords)
    }
}

// ==================== Upload helpers ====================

/**
 * Intermediate result carrying the server-assigned document triple
 * returned by messages.uploadMedia.
 */
private class UploadMediaDocResult {
    var success: Bool = false
    var documentId: Int64 = 0
    var accessHash: Int64 = 0
    var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)

    init() {}
}

/**
 * Step 2 of the iOS upload flow (ImportStickers.swift L86-103):
 *   upload → messages.uploadMedia → messageMediaDocument → document
 *
 * Sends messages.uploadMedia#14967978 with the InputFile already uploaded,
 * parses the messageMediaDocument#52d8ccd9 response, and extracts the
 * server-assigned document triple (id / access_hash / file_reference).
 *
 * TL ctors used (all tl_codegen verified):
 *   inputMediaUploadedDocument#037c9330  (telegram_api.tl:62)
 *   documentAttributeSticker#6319d612   (telegram_api.tl:617)
 *   documentAttributeImageSize#6c37c15c  (telegram_api.tl:615)
 *   messages.uploadMedia#14967978       (telegram_api.tl:2277)
 *   messageMediaDocument#52d8ccd9       (telegram_api.tl:153)
 *   document#8fd4c4d8                   (telegram_api.tl:526)
 *
 * @param tlFile   The InputFile TLObject returned by FileUploadService.uploadFile()
 * @param mimeType MIME type string (e.g. "image/png", "image/webp")
 * @param alt      Emoji alt string for the sticker (used in documentAttributeSticker)
 * @return UploadMediaDocResult with success=true and valid id/accessHash/fileReference,
 *         or success=false on network/parse error.
 */
private func uploadMediaGetDocument(
    tlFile: TLObject,
    mimeType: String,
    alt: String
): UploadMediaDocResult {
    let result = UploadMediaDocResult()

    // Build inputMediaUploadedDocument#037c9330
    // attributes: [documentAttributeSticker, documentAttributeImageSize]
    // iOS ImportStickers.swift L80-86: sticker alt + imageSize always present;
    // video duration skipped here (attributes are informational, server regenerates thumbs).
    let stickerAttr = DocumentAttributeSticker()
    stickerAttr.alt = alt

    let imageSizeAttr = DocumentAttributeImageSize()
    // w/h default to 512x512 — informational; server ignores for stickers

    let uploadedDoc = InputMediaUploadedDocument()
    uploadedDoc.file = tlFile
    uploadedDoc.mimeType = mimeType
    uploadedDoc.attributes.add(stickerAttr)
    uploadedDoc.attributes.add(imageSizeAttr)

    // Build messages.uploadMedia#14967978 (peer=inputPeerSelf, no business_connection_id)
    let req = MessagesUploadMedia()
    req.media = uploadedDoc

    let client = getMTProtoClient()
    Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] messages.uploadMedia alt=${alt} mime=${mimeType}")
    let responseData = client.sendRequest(req.toBytes())
    if (responseData.size < 4) {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] uploadMedia empty response")
        return result
    }

    // Parse messageMediaDocument#52d8ccd9
    // flags:# nopremium:flags.3?true spoiler:flags.4?true video:flags.6?true
    //   round:flags.7?true voice:flags.8?true document:flags.0?Document
    //   alt_documents:flags.5?Vector<Document> video_cover:flags.9?Photo
    //   video_timestamp:flags.10?int ttl_seconds:flags.2?int
    let d = TLDeserializer(responseData)
    let mediaCtor = d.readUInt32()
    if (mediaCtor != 0x52d8ccd9) {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] uploadMedia unexpected ctor 0x${mediaCtor}")
        return result
    }
    let mediaFlags = d.readInt32()
    // document is flags.0? — check bit 0
    if ((mediaFlags & 1) == 0) {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] uploadMedia: document field absent in messageMediaDocument")
        return result
    }

    // Parse document#8fd4c4d8
    // flags:# id:long access_hash:long file_reference:bytes date:int mime_type:string
    //   size:long thumbs:flags.0?... video_thumbs:flags.1?... dc_id:int attributes:Vector<...>
    let docCtor = d.readUInt32()
    if (docCtor != 0x8fd4c4d8) {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] uploadMedia unexpected document ctor 0x${docCtor}")
        return result
    }
    // skip docFlags — remaining document fields not needed after id/accessHash/fileReference
    let _ = d.readInt32()
    result.documentId = d.readInt64()
    result.accessHash = d.readInt64()
    result.fileReference = d.readBytes()
    result.success = true

    Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] uploadMedia OK docId=${result.documentId}")
    return result
}

// ==================== TL Request Classes ====================

/**
 * stickers.createStickerSet#9021ab67
 * flags:# masks:flags.0?true emojis:flags.5?true text_color:flags.6?true
 *   user_id:InputUser title:string short_name:string
 *   thumb:flags.2?InputDocument stickers:Vector<InputStickerSetItem>
 *   software:flags.3?string = messages.StickerSet
 *
 * We always use inputUserSelf#f7c1b13f (own account).
 * thumb is not set (flags.2 = 0).
 * software is not set (flags.3 = 0).
 */
private class StickersCreateStickerSetReq <: TLObject {
    var isMaskPack: Bool = false
    var isEmojiPack: Bool = false
    var title: String = ""
    var shortName: String = ""
    var stickers: ArrayList<StickerSetDocumentItem> = ArrayList<StickerSetDocumentItem>()

    public func getConstructorId(): UInt32 { return 0x9021ab67 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.isMaskPack) { flags = flags | 1 }       // masks: flags.0
        if (this.isEmojiPack) { flags = flags | 32 }     // emojis: flags.5
        serializer.writeInt32(flags)
        // user_id: InputUser — inputUserSelf#f7c1b13f (no fields)
        serializer.writeUInt32(0xf7c1b13f)
        serializer.writeString(this.title)
        serializer.writeString(this.shortName)
        // stickers: Vector<InputStickerSetItem>
        // Outer vector: 0x1cb5c415 + count, then each item inline
        serializer.writeUInt32(TLConstructors.VECTOR)
        serializer.writeInt32(Int32(this.stickers.size))
        for (item in this.stickers) {
            serializeInputStickerSetItem(serializer, item)
        }
    }
}

/**
 * stickers.addStickerToSet#8653febe
 * stickerset:InputStickerSet sticker:InputStickerSetItem = messages.StickerSet
 */
private class StickersAddStickerToSetReq <: TLObject {
    var packId: Int64 = 0
    var packAccessHash: Int64 = 0
    var sticker: StickerSetDocumentItem = StickerSetDocumentItem()

    public func getConstructorId(): UInt32 { return 0x8653febe }

    public func serialize(serializer: TLSerializer) {
        serializeInputStickerSetID(serializer, this.packId, this.packAccessHash)
        serializeInputStickerSetItem(serializer, this.sticker)
    }
}

/**
 * stickers.removeStickerFromSet#f7760f51
 * sticker:InputDocument = messages.StickerSet
 */
private class StickersRemoveStickerFromSetReq <: TLObject {
    var documentId: Int64 = 0
    var accessHash: Int64 = 0
    var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xf7760f51 }

    public func serialize(serializer: TLSerializer) {
        serializeInputDocument(serializer, this.documentId, this.accessHash, this.fileReference)
    }
}

/**
 * stickers.changeStickerPosition#ffb6d4ca
 * sticker:InputDocument position:int = messages.StickerSet
 */
private class StickersChangeStickerPositionReq <: TLObject {
    var documentId: Int64 = 0
    var accessHash: Int64 = 0
    var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    var position: Int32 = 0

    public func getConstructorId(): UInt32 { return 0xffb6d4ca }

    public func serialize(serializer: TLSerializer) {
        serializeInputDocument(serializer, this.documentId, this.accessHash, this.fileReference)
        serializer.writeInt32(this.position)
    }
}

/**
 * stickers.renameStickerSet#124b1c00
 * stickerset:InputStickerSet title:string = messages.StickerSet
 */
private class StickersRenameStickerSetReq <: TLObject {
    var packId: Int64 = 0
    var packAccessHash: Int64 = 0
    var title: String = ""

    public func getConstructorId(): UInt32 { return 0x124b1c00 }

    public func serialize(serializer: TLSerializer) {
        serializeInputStickerSetID(serializer, this.packId, this.packAccessHash)
        serializer.writeString(this.title)
    }
}

// ==================== Response Parsing ====================

/**
 * Parse messages.StickerSet response for authoring operations.
 * messages.stickerSet#6e153f16 set:StickerSet packs:Vector<StickerPack>
 *   keywords:Vector<StickerKeyword> documents:Vector<Document> = messages.StickerSet
 * (tl_codegen verified: 0x6e153f16 from telegram_api.tl:674)
 * We only extract the StickerSet header fields for the result.
 *
 * Inline because StickersService.parseStickerSetResponse is package-private.
 */
private func parseAuthorStickerSetResponse(data: Array<Byte>): StickerPackAuthorResult {
    let result = StickerPackAuthorResult()
    if (data.size < 4) {
        return result
    }
    let d = TLDeserializer(data)
    let outerCtor = d.readUInt32()
    if (outerCtor != 0x6e153f16) {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] unexpected messages.StickerSet ctor 0x${outerCtor}")
        return result
    }
    let setCtor = d.readUInt32()
    if (setCtor != 0x2dd14edc && setCtor != 0xeeb46f27) {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] unexpected stickerSet inner ctor")
        return result
    }
    let flags = d.readInt32()
    // flags.0 installed_date?int
    if ((flags & 1) != 0) {
        let _ = d.readInt32()
    }
    // We only need id, access_hash, title, short_name, count from the set header
    let _ = flags  // archived/animated/video/emoji bits not needed here
    result.packId = d.readInt64()
    result.accessHash = d.readInt64()
    result.title = d.readString()
    result.shortName = d.readString()
    result.success = true
    return result
}

// ==================== StickerPackAuthorService ====================

/**
 * StickerPackAuthorService — 贴纸包创作/编辑服务
 *
 * iOS 对照:
 *   TelegramCore/Sources/TelegramEngine/Stickers/ImportStickers.swift
 *   TelegramCore/Sources/TelegramEngine/Stickers/ManageStickers.swift
 *
 * 支持的操作:
 *   createStickerPack  — 上传贴纸字节 → FileUploadService → createStickerSet
 *   addStickerToSet    — 上传单张贴纸 → FileUploadService → addStickerToSet
 *   removeStickerFromSet — 从包中删除已有贴纸（需 InputDocument 引用）
 *   renameStickerSet   — 修改包标题
 *   changeStickerPosition — 移动贴纸顺序
 *
 * FileUploadService (P2-250) 复用:
 *   uploadFile(data, fileName) → Some(InputFileUploaded) or Some(InputFileBig)
 *   上传结果 TLObject 中的 id/parts/name 用于构造 InputDocument（需服务端分配 documentId 后才有）
 *
 * 注意：createStickerSet 接受 InputFile（已上传分块），不是 InputDocument。
 * 贴纸文件上传完成后，stickers.createStickerSet 的 sticker.document 字段是
 * 新上传内容对应的 InputDocument（由客户端构造：id=fileId, access_hash=0, file_reference=[]）。
 * 实际 documentId/accessHash 由服务端在响应 messages.StickerSet.documents[] 中返回。
 * 这与 iOS TelegramCore 中 ImportStickers 的实现一致：传 inputDocument(id: file.id, ...) 。
 */
public class StickerPackAuthorService {

    /**
     * 上传一张独立贴纸并返回服务端 Document。iOS 编辑器的 Send / Favorite 都先走
     * uploadMedia，再分别发送或收藏；此前鸿蒙只有建包路径，导致编辑器无法闭环。
     */
    public func uploadStandaloneSticker(item: StickerSetInputItem): StickerItem {
        let output = StickerItem()
        let uploadResult = getFileUploadService().uploadFile(item.documentBytes, item.fileName)
        match (uploadResult) {
            case None => return output
            case Some(tlFile) =>
                let doc = uploadMediaGetDocument(tlFile, item.mimeType, item.emoji)
                if (!doc.success) { return output }
                output.documentId = doc.documentId
                output.accessHash = doc.accessHash
                output.fileReference = doc.fileReference
                output.mimeType = item.mimeType
                output.altEmoji = item.emoji
                output.size = Int64(item.documentBytes.size)
                output.width = 512
                output.height = 512
                return output
        }
    }

    /**
     * 创建贴纸包
     *
     * 流程:
     *   1. 对每个 StickerSetInputItem，调用 FileUploadService.uploadFile 上传字节 → InputFile(id, parts)
     *   2. 将上传结果 id 当作 InputDocument(id=fileId, accessHash=0, fileReference=[]) 放入 stickers
     *   3. 发送 stickers.createStickerSet
     *
     * @param title      包显示名
     * @param shortName  包短名 (user_pack_name)
     * @param items      待上传的贴纸列表（含原始字节和 emoji）
     * @param isMaskPack 是否是面具包（masks flag）
     * @return StickerPackAuthorResult
     */
    public func createStickerPack(
        title: String,
        shortName: String,
        items: ArrayList<StickerSetInputItem>,
        isMaskPack!: Bool = false
    ): StickerPackAuthorResult {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] createStickerPack title=${title} items=${items.size}")
        let result = StickerPackAuthorResult()
        if (items.size == 0) {
            result.errorCode = "NO_STICKERS"
            return result
        }

        let uploadSvc = getFileUploadService()
        let docItems: ArrayList<StickerSetDocumentItem> = ArrayList<StickerSetDocumentItem>()

        var i: Int64 = 0
        while (i < Int64(items.size)) {
            let src = items[i]
            let uploadResult = uploadSvc.uploadFile(src.documentBytes, src.fileName)
            match (uploadResult) {
                case None =>
                    Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] upload failed at index=${i}")
                    result.errorCode = "UPLOAD_FAILED"
                    return result
                case Some(tlFile) =>
                    // Step 2 (iOS ImportStickers.swift L86): call messages.uploadMedia to get
                    // the server-assigned document triple (id/access_hash/file_reference).
                    let docRes = uploadMediaGetDocument(tlFile, src.mimeType, src.emoji)
                    if (!docRes.success) {
                        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] uploadMedia failed at index=${i}")
                        result.errorCode = "UPLOAD_MEDIA_FAILED"
                        return result
                    }
                    let docItem = StickerSetDocumentItem()
                    docItem.documentId = docRes.documentId
                    docItem.accessHash = docRes.accessHash
                    docItem.fileReference = docRes.fileReference
                    docItem.emoji = src.emoji
                    docItem.hasMaskCoords = src.hasMaskCoords
                    docItem.maskCoordsN = src.maskCoordsN
                    docItem.maskCoordsX = src.maskCoordsX
                    docItem.maskCoordsY = src.maskCoordsY
                    docItem.maskCoordsZoom = src.maskCoordsZoom
                    docItem.keywords = src.keywords
                    docItems.add(docItem)
            }
            i = i + 1
        }

        let req = StickersCreateStickerSetReq()
        req.title = title
        req.shortName = shortName
        req.stickers = docItems
        req.isMaskPack = isMaskPack

        let client = getMTProtoClient()
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] stickers.createStickerSet shortName=${shortName}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }
        return parseAuthorStickerSetResponse(responseData)
    }

    /**
     * 向已有贴纸包添加贴纸
     *
     * 流程:
     *   1. 上传贴纸字节 → FileUploadService.uploadFile → InputFile
     *   2. 构造 InputDocument(id=fileId, accessHash=0, fileReference=[])
     *   3. 发送 stickers.addStickerToSet
     *
     * @param packId        贴纸包 ID
     * @param packAccessHash 贴纸包 access_hash
     * @param item          待上传的贴纸（含字节和 emoji）
     * @return StickerPackAuthorResult
     */
    public func addStickerToSet(
        packId: Int64,
        packAccessHash: Int64,
        item: StickerSetInputItem
    ): StickerPackAuthorResult {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] addStickerToSet packId=${packId}")
        let result = StickerPackAuthorResult()

        let uploadSvc = getFileUploadService()
        let uploadResult = uploadSvc.uploadFile(item.documentBytes, item.fileName)
        let docItem = StickerSetDocumentItem()
        match (uploadResult) {
            case None =>
                result.errorCode = "UPLOAD_FAILED"
                return result
            case Some(tlFile) =>
                // Step 2 (iOS ImportStickers.swift L86): call messages.uploadMedia to get
                // the server-assigned document triple (id/access_hash/file_reference).
                let docRes = uploadMediaGetDocument(tlFile, item.mimeType, item.emoji)
                if (!docRes.success) {
                    Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] addStickerToSet uploadMedia failed")
                    result.errorCode = "UPLOAD_MEDIA_FAILED"
                    return result
                }
                docItem.documentId = docRes.documentId
                docItem.accessHash = docRes.accessHash
                docItem.fileReference = docRes.fileReference
                docItem.emoji = item.emoji
                docItem.hasMaskCoords = item.hasMaskCoords
                docItem.maskCoordsN = item.maskCoordsN
                docItem.maskCoordsX = item.maskCoordsX
                docItem.maskCoordsY = item.maskCoordsY
                docItem.maskCoordsZoom = item.maskCoordsZoom
                docItem.keywords = item.keywords
        }

        let req = StickersAddStickerToSetReq()
        req.packId = packId
        req.packAccessHash = packAccessHash
        req.sticker = docItem

        let client = getMTProtoClient()
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] stickers.addStickerToSet")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }
        return parseAuthorStickerSetResponse(responseData)
    }

    /**
     * 从贴纸包中删除已有贴纸
     * 调用者提供已知的 InputDocument 引用（documentId/accessHash/fileReference）
     *
     * TL: stickers.removeStickerFromSet#f7760f51 sticker:InputDocument = messages.StickerSet
     *
     * @param documentId  已有贴纸的 document ID
     * @param accessHash  已有贴纸的 access_hash
     * @param fileReference 已有贴纸的 file_reference
     * @return StickerPackAuthorResult
     */
    public func removeStickerFromSet(
        documentId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>
    ): StickerPackAuthorResult {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] removeStickerFromSet documentId=${documentId}")
        let result = StickerPackAuthorResult()

        let req = StickersRemoveStickerFromSetReq()
        req.documentId = documentId
        req.accessHash = accessHash
        req.fileReference = fileReference

        let client = getMTProtoClient()
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] stickers.removeStickerFromSet")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }
        return parseAuthorStickerSetResponse(responseData)
    }

    /**
     * 重命名贴纸包
     * TL: stickers.renameStickerSet#124b1c00 stickerset:InputStickerSet title:string = messages.StickerSet
     *
     * @param packId        贴纸包 ID
     * @param packAccessHash 贴纸包 access_hash
     * @param newTitle      新标题
     * @return StickerPackAuthorResult
     */
    public func renameStickerSet(
        packId: Int64,
        packAccessHash: Int64,
        newTitle: String
    ): StickerPackAuthorResult {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] renameStickerSet packId=${packId} newTitle=${newTitle}")
        let result = StickerPackAuthorResult()

        let req = StickersRenameStickerSetReq()
        req.packId = packId
        req.packAccessHash = packAccessHash
        req.title = newTitle

        let client = getMTProtoClient()
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] stickers.renameStickerSet")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }
        return parseAuthorStickerSetResponse(responseData)
    }

    /**
     * 修改贴纸在包内的顺序
     * TL: stickers.changeStickerPosition#ffb6d4ca sticker:InputDocument position:int = messages.StickerSet
     *
     * @param documentId    贴纸的 document ID
     * @param accessHash    贴纸的 access_hash
     * @param fileReference 贴纸的 file_reference
     * @param newPosition   新位置索引（0-based）
     * @return StickerPackAuthorResult
     */
    public func changeStickerPosition(
        documentId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        newPosition: Int32
    ): StickerPackAuthorResult {
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] changeStickerPosition documentId=${documentId} pos=${newPosition}")
        let result = StickerPackAuthorResult()

        let req = StickersChangeStickerPositionReq()
        req.documentId = documentId
        req.accessHash = accessHash
        req.fileReference = fileReference
        req.position = newPosition

        let client = getMTProtoClient()
        Hilog.info(0, "CjTelegram", "[StickerPackAuthorService] stickers.changeStickerPosition")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            result.errorCode = "NETWORK_ERROR"
            return result
        }
        return parseAuthorStickerSetResponse(responseData)
    }
}

// ==================== Singleton accessor ====================

private var _stickerPackAuthorServiceInstance: Option<StickerPackAuthorService> = None

public func getStickerPackAuthorService(): StickerPackAuthorService {
    match (_stickerPackAuthorServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = StickerPackAuthorService()
            _stickerPackAuthorServiceInstance = Some(inst)
            return inst
    }
}
