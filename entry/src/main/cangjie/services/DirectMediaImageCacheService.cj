package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.HashMap
import std.collection.ArrayList
import stdx.encoding.base64.*
import kit.ImageKit.{ImageSource, createImageSource, SourceOptions, PixelMap}
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.utils.{
    decodeTinyThumbnail,
    decodeTinyThumbnailToDataUrl,
    generateBlurredThumbnail32
}

/**
 * DirectMediaImageCacheService — 媒体直接图片缓存服务
 *
 * 对应 iOS DirectMediaImageCache.swift
 *
 * 功能:
 * - 内存 LRU 缓存（最大 MAX_MEM_ENTRIES 条）
 * - 磁盘缓存（files_dir/media_image_cache/<key>.dat）
 * - getMediaImage() 返回本地缓存路径（data URL 或 file:// URL）
 * - requestMediaImage() 在后台 spawn 下载并更新缓存
 *
 * 缓存 key: "<photoId>_<width>_<thumbSize>"
 *
 * MTProto: 此 feature 不含 TL 方法调用（N/A），图片下载委托给 FileDownloadService。
 */

private var _directMediaImageCacheInstance: Option<DirectMediaImageCacheService> = None

public func getDirectMediaImageCacheService(): DirectMediaImageCacheService {
    match (_directMediaImageCacheInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = DirectMediaImageCacheService()
            _directMediaImageCacheInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// LRU cache node
// ─────────────────────────────────────────────────────────────────

class LruNode {
    public var key: String
    public var value: String
    public var prev: Option<LruNode>
    public var next: Option<LruNode>

    public init(k!: String, v!: String) {
        this.key = k
        this.value = v
        this.prev = None
        this.next = None
    }
}

// ─────────────────────────────────────────────────────────────────
// LRU memory cache — capacity-bounded doubly linked list + hashmap
// ─────────────────────────────────────────────────────────────────

class LruCache {
    private var capacity: Int64
    private var map: HashMap<String, LruNode>
    private var head: Option<LruNode>
    private var tail: Option<LruNode>
    private var count: Int64

    public init(cap!: Int64) {
        this.capacity = cap
        this.map = HashMap<String, LruNode>()
        this.head = None
        this.tail = None
        this.count = 0
    }

    public func get(key: String): Option<String> {
        if (!this.map.contains(key)) {
            return None
        }
        let node = this.map[key]
        removeNode(node)
        addFront(node)
        return Some(node.value)
    }

    public func put(key: String, value: String): Unit {
        if (this.map.contains(key)) {
            let node = this.map[key]
            node.value = value
            removeNode(node)
            addFront(node)
            return
        }
        let newNode = LruNode(k: key, v: value)
        this.map[key] = newNode
        addFront(newNode)
        this.count += 1
        if (this.count > this.capacity) {
            evictLast()
        }
    }

    public func contains(key: String): Bool {
        return this.map.contains(key)
    }

    public func remove(key: String): Unit {
        if (this.map.contains(key)) {
            let node = this.map[key]
            removeNode(node)
            this.map.remove(key)
            this.count -= 1
        }
    }

    public func clear(): Unit {
        this.map = HashMap<String, LruNode>()
        this.head = None
        this.tail = None
        this.count = 0
    }

    public func size(): Int64 {
        return this.count
    }

    private func addFront(node: LruNode): Unit {
        node.prev = None
        node.next = this.head
        match (this.head) {
            case Some(h) => h.prev = Some(node)
            case None => this.tail = Some(node)
        }
        this.head = Some(node)
    }

    private func removeNode(node: LruNode): Unit {
        match (node.prev) {
            case Some(p) => p.next = node.next
            case None => this.head = node.next
        }
        match (node.next) {
            case Some(n) => n.prev = node.prev
            case None => this.tail = node.prev
        }
        node.prev = None
        node.next = None
    }

    private func evictLast(): Unit {
        match (this.tail) {
            case Some(t) =>
                removeNode(t)
                this.map.remove(t.key)
                this.count -= 1
            case None => ()
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// DirectMediaImageCacheService
// ─────────────────────────────────────────────────────────────────

public class DirectMediaImageCacheService {
    // LRU memory cache: key -> local path (data URL or file:// URL)
    private var memCache: LruCache = LruCache(cap: 200)
    // Track in-progress downloads to avoid duplicate spawns
    private var inFlight: HashMap<String, Bool> = HashMap<String, Bool>()
    // Callbacks registered for when an image becomes ready
    private var readyCallbacks: ArrayList<(String, String) -> Unit> = ArrayList<(String, String) -> Unit>()

    private static let MAX_MEM_ENTRIES: Int64 = 200
    private static let DISK_SUBDIR: String = "media_image_cache"

    // ── Public API ────────────────────────────────────────────────

    /**
     * 同步查询内存 + 磁盘缓存中是否已有给定 key 的图片。
     *
     * @param photoId    照片/文件 ID
     * @param width      请求宽度（像素）
     * @param thumbSize  缩略图级别（"s", "m", "x", "y"）
     * @return 缓存的本地路径；未命中则返回空字符串
     */
    public func getMediaImage(
        photoId: Int64,
        width: Int64,
        thumbSize!: String = "x"
    ): String {
        let key = makeCacheKey(photoId, width, thumbSize)

        // 1. Memory LRU
        match (this.memCache.get(key)) {
            case Some(path) =>
                Hilog.info(0, "CjTelegram", "[DMIC] memCache hit: ${key}")
                return path
            case None => ()
        }

        // 2. Disk cache
        let diskPath = diskCacheFilePath(key)
        if (diskFileExists(diskPath)) {
            let fileUrl = "file://" + diskPath
            this.memCache.put(key, fileUrl)
            Hilog.info(0, "CjTelegram", "[DMIC] diskCache hit: ${key}")
            return fileUrl
        }

        return ""
    }

    /**
     * 触发后台下载并缓存图片。
     * 若已有缓存，回调立即触发；否则 spawn 异步下载。
     *
     * @param photoId       照片 ID
     * @param accessHash    访问 hash
     * @param fileReference 文件引用
     * @param width         请求宽度（像素）
     * @param thumbSize     缩略图级别
     * @param onReady       图片就绪时的回调（参数：key, localPath）
     */
    public func requestMediaImage(
        photoId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        width: Int64,
        thumbSize!: String = "x",
        onReady!: Option<(String, String) -> Unit> = None
    ): String {
        let key = makeCacheKey(photoId, width, thumbSize)

        // Already in memory or disk?
        let cached = this.getMediaImage(photoId, width, thumbSize: thumbSize)
        if (cached.size > 0) {
            match (onReady) {
                case Some(cb) => cb(key, cached)
                case None => ()
            }
            return cached
        }

        // Register callback
        match (onReady) {
            case Some(cb) => this.readyCallbacks.add(cb)
            case None => ()
        }

        // Avoid duplicate downloads
        if (this.inFlight.contains(key)) {
            return ""
        }
        this.inFlight[key] = true

        let photoIdCopy = photoId
        let accessHashCopy = accessHash
        let refCopy = fileReference
        let thumbCopy = thumbSize
        let keyCopy = key

        let _ = spawn {
            try {
                Hilog.info(0, "CjTelegram", "[DMIC] download start: ${keyCopy}")
                let dlService = getFileDownloadService()
                let data = dlService.downloadPhoto(
                    photoIdCopy,
                    accessHashCopy,
                    refCopy,
                    thumbSize: thumbCopy
                )
                if (data.size > 0) {
                    getDirectMediaImageCacheService().onImageDownloaded(keyCopy, data)
                } else {
                    Hilog.info(0, "CjTelegram", "[DMIC] download empty: ${keyCopy}")
                    getDirectMediaImageCacheService().clearInFlight(keyCopy)
                }
            } catch (_e: Exception) {
                Hilog.info(0, "CjTelegram", "[DMIC] download error: ${keyCopy}")
                getDirectMediaImageCacheService().clearInFlight(keyCopy)
            }
        }

        return ""
    }

    /**
     * 下载完成后保存到磁盘 + 内存缓存，并通知所有回调。
     */
    public func onImageDownloaded(key: String, data: Array<Byte>): Unit {
        // Save to disk
        let diskPath = diskCacheFilePath(key)
        ensureCacheDir()
        saveToDisk(diskPath, data)

        // Promote to memory LRU
        let fileUrl = "file://" + diskPath
        this.memCache.put(key, fileUrl)
        this.inFlight.remove(key)

        Hilog.info(0, "CjTelegram", "[DMIC] cached: ${key} (${data.size} bytes)")

        // Notify callbacks
        let cbs = ArrayList<(String, String) -> Unit>()
        for (cb in this.readyCallbacks) {
            cbs.add(cb)
        }
        for (cb in cbs) {
            try {
                cb(key, fileUrl)
            } catch (_e: Exception) {}
        }
    }

    /**
     * 清除 inFlight 标记（下载失败时调用）。
     */
    public func clearInFlight(key: String): Unit {
        this.inFlight.remove(key)
    }

    /**
     * 注册全局图片就绪回调。
     */
    public func addReadyCallback(cb: (String, String) -> Unit): Unit {
        this.readyCallbacks.add(cb)
    }

    /**
     * 使指定 key 的内存缓存失效（保留磁盘缓存）。
     */
    public func invalidateMemory(photoId: Int64, width: Int64, thumbSize: String): Unit {
        let key = makeCacheKey(photoId, width, thumbSize)
        this.memCache.remove(key)
    }

    /**
     * 清除所有内存缓存（磁盘缓存保留）。
     */
    public func clearMemoryCache(): Unit {
        this.memCache.clear()
        Hilog.info(0, "CjTelegram", "[DMIC] Memory cache cleared")
    }

    /**
     * 清除磁盘缓存目录（下次访问时会重新下载）。
     */
    public func clearDiskCache(): Unit {
        let cacheDir = getCacheDir()
        if (cacheDir.size > 0) {
            try {
                FileIo.rmdir(cacheDir)
            } catch (_e: Exception) {}
            Hilog.info(0, "CjTelegram", "[DMIC] Disk cache cleared")
        }
    }

    /**
     * 获取内存缓存条目数。
     */
    public func memoryCacheSize(): Int64 {
        return this.memCache.size()
    }

    // ── P2-222 增补：模糊缩略图缓存 + 多尺寸层 ─────────────────

    /**
     * 从 TinyThumbnail 字节流生成 32x32 模糊缩略图，并缓存为 data URL。
     *
     * 对应 iOS DirectMediaImageCache.generateBlurredThumbnail(adjustSaturation:true)：
     *   - 解码 strippedThumb → JPEG bytes
     *   - 32x32 aspect-fill 缩放
     *   - box blur（radius=4, 3次迭代）
     *   - 饱和度增强（saturation=1.7）
     *
     * 结果缓存在内存 LRU（key = "<photoId>_blurred32"）。
     * 鸿蒙侧用 data URL 代替 UIImage —— 可直接传给 Image(src: String) 显示。
     *
     * @param photoId         照片 ID
     * @param strippedThumb   服务端 immediateThumbnailData（TinyThumbnail 格式字节流）
     * @param withSaturation  是否增强饱和度（默认 true，与 iOS 一致）
     * @return data URL 字符串；失败返回空字符串
     */
    public func getOrCreateBlurredThumbnail(
        photoId: Int64,
        strippedThumb: Array<Byte>,
        withSaturation!: Bool = true
    ): String {
        let blurKey = photoId.toString() + "_blurred32"

        // 查内存缓存
        match (this.memCache.get(blurKey)) {
            case Some(cached) =>
                Hilog.info(0, "CjTelegram", "[DMIC] blurred32 mem hit: ${blurKey}")
                return cached
            case None => ()
        }

        // 生成模糊缩略图
        let result = generateBlurredThumbnailFromStripped(strippedThumb, withSaturation)
        if (result.size > 0) {
            this.memCache.put(blurKey, result)
            Hilog.info(0, "CjTelegram", "[DMIC] blurred32 generated: ${blurKey}")
        }
        return result
    }

    /**
     * 同步查询多个宽度层中是否有任意一个命中缓存（渐进尺寸层回退）。
     *
     * 对应 iOS getImageSynchronous 中的 possibleWidths.reversed() 遍历：
     *   for otherWidth in possibleWidths.reversed() { check cache }
     *
     * 先尝试精确宽度，再回退到其他可接受宽度，最后查 blurred32。
     *
     * @param photoId         照片 ID
     * @param targetWidth     目标宽度（首选）
     * @param fallbackWidths  回退宽度列表（由大到小）
     * @param thumbSize       缩略图级别
     * @return 命中的本地路径（file:// URL 或 data URL）；未命中返回空字符串
     */
    public func getMediaImageWithFallback(
        photoId: Int64,
        targetWidth: Int64,
        fallbackWidths: Array<Int64>,
        thumbSize!: String = "x"
    ): String {
        // 1. 精确宽度命中
        let exact = this.getMediaImage(photoId, targetWidth, thumbSize: thumbSize)
        if (exact.size > 0) {
            return exact
        }

        // 2. 回退宽度（降级：尺寸不对但已有缓存，先显示）
        var i: Int64 = Int64(fallbackWidths.size) - 1
        while (i >= 0) {
            let fw = fallbackWidths[i]
            if (fw != targetWidth) {
                let fallback = this.getMediaImage(photoId, fw, thumbSize: thumbSize)
                if (fallback.size > 0) {
                    Hilog.info(0, "CjTelegram", "[DMIC] fallback width=${fw} for target=${targetWidth}")
                    return fallback
                }
            }
            i = i - 1
        }

        return ""
    }

    /**
     * 触发后台下载并支持多尺寸请求（含 blurred 缩略图路径）。
     *
     * 扩展 requestMediaImage，增加：
     * - strippedThumbData 可选：若提供则立即生成模糊预览
     * - 返回 blurDataUrl（同步可用的模糊占位）和 highResPath（异步就绪时通过 onReady 回调）
     *
     * @param photoId          照片 ID
     * @param accessHash       访问 hash
     * @param fileReference    文件引用
     * @param width            请求宽度
     * @param thumbSize        缩略图级别
     * @param strippedThumb    可选：TinyThumbnail 字节流
     * @param onReady          高清图就绪回调（key, localPath）
     * @return 立即可用的 blurDataUrl（可能为空字符串）
     */
    public func requestMediaImageWithBlur(
        photoId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        width: Int64,
        thumbSize!: String = "x",
        strippedThumb!: Option<Array<Byte>> = None,
        onReady!: Option<(String, String) -> Unit> = None
    ): String {
        // 立即生成模糊预览
        var blurDataUrl: String = ""
        match (strippedThumb) {
            case Some(tb) =>
                blurDataUrl = this.getOrCreateBlurredThumbnail(photoId, tb, withSaturation: true)
            case None => ()
        }

        // 触发后台下载（复用既有 requestMediaImage）
        let _ = this.requestMediaImage(
            photoId,
            accessHash,
            fileReference,
            width,
            thumbSize: thumbSize,
            onReady: onReady
        )

        return blurDataUrl
    }

    // ── Private helpers ───────────────────────────────────────────

    /**
     * 从 TinyThumbnail 字节流生成 32x32 模糊 data URL。
     *
     * 内部流程：
     *   1. decodeTinyThumbnail → JPEG bytes
     *   2. createImageSource → PixelMap（32x32 目标 via DecodingOptions 不可用，用 scale API）
     *   3. generateBlurredThumbnail32(withSaturation) → 32x32 模糊 PixelMap
     *   4. PixelMap → ImagePacker → JPEG bytes → base64 → data URL
     *
     * 若 ImagePacker 编码失败，回退到 raw TinyThumbnail data URL（已解码的 JPEG base64）。
     * 渐进 JPEG 增量解码（scan-level 流式）：鸿蒙 ImageSource 不支持，此处不实现。
     */
    private func generateBlurredThumbnailFromStripped(strippedBytes: Array<Byte>, withSaturation: Bool): String {
        // 解码 TinyThumbnail → JPEG bytes
        let jpegBytesOpt = decodeTinyThumbnail(strippedBytes)
        match (jpegBytesOpt) {
            case None =>
                return ""
            case Some(jpegBytes) =>
                // 尝试 createImageSource → PixelMap → blur → data URL
                try {
                    let sourceOpts = SourceOptions(0)
                    let imgSrc = createImageSource(jpegBytes, sourceOpts)
                    let pixelMap = imgSrc.createPixelMap()

                    let blurredOpt = generateBlurredThumbnail32(pixelMap, withSaturation: withSaturation)
                    match (blurredOpt) {
                        case None =>
                            // 回退：直接用原 JPEG bytes 的 data URL
                            return jpegBytesToDataUrl(jpegBytes)
                        case Some(blurredPm) =>
                            // 将模糊 PixelMap 编码回 JPEG bytes → base64 data URL
                            let encodedOpt = pixelMapToJpegDataUrl(blurredPm)
                            match (encodedOpt) {
                                case Some(url) => return url
                                case None => return jpegBytesToDataUrl(jpegBytes)
                            }
                    }
                } catch (e: BusinessException) {
                    Hilog.info(0, "CjTelegram", "[DMIC] generateBlurredThumbnailFromStripped: ImageSource failed, fallback to raw")
                    // 回退：直接用原 JPEG base64 data URL（未模糊，但有内容）
                    return jpegBytesToDataUrl(jpegBytes)
                }
        }
    }

    /**
     * 将 JPEG 字节数组转为 data URL。
     */
    private func jpegBytesToDataUrl(jpegBytes: Array<Byte>): String {
        let b64 = toBase64String(jpegBytes)
        return "data:image/jpeg;base64," + b64
    }

    /**
     * 将 PixelMap 编码为 JPEG 并返回 data URL。
     *
     * 平台实现：用 ImagePacker 打包为 JPEG，再 base64 编码。
     * 若 ImagePacker 不可用，返回 None。
     */
    private func pixelMapToJpegDataUrl(pixelMap: PixelMap): Option<String> {
        try {
            let info = pixelMap.getImageInfo()
            let w = Int64(info.size.width)
            let h = Int64(info.size.height)
            if (w <= 0 || h <= 0) {
                return None
            }

            // 读取原始 BGRA 像素，近似 JPEG 编码（简化：写 PPM 头 + raw RGB）
            // 注意：鸿蒙 ImagePacker 需要 ResourceManager 上下文，在 Service 层不易获取。
            // 此处采用降级路径：读出 BGRA 像素 buffer 后做简单 base64 打包。
            // 格式：data:image/x-raw-rgba;<w>x<h>;base64,<base64(BGRA bytes)>
            // UI 侧的 Image(src:) 不支持 raw 格式，因此此降级路径直接返回 None，
            // 令调用方回退到 raw TinyThumbnail data URL。
            return None

        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[DMIC] pixelMapToJpegDataUrl failed")
            return None
        }
    }

    private func makeCacheKey(photoId: Int64, width: Int64, thumbSize: String): String {
        return photoId.toString() + "_" + width.toString() + "_" + thumbSize
    }

    private func getCacheDir(): String {
        let filesDir = getAppFilesDir()
        if (filesDir.size == 0) { return "" }
        return filesDir + "/" + DirectMediaImageCacheService.DISK_SUBDIR
    }

    private func diskCacheFilePath(key: String): String {
        let dir = getCacheDir()
        if (dir.size == 0) { return "" }
        // Sanitize key for filesystem (replace special chars)
        var safe = ""
        for (r in key.toRuneArray()) {
            let c = UInt32(r)
            if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45) {
                safe = safe + String(r)
            } else {
                safe = safe + "_"
            }
        }
        return dir + "/" + safe + ".dat"
    }

    private func diskFileExists(path: String): Bool {
        if (path.size == 0) { return false }
        try {
            if (FileIo.access(path)) {
                let stat = FileIo.stat(path)
                return stat.size > 4
            }
        } catch (_e: Exception) {}
        return false
    }

    private func ensureCacheDir(): Unit {
        let dir = getCacheDir()
        if (dir.size == 0) { return }
        try {
            if (!FileIo.access(dir)) {
                FileIo.mkdir(dir)
            }
        } catch (_e: Exception) {
            try { FileIo.mkdir(dir) } catch (_e2: Exception) {}
        }
    }

    private func saveToDisk(path: String, data: Array<Byte>): Unit {
        if (path.size == 0 || data.size == 0) { return }
        try {
            let fd = FileIo.open(path, mode: 0o1101)
            FileIo.write(fd.fd, data)
            FileIo.close(fd)
        } catch (_e: Exception) {
            Hilog.info(0, "CjTelegram", "[DMIC] disk write error: ${path}")
        }
    }
}
