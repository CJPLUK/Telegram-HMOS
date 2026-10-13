package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*

/**
 * WallpaperResourcesViewModel — 云端壁纸资源视图模型
 *
 * 对应 iOS WallpaperResources.swift 的客户端使用层。
 *
 * 职责：
 * - 异步加载云端壁纸列表（account.getWallPapers）
 * - 按 slug 查询单张壁纸（account.getWallPaper）
 * - 触发壁纸文件下载并管理本地路径
 * - 向 UI 层暴露加载状态（isLoading / lastError）和壁纸列表（items）
 *
 * 调用链（完整）：
 *   loadWallpapers()
 *     → spawn → WallpaperResourcesService.getWallPapers(hash)
 *       → MTProtoClient.sendRequest(AccountGetWallPapers)
 *       → parseWallPapersResponse()
 *       → this.items / this.listHash 更新
 *
 *   downloadWallpaperByIndex(idx)
 *     → spawn → WallpaperResourcesService.downloadWallpaper(item)
 *       → FileDownloadService.downloadDocument(fileId, accessHash, ...)
 *         → MTProtoClient.sendRequest(UploadGetFile)
 *       → 写入磁盘 → 更新 items[idx] 无副作用（返回路径给调用方）
 *
 *   lookupWallpaperBySlug(slug)
 *     → spawn → WallpaperResourcesService.getWallPaper(slug)
 *       → MTProtoClient.sendRequest(AccountGetWallPaper)
 *       → parseSingleWallPaperResponse()
 *       → this.singleItem 更新
 */
@Observed
public class WallpaperResourcesViewModel {
    /** 壁纸列表 */
    @Publish public var items: ArrayList<WallpaperItem> = ArrayList<WallpaperItem>()
    /** 服务端列表 hash（用于增量更新） */
    @Publish public var listHash: Int64 = 0
    /** 是否正在加载列表 */
    @Publish public var isLoading: Bool = false
    /** 单张壁纸查询结果（lookupWallpaperBySlug 使用） */
    @Publish public var singleItem: WallpaperItem = WallpaperItem()
    /** 最近一次错误描述（空字符串 = 无错误） */
    @Publish public var lastError: String = ""
    /** 是否已加载（至少成功获取过一次列表） */
    @Publish public var hasLoaded: Bool = false
    /** 正在下载的壁纸 ID（0 = 无下载进行中） */
    @Publish public var downloadingId: Int64 = 0
    /** 最近一次下载结果的本地 URI（空字符串 = 下载失败或未触发） */
    @Publish public var lastDownloadedUri: String = ""

    // ── 核心加载方法 ────────────────────────────────────────────

    /**
     * 异步加载云端壁纸列表。
     *
     * 发送 account.getWallPapers(hash=listHash)；
     * 若服务端返回 notModified，则 items 不变（仅清除 isLoading）。
     * 若服务端返回新列表，则覆盖 this.items 并更新 this.listHash。
     */
    public func loadWallpapers(): Unit {
        if (this.isLoading) { return }
        this.isLoading = true
        this.lastError = ""
        let hashCopy = this.listHash
        let _ = spawn {
            let svc = getWallpaperResourcesService()
            let result = svc.getWallPapers(hash: hashCopy)
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[WallpaperResVM] Loaded wallpapers")
                launch {
                    if (!result.notModified) {
                        this.items = result.items
                        this.listHash = result.hash
                    }
                    this.hasLoaded = true
                    this.lastError = ""
                    this.isLoading = false
                }
            } else {
                Hilog.info(0, "CjTelegram", "[WallpaperResVM] Load failed")
                launch {
                    this.lastError = result.errorMessage
                    this.isLoading = false
                }
            }
        }
    }

    /**
     * 强制刷新壁纸列表（忽略 hash，从头请求）。
     *
     * 重置 listHash 为 0 后调用 loadWallpapers()。
     */
    public func refreshWallpapers(): Unit {
        this.listHash = 0
        this.hasLoaded = false
        loadWallpapers()
    }

    /**
     * 异步按 slug 查询单张壁纸信息。
     *
     * 结果写入 this.singleItem；失败时 singleItem.id == 0。
     *
     * @param slug  壁纸 slug（如 "fqeXCsBAAAA"）
     */
    public func lookupWallpaperBySlug(slug: String): Unit {
        if (slug.size == 0) { return }
        this.lastError = ""
        let slugCopy = slug
        let _ = spawn {
            let svc = getWallpaperResourcesService()
            let item = svc.getWallPaper(slugCopy)
            Hilog.info(0, "CjTelegram", "[WallpaperResVM] getWallPaper done")
            launch {
                this.singleItem = item
            }
        }
    }

    /**
     * 异步下载壁纸文件并返回本地 URI（写入 lastDownloadedUri）。
     *
     * 若本地已有缓存，直接返回 URI 不重复下载。
     * 下载中 downloadingId == item.id；完成后恢复 0。
     *
     * @param item  要下载的壁纸（必须 hasDocument=true）
     */
    public func downloadWallpaper(item: WallpaperItem): Unit {
        if (!item.hasDocument) { return }
        this.downloadingId = item.id
        this.lastDownloadedUri = ""
        let itemId = item.id
        let itemAccessHash = item.accessHash
        let itemDocId = item.document.fileId
        let itemDocAccessHash = item.document.accessHash
        let itemDocRef = item.document.fileReference
        let itemDocDc = item.document.dcId
        let itemDocSize = item.document.fileSize
        let itemHasDoc = item.hasDocument
        let _ = spawn {
            let svc = getWallpaperResourcesService()
            let key = svc.deriveWallpaperCacheKey(itemId, itemAccessHash)
            let cached = svc.getCachedLocalPath(key)
            if (cached.size > 0) {
                Hilog.info(0, "CjTelegram", "[WallpaperResVM] download cache hit")
                launch {
                    this.lastDownloadedUri = cached
                    this.downloadingId = 0
                }
                return
            }
            let rebuildItem = WallpaperItem()
            rebuildItem.id = itemId
            rebuildItem.accessHash = itemAccessHash
            rebuildItem.hasDocument = itemHasDoc
            rebuildItem.document.fileId = itemDocId
            rebuildItem.document.accessHash = itemDocAccessHash
            rebuildItem.document.fileReference = itemDocRef
            rebuildItem.document.dcId = itemDocDc
            rebuildItem.document.fileSize = itemDocSize
            let uri = svc.downloadWallpaper(rebuildItem)
            if (uri.size > 0) {
                Hilog.info(0, "CjTelegram", "[WallpaperResVM] download done")
                launch {
                    this.lastDownloadedUri = uri
                    this.downloadingId = 0
                }
            } else {
                Hilog.info(0, "CjTelegram", "[WallpaperResVM] download failed")
                launch {
                    this.lastDownloadedUri = ""
                    this.downloadingId = 0
                    this.lastError = "download_failed"
                }
            }
        }
    }

    /**
     * 查询壁纸本地缓存路径（不触发下载）。
     *
     * @param item  壁纸条目
     * @return 本地 file:// URI；未缓存返回空字符串
     */
    public func getCachedUri(item: WallpaperItem): String {
        if (!item.hasDocument) { return "" }
        let svc = getWallpaperResourcesService()
        let key = svc.deriveWallpaperCacheKey(item.id, item.accessHash)
        return svc.getCachedLocalPath(key)
    }

    /**
     * 使列表失效并清理内存缓存（下次 loadWallpapers 时重新请求）。
     */
    public func invalidateList(): Unit {
        this.items = ArrayList<WallpaperItem>()
        this.listHash = 0
        this.hasLoaded = false
        this.lastError = ""
    }
}
