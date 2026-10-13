package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.HashMap
import ohos_app_cangjie_entry.services.*

/**
 * MediaResourcesViewModel — 缓存媒体资源派生视图模型
 *
 * 对应 iOS MediaResources/CachedResourceRepresentations 客户端使用层。
 *
 * 职责：
 * - 查询指定媒体 ID + 派生表示类型的本地缓存路径
 * - 在后台下载缺失的缓存派生文件，完成后更新状态
 * - 向 UI 层提供表示就绪状态（isReady）和路径（localPath）
 *
 * 调用链（完整）：
 *   UI 触发 ensureRepresentation()
 *     → MediaResourcesService.hasCachedFile()                   （检查本地）
 *       若命中 → 直接更新 isReady / localPath
 *       若未命中 → spawn 异步下载
 *         → MediaResourcesService.downloadRepresentation()
 *           → FileDownloadService.downloadDocument()
 *             → MTProtoClient.sendRequest(UploadGetFile)
 *         → 完成后更新 localPath / isReady
 */
@Observed
public class MediaResourcesViewModel {
    // 当前查询的媒体文件 ID
    @Publish public var mediaId: Int64 = 0
    // 当前查询的表示类型标签（用于调试/显示）
    @Publish public var reprKind: String = ""
    // 缓存文件本地路径（空字符串 = 尚未就绪）
    @Publish public var localPath: String = ""
    // 是否已就绪（localPath 非空且文件存在）
    @Publish public var isReady: Bool = false
    // 是否正在下载
    @Publish public var isDownloading: Bool = false
    // 最近一次错误描述（空字符串 = 无错误）
    @Publish public var lastError: String = ""

    // 缓存多个表示路径：key = "<mediaId>/<uniqueId>"
    private var _resolvedPaths: HashMap<String, String> = HashMap<String, String>()

    // ── 核心查询方法 ──────────────────────────────────────────────

    /**
     * 确保指定媒体 ID 的缓存派生表示已就绪。
     *
     * 先检查本地缓存；若存在则立即返回路径并设置 isReady=true。
     * 若不存在则在后台 spawn 下载任务；下载完成后更新 localPath / isReady。
     *
     * @param targetMediaId   媒体文件 ID
     * @param accessHash      访问 hash（用于 MTProto 下载）
     * @param fileReference   文件引用（用于 MTProto 下载）
     * @param dcId            数据中心 ID
     * @param fileSize        文件大小（字节）
     * @param repr            目标派生表示
     */
    public func ensureRepresentation(
        targetMediaId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        dcId: Int32,
        fileSize: Int64,
        repr: CachedRepresentation
    ): Unit {
        let svc = getMediaResourcesService()
        this.mediaId = targetMediaId
        this.reprKind = repr.kind()

        // 检查内存 + 磁盘缓存
        let cached = svc.getCachedPath(targetMediaId, repr)
        if (cached.size > 0) {
            this.localPath = cached
            this.isReady = true
            this.isDownloading = false
            this.lastError = ""
            let key = targetMediaId.toString() + "/" + repr.uniqueId()
            _resolvedPaths[key] = cached
            Hilog.info(0, "CjTelegram", "[MediaResourcesVM] Cache hit: id=${targetMediaId} repr=${repr.uniqueId()}")
            return
        }

        // 未命中，启动后台下载
        this.isReady = false
        this.isDownloading = true
        this.lastError = ""
        Hilog.info(0, "CjTelegram", "[MediaResourcesVM] Trigger download: id=${targetMediaId} repr=${repr.uniqueId()}")

        let midCopy = targetMediaId
        let ahCopy = accessHash
        let refCopy = fileReference
        let dcCopy = dcId
        let sizeCopy = fileSize
        let reprKindStr = repr.kind()
        let reprUniqueId = repr.uniqueId()

        let _ = spawn {
            let svcInner = getMediaResourcesService()
            let reprForDownload = rebuildReprFromKind(reprKindStr)
            let path = svcInner.downloadRepresentation(
                midCopy,
                ahCopy,
                refCopy,
                dcCopy,
                sizeCopy,
                reprForDownload
            )
            if (path.size > 0) {
                this.localPath = path
                this.isReady = true
                this.isDownloading = false
                let key = midCopy.toString() + "/" + reprUniqueId
                _resolvedPaths[key] = path
                Hilog.info(0, "CjTelegram", "[MediaResourcesVM] Download done: ${path}")
            } else {
                this.isDownloading = false
                this.lastError = "download_failed"
                Hilog.info(0, "CjTelegram", "[MediaResourcesVM] Download failed: id=${midCopy} repr=${reprUniqueId}")
            }
        }
    }

    /**
     * 同步查询指定表示的本地缓存路径（不触发下载）。
     *
     * 适用于 UI 组件在 build() 中快速判断是否有缓存。
     *
     * @param targetMediaId  媒体文件 ID
     * @param repr           缓存资源表示
     * @return 已缓存文件路径；若不存在则返回空字符串
     */
    public func queryCachedPath(targetMediaId: Int64, repr: CachedRepresentation): String {
        let key = targetMediaId.toString() + "/" + repr.uniqueId()
        if (_resolvedPaths.contains(key)) {
            return _resolvedPaths[key]
        }
        let svc = getMediaResourcesService()
        return svc.getCachedPath(targetMediaId, repr)
    }

    /**
     * 判断指定表示是否有本地缓存（不触发下载）。
     *
     * @param targetMediaId  媒体文件 ID
     * @param repr           缓存资源表示
     * @return true = 本地已有；false = 需要下载
     */
    public func isCached(targetMediaId: Int64, repr: CachedRepresentation): Bool {
        return queryCachedPath(targetMediaId, repr).size > 0
    }

    /**
     * 使指定媒体 ID 的全部内存缓存失效（强制重查）。
     *
     * @param targetMediaId  媒体文件 ID
     */
    public func invalidateCache(targetMediaId: Int64): Unit {
        let prefix = targetMediaId.toString() + "/"
        let newPaths = HashMap<String, String>()
        for ((k, v) in _resolvedPaths) {
            if (!k.startsWith(prefix)) {
                newPaths[k] = v
            }
        }
        _resolvedPaths = newPaths
        getMediaResourcesService().invalidateMemoryCache(targetMediaId)
        if (this.mediaId == targetMediaId) {
            this.localPath = ""
            this.isReady = false
        }
        Hilog.info(0, "CjTelegram", "[MediaResourcesVM] Invalidated cache: id=${targetMediaId}")
    }

}

// ─────────────────────────────────────────────────────────────────
// 顶层辅助函数（位于 @Observed 类外，避免宏展开 None 歧义）
// ─────────────────────────────────────────────────────────────────

/**
 * 根据 kind 标签重建 CachedRepresentation 实例（用于 spawn 闭包内部）。
 *
 * 在 spawn 内直接捕获 CachedRepresentation 变量可能触发 S-#77
 * （lambda capturing mutable variables），因此通过 kind/uniqueId String 间接恢复。
 * 该函数定义在 @Observed 类外，避免 @Observed 宏展开引入 None 类型歧义。
 */
func rebuildReprFromKind(kind: String): CachedRepresentation {
    if (kind == "first-frame") {
        return CachedRepresentation.videoFirstFrame()
    }
    if (kind == "prefix-first-frame") {
        return CachedRepresentation.videoPrefixFirstFrame(0)
    }
    if (kind == "blurred-wallpaper") {
        return CachedRepresentation.blurredWallpaper()
    }
    if (kind == "prepared-pattern-wallpaper") {
        return CachedRepresentation.patternWallpaper()
    }
    if (kind == "prepared-svg") {
        return CachedRepresentation.preparedSvg()
    }
    if (kind == "sticker-ajpeg") {
        let noSize: Option<MediaSize> = None
        return CachedRepresentation.stickerAJpeg(noSize)
    }
    if (kind == "album-artwork") {
        let noSize: Option<MediaSize> = None
        return CachedRepresentation.albumArtwork(noSize)
    }
    if (kind == "video-sticker") {
        return CachedRepresentation.videoSticker(0, 0)
    }
    if (kind == "animated-sticker") {
        let noFitz: Option<EmojiFitzModifier> = None
        return CachedRepresentation.animatedSticker(0, 0, noFitz)
    }
    if (kind == "animated-sticker-first-frame") {
        let noFitz: Option<EmojiFitzModifier> = None
        return CachedRepresentation.animatedStickerFirstFrame(0, 0, noFitz)
    }
    if (kind == "scaled-image") {
        return CachedRepresentation.scaledImage(MediaSize(0, 0), ScaledImageMode.Fill)
    }
    if (kind == "scaled-frame") {
        return CachedRepresentation.scaledVideoFirstFrame(MediaSize(0, 0))
    }
    if (kind == "emoji-thumb") {
        return CachedRepresentation.emojiThumbnail(false)
    }
    if (kind == "emoji") {
        return CachedRepresentation.emoji(0, false)
    }
    return CachedRepresentation.videoFirstFrame()
}
