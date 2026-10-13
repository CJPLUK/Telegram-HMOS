package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * ItemListStickerPackService — 贴纸包列表行项数据服务
 *
 * 封装贴纸包列表所需的数据操作：
 *   getAllStickerPacks() — 获取所有已安装贴纸包列表
 *   installStickerSet()  — 安装贴纸包
 *   uninstallStickerSet() — 卸载贴纸包
 *
 * 调用链: ItemListStickerPackService → getStickersService() → StickersService → getMTProtoClient().sendRequest()
 */
public class ItemListStickerPackService {

    /**
     * 获取所有已安装贴纸包列表（用于贴纸包列表行项展示）
     * TL: messages.getAllStickers#1c9618b1 hash:long
     */
    public func getAllStickerPacks(): AllStickersResult {
        Hilog.info(0, "CjTelegram", "[ItemListStickerPackService] getAllStickerPacks", [])
        let svc = getStickersService()
        let result = svc.getAllStickers()
        Hilog.info(0, "CjTelegram", "[ItemListStickerPackService] getAllStickerPacks done", [])
        return result
    }

    /**
     * 安装贴纸包
     * TL: messages.installStickerSet#c78fe460 stickerset:InputStickerSet archived:Bool
     *
     * @param packId     贴纸包 ID
     * @param accessHash 贴纸包 access_hash
     * @return StickerInstallResult (success=true 时安装成功)
     */
    public func installStickerSet(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[ItemListStickerPackService] installStickerSet", [])
        let svc = getStickersService()
        let result = svc.installStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[ItemListStickerPackService] installStickerSet done", [])
        return result
    }

    /**
     * 卸载贴纸包
     * TL: messages.uninstallStickerSet#f96e55de stickerset:InputStickerSet = Bool
     *
     * @param packId     贴纸包 ID
     * @param accessHash 贴纸包 access_hash
     * @return StickerInstallResult (success=true 时卸载成功)
     */
    public func uninstallStickerSet(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[ItemListStickerPackService] uninstallStickerSet", [])
        let svc = getStickersService()
        let result = svc.uninstallStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[ItemListStickerPackService] uninstallStickerSet done", [])
        return result
    }
}

// ==================== Singleton accessor ====================

private var _itemListStickerPackServiceInstance: Option<ItemListStickerPackService> = None

public func getItemListStickerPackService(): ItemListStickerPackService {
    match (_itemListStickerPackServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ItemListStickerPackService()
            _itemListStickerPackServiceInstance = Some(inst)
            return inst
    }
}
