package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

// ==================== TL Request Types ====================

/**
 * messages.getArchivedStickers#57f17692 flags:# masks:flags.0?true offset_id:long limit:int
 *   = messages.ArchivedStickers
 *
 * 获取已归档的贴纸包列表。
 *   flags.0 masks: 若设置则获取已归档 mask 贴纸包，否则获取普通已归档贴纸包
 *   offset_id: 翻页偏移（首次请求传 0）
 *   limit: 每页条数（建议 100）
 */
class ArchivedGetArchivedStickers <: TLObject {
    var masks: Bool = false
    var offsetId: Int64 = 0
    var limit: Int32 = 100

    public func getConstructorId(): UInt32 { return 0x57f17692 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.masks) { flags = flags | 1 }
        serializer.writeInt32(flags)
        serializer.writeInt64(this.offsetId)
        serializer.writeInt32(this.limit)
    }
}

// ==================== Response Models ====================

/**
 * ArchivedStickerPackInfo — 已归档贴纸包摘要信息
 *
 * 对应 TL StickerSet 中提取的核心字段，以及可选的封面贴纸文件 ID。
 */
public class ArchivedStickerPackInfo {
    public var id: Int64 = 0
    public var accessHash: Int64 = 0
    public var title: String = ""
    public var shortName: String = ""
    public var count: Int32 = 0
    public var isAnimated: Bool = false
    public var isVideo: Bool = false
    public var isEmoji: Bool = false
    public var coverDocumentId: Int64 = 0

    public init() {}
}

/**
 * ArchivedStickersResult — getArchivedStickers 返回值
 *
 * messages.archivedStickers#4fcba9c8 count:int sets:Vector<StickerSetCovered>
 */
public class ArchivedStickersResult {
    public var totalCount: Int32 = 0
    public var packs: ArrayList<ArchivedStickerPackInfo> = ArrayList<ArchivedStickerPackInfo>()
    public var success: Bool = false

    public init() {}
}

// ==================== Response Parser ====================

/**
 * 解析 stickerSet 构造器体（不含前置构造器 ID）
 *
 * stickerSet#2dd14edc flags:# installed_date:flags.0?int archived:flags.1?true ...
 *   id:long access_hash:long title:string short_name:string ...count:int hash:int
 */
private func parseArchivedStickerSetCore(d: TLDeserializer): ArchivedStickerPackInfo {
    let info = ArchivedStickerPackInfo()
    let flags = d.readInt32()
    // flags.0 installed_date?int
    if ((flags & 1) != 0) {
        let _ = d.readInt32()
    }
    // flags.1 archived (Bool flag, no field)
    info.isAnimated = (flags & 32)  != 0  // flags.5
    info.isVideo    = (flags & 64)  != 0  // flags.6
    info.isEmoji    = (flags & 128) != 0  // flags.7
    info.id          = d.readInt64()
    info.accessHash  = d.readInt64()
    info.title       = d.readString()
    info.shortName   = d.readString()
    // thumbs flags.4 Vector<PhotoSize>
    if ((flags & 16) != 0) {
        skipArchivedPhotoSizeVector(d)
        // thumb_dc_id:flags.4?int, thumb_version:flags.4?int
        let _ = d.readInt32()
        let _ = d.readInt32()
    }
    // thumb_document_id:flags.8?long
    if ((flags & 256) != 0) { let _ = d.readInt64() }
    info.count = d.readInt32()
    let _ = d.readInt32() // hash
    return info
}

/**
 * Skip a boxed Vector<PhotoSize> to advance the deserializer past thumbs fields.
 *
 * PhotoSize variants handled:
 *   photoSizeEmpty#0e17e23c type:string
 *   photoSize#75c831cd type:string w:int h:int size:int
 *   photoCachedSize#021e1ad6 type:string w:int h:int bytes:bytes
 *   photoStrippedSize#e0b0bc2e type:string bytes:bytes
 *   photoSizeProgressive#fa3efb95 type:string w:int h:int sizes:Vector<int>
 *   photoPathSize#d8214d41 type:string bytes:bytes
 */
private func skipArchivedPhotoSizeVector(d: TLDeserializer) {
    let ctor = d.readUInt32()
    if (ctor != TLConstructors.VECTOR) { return }
    let cnt = d.readInt32()
    var i: Int32 = 0
    while (i < cnt) {
        let psCtor = d.readUInt32()
        if (psCtor == 0x0e17e23c) {
            let _ = d.readString()
        } else if (psCtor == 0x75c831cd) {
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
            let _ = d.readString()
            let _ = d.readBytes()
        }
        i = i + 1
    }
}

/**
 * Skip a Document (cover sticker) and extract its document ID.
 *
 * document#8fd4c4d8 flags:# id:long access_hash:long file_reference:bytes date:int
 *   mime_type:string size:long thumbs:flags.0?Vector<PhotoSize>
 *   video_thumbs:flags.1?Vector<VideoSize> dc_id:int attributes:Vector<DocumentAttribute>
 *
 * Returns the document id (0 on parse failure / documentEmpty).
 */
private func skipArchivedDocument(d: TLDeserializer): Int64 {
    let ctor = d.readUInt32()
    // documentEmpty#36f8c871 id:long
    if (ctor == 0x36f8c871) {
        let docId = d.readInt64()
        return docId
    }
    if (ctor != 0x8fd4c4d8 && ctor != 0x1e5c1b28 && ctor != 0x9ba29cc1) {
        return 0
    }
    let flags = d.readInt32()
    let docId = d.readInt64()
    let _ = d.readInt64()   // access_hash
    let _ = d.readBytes()   // file_reference
    let _ = d.readInt32()   // date
    let _ = d.readString()  // mime_type
    let _ = d.readInt64()   // size
    if ((flags & 1) != 0) { skipArchivedPhotoSizeVector(d) }
    if ((flags & 2) != 0) { skipArchivedVideoSizeVector(d) }
    let _ = d.readInt32()   // dc_id
    // attributes: Vector<DocumentAttribute> — skip entire vector
    let attrVCtor = d.readUInt32()
    if (attrVCtor == TLConstructors.VECTOR) {
        let attrCount = d.readInt32()
        var ai: Int32 = 0
        while (ai < attrCount) {
            let attrCtor = d.readUInt32()
            if (attrCtor == 0x6319d612) {
                // documentAttributeSticker flags:# alt:string stickerset:InputStickerSet mask_coords:flags.0?MaskCoords
                let attrFlags = d.readInt32()
                let _ = d.readString()
                skipArchivedInputStickerSet(d)
                if ((attrFlags & 1) != 0) {
                    let _ = d.readInt32()
                    let _ = d.readInt64()
                    let _ = d.readInt64()
                    let _ = d.readInt64()
                }
            } else if (attrCtor == 0x11b58939) {
                let _ = d.readInt32()
                let _ = d.readInt32()
            } else if (attrCtor == 0x6c37c15c) {
                let _ = d.readString()
            } else if (attrCtor == 0xef02ce6 || attrCtor == 0x0ef02ce6) {
                // animated — no fields
            } else if (attrCtor == 0x051448e5 || attrCtor == 0x51448e5) {
                let _ = d.readInt32()
                let _ = d.readInt64()
                let _ = d.readInt32()
                let _ = d.readInt32()
            } else if (attrCtor == 0x9801d2f7) {
                let attrFlags2 = d.readInt32()
                let _ = attrFlags2
                let _ = d.readString()
                skipArchivedInputStickerSet(d)
            } else {
                return docId
            }
            ai = ai + 1
        }
    }
    return docId
}

/**
 * Skip Vector<VideoSize> to advance deserializer.
 */
private func skipArchivedVideoSizeVector(d: TLDeserializer) {
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
                let colorCnt = d.readInt32()
                var ci: Int32 = 0
                while (ci < colorCnt) {
                    let _ = d.readInt32()
                    ci = ci + 1
                }
            }
        }
        i = i + 1
    }
}

/**
 * Skip InputStickerSet (boxed) to advance deserializer.
 */
private func skipArchivedInputStickerSet(d: TLDeserializer) {
    let ctor = d.readUInt32()
    if (ctor == 0xffb62b95 || ctor == 0x028703c8) {
        return
    }
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
 * 解析 messages.archivedStickers 响应
 *
 * messages.archivedStickers#4fcba9c8 count:int sets:Vector<StickerSetCovered>
 *
 * StickerSetCovered variants:
 *   stickerSetCovered#6410a5d2 set:StickerSet cover:Document
 *   stickerSetMultiCovered#3407e51b set:StickerSet covers:Vector<Document>
 */
private func parseArchivedStickersResponse(data: Array<Byte>): ArchivedStickersResult {
    let result = ArchivedStickersResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor != 0x4fcba9c8) {
        Hilog.info(0, "CjTelegram", "[ArchivedStickerPacksNoticeService] Unexpected archivedStickers ctor")
        return result
    }
    result.totalCount = d.readInt32()
    let setVCtor = d.readUInt32()
    if (setVCtor == TLConstructors.VECTOR) {
        let setCount = d.readInt32()
        var si: Int32 = 0
        while (si < setCount) {
            let coverCtor = d.readUInt32()
            if (coverCtor == 0x6410a5d2) {
                // stickerSetCovered: set:StickerSet cover:Document
                let setCtor2 = d.readUInt32()
                if (setCtor2 == 0x2dd14edc || setCtor2 == 0xeeb46f27) {
                    let info = parseArchivedStickerSetCore(d)
                    let coverId = skipArchivedDocument(d)
                    info.coverDocumentId = coverId
                    result.packs.add(info)
                }
            } else if (coverCtor == 0x3407e51b) {
                // stickerSetMultiCovered: set:StickerSet covers:Vector<Document>
                let setCtor3 = d.readUInt32()
                if (setCtor3 == 0x2dd14edc || setCtor3 == 0xeeb46f27) {
                    let info = parseArchivedStickerSetCore(d)
                    let coversVCtor = d.readUInt32()
                    if (coversVCtor == TLConstructors.VECTOR) {
                        let coversCount = d.readInt32()
                        var ci: Int32 = 0
                        while (ci < coversCount) {
                            let covId = skipArchivedDocument(d)
                            if (ci == 0) { info.coverDocumentId = covId }
                            ci = ci + 1
                        }
                    }
                    result.packs.add(info)
                }
            }
            si = si + 1
        }
    }
    result.success = true
    return result
}

// ==================== Service Singleton ====================

private var _archivedStickerPacksNoticeServiceInstance: Option<ArchivedStickerPacksNoticeService> = None

public func getArchivedStickerPacksNoticeService(): ArchivedStickerPacksNoticeService {
    match (_archivedStickerPacksNoticeServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ArchivedStickerPacksNoticeService()
            _archivedStickerPacksNoticeServiceInstance = Some(inst)
            return inst
    }
}

// ==================== ArchivedStickerPacksNoticeService ====================

/**
 * ArchivedStickerPacksNoticeService — 已归档贴纸包提示数据层
 *
 * 封装 messages.getArchivedStickers TL 方法，供 ArchivedStickerPacksNoticeComponent 使用。
 *
 * 调用链：ArchivedStickerPacksNoticeService → getMTProtoClient() → MTProtoClient.sendRequest()
 *
 * 依赖 StickersService 的 installStickerSet 能力来恢复归档贴纸包。
 */
public class ArchivedStickerPacksNoticeService {

    /**
     * 获取已归档的贴纸包列表
     *
     * TL: messages.getArchivedStickers#57f17692 flags:# masks:flags.0?true offset_id:long limit:int
     *
     * @param offsetId 翻页偏移，首次调用传 0
     * @param limit 每页数量，默认 100
     * @param masks 是否获取已归档的 mask 贴纸包（默认 false，获取普通贴纸包）
     */
    public func getArchivedStickers(offsetId!: Int64 = 0, limit!: Int32 = 100, masks!: Bool = false): ArchivedStickersResult {
        let client = getMTProtoClient()
        let req = ArchivedGetArchivedStickers()
        req.masks = masks
        req.offsetId = offsetId
        req.limit = limit
        Hilog.info(0, "CjTelegram", "[ArchivedStickerPacksNoticeService] messages.getArchivedStickers offset=${offsetId}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ArchivedStickerPacksNoticeService] getArchivedStickers: empty response")
            return ArchivedStickersResult()
        }
        let result = parseArchivedStickersResponse(responseData)
        Hilog.info(0, "CjTelegram", "[ArchivedStickerPacksNoticeService] getArchivedStickers: total=${result.totalCount}, loaded=${result.packs.size}, success=${result.success}")
        return result
    }

    /**
     * 恢复（重新安装）一个已归档贴纸包
     *
     * 复用 StickersService.installStickerSet 发送
     * TL: messages.installStickerSet#c78fe460 stickerset:InputStickerSet archived:Bool
     *
     * @param packId 贴纸包 id
     * @param accessHash 贴纸包 access_hash
     * @return true 代表恢复成功
     */
    public func restoreArchivedPack(packId: Int64, accessHash: Int64): Bool {
        let svc = getStickersService()
        let result = svc.installStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[ArchivedStickerPacksNoticeService] restoreArchivedPack id=${packId} success=${result.success}")
        return result.success
    }
}
