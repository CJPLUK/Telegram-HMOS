package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.*

/**
 * DirectMediaImageCacheViewModel — 媒体直接图片缓存视图模型
 *
 * 对应 iOS DirectMediaImageCache.GetMediaResult 的消费侧适配。
 *
 * 职责:
 * - 持有当前查询 photoId / width 的缓存状态（isReady / localPath）
 * - 调用 DirectMediaImageCacheService 进行同步查询和异步下载触发
 * - 提供 ensureImage() 统一入口，供 UI 组件在 aboutToAppear/onAppear 中调用
 *
 * 调用链（完整）:
 *   UI → ensureImage(photoId, accessHash, fileReference, width, thumbSize)
 *     → DirectMediaImageCacheService.getMediaImage()          （内存 LRU + 磁盘）
 *       命中 → localPath / isReady 立即更新
 *       未命中 → DirectMediaImageCacheService.requestMediaImage() （spawn 后台下载）
 *                  → FileDownloadService.downloadPhoto()
 *                    → MTProtoClient.sendRequest(UploadGetFile)  [N/A 委托]
 *                  完成 → onImageReady() → localPath / isReady 更新
 */
@Observed
public class DirectMediaImageCacheViewModel {
    // 当前查询的媒体 ID
    @Publish public var photoId: Int64 = 0
    // 请求宽度（像素）
    @Publish public var requestWidth: Int64 = 0
    // 本地路径（空字符串 = 尚未就绪）
    @Publish public var localPath: String = ""
    // 是否就绪
    @Publish public var isReady: Bool = false
    // 是否正在下载
    @Publish public var isDownloading: Bool = false
    // 最近一次错误描述（空字符串 = 无错误）
    @Publish public var lastError: String = ""
    // 模糊缩略图路径（来自 strippedThumb，立即可用）
    @Publish public var blurredPath: String = ""

    // ── 核心查询方法 ──────────────────────────────────────────────

    /**
     * 确保指定媒体图片的缓存已就绪。
     *
     * 先检查内存 LRU + 磁盘缓存；若命中直接更新 localPath / isReady。
     * 若未命中，触发后台 spawn 下载，完成后通过回调更新状态。
     *
     * @param targetPhotoId   照片 ID
     * @param accessHash      访问 hash
     * @param fileReference   文件引用
     * @param width           请求宽度
     * @param thumbSize       缩略图级别（"s", "m", "x", "y"）
     * @param blurredDataUrl  可选：strippedThumb 生成的模糊预览 data URL
     */
    public func ensureImage(
        targetPhotoId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        width: Int64,
        thumbSize!: String = "x",
        blurredDataUrl!: String = ""
    ): Unit {
        this.photoId = targetPhotoId
        this.requestWidth = width
        this.lastError = ""

        // Blurred thumbnail available immediately
        if (blurredDataUrl.size > 0) {
            this.blurredPath = blurredDataUrl
        }

        let svc = getDirectMediaImageCacheService()

        // Synchronous check: memory LRU + disk
        let cached = svc.getMediaImage(targetPhotoId, width, thumbSize: thumbSize)
        if (cached.size > 0) {
            this.localPath = cached
            this.isReady = true
            this.isDownloading = false
            Hilog.info(0, "CjTelegram", "[DMICVM] Cache hit: id=${targetPhotoId} w=${width}")
            return
        }

        // Trigger async download
        this.isReady = false
        this.isDownloading = true
        Hilog.info(0, "CjTelegram", "[DMICVM] Trigger download: id=${targetPhotoId} w=${width}")

        let pidCopy = targetPhotoId
        let widCopy = width
        let thumbCopy = thumbSize

        let _ = svc.requestMediaImage(
            pidCopy,
            accessHash,
            fileReference,
            widCopy,
            thumbSize: thumbCopy,
            onReady: Some({ key: String, path: String =>
                this.onImageReady(key, path, pidCopy, widCopy, thumbCopy)
            })
        )
    }

    /**
     * 同步查询缓存路径，不触发下载。
     *
     * 适用于 build() 方法中快速判断是否有缓存。
     *
     * @return 已缓存本地路径；若不存在则返回空字符串
     */
    public func queryCached(targetPhotoId: Int64, width: Int64, thumbSize!: String = "x"): String {
        let svc = getDirectMediaImageCacheService()
        return svc.getMediaImage(targetPhotoId, width, thumbSize: thumbSize)
    }

    /**
     * 使当前条目内存缓存失效（保留磁盘缓存）并重置状态。
     */
    public func invalidate(): Unit {
        if (this.photoId > 0) {
            getDirectMediaImageCacheService().invalidateMemory(
                this.photoId,
                this.requestWidth,
                "x"
            )
        }
        this.localPath = ""
        this.isReady = false
        this.isDownloading = false
        Hilog.info(0, "CjTelegram", "[DMICVM] Invalidated: id=${this.photoId}")
    }

    // ── Private callbacks ─────────────────────────────────────────

    private func onImageReady(
        key: String,
        path: String,
        targetPhotoId: Int64,
        width: Int64,
        thumbSize: String
    ): Unit {
        // Only update if this callback is for the current query
        if (this.photoId == targetPhotoId && this.requestWidth == width) {
            this.localPath = path
            this.isReady = true
            this.isDownloading = false
            this.lastError = ""
            Hilog.info(0, "CjTelegram", "[DMICVM] Ready: ${path}")
        }
    }
}
