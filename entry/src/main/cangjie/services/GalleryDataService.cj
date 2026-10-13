package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

// GalleryDataService — 画廊数据聚合服务（P2-219 gallery_data_model fidelity）
//
// 对应 iOS submodules/GalleryData/Sources/GalleryData.swift：
//   - chatMessageGalleryControllerData：按单条 message.media 路由（Gap ①）
//   - instantPageBlockMedia：collage/slideshow 聚合（Gap ②）
//   - GalleryMediaSubject 细分：gif/voice/audio/sticker/video_note（Gap ③）
//
// 职责（local_state，无新建 MTProto 通道）：
//   1. 委托 GalleryService.loadAllMediaItems() 拉取已索引的图片与视频消息
//   2. 对每条 GalleryItem 执行 resolveMediaKind()，基于精确 mediaType 派生 GalleryMediaKind
//   3. 聚合：groupedId > 0 的多条 GalleryItem 合并为 GalleryDataEntry（isCollage=true）
//   4. 单条消息独立成 GalleryDataEntry（isCollage=false）
//
// 调用链（完整）：
//   GalleryDataComponent.aboutToAppear()
//     → getGalleryDataService().loadAndAggregateGalleryData(peerType, peerId, limit)
//         → getGalleryService().loadAllMediaItems(peerType, peerId, limit)
//             → loadPhotoMediaItems / loadVideoMediaItems
//                 → getRealMessageService().searchMessages(...)
//                     → MTProtoClient.sendRequest(MessagesSearch)
//
// MTProto 调用路径由 GalleryService + RealMessageService 负责，本 service 仅做分类聚合。

// ─── Gap ③: 媒体主体类型细分枚举 ─────────────────────────────────────────────────

// 画廊媒体分类（mediaSubject 细分）
//
// 对应 iOS chatMessageGalleryControllerData 的 media 类型分发逻辑：
//   Photo      ← TelegramMediaImage（原始图片）
//   Video      ← TelegramMediaFile(isVideo), mediaType == "video"
//   VideoNote  ← TelegramMediaFile(isRoundVideo), mediaType == "video_note"
//   Gif        ← TelegramMediaFile(isAnimated && !isVideo), mediaType == "gif"
//   Voice      ← TelegramMediaFile(isVoice), mediaType == "voice"
//   Audio      ← TelegramMediaFile(isMusic), mediaType == "audio"
//   Sticker    ← TelegramMediaFile(isSticker/isAnimatedSticker), mediaType == "sticker"
//   Document   ← TelegramMediaFile（普通文档）, mediaType == "document"
//   Unknown    ← 其他（地图/联系人等，暂不支持展示）
public enum GalleryMediaKind {
    | Photo
    | Video
    | VideoNote
    | Gif
    | Voice
    | Audio
    | Sticker
    | Document
    | Unknown
}

// 将 GalleryMediaKind 转为可读字符串（日志 / UI 标签用）
public func galleryMediaKindLabel(kind: GalleryMediaKind): String {
    match (kind) {
        case GalleryMediaKind.Photo     => return "photo"
        case GalleryMediaKind.Video     => return "video"
        case GalleryMediaKind.VideoNote => return "video_note"
        case GalleryMediaKind.Gif       => return "gif"
        case GalleryMediaKind.Voice     => return "voice"
        case GalleryMediaKind.Audio     => return "audio"
        case GalleryMediaKind.Sticker   => return "sticker"
        case GalleryMediaKind.Document  => return "document"
        case GalleryMediaKind.Unknown   => return "unknown"
    }
}

// ─── Gap ②: 聚合数据条目（含 collage/slideshow 支持）──────────────────────────

// GalleryDataEntry — 单条或相册聚合画廊数据视图
//
// 单条消息：item = 该消息的 GalleryItem，collageItems 为空，isCollage = false
// 相册（collage）：item = 第一张（封面），collageItems = 全部，isCollage = true
// 对应 iOS instantPageBlockMedia 的 collage/slideshow 聚合语义
public class GalleryDataEntry {
    // 主条目（单条消息或相册封面）
    public var item: GalleryItem
    // 分类结果
    public var kind: GalleryMediaKind
    // 可读分类标签（"photo" / "video" / "gif" / "voice" / "audio" / "sticker" / "video_note" / "document" / "unknown"）
    public var typeLabel: String
    // 是否是 collage/slideshow 相册聚合
    public var isCollage: Bool
    // 相册成员（isCollage=true 时非空；isCollage=false 时为空列表）
    public var collageItems: ArrayList<GalleryItem>

    public init(item: GalleryItem, kind: GalleryMediaKind) {
        this.item = item
        this.kind = kind
        this.typeLabel = galleryMediaKindLabel(kind)
        this.isCollage = false
        this.collageItems = ArrayList<GalleryItem>()
    }

    public init(item: GalleryItem, kind: GalleryMediaKind, collageItems: ArrayList<GalleryItem>) {
        this.item = item
        this.kind = kind
        this.typeLabel = galleryMediaKindLabel(kind)
        this.isCollage = collageItems.size > 1
        this.collageItems = collageItems
    }

    // 相册成员数（单条 = 1）
    public func collageCount(): Int64 {
        if (this.isCollage) {
            return Int64(this.collageItems.size)
        }
        return 1
    }
}

// ─── 单例 ─────────────────────────────────────────────────────────────────────

private var _galleryDataServiceInstance: Option<GalleryDataService> = None

// 获取 GalleryDataService 单例
public func getGalleryDataService(): GalleryDataService {
    match (_galleryDataServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = GalleryDataService()
            _galleryDataServiceInstance = Some(inst)
            return inst
    }
}

// ─── GalleryDataService ───────────────────────────────────────────────────────

// GalleryDataService — 画廊数据聚合服务核心（P2-219 fidelity）
//
// 复用既有 GalleryService + MediaResourcesService，不重新实现 MTProto 下载逻辑。
public class GalleryDataService {

    // 当前已加载的聚合条目列表
    public var entries: ArrayList<GalleryDataEntry> = ArrayList<GalleryDataEntry>()
    // 是否正在加载
    public var isLoading: Bool = false
    // 最后错误描述（空 = 无错误）
    public var lastError: String = ""

    public init() {}

    // ─── 主加载接口（Gap ①: 按单条 message.media 路由 + Gap ②: collage 聚合）────────

    // 加载并聚合指定聊天的画廊数据
    //
    // 实现 iOS chatMessageGalleryControllerData 的 per-message media 路由语义：
    //   每条消息独立路由 → 精确 GalleryMediaKind（Gap ①：而非 peer 级粗索引）
    //   同 groupedId 的消息聚合为 collage GalleryDataEntry（Gap ②）
    //
    // Gap ② 依赖：GalleryItem.groupedId 字段 + buildItemFromTLMessage 中填充。
    //   该字段由 ic_gallery_item_grouped_id（gallery_data_model → gallery_viewer_core）接线后生效。
    //   在 IC 未完成时，所有 groupedId 为 0，collage 聚合静默跳过（单条独立，功能不退化）。
    //
    // peerType: 对端类型（"user" / "group" / "channel"）
    // peerId:   对端 ID
    // limit:    每类最大条目数（默认 50）
    // 返回：聚合后的 GalleryDataEntry 列表（同时更新 this.entries）
    public func loadAndAggregateGalleryData(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 50
    ): ArrayList<GalleryDataEntry> {
        Hilog.info(0, "CjTelegram", "[GalleryDataService] loadAndAggregateGalleryData peer=${peerId}")
        isLoading = true
        lastError = ""
        let result = ArrayList<GalleryDataEntry>()
        try {
            let gallerySvc = getGalleryService()
            gallerySvc.loadAllMediaItems(peerType, peerId, limit: limit)
            let rawItems = gallerySvc.items

            // Gap ①: per-message media routing
            // 每条 GalleryItem 独立路由到 GalleryMediaKind（精确 mediaType 分类）
            // Gap ②: collage 聚合由 aggregateByGroupedId 完成（已实现）
            // 当前阶段（IC ic_gallery_item_grouped_id 未完成）所有 groupedId=0，
            // aggregateByGroupedId 对全 0 groupedId 自然退化为每条单独，不影响功能正确性。
            let grouped = aggregateByGroupedId(rawItems)
            let groupedCount = grouped.size
            var idx: Int64 = 0
            while (idx < groupedCount) {
                result.add(grouped[idx])
                idx = idx + 1
            }

        } catch (e: Exception) {
            lastError = e.message
            Hilog.info(0, "CjTelegram", "[GalleryDataService] loadAndAggregateGalleryData error")
        }
        entries = result
        isLoading = false
        Hilog.info(0, "CjTelegram", "[GalleryDataService] loadAndAggregateGalleryData done count=${entries.size}")
        return result
    }


    // 向后兼容：loadGalleryData = loadAndAggregateGalleryData（保持旧调用方可用）
    public func loadGalleryData(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 50
    ): ArrayList<GalleryDataEntry> {
        return loadAndAggregateGalleryData(peerType, peerId, limit: limit)
    }

    // 仅加载图片类条目
    public func loadPhotoEntries(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 50
    ): ArrayList<GalleryDataEntry> {
        Hilog.info(0, "CjTelegram", "[GalleryDataService] loadPhotoEntries peer=${peerId}")
        let all = loadAndAggregateGalleryData(peerType, peerId, limit: limit)
        let photos = ArrayList<GalleryDataEntry>()
        let count = all.size
        var idx: Int64 = 0
        while (idx < count) {
            let entry = all[idx]
            match (entry.kind) {
                case GalleryMediaKind.Photo => photos.add(entry)
                case _ => ()
            }
            idx = idx + 1
        }
        Hilog.info(0, "CjTelegram", "[GalleryDataService] loadPhotoEntries result=${photos.size}")
        return photos
    }

    // 仅加载视频类条目（含 VideoNote）
    public func loadVideoEntries(
        peerType: String,
        peerId: Int64,
        limit!: Int32 = 50
    ): ArrayList<GalleryDataEntry> {
        Hilog.info(0, "CjTelegram", "[GalleryDataService] loadVideoEntries peer=${peerId}")
        let all = loadAndAggregateGalleryData(peerType, peerId, limit: limit)
        let videos = ArrayList<GalleryDataEntry>()
        let count = all.size
        var idx: Int64 = 0
        while (idx < count) {
            let entry = all[idx]
            match (entry.kind) {
                case GalleryMediaKind.Video     => videos.add(entry)
                case GalleryMediaKind.VideoNote => videos.add(entry)
                case _ => ()
            }
            idx = idx + 1
        }
        Hilog.info(0, "CjTelegram", "[GalleryDataService] loadVideoEntries result=${videos.size}")
        return videos
    }

    // ─── Gap ①+③: 精确 per-message media 路由 ─────────────────────────────────

    // 将 GalleryItem 分类为 GalleryMediaKind
    //
    // 对应 iOS chatMessageGalleryControllerData 的 media 类型分发逻辑：
    //   item.mediaType 来自 TLMessage.mediaType，由 TLDialogs.parseDocument 精确设置
    //   （sticker / gif / voice / audio / video / video_note / photo / document）
    //
    // item: GalleryItem 原始条目（mediaType 已由 GalleryService.buildItemFromTLMessage 设置）
    // 返回：细分分类结果
    public func resolveMediaKind(item: GalleryItem): GalleryMediaKind {
        match (item.mediaType) {
            case "photo"      => return GalleryMediaKind.Photo
            case "video"      => return GalleryMediaKind.Video
            case "video_note" => return GalleryMediaKind.VideoNote
            case "gif"        => return GalleryMediaKind.Gif
            case "voice"      => return GalleryMediaKind.Voice
            case "audio"      => return GalleryMediaKind.Audio
            case "sticker"    => return GalleryMediaKind.Sticker
            case "document"   => return GalleryMediaKind.Document
            case _ => return GalleryMediaKind.Unknown
        }
    }

    // ─── Gap ②: collage 聚合 ──────────────────────────────────────────────────

    // 按 groupedId 聚合 GalleryItem 列表为 GalleryDataEntry 列表
    //
    // 聚合规则（iOS instantPageBlockMedia / chatMessageGalleryControllerData 语义）：
    //   - item.groupedId > 0：同组多条 → 合并为 1 个 collage GalleryDataEntry
    //       封面 = 首次出现的条目（保持原始顺序）
    //       collageItems = 该 groupedId 下所有条目
    //       isCollage = true（collageItems.size > 1 时）
    //   - item.groupedId <= 0 或同组仅 1 条：每条独立为单条 GalleryDataEntry
    //       isCollage = false
    //
    // IC 依赖：GalleryItem.groupedId 由 ic_gallery_item_grouped_id 在 gallery_viewer_core
    //   的 buildItemFromTLMessage 中赋值。IC 未完成时 groupedId 恒为 0，
    //   此方法自然退化为每条单独（单条路径），功能完全正确。
    //
    // items: GalleryService 返回的原始 GalleryItem 列表（有序）
    // 返回：聚合后的 GalleryDataEntry 列表（保持首次出现顺序）
    public func aggregateByGroupedId(items: ArrayList<GalleryItem>): ArrayList<GalleryDataEntry> {
        let result = ArrayList<GalleryDataEntry>()
        // 按 groupedId 收集同组的所有 item（保持插入顺序）
        // 用平行的两个 ArrayList 模拟有序 map：
        //   groupKeys[i]   → 去重后的 groupedId（>0），按首次出现顺序排列
        //   groupBuckets[i]→ 对应 groupedId 的所有 item 列表
        let groupKeys = ArrayList<Int64>()
        let groupBuckets = ArrayList<ArrayList<GalleryItem>>()
        // 单条（groupedId <= 0）按原始顺序独立存放
        let singles = ArrayList<GalleryItem>()
        // orderList 记录原始消息首次出现顺序（保证输出顺序与输入一致）
        // 每个元素是 (isGroup: Bool, indexInList: Int64)：
        //   isGroup=true  → indexInList 是 groupKeys 中的 bucket 索引
        //   isGroup=false → indexInList 是 singles 中的条目索引
        let orderIsGroup = ArrayList<Bool>()
        let orderIndex = ArrayList<Int64>()

        let count = items.size
        var i: Int64 = 0
        while (i < count) {
            let item = items[i]
            let gid = item.groupedId
            if (gid > 0) {
                // 检查是否已见过该 groupedId
                var found: Bool = false
                var keyIdx: Int64 = 0
                let keyCount = groupKeys.size
                while (keyIdx < keyCount) {
                    if (groupKeys[keyIdx] == gid) {
                        found = true
                        // 追加到已有 bucket
                        groupBuckets[keyIdx].add(item)
                        break
                    }
                    keyIdx = keyIdx + 1
                }
                if (!found) {
                    // 新 groupedId：创建新 bucket
                    let bucket = ArrayList<GalleryItem>()
                    bucket.add(item)
                    groupKeys.add(gid)
                    groupBuckets.add(bucket)
                    // 记录首次出现顺序：group，index = groupKeys.size - 1
                    orderIsGroup.add(true)
                    orderIndex.add(Int64(groupKeys.size) - 1)
                }
            } else {
                // 单条：直接记录
                singles.add(item)
                orderIsGroup.add(false)
                orderIndex.add(Int64(singles.size) - 1)
            }
            i = i + 1
        }

        // 按首次出现顺序输出聚合结果
        let orderCount = orderIsGroup.size
        var j: Int64 = 0
        while (j < orderCount) {
            if (orderIsGroup[j]) {
                let gIdx = orderIndex[j]
                let bucket = groupBuckets[gIdx]
                let firstItem = bucket[0]
                let kind = resolveMediaKind(firstItem)
                // 2-arg 构造：填充 collageItems（isCollage = collageItems.size > 1）
                result.add(GalleryDataEntry(firstItem, kind, bucket))
            } else {
                let sIdx = orderIndex[j]
                let singleItem = singles[sIdx]
                let kind = resolveMediaKind(singleItem)
                result.add(GalleryDataEntry(singleItem, kind))
            }
            j = j + 1
        }
        return result
    }

    // ─── 导航辅助 ──────────────────────────────────────────────────────────────

    // 获取指定索引的条目（Option 安全访问）
    public func entryAt(index: Int64): Option<GalleryDataEntry> {
        if (index < 0 || index >= Int64(entries.size)) {
            return None
        }
        return Some(entries[index])
    }

    // 返回当前已加载条目总数
    public func entryCount(): Int64 {
        return Int64(entries.size)
    }

    // 清空当前条目列表（切换聊天时调用）
    public func clearEntries(): Unit {
        entries = ArrayList<GalleryDataEntry>()
        lastError = ""
        Hilog.info(0, "CjTelegram", "[GalleryDataService] clearEntries")
    }
}
