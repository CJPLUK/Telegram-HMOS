package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.ArrayList

/**
 * TelegramUniversalVideoContentService — 通用视频内容播放服务
 *
 * 对应 iOS submodules/TelegramUniversalVideoContent/Sources/:
 *   - NativeVideoContent.swift     — 聊天内嵌视频（文件下载 + 播放）
 *   - SystemVideoContent.swift     — 圆形视频消息（即时视频）
 *   - HLSVideoContent.swift        — HLS 流媒体（外链视频）
 *   - UniversalVideoContentManager.swift — 多播放器统一调度
 *
 * HarmonyOS 实现方案：
 *   - 普通视频/文件视频：FileDownloadService.downloadDocument → 存本地 → Video 组件（kit.ArkUI Video）
 *   - GIF 动图：SoftwareVideoService.extractFrame（AVImageGenerator 逐帧提取）
 *   - 圆形视频消息（roundVideo）：FileDownloadService.downloadDocument → Video 组件 + circular clip
 *   - HLS/网络流：Video 组件 src 直接传 http:// URL（ArkUI Video 原生支持 HLS）
 *
 * MTProto 调用链：
 *   TelegramUniversalVideoContentService.downloadVideoFile(fileId, accessHash, fileRef, dcId, fileSize)
 *     → FileDownloadService.downloadDocument(fileId, accessHash, fileRef, dcId, fileSize)
 *       → UploadGetFile TL 方法 → MTProtoClient.send()
 *         → 返回 Array<Byte> → 写入本地文件
 *           → 返回本地 file:// 路径
 */

// ─────────────────────────────────────────────────────────────────
// 视频内容类型
// ─────────────────────────────────────────────────────────────────

/**
 * 视频内容类型
 * - NativeVideo:     聊天内普通视频文件（MP4/MOV 等）
 * - RoundVideo:      圆形视频消息（即时视频，带圆形裁切）
 * - GifAnimation:    GIF 动图（SoftwareVideo 帧提取渲染）
 * - HlsStream:       HLS 流媒体（外链视频，http:// 直接播放）
 */
public enum UniversalVideoContentType {
    | NativeVideo
    | RoundVideo
    | GifAnimation
    | HlsStream
}

// ─────────────────────────────────────────────────────────────────
// 视频内容描述符
// ─────────────────────────────────────────────────────────────────

/**
 * UniversalVideoContent — 统一视频内容描述符
 *
 * 对应 iOS NativeVideoContent / SystemVideoContent / HLSVideoContent 的公共字段。
 */
public class UniversalVideoContent {
    /** 视频唯一标识（fileId 或消息 ID 衍生） */
    public var contentId: Int64 = 0
    /** 视频类型 */
    public var contentType: UniversalVideoContentType = UniversalVideoContentType.NativeVideo
    /** MTProto 文件 ID（下载用），流媒体时为 0 */
    public var fileId: Int64 = 0
    /** MTProto 访问 Hash */
    public var accessHash: Int64 = 0
    /** MTProto 文件引用 */
    public var fileReference: Array<Byte> = Array<Byte>(0, { _i: Int64 => UInt8(0) })
    /** 数据中心 ID */
    public var dcId: Int32 = 1
    /** 文件大小（字节），0 表示未知 */
    public var fileSize: Int64 = 0
    /** 视频宽度（像素） */
    public var width: Int32 = 0
    /** 视频高度（像素） */
    public var height: Int32 = 0
    /** 视频时长（秒） */
    public var duration: Float64 = 0.0
    /** 缩略图本地路径（已下载） */
    public var thumbnailLocalPath: String = ""
    /** 视频本地文件路径（已下载后填入） */
    public var localFilePath: String = ""
    /** HLS 流 URL（HlsStream 类型时使用） */
    public var hlsUrl: String = ""
    /** 是否开启声音 */
    public var enableSound: Bool = true
    /** 是否循环播放（GIF/圆形视频默认循环） */
    public var loopVideo: Bool = false

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 播放状态
// ─────────────────────────────────────────────────────────────────

/**
 * 视频播放状态
 */
public enum VideoPlaybackState {
    | Idle
    | Downloading
    | Ready
    | Playing
    | Paused
    | Finished
    | Failed
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _telegramUniversalVideoContentServiceInstance: Option<TelegramUniversalVideoContentService> = None

/**
 * 获取 TelegramUniversalVideoContentService 单例
 */
public func getTelegramUniversalVideoContentService(): TelegramUniversalVideoContentService {
    match (_telegramUniversalVideoContentServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramUniversalVideoContentService()
            _telegramUniversalVideoContentServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// TelegramUniversalVideoContentService
// ─────────────────────────────────────────────────────────────────

/**
 * TelegramUniversalVideoContentService — 通用视频内容播放服务
 *
 * 职责：
 * 1. 根据 UniversalVideoContent 描述符下载视频文件（委托 FileDownloadService）
 * 2. 管理本地视频缓存（/files/videos/ 目录）
 * 3. 提供 GIF 动图首帧提取（委托 SoftwareVideoService）
 * 4. 向 UI 层（TelegramUniversalVideoContentPage）提供可播放的本地路径
 *
 * 调用链：
 *   TelegramUniversalVideoContentPage.startPlayback(content)
 *     → TelegramUniversalVideoContentService.downloadVideoFile(content)
 *       → FileDownloadService.downloadDocument(fileId, accessHash, fileRef, dcId, fileSize)
 *         → UploadGetFile TL → MTProtoClient.send()
 *       → 写入 /files/videos/video_<fileId>.mp4
 *     → 返回 file:// 路径
 *     → Video 组件 .src(localFileUri) 播放
 */
public class TelegramUniversalVideoContentService {

    public init() {}

    /**
     * 下载视频文件并返回本地 file:// URI。
     *
     * 对应 iOS NativeVideoContent.makeContentNode() 触发的文件下载流程。
     * 先检查缓存，命中直接返回；否则通过 FileDownloadService.downloadDocument 下载。
     *
     * 调用链：
     *   downloadVideoFile(content)
     *     → getFileDownloadService().downloadDocument(fileId, accessHash, fileRef, dcId, fileSize)
     *       → UploadGetFile TL → MTProtoClient.send()
     *
     * @param content  视频内容描述符（需填写 fileId / accessHash / fileReference / dcId / fileSize）
     * @return 本地文件的 file:// URI，失败时返回空字符串
     */
    public func downloadVideoFile(content: UniversalVideoContent): String {
        if (content.fileId == 0) {
            Hilog.info(0, "CjTelegram", "[TUVC] downloadVideoFile: fileId=0, skip download")
            return ""
        }

        let cacheKey = content.fileId
        let videoDir = getVideoStorageDir()
        let localPath = "${videoDir}/video_${cacheKey}.mp4"

        if (FileIo.access(localPath)) {
            Hilog.info(0, "CjTelegram", "[TUVC] Cache hit: ${localPath}")
            return "file://${localPath}"
        }

        Hilog.info(0, "CjTelegram", "[TUVC] Downloading video fileId=${content.fileId}, size=${content.fileSize}")

        let downloadService = getFileDownloadService()
        let data = downloadService.downloadDocument(
            content.fileId,
            content.accessHash,
            content.fileReference,
            content.dcId,
            fileSize: content.fileSize
        )

        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[TUVC] Download failed: empty data for fileId=${content.fileId}")
            return ""
        }

        ensureVideoDirectory(videoDir)
        let writeOk = writeVideoFile(localPath, data)
        if (!writeOk) {
            Hilog.info(0, "CjTelegram", "[TUVC] Write failed: ${localPath}")
            return ""
        }

        Hilog.info(0, "CjTelegram", "[TUVC] Downloaded: ${localPath} (${data.size} bytes)")
        return "file://${localPath}"
    }

    /**
     * 为 GIF 动图提取首帧，返回 SoftwareVideoFrame。
     *
     * 对应 iOS NativeVideoContent 中 loopVideo=true + no-sound 的 GIF 播放路径。
     * 先下载文件，再委托 SoftwareVideoService.extractFrame 提取 timeUs=0 处的帧。
     *
     * 调用链：
     *   extractGifFirstFrame(content)
     *     → downloadVideoFile(content) → FileDownloadService.downloadDocument()
     *     → getSoftwareVideoService().extractFrame(localPath, timeUs: 0)
     *       → AVImageGenerator.fetchFrameByTime()
     *
     * @param content 视频内容描述符（contentType 应为 GifAnimation）
     * @return SoftwareVideoFrame；isValid=false 表示提取失败
     */
    public func extractGifFirstFrame(content: UniversalVideoContent): SoftwareVideoFrame {
        let localUri = downloadVideoFile(content)
        if (localUri.size == 0) {
            Hilog.info(0, "CjTelegram", "[TUVC] extractGifFirstFrame: download failed")
            return SoftwareVideoFrame()
        }

        let localPath = stripFilePrefix(localUri)
        let svc = getSoftwareVideoService()
        let frame = svc.extractFrame(localPath, 0)
        Hilog.info(0, "CjTelegram", "[TUVC] GIF first frame: valid=${frame.isValid}")
        return frame
    }

    /**
     * 查询视频本地缓存路径（不触发下载）。
     *
     * 供 UI 层判断是否已缓存（显示下载进度 vs 直接播放）。
     *
     * @param fileId 文件 ID
     * @return 本地 file:// URI，若未缓存返回空字符串
     */
    public func getCachedVideoUri(fileId: Int64): String {
        if (fileId == 0) { return "" }
        let videoDir = getVideoStorageDir()
        let localPath = "${videoDir}/video_${fileId}.mp4"
        if (FileIo.access(localPath)) {
            return "file://${localPath}"
        }
        return ""
    }

    /**
     * 清理指定 fileId 的本地视频缓存。
     *
     * 对应 iOS UniversalVideoContentManager 中的内容释放逻辑。
     *
     * @param fileId 文件 ID
     */
    public func clearVideoCache(fileId: Int64): Unit {
        if (fileId == 0) { return }
        let videoDir = getVideoStorageDir()
        let localPath = "${videoDir}/video_${fileId}.mp4"
        if (FileIo.access(localPath)) {
            try {
                FileIo.unlink(localPath)
                Hilog.info(0, "CjTelegram", "[TUVC] Cache cleared: ${localPath}")
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[TUVC] Cache clear failed: ${localPath}")
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 内部辅助
    // ─────────────────────────────────────────────────────────────

    /**
     * 视频存储目录（沙箱路径）
     */
    private func getVideoStorageDir(): String {
        let filesDir = getAppFilesDir()
        return "${filesDir}/videos"
    }

    /**
     * 确保视频目录存在
     */
    private func ensureVideoDirectory(dir: String): Unit {
        if (!FileIo.access(dir)) {
            try {
                FileIo.mkdir(dir)
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[TUVC] mkdir failed: ${dir}")
            }
        }
    }

    /**
     * 将字节数组写入本地文件
     *
     * @param path  目标文件路径
     * @param data  文件数据
     * @return 写入成功返回 true
     */
    private func writeVideoFile(path: String, data: Array<Byte>): Bool {
        try {
            let file = FileIo.open(path, mode: 0o1101)
            let _ = FileIo.write(file.fd, data)
            FileIo.close(file)
            return true
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[TUVC] File write error: ${path}")
            return false
        }
    }

    /**
     * 去除 file:// 前缀，返回原始文件系统路径
     */
    private func stripFilePrefix(uri: String): String {
        let prefix = "file://"
        if (uri.startsWith(prefix)) {
            return uri[prefix.size..]
        }
        return uri
    }
}
