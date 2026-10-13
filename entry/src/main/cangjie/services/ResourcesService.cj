package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.HashMap
import std.collection.ArrayList
import std.sync.Monitor
import std.convert.*

/**
 * ResourcesService — TelegramEngine.Resources 媒体资源下载引擎
 *
 * 对应 iOS TelegramEngine.Resources（TelegramEngineResources.swift）
 *
 * 职责：
 * 1. 通过 MTProto upload.getFile 下载/获取媒体资源原始字节
 * 2. 管理本地磁盘缓存（路径派生与命中检测）
 * 3. 提供资源获取状态查询（Local / Remote / Fetching）
 * 4. 支持存储/移动/复制资源数据（对应 iOS storeResourceData / moveResourceData）
 * 5. 收集缓存使用统计（对应 iOS collectCacheUsageStats）
 * 6. 清理/移除缓存资源（对应 iOS clearCachedMediaResources / removeCachedResources）
 *
 * 调用链（完整）：
 *   TelegramEngine_ResourcesService.fetchMediaResource(resourceId, accessHash, fileRef, dcId, fileSize)
 *     → FileDownloadService.downloadDocument(fileId, accessHash, fileRef, dcId, fileSize)
 *       → MTProtoClient.sendRequest(UploadGetFile.toBytes())
 *         → upload.getFile TL 方法
 *
 * MTProto TL 方法：
 *   upload.getFile#be5335be precise:flags.0?true cdn_supported:flags.1?true
 *       location:InputFileLocation offset:long limit:int = upload.File
 *   upload.File#096a18d5 type:storage.FileType mtime:int bytes:bytes
 *
 * 设计说明：
 *   - MTProto 分块下载委托给 FileDownloadService（避免重复实现协议层）
 *   - 本服务在 FileDownloadService 之上提供：资源 ID 抽象、磁盘路径管理、状态跟踪
 */

// ─── 资源获取状态 ────────────────────────────────────────────────────────────

/** 媒体资源获取状态（对应 iOS EngineMediaResource.FetchStatus） */
public enum ResourceFetchStatus {
    /** 仅远端可用，尚未开始下载 */
    | Remote
    /** 本地已完整缓存 */
    | Local
    /** 正在下载中 */
    | Fetching
    /** 下载已暂停 */
    | Paused
}

// ─── 资源下载请求描述符 ───────────────────────────────────────────────────────

/**
 * MediaResourceRef — 标识一个可通过 MTProto 下载的媒体资源
 *
 * 对应 iOS MediaResourceReference / EngineMediaResource.Id
 */
public class MediaResourceRef {
    /** 媒体 ID（TL file_id，对应 iOS EngineMediaResource.Id.stringRepresentation） */
    public var resourceId: Int64 = 0
    /** MTProto accessHash */
    public var accessHash: Int64 = 0
    /** MTProto fileReference */
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    /** 数据中心 ID */
    public var dcId: Int32 = 0
    /** 文件大小（字节），0 表示未知 */
    public var fileSize: Int64 = 0
    /** 可选：thumbSize 标识（用于文档缩略图，留空表示完整文件） */
    public var thumbSize: String = ""

    public init(
        resourceId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        dcId: Int32,
        fileSize!: Int64 = 0,
        thumbSize!: String = ""
    ) {
        this.resourceId = resourceId
        this.accessHash = accessHash
        this.fileReference = fileReference
        this.dcId = dcId
        this.fileSize = fileSize
        this.thumbSize = thumbSize
    }
}

// ─── 缓存使用统计 ─────────────────────────────────────────────────────────────

/**
 * CacheUsageEntry — 单个缓存条目描述
 *
 * 对应 iOS CacheUsageStatsResult 中的条目结构
 */
public class CacheUsageEntry {
    /** 媒体 ID */
    public var resourceId: Int64
    /** 磁盘占用字节数 */
    public var sizeBytes: Int64
    /** 本地路径 */
    public var localPath: String

    public init(resourceId: Int64, sizeBytes: Int64, localPath: String) {
        this.resourceId = resourceId
        this.sizeBytes = sizeBytes
        this.localPath = localPath
    }
}

// ─── 存储使用统计（按类目聚合）──────────────────────────────────────────────────

/**
 * StorageCategoryKey — 存储类目键
 *
 * 对应 iOS StorageUsageStats.CategoryKey
 * photos/videos/files/music/stickers/avatars/misc
 */
public enum StorageCategoryKey {
    | Photos
    | Videos
    | Files
    | Music
    | Stickers
    | Avatars
    | Misc
}

/**
 * StorageCategoryStats — 单类目存储统计
 *
 * 对应 iOS StorageUsageStats.CategoryData
 */
public class StorageCategoryStats {
    /** 该类目占用磁盘字节数 */
    public var sizeBytes: Int64
    /** 该类目的资源 ID 列表 */
    public var resourceIds: ArrayList<Int64>

    public init(sizeBytes: Int64) {
        this.sizeBytes = sizeBytes
        this.resourceIds = ArrayList<Int64>()
    }
}

/**
 * StorageUsageStats — 全量存储使用统计
 *
 * 对应 iOS AllStorageUsageStats（含分类汇总）
 * Cangjie 无 Postbox 事务层：直接扫描 engine_resources 目录，
 * 按资源文件扩展名分类（图片/视频/音频/其他）。
 *
 * Signal-async 取舍说明：
 *   iOS 用 Signal 流式推送进度；Cangjie 无 Signal/Postbox，改用同步扫描，
 *   调用方如需异步，用 spawn{} 在后台线程调用本函数后通过回调更新 @State。
 */
public class StorageUsageStats {
    /** 各类目统计（key = StorageCategoryKey 序数 0-6） */
    public var categories: HashMap<Int32, StorageCategoryStats>
    /** 总占用字节数 */
    public var totalBytes: Int64
    /** 临时/中间文件占用字节数 */
    public var miscBytes: Int64

    public init() {
        this.categories = HashMap<Int32, StorageCategoryStats>()
        this.totalBytes = 0
        this.miscBytes = 0
    }
}

// ─── 自定义资源 fetch 回调描述符 ────────────────────────────────────────────────

/**
 * CustomFetchRequest — 自定义资源 fetch 请求（对应 iOS TelegramEngine.Resources.custom()）
 *
 * 持有资源 ID、可选下载描述符、完成回调。
 * Cangjie 无 Signal 响应式层：回调 onData(localPath) 在下载完成后同步调用。
 * 调用方如需响应式刷新，在 onData 回调中修改 @State 并确保在 UI 线程执行（S-001）。
 */
public class CustomFetchRequest {
    /** 自定义资源 ID 字符串（对应 iOS id: String） */
    public var resourceId: String = ""
    /** 可选：对应的 MediaResourceRef（有则走 MTProto download，无则走本地路径） */
    public var ref: Option<MediaResourceRef> = None
    /** 下载完成回调 (localPath: String) -> Unit；下载失败时 localPath 为空字符串 */
    public var onData: (String) -> Unit = { _ => }

    public init(resourceId: String, ref: Option<MediaResourceRef>, onData: (String) -> Unit) {
        this.resourceId = resourceId
        this.ref = ref
        this.onData = onData
    }
}

// ─── 单例访问 ─────────────────────────────────────────────────────────────────

private var _resourcesServiceInstance: Option<TelegramEngine_ResourcesService> = None

/** 获取 TelegramEngine_ResourcesService 单例 */
public func getResourcesService(): TelegramEngine_ResourcesService {
    match (_resourcesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramEngine_ResourcesService()
            _resourcesServiceInstance = Some(inst)
            return inst
    }
}

// ─── TelegramEngine_ResourcesService ─────────────────────────────────────────

/**
 * TelegramEngine_ResourcesService
 *
 * 实现 TelegramEngine.Resources 中的核心资源下载与缓存管理逻辑。
 * 所有实际 MTProto 网络通信委托给 FileDownloadService（upload.getFile）。
 *
 * 对应 iOS TelegramEngine.Resources 方法映射：
 *   fetchMediaResource()           ← fetch(reference:userLocation:userContentType:)
 *   getResourceStatus()            ← status(resource:) / status(id:resourceSize:)
 *   fetchMediaData()               ← data(id:) / data(resource:...)
 *   storeResourceData()            ← storeResourceData(id:data:synchronous:)
 *   completedResourcePath()        ← completedResourcePath(id:pathExtension:)
 *   moveResourceData()             ← moveResourceData(id:toTempPath:)
 *   copyResourceData()             ← copyResourceData(id:fromTempPath:)
 *   clearCachedMediaResources()    ← clearCachedMediaResources(mediaResourceIds:)
 *   collectCacheUsageStats()       ← collectCacheUsageStats(peerId:...)
 *   cancelInteractiveResourceFetch()← cancelInteractiveResourceFetch(id:)
 */
public class TelegramEngine_ResourcesService {
    /** 缓存根目录 */
    private var _cacheDir: String = ""
    /** 资源磁盘路径缓存 (resourceId -> localPath) */
    private var _pathCache: HashMap<Int64, String> = HashMap<Int64, String>()
    /** 正在下载中的资源 ID 集合（用于 Fetching 状态判断） */
    private var _activeDownloads: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    /** 自定义字符串 ID 到本地路径缓存（供 customFetch 使用） */
    private var _stringPathCache: HashMap<String, String> = HashMap<String, String>()

    public init() {
        _cacheDir = getAppFilesDir() + "/engine_resources"
        ensureDir(_cacheDir)
    }

    // ── 核心下载 ─────────────────────────────────────────────────────────────

    /**
     * 下载媒体资源并保存到本地磁盘（对应 iOS fetch(reference:userLocation:userContentType:)）
     *
     * 调用链：
     *   fetchMediaResource()
     *     → FileDownloadService.downloadDocument()   [services 包，MTProto 实现]
     *       → MTProtoClient.sendRequest(UploadGetFile)  [core.mtproto 包]
     *         → upload.getFile TL 调用
     *
     * @param ref  媒体资源引用（resourceId / accessHash / fileRef / dcId）
     * @return     本地文件路径；下载失败返回空字符串
     */
    public func fetchMediaResource(ref: MediaResourceRef): String {
        let resourceId = ref.resourceId

        // 先检查本地缓存
        let cached = this.completedResourcePath(resourceId)
        if (cached.size > 0) {
            Hilog.info(0, "CjTelegram", "[ResourcesService] Cache hit: id=${resourceId}")
            return cached
        }

        // 标记为下载中
        _activeDownloads[resourceId] = true
        Hilog.info(0, "CjTelegram", "[ResourcesService] Fetching: id=${resourceId}, dc=${ref.dcId}, size=${ref.fileSize}")

        // 委托 FileDownloadService 进行 MTProto upload.getFile 下载
        let downloadSvc = getFileDownloadService()
        let data: Array<Byte>
        if (ref.thumbSize.size > 0) {
            data = downloadSvc.downloadDocumentThumb(
                ref.resourceId,
                ref.accessHash,
                ref.fileReference,
                thumbSize: ref.thumbSize
            )
        } else {
            data = downloadSvc.downloadDocument(
                ref.resourceId,
                ref.accessHash,
                ref.fileReference,
                ref.dcId,
                fileSize: ref.fileSize
            )
        }

        _activeDownloads.remove(resourceId)

        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[ResourcesService] Empty download: id=${resourceId}")
            return ""
        }

        // 写入磁盘
        let localPath = buildResourcePath(resourceId)
        ensureParentDir(localPath)
        let saved = writeBytes(data, localPath)
        if (saved) {
            _pathCache[resourceId] = localPath
            Hilog.info(0, "CjTelegram", "[ResourcesService] Saved: id=${resourceId} path=${localPath} bytes=${data.size}")
            return localPath
        }
        Hilog.info(0, "CjTelegram", "[ResourcesService] Write failed: id=${resourceId}")
        return ""
    }

    // ── 状态查询 ─────────────────────────────────────────────────────────────

    /**
     * 查询资源获取状态（对应 iOS status(resource:) / status(id:resourceSize:)）
     *
     * @param resourceId  媒体资源 ID
     * @return ResourceFetchStatus
     */
    public func getResourceStatus(resourceId: Int64): ResourceFetchStatus {
        // 正在下载
        if (_activeDownloads.contains(resourceId)) {
            return ResourceFetchStatus.Fetching
        }
        // 本地已有
        let path = completedResourcePath(resourceId)
        if (path.size > 0) {
            return ResourceFetchStatus.Local
        }
        return ResourceFetchStatus.Remote
    }

    // ── 数据读取 ─────────────────────────────────────────────────────────────

    /**
     * 读取本地已缓存资源数据（对应 iOS data(id:) / data(resource:...)）
     *
     * @param resourceId  媒体资源 ID
     * @return 资源字节数组；不存在则返回空数组
     */
    public func fetchMediaData(resourceId: Int64): Array<Byte> {
        let path = completedResourcePath(resourceId)
        if (path.size == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        return readBytes(path)
    }

    // ── 路径查询 ─────────────────────────────────────────────────────────────

    /**
     * 返回本地已完整下载的资源磁盘路径（对应 iOS completedResourcePath(id:pathExtension:)）
     *
     * @param resourceId  媒体资源 ID
     * @return 本地路径；不存在返回空字符串
     */
    public func completedResourcePath(resourceId: Int64): String {
        // 先查内存缓存
        if (_pathCache.contains(resourceId)) {
            let cached = _pathCache[resourceId]
            if (cached.size > 0) {
                return cached
            }
        }
        // 检查磁盘
        let diskPath = buildResourcePath(resourceId)
        var exists = false
        try {
            exists = FileIo.access(diskPath)
        } catch (_: Exception) {
            exists = false
        }
        if (exists) {
            _pathCache[resourceId] = diskPath
            return diskPath
        }
        return ""
    }

    // ── 存储与移动 ────────────────────────────────────────────────────────────

    /**
     * 将字节数据直接写入资源缓存（对应 iOS storeResourceData(id:data:synchronous:)）
     *
     * @param resourceId  媒体资源 ID
     * @param data        字节数据
     */
    public func storeResourceData(resourceId: Int64, data: Array<Byte>): Unit {
        if (data.size == 0) {
            return
        }
        let localPath = buildResourcePath(resourceId)
        ensureParentDir(localPath)
        let saved = writeBytes(data, localPath)
        if (saved) {
            _pathCache[resourceId] = localPath
            Hilog.info(0, "CjTelegram", "[ResourcesService] Stored: id=${resourceId} bytes=${data.size}")
        }
    }

    /**
     * 将临时文件移动到资源缓存目录（对应 iOS moveResourceData(id:toTempPath:)）
     *
     * 使用 copyFile + unlink 模拟原子移动（FileIo 无原生 move/rename）。
     *
     * @param resourceId  媒体资源 ID
     * @param tempPath    临时文件路径（将被移至缓存目录）
     * @return true = 移动成功
     */
    public func moveResourceData(resourceId: Int64, tempPath: String): Bool {
        let targetPath = buildResourcePath(resourceId)
        ensureParentDir(targetPath)
        var moved = false
        try {
            FileIo.copyFile(tempPath, targetPath, mode: 0)
            moved = true
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ResourcesService] copyFile failed for id=${resourceId}")
        }
        if (moved) {
            try { FileIo.unlink(tempPath) } catch (_: Exception) {}
            _pathCache[resourceId] = targetPath
            Hilog.info(0, "CjTelegram", "[ResourcesService] Moved to cache: id=${resourceId}")
        }
        return moved
    }

    /**
     * 从临时文件复制到资源缓存（对应 iOS copyResourceData(id:fromTempPath:)）
     *
     * @param resourceId  媒体资源 ID
     * @param fromPath    源文件路径
     * @return true = 复制成功
     */
    public func copyResourceData(resourceId: Int64, fromPath: String): Bool {
        let targetPath = buildResourcePath(resourceId)
        ensureParentDir(targetPath)
        var ok = false
        try {
            FileIo.copyFile(fromPath, targetPath, mode: 0)
            ok = true
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ResourcesService] copyFile failed for id=${resourceId}")
        }
        if (ok) {
            _pathCache[resourceId] = targetPath
            Hilog.info(0, "CjTelegram", "[ResourcesService] Copied to cache: id=${resourceId}")
        }
        return ok
    }

    // ── 缓存清理 ─────────────────────────────────────────────────────────────

    /**
     * 清理指定资源的本地缓存文件（对应 iOS clearCachedMediaResources / removeCachedResources）
     *
     * @param resourceId  要清除的媒体资源 ID
     * @return 已释放的字节数
     */
    public func clearCachedResource(resourceId: Int64): Int64 {
        let path = completedResourcePath(resourceId)
        var freed: Int64 = 0
        if (path.size > 0) {
            freed = fileSizeAt(path)
            try {
                FileIo.unlink(path)
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[ResourcesService] Unlink failed: id=${resourceId}")
            }
            _pathCache.remove(resourceId)
            Hilog.info(0, "CjTelegram", "[ResourcesService] Cleared: id=${resourceId} freed=${freed}")
        }
        return freed
    }

    /**
     * 批量清理多个资源的本地缓存（对应 iOS removeCachedResources(ids:...)）
     *
     * @param resourceIds  要清除的媒体资源 ID 列表
     * @return 已释放的总字节数
     */
    public func clearCachedResources(resourceIds: Array<Int64>): Int64 {
        var totalFreed: Int64 = 0
        for (rid in resourceIds) {
            totalFreed = totalFreed + clearCachedResource(rid)
        }
        Hilog.info(0, "CjTelegram", "[ResourcesService] Batch cleared ${resourceIds.size} resources, freed=${totalFreed}")
        return totalFreed
    }

    // ── 缓存使用统计 ─────────────────────────────────────────────────────────

    /**
     * 收集缓存使用统计（对应 iOS collectCacheUsageStats(peerId:additionalCachePaths:...)）
     *
     * 扫描 engine_resources 目录，统计每个缓存文件的大小。
     *
     * @return 缓存条目列表
     */
    public func collectCacheUsageStats(): ArrayList<CacheUsageEntry> {
        let entries = ArrayList<CacheUsageEntry>()
        for ((rid, path) in _pathCache) {
            var exists = false
            try {
                exists = FileIo.access(path)
            } catch (_: Exception) {
                exists = false
            }
            if (exists) {
                let sz = fileSizeAt(path)
                entries.add(CacheUsageEntry(rid, sz, path))
            }
        }
        Hilog.info(0, "CjTelegram", "[ResourcesService] Cache stats: ${entries.size} entries")
        return entries
    }

    /**
     * 取消正在进行的资源下载（对应 iOS cancelInteractiveResourceFetch(id:)）
     *
     * 当前实现：从 _activeDownloads 移除标记，让下载线程自然停止后不写入缓存。
     *
     * @param resourceId  要取消下载的媒体资源 ID
     */
    public func cancelInteractiveResourceFetch(resourceId: Int64): Unit {
        _activeDownloads.remove(resourceId)
        Hilog.info(0, "CjTelegram", "[ResourcesService] Cancelled fetch: id=${resourceId}")
    }

    // ── 存储使用统计（Gap 1: storageUsageStats）──────────────────────────────────

    /**
     * 按类目聚合存储使用统计（对应 iOS TelegramEngine.Resources.collectStorageUsageStats()）
     *
     * 扫描 engine_resources 目录，按文件扩展名映射类目：
     *   .jpg/.jpeg/.png/.webp/.gif → Photos
     *   .mp4/.mov/.avi/.mkv        → Videos
     *   .mp3/.m4a/.ogg/.flac/.wav  → Music
     *   .tgs/.webm (small)         → Stickers
     *   其余                        → Files / Misc
     *
     * Signal-async deferred：返回同步结果；调用方可在后台 spawn 调用，结果通过 spawn(UIThread) 推送 @State。
     *
     * @return StorageUsageStats 完整统计结果
     */
    public func collectStorageUsageStats(): StorageUsageStats {
        let stats = StorageUsageStats()

        var rootExists = false
        try {
            rootExists = FileIo.access(_cacheDir)
        } catch (_: Exception) {
            rootExists = false
        }
        if (!rootExists) {
            Hilog.info(0, "CjTelegram", "[ResourcesService] storageStats: cache dir not found")
            return stats
        }

        var fileNames: Array<String> = Array<String>(0, repeat: "")
        try {
            let opts = ListFileOptions(recursion: false, listNum: 0, filter: Filter())
            fileNames = FileIo.listFile(_cacheDir, options: opts)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ResourcesService] storageStats: listFile error")
            return stats
        }

        var total: Int64 = 0
        for (name in fileNames) {
            let fullPath = _cacheDir + "/" + name
            let sz = fileSizeAt(fullPath)
            if (sz <= 0) {
                continue
            }
            total = total + sz
            let catKey = categoryKeyForFileName(name)
            let catOrd = storageCategoryOrdinal(catKey)
            if (stats.categories.contains(catOrd)) {
                stats.categories[catOrd].sizeBytes = stats.categories[catOrd].sizeBytes + sz
            } else {
                stats.categories[catOrd] = StorageCategoryStats(sz)
            }
            // Populate resourceIds: parse numeric filename as resourceId (engine_resources
            // stores files as plain Int64 resourceId with no extension)
            var isNum = true
            for (ch in name.toRuneArray()) {
                if (ch < r'0' || ch > r'9') {
                    isNum = false
                    break
                }
            }
            if (isNum && name.size > 0) {
                try {
                    let rid = Int64.parse(name)
                    stats.categories[catOrd].resourceIds.add(rid)
                } catch (_: Exception) {}
            }
        }
        stats.totalBytes = total

        Hilog.info(0, "CjTelegram", "[ResourcesService] storageStats: total=${total} files=${fileNames.size}")
        return stats
    }

    // ── 按类目清缓存（Gap 2: clearStorageByCategory）──────────────────────────

    /**
     * 按类目批量清理本地缓存（对应 iOS TelegramEngine.Resources.clearStorage(peerId:categories:...)）
     *
     * 遍历 engine_resources 目录文件，按 categoryKeyForFileName 判断类目，
     * 若类目在 categories 中则删除并更新内存 _pathCache。
     *
     * Signal-async deferred：同步执行，返回释放字节数。
     *
     * @param categories  要清理的类目列表（StorageCategoryKey）
     * @return 释放的总字节数
     */
    public func clearStorageByCategory(categories: ArrayList<StorageCategoryKey>): Int64 {
        if (categories.isEmpty()) {
            return 0
        }

        var rootExists = false
        try {
            rootExists = FileIo.access(_cacheDir)
        } catch (_: Exception) {
            rootExists = false
        }
        if (!rootExists) {
            return 0
        }

        var fileNames: Array<String> = Array<String>(0, repeat: "")
        try {
            let opts = ListFileOptions(recursion: false, listNum: 0, filter: Filter())
            fileNames = FileIo.listFile(_cacheDir, options: opts)
        } catch (_: Exception) {
            return 0
        }

        var freed: Int64 = 0
        for (name in fileNames) {
            let catKey = categoryKeyForFileName(name)
            var shouldClear = false
            for (cat in categories) {
                if (storageCategoryOrdinal(cat) == storageCategoryOrdinal(catKey)) {
                    shouldClear = true
                    break
                }
            }
            if (shouldClear) {
                let fullPath = _cacheDir + "/" + name
                let sz = fileSizeAt(fullPath)
                try {
                    FileIo.unlink(fullPath)
                    freed = freed + sz
                } catch (_: Exception) {}
            }
        }

        let newCache = HashMap<Int64, String>()
        for ((rid, path) in _pathCache) {
            var stillExists = false
            try {
                stillExists = FileIo.access(path)
            } catch (_: Exception) {
                stillExists = false
            }
            if (stillExists) {
                newCache[rid] = path
            }
        }
        _pathCache = newCache

        Hilog.info(0, "CjTelegram", "[ResourcesService] clearByCategory: freed=${freed}")
        return freed
    }

    // ── 取消所有进行中的 fetch（Gap 5: cancelAllFetches）────────────────────────

    /**
     * 取消所有正在进行的资源下载（对应 iOS TelegramEngine.Resources.cancelAllFetches(id:)）
     *
     * 清空 _activeDownloads 表，并对每个活跃 ID 调用 FileDownloadService.cancelDownload()。
     */
    public func cancelAllFetches(): Unit {
        let resourceIds = ArrayList<Int64>()
        for ((rid, _) in _activeDownloads) {
            resourceIds.add(rid)
        }
        _activeDownloads = HashMap<Int64, Bool>()

        let downloadSvc = getFileDownloadService()
        for (rid in resourceIds) {
            downloadSvc.cancelDownload(rid)
            Hilog.info(0, "CjTelegram", "[ResourcesService] cancelAllFetches: cancelled id=${rid}")
        }
        Hilog.info(0, "CjTelegram", "[ResourcesService] cancelAllFetches: total=${resourceIds.size}")
    }

    // ── 重建本地缓存索引（Gap 6: reindexCache）──────────────────────────────────

    /**
     * 重建本地缓存索引（对应 iOS TelegramEngine.Resources.reindexCacheInBackground(lowImpact:)）
     *
     * 扫描 engine_resources 目录（非递归），将纯数字文件名（resourceId）重载入 _pathCache。
     * 持久化索引（MediaResourceIndexTable）由 MediaResourcesService.recordCacheIndex 维护，
     * 本方法仅重建内存 _pathCache。
     *
     * Signal-async deferred：同步执行，返回索引条目数。
     *
     * @return 重新索引的条目数
     */
    public func reindexCache(): Int64 {
        let newCache = HashMap<Int64, String>()

        var rootExists = false
        try {
            rootExists = FileIo.access(_cacheDir)
        } catch (_: Exception) {
            rootExists = false
        }
        if (!rootExists) {
            _pathCache = newCache
            return 0
        }

        var fileNames: Array<String> = Array<String>(0, repeat: "")
        try {
            let opts = ListFileOptions(recursion: false, listNum: 0, filter: Filter())
            fileNames = FileIo.listFile(_cacheDir, options: opts)
        } catch (_: Exception) {
            return 0
        }

        for (name in fileNames) {
            let fullPath = _cacheDir + "/" + name
            var isNum = true
            for (ch in name.toRuneArray()) {
                if (ch < r'0' || ch > r'9') {
                    isNum = false
                    break
                }
            }
            if (isNum && name.size > 0) {
                try {
                    let rid = Int64.parse(name)
                    newCache[rid] = fullPath
                } catch (_: Exception) {}
            }
        }

        _pathCache = newCache
        Hilog.info(0, "CjTelegram", "[ResourcesService] reindexCache: indexed ${fileNames.size} entries")
        return Int64(fileNames.size)
    }

    // ── 自定义资源 fetch + 回调（Gap 3: custom() + fetch cb）──────────────────

    /**
     * 自定义资源 fetch（对应 iOS TelegramEngine.Resources.custom(id:fetch:cacheTimeout:)）
     *
     * 先检查 _stringPathCache（自定义 id 字符串到路径的内存索引）。
     * 命中且文件存在则直接 onData(path)；未命中则通过 MediaResourceRef 下载，完成后回调。
     *
     * Signal-async 取舍：iOS 返回 Signal<ResourceData>；Cangjie 用同步回调模式。
     * 调用方如需异步，在 spawn{} 中调用本函数，在 onData 中通过 spawn(UIThread) 更新 @State（S-001）。
     *
     * @param request  自定义 fetch 请求描述符
     */
    public func customFetch(request: CustomFetchRequest): Unit {
        let resourceIdStr = request.resourceId

        if (_stringPathCache.contains(resourceIdStr)) {
            let cached = _stringPathCache[resourceIdStr]
            if (cached.size > 0) {
                var stillExists = false
                try {
                    stillExists = FileIo.access(cached)
                } catch (_: Exception) {
                    stillExists = false
                }
                if (stillExists) {
                    Hilog.info(0, "CjTelegram", "[ResourcesService] customFetch cache hit: ${resourceIdStr}")
                    request.onData(cached)
                    return
                }
            }
        }

        match (request.ref) {
            case Some(ref) =>
                let localPath = fetchMediaResource(ref)
                if (localPath.size > 0) {
                    _stringPathCache[resourceIdStr] = localPath
                }
                request.onData(localPath)
            case None =>
                Hilog.info(0, "CjTelegram", "[ResourcesService] customFetch no ref: ${resourceIdStr}")
                request.onData("")
        }
    }

    // ── 私有辅助 ─────────────────────────────────────────────────────────────

    /** 构建资源缓存文件路径：<cacheDir>/<resourceId> */
    private func buildResourcePath(resourceId: Int64): String {
        return _cacheDir + "/" + resourceId.toString()
    }

    /** 确保目录存在（单层 mkdir，参见 S-#58） */
    private func ensureDir(dir: String): Unit {
        var exists = false
        try {
            exists = FileIo.access(dir)
        } catch (_: Exception) {
            exists = false
        }
        if (!exists) {
            try {
                FileIo.mkdir(dir)
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[ResourcesService] mkdir failed: ${dir}")
            }
        }
    }

    /** 确保路径的父目录存在 */
    private func ensureParentDir(filePath: String): Unit {
        var lastSlash = -1
        let runes = filePath.toRuneArray()
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] == r'/') {
                lastSlash = Int64(i)
            }
            i += 1
        }
        if (lastSlash > 0) {
            let parentDir = filePath[0..lastSlash]
            ensureDir(parentDir)
        }
    }

    /** 将字节数组写入磁盘（O_CREAT|O_WRONLY|O_TRUNC = 0o1101） */
    private func writeBytes(data: Array<Byte>, path: String): Bool {
        try {
            let f = FileIo.open(path, mode: 0o1101)
            let _ = FileIo.write(f.fd, data)
            FileIo.close(f)
            return true
        } catch (_: Exception) {
            return false
        }
    }

    /** 从磁盘读取文件字节（先 stat 确定大小，再一次性 read）*/
    private func readBytes(path: String): Array<Byte> {
        try {
            let stat = FileIo.stat(path)
            let sz = stat.size
            if (sz <= 0) {
                return Array<Byte>(0, repeat: 0)
            }
            let buf = Array<Byte>(sz, repeat: 0)
            let f = FileIo.open(path, mode: 0o0)
            let _ = FileIo.read(f.fd, buf)
            FileIo.close(f)
            return buf
        } catch (_: Exception) {
            return Array<Byte>(0, repeat: 0)
        }
    }

    /** 获取文件大小（字节） */
    private func fileSizeAt(path: String): Int64 {
        try {
            let stat = FileIo.stat(path)
            return stat.size
        } catch (_: Exception) {
            return 0
        }
    }

    /**
     * 根据文件名（含扩展名）返回存储类目键
     *
     * 对应 iOS MediaResourceUserContentType 按内容类型分类：
     *   image → Photos；video → Videos；audio → Music；sticker → Stickers；other → Misc
     */
    private func categoryKeyForFileName(name: String): StorageCategoryKey {
        let lower = name.toAsciiLower()
        if (strEndsWith(lower, ".jpg") || strEndsWith(lower, ".jpeg") ||
            strEndsWith(lower, ".png") || strEndsWith(lower, ".webp") ||
            strEndsWith(lower, ".gif")) {
            return StorageCategoryKey.Photos
        }
        if (strEndsWith(lower, ".mp4") || strEndsWith(lower, ".mov") ||
            strEndsWith(lower, ".avi") || strEndsWith(lower, ".mkv")) {
            return StorageCategoryKey.Videos
        }
        if (strEndsWith(lower, ".mp3") || strEndsWith(lower, ".m4a") ||
            strEndsWith(lower, ".ogg") || strEndsWith(lower, ".flac") ||
            strEndsWith(lower, ".wav")) {
            return StorageCategoryKey.Music
        }
        if (strEndsWith(lower, ".tgs") || strEndsWith(lower, ".webm")) {
            return StorageCategoryKey.Stickers
        }
        if (strEndsWith(lower, ".pdf") || strEndsWith(lower, ".doc") ||
            strEndsWith(lower, ".docx") || strEndsWith(lower, ".zip") ||
            strEndsWith(lower, ".txt")) {
            return StorageCategoryKey.Files
        }
        return StorageCategoryKey.Misc
    }

    /**
     * 检查字符串是否以指定后缀结尾（Cangjie String struct 无内建 hasSuffix，通过切片比较实现）
     *
     * R-XXX: Cangjie String.hasSuffix() 不存在，不要调用；改用切片 s[start..end] == suffix。
     */
    private func strEndsWith(s: String, suffix: String): Bool {
        if (suffix.size == 0) {
            return true
        }
        if (s.size < suffix.size) {
            return false
        }
        let start: Int64 = s.size - suffix.size
        return s[start..s.size] == suffix
    }

    /**
     * 将 StorageCategoryKey 转为 Int32 序数（用于 HashMap key）
     *
     * 对应 iOS StorageUsageStats.CategoryKey hashValue
     */
    private func storageCategoryOrdinal(key: StorageCategoryKey): Int32 {
        match (key) {
            case StorageCategoryKey.Photos   => return 0
            case StorageCategoryKey.Videos   => return 1
            case StorageCategoryKey.Files    => return 2
            case StorageCategoryKey.Music    => return 3
            case StorageCategoryKey.Stickers => return 4
            case StorageCategoryKey.Avatars  => return 5
            case StorageCategoryKey.Misc     => return 6
        }
    }
}
