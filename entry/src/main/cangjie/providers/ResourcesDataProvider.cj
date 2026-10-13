package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getResourcesService,
    getFileDownloadService,
    getMediaResourcesService,
    TelegramEngine_ResourcesService,
    MediaResourceRef,
    ResourceFetchStatus,
    CacheUsageEntry,
    StorageUsageStats,
    StorageCategoryKey,
    CustomFetchRequest
}
import std.collection.ArrayList

/**
 * ResourcesDataProvider — 将 TelegramEngine.Resources API 数据转为 UI 可用的 ViewModel
 *
 * 对应 iOS TelegramEngine.Resources UI 适配层
 * 对应 telegram_engine_resources feature TERSC-IF-1
 *
 * 职责：
 * - 封装 TelegramEngine_ResourcesService，向 UI 层暴露 ViewModel 友好接口
 * - 提供 ResourceViewModel（本地路径 + 状态 + 大小）
 * - 异步下载资源并返回本地路径
 * - 提供缓存使用统计汇总
 * - 提供清理/存储接口
 *
 * 调用链（完整）：
 *   ResourcesDataProvider.fetchResource(ref)
 *     → TelegramEngine_ResourcesService.fetchMediaResource(ref)
 *       → FileDownloadService.downloadDocument()
 *         → MTProtoClient.sendRequest(UploadGetFile)
 */

// ─── UI ViewModel 类型 ─────────────────────────────────────────────────────────

/**
 * ResourceViewModel — 单个媒体资源的 UI 状态快照
 *
 * 对应 iOS EngineMediaResource.ResourceData
 */
public class ResourceViewModel {
    /** 媒体资源 ID */
    public var resourceId: Int64
    /** 本地磁盘路径（空字符串 = 未缓存） */
    public var localPath: String
    /** 是否本地完整缓存 */
    public var isLocal: Bool
    /** 已缓存大小（字节，0 = 未知或未缓存） */
    public var availableSize: Int64
    /** 当前获取状态 */
    public var status: ResourceFetchStatus

    public init(
        resourceId: Int64,
        localPath: String,
        isLocal: Bool,
        availableSize: Int64,
        status: ResourceFetchStatus
    ) {
        this.resourceId = resourceId
        this.localPath = localPath
        this.isLocal = isLocal
        this.availableSize = availableSize
        this.status = status
    }
}

/**
 * CacheStatsViewModel — 缓存使用统计 ViewModel
 *
 * 对应 iOS CacheUsageStatsResult 的汇总视图
 */
public class CacheStatsViewModel {
    /** 总缓存条目数 */
    public var entryCount: Int64
    /** 总磁盘占用（字节） */
    public var totalSizeBytes: Int64
    /** 所有缓存条目列表 */
    public var entries: ArrayList<CacheUsageEntry>

    public init(
        entryCount: Int64,
        totalSizeBytes: Int64,
        entries: ArrayList<CacheUsageEntry>
    ) {
        this.entryCount = entryCount
        this.totalSizeBytes = totalSizeBytes
        this.entries = entries
    }
}

// ─── ResourcesDataProvider ─────────────────────────────────────────────────────

public class ResourcesDataProvider {
    private let service: TelegramEngine_ResourcesService = getResourcesService()

    // ── 下载与获取 ──────────────────────────────────────────────────────────────

    /**
     * 获取/下载媒体资源，返回 ResourceViewModel
     *
     * 先查本地缓存；若缓存命中直接返回 Local 状态。
     * 若未缓存，通过 MTProto upload.getFile 下载，写入磁盘后返回路径。
     *
     * 对应 iOS engine.resources.fetch(reference:...) + data(id:)
     *
     * @param ref  媒体资源引用（resourceId / accessHash / fileRef / dcId）
     * @return ResourceViewModel（包含本地路径与状态）
     */
    public func fetchResource(ref: MediaResourceRef): ResourceViewModel {
        let resourceId = ref.resourceId

        // 先查状态，如已 Local 直接返回
        let status = this.service.getResourceStatus(resourceId)
        match (status) {
            case ResourceFetchStatus.Local =>
                let path = this.service.completedResourcePath(resourceId)
                Hilog.info(0, "CjTelegram", "[ResourcesProvider] Local hit: id=${resourceId}")
                return ResourceViewModel(resourceId, path, true, Int64(path.size), ResourceFetchStatus.Local)
            case _ => ()
        }

        // 调用 Service 下载（MTProto upload.getFile）
        let localPath = this.service.fetchMediaResource(ref)
        if (localPath.size > 0) {
            return ResourceViewModel(resourceId, localPath, true, Int64(localPath.size), ResourceFetchStatus.Local)
        }

        // 下载失败：返回 Remote 状态
        Hilog.info(0, "CjTelegram", "[ResourcesProvider] Fetch failed: id=${resourceId}")
        return ResourceViewModel(resourceId, "", false, 0, ResourceFetchStatus.Remote)
    }

    /**
     * 获取资源的当前状态快照（不触发下载）
     *
     * 对应 iOS engine.resources.status(resource:)
     *
     * @param resourceId  媒体资源 ID
     * @return ResourceViewModel（仅状态，localPath 可能为空）
     */
    public func getResourceStatus(resourceId: Int64): ResourceViewModel {
        let status = this.service.getResourceStatus(resourceId)
        let path = this.service.completedResourcePath(resourceId)
        let isLocal: Bool = match (status) {
            case ResourceFetchStatus.Local => true
            case _ => false
        }
        let avail: Int64 = if (isLocal) { Int64(path.size) } else { 0 }
        return ResourceViewModel(resourceId, path, isLocal, avail, status)
    }

    /**
     * 读取本地已缓存的资源字节数据
     *
     * 对应 iOS engine.resources.data(id:) / data(resource:...)
     *
     * @param resourceId  媒体资源 ID
     * @return 字节数组；未缓存返回空数组
     */
    public func fetchLocalData(resourceId: Int64): Array<Byte> {
        return this.service.fetchMediaData(resourceId)
    }

    // ── 存储与移动 ────────────────────────────────────────────────────────────

    /**
     * 直接存储资源字节到本地缓存（对应 iOS storeResourceData(id:data:synchronous:)）
     *
     * @param resourceId  媒体资源 ID
     * @param data        资源字节数据
     */
    public func storeResource(resourceId: Int64, data: Array<Byte>): Unit {
        this.service.storeResourceData(resourceId, data)
    }

    /**
     * 将临时文件移动到资源缓存（对应 iOS moveResourceData(id:toTempPath:)）
     *
     * @param resourceId  媒体资源 ID
     * @param tempPath    临时文件路径
     * @return true = 成功
     */
    public func moveResource(resourceId: Int64, tempPath: String): Bool {
        return this.service.moveResourceData(resourceId, tempPath)
    }

    /**
     * 从路径复制资源到缓存（对应 iOS copyResourceData(id:fromTempPath:)）
     *
     * @param resourceId  媒体资源 ID
     * @param fromPath    源文件路径
     * @return true = 成功
     */
    public func copyResource(resourceId: Int64, fromPath: String): Bool {
        return this.service.copyResourceData(resourceId, fromPath)
    }

    // ── 缓存清理 ──────────────────────────────────────────────────────────────

    /**
     * 清除单个资源缓存（对应 iOS clearCachedMediaResources(mediaResourceIds:)）
     *
     * @param resourceId  要清除的媒体资源 ID
     * @return 释放的字节数
     */
    public func clearCachedResource(resourceId: Int64): Int64 {
        return this.service.clearCachedResource(resourceId)
    }

    /**
     * 批量清除多个资源缓存（对应 iOS removeCachedResources(ids:...)）
     *
     * @param resourceIds  要清除的资源 ID 数组
     * @return 释放的总字节数
     */
    public func clearCachedResources(resourceIds: Array<Int64>): Int64 {
        return this.service.clearCachedResources(resourceIds)
    }

    /**
     * 取消正在进行的资源下载（对应 iOS cancelInteractiveResourceFetch(id:)）
     *
     * @param resourceId  要取消的媒体资源 ID
     */
    public func cancelFetch(resourceId: Int64): Unit {
        this.service.cancelInteractiveResourceFetch(resourceId)
    }

    // ── 缓存统计 ──────────────────────────────────────────────────────────────

    /**
     * 收集缓存使用统计并汇总（对应 iOS collectCacheUsageStats(peerId:...)）
     *
     * @return CacheStatsViewModel（总数、总大小、条目列表）
     */
    public func collectCacheStats(): CacheStatsViewModel {
        let entries = this.service.collectCacheUsageStats()
        var totalSize: Int64 = 0
        for (entry in entries) {
            totalSize = totalSize + entry.sizeBytes
        }
        Hilog.info(0, "CjTelegram", "[ResourcesProvider] Cache stats: entries=${entries.size} total=${totalSize}")
        return CacheStatsViewModel(Int64(entries.size), totalSize, entries)
    }

    // ── 存储使用统计（Gap 1）────────────────────────────────────────────────────

    /**
     * 按类目聚合存储使用统计（对应 iOS TelegramEngine.Resources.collectStorageUsageStats()）
     *
     * @return StorageUsageStats（含各类目字节数 + 总量）
     */
    public func collectStorageUsageStats(): StorageUsageStats {
        return this.service.collectStorageUsageStats()
    }

    // ── 按类目清缓存（Gap 2）────────────────────────────────────────────────────

    /**
     * 按类目清理本地缓存（对应 iOS TelegramEngine.Resources.clearStorage(peerId:categories:...)）
     *
     * @param categories  要清理的类目列表
     * @return 释放的总字节数
     */
    public func clearStorageByCategory(categories: ArrayList<StorageCategoryKey>): Int64 {
        return this.service.clearStorageByCategory(categories)
    }

    // ── 自定义 fetch + 回调（Gap 3）──────────────────────────────────────────────

    /**
     * 自定义资源 fetch（对应 iOS TelegramEngine.Resources.custom(id:fetch:cacheTimeout:)）
     *
     * @param request  自定义 fetch 请求（resourceId / ref / onData 回调）
     */
    public func customFetch(request: CustomFetchRequest): Unit {
        this.service.customFetch(request)
    }

    // ── 资源分段下载状态（Gap 4）────────────────────────────────────────────────

    /**
     * 查询资源已下载的字节范围（对应 iOS TelegramEngine.Resources.resourceRangesStatus(resource:)）
     *
     * 返回 [(start, end)] 区间列表（end exclusive），对应 iOS RangeSet<Int64>。
     *
     * @param fileId  媒体文件 ID（TL file_id）
     * @return 已下载字节范围列表
     */
    public func resourceRangesStatus(fileId: Int64): ArrayList<(Int64, Int64)> {
        return getFileDownloadService().resourceRangesStatus(fileId)
    }

    // ── 取消所有 fetches（Gap 5）────────────────────────────────────────────────

    /**
     * 取消所有正在进行的资源下载（对应 iOS TelegramEngine.Resources.cancelAllFetches(id:)）
     */
    public func cancelAllFetches(): Unit {
        this.service.cancelAllFetches()
    }

    // ── 重建缓存索引（Gap 6）────────────────────────────────────────────────────

    /**
     * 重建本地缓存索引（对应 iOS TelegramEngine.Resources.reindexCacheInBackground(lowImpact:)）
     *
     * @return 重新索引的条目数
     */
    public func reindexCache(): Int64 {
        return this.service.reindexCache()
    }

    // ── 相册封面预取（Gap 7）────────────────────────────────────────────────────

    /**
     * 预取相册封面（对应 iOS TelegramEngine.Resources.fetchAlbumCover(file:title:performer:isThumbnail:)）
     *
     * 在后台 spawn 下载，完成后通过 onComplete 回调返回本地路径。
     *
     * @param mediaId        音乐媒体文件 ID
     * @param accessHash     访问 hash
     * @param fileReference  文件引用字节
     * @param dcId           数据中心 ID
     * @param fileSize       文件大小（0 = 未知）
     * @param isThumbnail    true = 缩略图版本（96x96）；false = 完整封面（512x512）
     * @param onComplete     完成回调（localPath；空 = 失败）
     */
    public func fetchAlbumCover(
        mediaId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        dcId: Int32,
        fileSize: Int64,
        isThumbnail: Bool,
        onComplete: (String) -> Unit
    ): Unit {
        getMediaResourcesService().fetchAlbumCover(
            mediaId,
            accessHash,
            fileReference,
            dcId,
            fileSize,
            isThumbnail,
            onComplete
        )
    }
}
