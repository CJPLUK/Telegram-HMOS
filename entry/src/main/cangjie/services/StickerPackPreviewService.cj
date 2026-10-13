package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

// ==================== StickerPackPreviewService ====================

/**
 * StickerPackPreviewService — 贴纸包预览服务层
 *
 * 封装贴纸包预览所需的 TL 方法调用，作为 StickerPackPreviewPage 的数据层。
 * 底层复用 StickersService，调用链：
 *   StickerPackPreviewService → StickersService → getMTProtoClient().sendRequest()
 *
 * implementation_kind: local_state (tl_methods=[])
 * 实际 TL 请求委托给 StickersService：
 *   messages.getStickerSet     — 获取贴纸包详情 + 贴纸列表
 *   messages.installStickerSet   — 安装贴纸包
 *   messages.uninstallStickerSet — 移除贴纸包
 */
public class StickerPackPreviewService {

    /**
     * 通过包 ID 获取贴纸包详情（含完整贴纸列表）
     * 调用链: getPackDetail → StickersService.getStickerSet → MTProtoClient.sendRequest()
     */
    public func getPackDetail(packId: Int64, accessHash: Int64): StickerPackDetail {
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] getPackDetail packId=${packId}")
        let svc = getStickersService()
        let result = svc.getStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] getPackDetail done stickers=${result.stickers.size}")
        return result
    }

    /**
     * 通过短名称获取贴纸包详情
     * 调用链: getPackDetailByName → StickersService.getStickerSetByName → MTProtoClient.sendRequest()
     */
    public func getPackDetailByName(shortName: String): StickerPackDetail {
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] getPackDetailByName name=${shortName}")
        let svc = getStickersService()
        let result = svc.getStickerSetByName(shortName)
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] getPackDetailByName done stickers=${result.stickers.size}")
        return result
    }

    /**
     * 安装贴纸包
     * TL: messages.installStickerSet
     * 调用链: installStickerSet → StickersService.installStickerSet → MTProtoClient.sendRequest()
     */
    public func installStickerSet(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] installStickerSet packId=${packId}")
        let svc = getStickersService()
        let result = svc.installStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] installStickerSet done success=${result.success}")
        return result
    }

    /**
     * 移除贴纸包
     * TL: messages.uninstallStickerSet
     * 调用链: uninstallStickerSet → StickersService.uninstallStickerSet → MTProtoClient.sendRequest()
     */
    public func uninstallStickerSet(packId: Int64, accessHash: Int64): StickerInstallResult {
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] uninstallStickerSet packId=${packId}")
        let svc = getStickersService()
        let result = svc.uninstallStickerSet(packId, accessHash)
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewService] uninstallStickerSet done success=${result.success}")
        return result
    }
}

// ==================== Singleton accessor ====================

private var _stickerPackPreviewServiceInstance: Option<StickerPackPreviewService> = None

public func getStickerPackPreviewService(): StickerPackPreviewService {
    match (_stickerPackPreviewServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = StickerPackPreviewService()
            _stickerPackPreviewServiceInstance = Some(inst)
            return inst
    }
}
