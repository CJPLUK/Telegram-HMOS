package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

// ==================== Peek State Models ====================

/**
 * StickerPeekData — 长按贴纸弹出预览所需的全部数据
 * 纯本地状态，从 StickersService / 调用方传入的 StickerItem 构建，无独立 MTProto 请求
 *
 * P2-383 增强：
 * - lottieJson: 若贴纸为动画贴纸（.tgs/animated），此字段为 Lottie JSON 字符串（已解压）
 *   对应 iOS StickerPreviewPeekContentNode animationNode（AnimatedStickerNode）
 *   调用方（StickerItem）需预先解压 .tgs gzip，将 JSON 字符串写入 sticker.lottieJson
 * - isPremium: 是否为 premium 贴纸（显示 premium effect overlay）
 */
public class StickerPeekData {
    public var sticker: StickerItem = StickerItem()
    public var packInfo: StickerPackInfo = StickerPackInfo()
    public var actions: ArrayList<StickerPeekAction> = ArrayList<StickerPeekAction>()
    public var isLoaded: Bool = false
    // P2-383: 动画贴纸的 Lottie JSON（已解压；空字符串 = 非动画贴纸）
    public var lottieJson: String = ""
    // P2-383: premium 贴纸标记（用于显示 premium effect overlay）
    public var isPremium: Bool = false

    public init() {}
}

/**
 * StickerPeekAction — 预览浮层底部快捷操作按钮描述
 */
public class StickerPeekAction {
    public var label: String = ""
    public var actionId: String = ""

    public init(label!: String, actionId!: String) {
        this.label = label
        this.actionId = actionId
    }
}

// ==================== Service Singleton ====================

private var _stickerPeekServiceInstance: Option<StickerPeekService> = None

public func getStickerPeekService(): StickerPeekService {
    match (_stickerPeekServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = StickerPeekService()
            _stickerPeekServiceInstance = Some(inst)
            return inst
    }
}

// ==================== StickerPeekService ====================

/**
 * StickerPeekService — 贴纸预览弹窗数据服务
 *
 * 职责：
 *   1. 根据调用方传入的 StickerItem 构建预览所需的 StickerPeekData（纯本地 state）
 *   2. 若 StickerItem 不含包信息（packInfo 缺失），调用 StickersService.getStickerSet 补全
 *   3. 构建默认快捷操作列表：发送（send）+ 收藏（fave）+ 查看包（view_pack）
 *
 * 调用链：
 *   StickerPeekUIComponent → StickerPeekService.buildPeekData()
 *                          → getStickersService().getStickerSet()（仅 packId 有效时）
 *                          → 返回 StickerPeekData（含 StickerItem + actions）
 *
 * 无独立 TL 方法，复用 StickersService（implementation_kind: local_state）
 */
public class StickerPeekService {

    /**
     * 构建贴纸预览数据
     *
     * - sticker: 来自贴纸列表/选择器的 StickerItem
     * - packId / packAccessHash: 贴纸所属包的 ID（0 表示未知，跳过包详情请求）
     * - canSend: 是否显示"发送"按钮（聊天上下文下为 true）
     *
     * 当 packId != 0 时，调用真实 StickersService.getStickerSet 补全包信息
     */
    public func buildPeekData(sticker: StickerItem, packId: Int64, packAccessHash: Int64,
                              canSend!: Bool = true): StickerPeekData {
        let data = StickerPeekData()
        data.sticker = sticker

        if (packId != 0) {
            Hilog.info(0, "CjTelegram", "[StickerPeekService] getStickerSet for pack")
            let svc = getStickersService()
            let detail = svc.getStickerSet(packId, packAccessHash)
            if (detail.success) {
                data.packInfo = detail.info
                Hilog.info(0, "CjTelegram", "[StickerPeekService] pack loaded success")
            } else {
                Hilog.info(0, "CjTelegram", "[StickerPeekService] getStickerSet returned no data")
            }
        }

        // P2-383: lottieJson and isPremium are injected by caller via buildPeekDataWithAnimation
        // StickerItem does not carry these fields (scope boundary)


        let acts = ArrayList<StickerPeekAction>()
        if (canSend) {
            acts.add(StickerPeekAction(label: "Send", actionId: "send"))
        }
        acts.add(StickerPeekAction(label: "Favorite", actionId: "fave"))
        if (packId != 0) {
            acts.add(StickerPeekAction(label: "View Pack", actionId: "view_pack"))
        }
        data.actions = acts
        data.isLoaded = true
        return data
    }

    /**
     * 仅用 StickerItem 构建最简预览（无包信息，例如搜索结果场景）
     */
    public func buildPeekDataFromSticker(sticker: StickerItem, canSend!: Bool = true): StickerPeekData {
        return this.buildPeekData(sticker, 0, 0, canSend: canSend)
    }

    /**
     * P2-383: 带动画信息的预览数据构建
     * 对应 iOS StickerPreviewPeekContentNode：
     *   case .animation, .video: animationNode = DefaultAnimatedStickerNodeImpl()
     *
     * @param sticker      贴纸 item
     * @param packId       贴纸包 ID（0=未知）
     * @param packAccessHash 贴纸包 access hash
     * @param lottieJson   已解压的 Lottie JSON 字符串（空字符串 = 静态贴纸）
     * @param isPremium    是否为 premium 贴纸（显示 effect overlay）
     * @param canSend      是否显示 Send 按钮
     */
    public func buildPeekDataWithAnimation(
        sticker: StickerItem,
        packId: Int64,
        packAccessHash: Int64,
        lottieJson!: String = "",
        isPremium!: Bool = false,
        canSend!: Bool = true
    ): StickerPeekData {
        let data = this.buildPeekData(sticker, packId, packAccessHash, canSend: canSend)
        if (lottieJson.size > 0) {
            data.lottieJson = lottieJson
            Hilog.info(0, "CjTelegram", "[StickerPeekService] animated peek: lottieJson present")
        }
        data.isPremium = isPremium
        return data
    }

    /**
     * 从最近使用贴纸列表构建预览（先获取最近贴纸，返回第一个满足 documentId 的数据）
     *
     * 场景：贴纸选择器中长按某个 recent sticker，已知 documentId 但无 StickerItem 实例
     * 若 recentStickers 列表中找到匹配项，补全预览数据；否则返回空数据
     */
    public func buildPeekDataForRecentSticker(documentId: Int64, canSend!: Bool = true): StickerPeekData {
        Hilog.info(0, "CjTelegram", "[StickerPeekService] buildPeekDataForRecentSticker")
        let svc = getStickersService()
        let recent = svc.getRecentStickers()
        if (recent.success) {
            var i: Int64 = 0
            while (i < Int64(recent.stickers.size)) {
                let item = recent.stickers[i]
                if (item.documentId == documentId) {
                    return this.buildPeekDataFromSticker(item, canSend: canSend)
                }
                i = i + 1
            }
        }
        let empty = StickerPeekData()
        empty.isLoaded = false
        return empty
    }
}
