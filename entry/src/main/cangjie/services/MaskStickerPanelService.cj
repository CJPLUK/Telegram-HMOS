package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.*

// ==================== TL Request ====================

/**
 * messages.getMaskStickers#640f82b8 hash:long = messages.AllStickers
 *
 * iOS Api42.swift L7354: appendInt32(1678738104) = 0x640f82b8
 * 返回安装的所有 mask 贴纸包。响应格式与 getAllStickers 完全一致：
 *   messages.allStickersNotModified#e86602c3
 *   messages.allStickers#cdbbcebb hash:long sets:Vector<StickerSet>
 *
 * 验证: python3 -c "print(hex(1678738104))" => 0x640f82b8
 */
class MaskStickersGetMaskStickers <: TLObject {
    var hash: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x640f82b8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt64(this.hash)
    }
}

/**
 * stickers.checkShortName#284b3639 short_name:string = Bool
 *
 * iOS Api42.swift L12936: appendInt32(676017721) = 0x284b3639
 * 验证贴纸包短名是否可用（Bool 响应）
 */
class StickersCheckShortNameReq <: TLObject {
    var shortName: String = ""

    public func getConstructorId(): UInt32 { return 0x284b3639 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.shortName)
    }
}

// ==================== Result Models ====================

/**
 * MaskPacksResult — getMaskStickers 响应结果
 * 结构与 AllStickersResult 相同，专供 mask 贴纸包路径使用
 */
public class MaskPacksResult {
    public var packs: ArrayList<StickerPackInfo> = ArrayList<StickerPackInfo>()
    public var hash: Int64 = 0
    public var notModified: Bool = false
    public var success: Bool = false

    public init() {}
}

// ==================== Response Parsing ====================

/**
 * 解析 messages.getMaskStickers 响应
 * 与 messages.getAllStickers 响应格式完全一致，共享解析逻辑
 * messages.allStickersNotModified#e86602c3
 * messages.allStickers#cdbbcebb hash:long sets:Vector<StickerSet>
 */
private func parseMaskStickersResponse(data: Array<Byte>): MaskPacksResult {
    let result = MaskPacksResult()
    if (data.size < 4) { return result }
    let d = TLDeserializer(data)
    let ctor = d.readUInt32()
    if (ctor == 0xe86602c3) {
        result.notModified = true
        result.success = true
        return result
    }
    if (ctor != 0xcdbbcebb) {
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] Unexpected getMaskStickers ctor=0x${ctor}")
        return result
    }
    result.hash = d.readInt64()
    let setVCtor = d.readUInt32()
    if (setVCtor == TLConstructors.VECTOR) {
        let setCount = d.readInt32()
        var si: Int32 = 0
        while (si < setCount) {
            let setCtor = d.readUInt32()
            if (setCtor == 0x2dd14edc || setCtor == 0xeeb46f27) {
                let info = parseMaskStickerSetInfo(d)
                result.packs.add(info)
            }
            si = si + 1
        }
    }
    result.success = true
    return result
}

/**
 * 内联解析 stickerSet（mask 专用路径，避免修改 StickersService private 函数）
 * stickerSet#2dd14edc flags:# installed_date:flags.0?int archived:flags.1?true ...
 *   id:long access_hash:long title:string short_name:string
 *   thumb_dc_id:flags.4?int thumb_version:flags.4?int count:int hash:int
 */
private func parseMaskStickerSetInfo(d: TLDeserializer): StickerPackInfo {
    let info = StickerPackInfo()
    let flags = d.readInt32()
    if ((flags & 1) != 0) {
        let _ = d.readInt32()
        info.isInstalled = true
    }
    info.isArchived = (flags & 2) != 0
    info.isAnimated = (flags & 32) != 0
    info.isVideo    = (flags & 64) != 0
    info.isEmoji    = (flags & 128) != 0
    info.id = d.readInt64()
    info.accessHash = d.readInt64()
    info.title = d.readString()
    info.shortName = d.readString()
    // thumbs:flags.4?Vector<PhotoSize>
    if ((flags & 16) != 0) {
        skipMaskPhotoSizeVector(d)
        let _ = d.readInt32()
        let _ = d.readInt32()
    }
    // thumb_document_id:flags.8?long
    if ((flags & 256) != 0) { let _ = d.readInt64() }
    info.count = d.readInt32()
    info.hash = d.readInt32()
    return info
}

/**
 * 跳过 PhotoSize Vector（mask 解析路径专用，内联以不修改 StickersService）
 */
private func skipMaskPhotoSizeVector(d: TLDeserializer) {
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

// ==================== Service ====================

/**
 * MaskStickerPanelService — 面具贴纸面板服务层
 *
 * 对应 iOS ManagedSynchronizeInstalledStickerPacksOperations.swift 中 masks=true 路径
 * + SettingsUI/InstalledStickerPacksController.swift 面具分类列表
 *
 * 能力:
 *   getMaskPacks  — messages.getMaskStickers (真 TL ctor 0x640f82b8) 获取已安装 mask 包列表
 *   installMask   — messages.installStickerSet (复用 StickersService) 安装 mask 包
 *   uninstallMask — messages.uninstallStickerSet (复用 StickersService) 移除 mask 包
 *   checkShortName — stickers.checkShortName (ctor 0x284b3639) 检查短名可用性
 *
 * 调用链:
 *   MaskStickerPanelPage.aboutToAppear
 *     → MaskStickerPanelService.getMaskPacks()
 *       → getMTProtoClient().sendRequest(MaskStickersGetMaskStickers)
 *       → parseMaskStickersResponse
 */
public class MaskStickerPanelService {

    /**
     * 获取已安装的 mask 贴纸包列表
     * TL: messages.getMaskStickers#640f82b8 hash:long = messages.AllStickers
     * iOS: Api42.swift L7354 appendInt32(1678738104)
     *
     * @param hash   上次响应的 hash（增量请求；首次传 0 强制全量刷新）
     * @return MaskPacksResult（packs 列表 + notModified 标志）
     */
    public func getMaskPacks(hash!: Int64 = 0): MaskPacksResult {
        let client = getMTProtoClient()
        let req = MaskStickersGetMaskStickers()
        req.hash = hash
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] messages.getMaskStickers hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] getMaskPacks: empty response")
            return MaskPacksResult()
        }
        let result = parseMaskStickersResponse(responseData)
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] getMaskPacks: packs=${result.packs.size} success=${result.success} notModified=${result.notModified}")
        return result
    }

    /**
     * 安装 mask 贴纸包（复用 StickersService.installStickerSet）
     * TL: messages.installStickerSet#c78fe460 stickerset:InputStickerSet archived:Bool
     */
    public func installMaskPack(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] installMaskPack packId=${packId}")
        return getStickersService().installStickerSet(packId, accessHash)
    }

    /**
     * 卸载 mask 贴纸包（复用 StickersService.uninstallStickerSet）
     * TL: messages.uninstallStickerSet#f96e55de stickerset:InputStickerSet = Bool
     */
    public func uninstallMaskPack(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] uninstallMaskPack packId=${packId}")
        return getStickersService().uninstallStickerSet(packId, accessHash)
    }

    /**
     * 检查贴纸包短名是否可用
     * TL: stickers.checkShortName#284b3639 short_name:string = Bool
     * iOS: Api42.swift L12936 appendInt32(676017721)
     * 验证: python3 -c "print(hex(676017721))" => 0x284b3639
     *
     * @param shortName 待检查的短名（字母数字下划线，通常4-32字符）
     * @return true = 可用，false = 已被占用或请求失败
     */
    public func checkShortName(shortName: String): Bool {
        let client = getMTProtoClient()
        let req = StickersCheckShortNameReq()
        req.shortName = shortName
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] stickers.checkShortName shortName=${shortName}")
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] checkShortName: empty response")
            return false
        }
        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()
        let available = (ctor == TLConstructors.BOOL_TRUE)
        Hilog.info(0, "CjTelegram", "[MaskStickerPanelService] checkShortName result=${available}")
        return available
    }
}

// ==================== Singleton ====================

private var _maskStickerPanelServiceInstance: Option<MaskStickerPanelService> = None

public func getMaskStickerPanelService(): MaskStickerPanelService {
    match (_maskStickerPanelServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MaskStickerPanelService()
            _maskStickerPanelServiceInstance = Some(inst)
            return inst
    }
}
