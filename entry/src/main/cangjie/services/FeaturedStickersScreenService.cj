package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

// ==================== Service Singleton ====================

private var _featuredStickersScreenServiceInstance: Option<FeaturedStickersScreenService> = None

public func getFeaturedStickersScreenService(): FeaturedStickersScreenService {
    match (_featuredStickersScreenServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = FeaturedStickersScreenService()
            _featuredStickersScreenServiceInstance = Some(inst)
            return inst
    }
}

// ==================== FeaturedStickersScreenService ====================

/**
 * FeaturedStickersScreenService — 精选贴纸屏服务层
 *
 * 封装精选/热门贴纸包列表屏所需的数据操作，复用既有 getStickersService()。
 * implementation_kind=local_state：tl_methods=[]，所有网络调用通过 StickersService 完成。
 *
 * 主要接口：
 *   getFeaturedPacks()     — 获取所有已安装贴纸包列表（作为精选展示）
 *   installStickerSet()    — 安装贴纸包
 *   uninstallStickerSet()  — 卸载贴纸包
 *   getStickerPackDetail() — 获取单个贴纸包详情（供预览前确认）
 *
 * 调用链:
 *   FeaturedStickersScreenService → getStickersService()
 *       → StickersService → getMTProtoClient().sendRequest() → MTProto
 */
public class FeaturedStickersScreenService {

    /**
     * 获取精选/全部已安装贴纸包列表
     * 底层: messages.getAllStickers#1c9618b1 hash:long
     */
    public func getFeaturedPacks(): AllStickersResult {
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] getFeaturedPacks")
        let svc = getStickersService()
        let result = svc.getAllStickers()
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] getFeaturedPacks done")
        return result
    }

    /**
     * 获取真实精选/推荐贴纸包列表（来自服务端精选）
     * 底层: messages.getFeaturedStickers#64780b14 hash:long
     * 响应: messages.featuredStickers#be382906 sets:Vector<StickerSetCovered>
     */
    public func getFeaturedStickerSets(): FeaturedStickerPacksResult {
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] getFeaturedStickerSets")
        let svc = getStickersService()
        let result = svc.getFeaturedStickerPacks()
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] getFeaturedStickerSets: packs=${result.packs.size}")
        return result
    }

    /**
     * 安装贴纸包
     * 底层: messages.installStickerSet#c78fe460 stickerset:InputStickerSet archived:Bool
     */
    public func installStickerSet(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] installStickerSet")
        let svc = getStickersService()
        let result = svc.installStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] installStickerSet done")
        return result
    }

    /**
     * 卸载贴纸包
     * 底层: messages.uninstallStickerSet#f96e55de stickerset:InputStickerSet = Bool
     */
    public func uninstallStickerSet(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] uninstallStickerSet")
        let svc = getStickersService()
        let result = svc.uninstallStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] uninstallStickerSet done")
        return result
    }

    /**
     * 获取单个贴纸包详情（包含贴纸列表）
     * 底层: messages.getStickerSet#c68a15e6 stickerset:InputStickerSet hash:int
     */
    public func getStickerPackDetail(packId: Int64, accessHash: Int64): StickerPackDetail {
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] getStickerPackDetail")
        let svc = getStickersService()
        let result = svc.getStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[FeaturedStickersScreenService] getStickerPackDetail done")
        return result
    }
}
