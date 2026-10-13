package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * GalleryService — 媒体浏览服务（Phase Gallery / GALL-API-1）
 *
 * 对应 iOS submodules/GalleryUI（GalleryController, GalleryItem, GalleryControllerNode）
 *
 * 职责：
 *   - 通过 messages.search + InputMessagesFilterPhotos/Video 从已缓存的聊天消息中
 *     检索可展示的图片与视频条目
 *   - 维护当前画廊条目列表 + 当前索引
 *   - 不新建 MTProto 连接：直接复用 getRealMessageService() 已有通道
 *
 * 调用链（完整）：
 *   GalleryPage.loadItems(peerType, peerId)
 *     → GalleryService.loadPhotoMediaItems(peerType, peerId, limit)
 *         → getRealMessageService().searchMessages(peerType, peerId, "", filter, limit)
 *             → MessagesHistoryResponse.messages: ArrayList<TLMessage>
 *                 → buildItem(tlMsg) → GalleryItem
 *
 *   GalleryPage.openItem(index)
 *     → GalleryService.setCurrentIndex(index)
 *         → currentItem() → GalleryItem
 *
 * MTProto 说明：
 *   搜索走 messages.search（MessagesSearch TL 方法）。
 *   图片下载走 FileDownloadService.downloadDocument / InputPhotoFileLocation。
 *   本 feature 为 local_state：浏览本地已下载媒体，不新发明独立 MTProto 通道。
 */

// ─── 数据模型 ─────────────────────────────────────────────────────────────────

/**
 * 单个画廊条目
 * 对应 iOS GalleryItem + ChatImageGalleryItem / UniversalVideoGalleryItem
 */
public class GalleryItem {
    /** 来源消息 ID */
    public var messageId: Int64 = 0
    /** 消息发送时间戳（秒） */
    public var date: Int32 = 0
    /** 媒体类型："photo" | "video" | "document" */
    public var mediaType: String = ""
    /** 已下载到本地的文件路径（空 = 尚未下载） */
    public var localPath: String = ""
    /** 媒体标题/文件名 */
    public var caption: String = ""
    /** 图片宽度（像素） */
    public var width: Int32 = 0
    /** 图片高度（像素） */
    public var height: Int32 = 0
    /** 文件大小（字节） */
    public var fileSize: Int64 = 0
    /** 对应 TLMessage 的 photoId（用于下载） */
    public var photoId: Int64 = 0
    public var photoAccessHash: Int64 = 0
    public var photoFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var photoDcId: Int32 = 0
    /** 对应 TLMessage 的 documentId（视频/文档用） */
    public var documentId: Int64 = 0
    public var documentAccessHash: Int64 = 0
    public var documentFileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var documentDcId: Int32 = 0
    public var mimeType: String = ""
    /** 是否是阅后即焚（secret chat media） */
    public var isSecret: Bool = false
    /** 秘密消息自毁倒计时（秒，0 表示无倒计时） */
    public var selfDestructSeconds: Int32 = 0
    /** 相册组 ID（>0 表示该消息属于相册，由 ic_gallery_item_grouped_id IC 填充；0 = 单条消息） */
    public var groupedId: Int64 = 0

    public init() {}
}

// ─── 单例 ─────────────────────────────────────────────────────────────────────

private var _galleryServiceInstance: Option<GalleryService> = None

/** 获取 GalleryService 单例 */
public func getGalleryService(): GalleryService {
    match (_galleryServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = GalleryService()
            _galleryServiceInstance = Some(inst)
            return inst
    }
}

// ─── GalleryService ───────────────────────────────────────────────────────────

public class GalleryService {

    /** 当前已加载的画廊条目列表 */
    public var items: ArrayList<GalleryItem> = ArrayList<GalleryItem>()
    /** 当前浏览索引（大图预览用） */
    public var currentIndex: Int64 = 0
    /** 是否正在加载 */
    public var isLoading: Bool = false
    /** 最后一次加载错误描述（空 = 无错误） */
    public var lastError: String = ""

    public init() {}

    // ─── 加载接口 ──────────────────────────────────────────────────────────────

    /**
     * 加载指定聊天的图片消息列表
     *
     * 对应 iOS GalleryController 初始化时通过 messages.search 拉取 photo 消息。
     *
     * @param peerType 对端类型（"user" / "group" / "channel"）
     * @param peerId   对端 ID
     * @param limit    最大条目数，默认 50
     * @return 加载到的 GalleryItem 列表（同时更新 this.items）
     */
    public func loadPhotoMediaItems(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 50
    ): ArrayList<GalleryItem> {
        Hilog.info(0, "CjTelegram", "[GalleryService] loadPhotoMediaItems peer=${peerId} limit=${limit}")
        isLoading = true
        lastError = ""
        let result = ArrayList<GalleryItem>()
        try {
            let msgService = getRealMessageService()
            let filter = InputMessagesFilterPhotos()
            let response = msgService.searchMessages(peerType, peerId, "", filter, limit)
            for (msg in response.messages) {
                if (msg.mediaType == "photo") {
                    result.add(buildItemFromTLMessage(msg))
                }
            }
        } catch (e: Exception) {
            lastError = e.message
            Hilog.info(0, "CjTelegram", "[GalleryService] loadPhotoMediaItems error: ${e.message}")
        }
        items = result
        currentIndex = 0
        isLoading = false
        return result
    }

    /**
     * 加载指定聊天的视频消息列表
     *
     * @param peerType 对端类型
     * @param peerId   对端 ID
     * @param limit    最大条目数，默认 50
     * @return 加载到的 GalleryItem 列表（追加到 this.items）
     */
    public func loadVideoMediaItems(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 50
    ): ArrayList<GalleryItem> {
        Hilog.info(0, "CjTelegram", "[GalleryService] loadVideoMediaItems peer=${peerId} limit=${limit}")
        lastError = ""
        let result = ArrayList<GalleryItem>()
        try {
            let msgService = getRealMessageService()
            let filter = InputMessagesFilterVideo()
            let response = msgService.searchMessages(peerType, peerId, "", filter, limit)
            for (msg in response.messages) {
                if (msg.mediaType == "video") {
                    result.add(buildItemFromTLMessage(msg))
                }
            }
        } catch (e: Exception) {
            lastError = e.message
            Hilog.info(0, "CjTelegram", "[GalleryService] loadVideoMediaItems error: ${e.message}")
        }
        return result
    }

    /**
     * 同时加载图片 + 视频（混合画廊）
     *
     * @param peerType 对端类型
     * @param peerId   对端 ID
     * @param limit    每种类型最大条目数，默认 50
     */
    public func loadAllMediaItems(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 50
    ): Unit {
        Hilog.info(0, "CjTelegram", "[GalleryService] loadAllMediaItems peer=${peerId}")
        isLoading = true
        lastError = ""
        let combined = ArrayList<GalleryItem>()
        let photos = loadPhotoMediaItems(peerType, peerId, limit: limit)
        for (item in photos) { combined.add(item) }
        let videos = loadVideoMediaItems(peerType, peerId, limit: limit)
        for (item in videos) { combined.add(item) }
        items = combined
        currentIndex = 0
        isLoading = false
        Hilog.info(0, "CjTelegram", "[GalleryService] loadAllMediaItems: ${items.size} items total")
    }

    // ─── 导航接口 ──────────────────────────────────────────────────────────────

    /** 设置当前浏览索引（用于 Swiper 联动） */
    public func setCurrentIndex(index: Int64): Unit {
        if (index >= 0 && index < Int64(items.size)) {
            currentIndex = index
        }
    }

    /** 获取当前条目（None = 列表为空） */
    public func currentItem(): Option<GalleryItem> {
        if (items.size == 0) { return None }
        if (currentIndex < 0 || currentIndex >= Int64(items.size)) { return None }
        return Some(items[currentIndex])
    }

    /** 移到下一条（到头循环） */
    public func moveNext(): Unit {
        if (items.size == 0) { return }
        currentIndex = (currentIndex + 1) % Int64(items.size)
    }

    /** 移到上一条（到头循环） */
    public func movePrev(): Unit {
        if (items.size == 0) { return }
        if (currentIndex == 0) {
            currentIndex = Int64(items.size) - 1
        } else {
            currentIndex = currentIndex - 1
        }
    }

    /** 返回条目总数 */
    public func itemCount(): Int64 { return Int64(items.size) }

    /** 清空条目列表（切换聊天时调用） */
    public func clearItems(): Unit {
        items = ArrayList<GalleryItem>()
        currentIndex = 0
        lastError = ""
    }

    // ─── 私有辅助方法 ──────────────────────────────────────────────────────────

    /**
     * 将 TLMessage 转换为 GalleryItem
     * 对应 iOS mediaForMessage(message:) 提取逻辑
     */
    private func buildItemFromTLMessage(msg: TLMessage): GalleryItem {
        let item = GalleryItem()
        item.messageId = Int64(msg.id)
        item.date = msg.date
        item.mediaType = msg.mediaType
        item.caption = msg.message
        item.groupedId = msg.groupedId
        // localPath starts empty; GalleryPage resolves via FileDownloadService on demand
        item.localPath = ""

        if (msg.mediaType == "photo") {
            item.photoId = msg.photoId
            item.photoAccessHash = msg.photoAccessHash
            item.photoFileReference = msg.photoFileReference
            item.photoDcId = msg.photoDcId
            item.width = msg.photoWidth
            item.height = msg.photoHeight
            item.fileSize = Int64(msg.photoFileSize)
        } else {
            item.documentId = msg.documentId
            item.documentAccessHash = msg.documentAccessHash
            item.documentFileReference = msg.documentFileReference
            item.documentDcId = msg.documentDcId
            item.fileSize = msg.documentSize
            item.mimeType = msg.documentMimeType
        }

        Hilog.info(0, "CjTelegram", "[GalleryService] buildItem msgId=${msg.id} type=${msg.mediaType}")
        return item
    }
}
