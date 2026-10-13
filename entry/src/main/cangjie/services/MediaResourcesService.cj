package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import std.collection.HashMap
import std.collection.ArrayList
import std.time.DateTime
import ohos_app_cangjie_entry.core.storage.postbox.MediaResourceIndexTable
import ohos_app_cangjie_entry.core.storage.postbox.MediaResourceCacheEntry

// ─────────────────────────────────────────────────────────────────
// P2-220: Typed Media Resource Classes（对应 iOS TelegramMediaResource 体系）
//
// iOS 侧 TelegramCore/SyncCore_CloudFileMediaResource.swift、Postbox/MediaResource.swift
// 以及 LocalMediaResources/MediaResources.swift 定义了一套具体资源类型系统：
//   - 每类资源有唯一 uniqueId()（用于缓存键）
//   - 每类资源有 size: Option<Int64>（下载字节大小，-1/None = 未知）
//   - 带 headerSize 的类型有分块下载头部尺寸（32 * 1024 bytes）
//
// Cangjie 实现：显式独立类，而非 iOS 的协议/继承体系（仓颉不适合 TelegramMediaResource 协议层），
// 提供 uniqueId() / size / headerSize 属性供 MediaResourcesService / ResourcesService 使用。
// ─────────────────────────────────────────────────────────────────

// ─── 图片格式枚举（对应 iOS MediaImageFormat: Int32）─────────────────────────

/**
 * 相册图片编码格式（对应 iOS LocalMediaResources/MediaResources.swift MediaImageFormat）
 *
 * JPEG 对应 iOS rawValue = 0；
 * PNG  对应 iOS rawValue = 1 (jxl → Cangjie 端退化为 PNG，HarmonyOS ImagePacker 无 JXL 支持)
 */
public enum MediaImageFormat {
    | Jpeg   // rawValue = 0, MIME = "image/jpeg"
    | Png    // rawValue = 1, MIME = "image/png"  (iOS jxl 对应 HarmonyOS 替代)
}

/** 将 MediaImageFormat 映射为 MIME 类型字符串（供 ImagePacker 使用）*/
public func mediaImageFormatMIME(fmt: MediaImageFormat): String {
    match (fmt) {
        case MediaImageFormat.Jpeg => return "image/jpeg"
        case MediaImageFormat.Png  => return "image/png"
    }
}

// ─── CloudDocumentMediaResource ──────────────────────────────────────────────

/**
 * CloudDocumentMediaResource — Telegram 云文档媒体资源
 *
 * 对应 iOS CloudDocumentMediaResource（TelegramCore/SyncCore_CloudFileMediaResource.swift）：
 *   - datacenterId：数据中心 ID
 *   - fileId：TL file_id（Int64）
 *   - accessHash：MTProto 访问 hash
 *   - size：文件大小（None = 未知，对应 iOS optional Int64?）
 *   - fileReference：文件引用字节
 *   - fileName：可选原始文件名
 *
 * uniqueId() 格式："telegram-cloud-document-<dcId>-<fileId>"
 * （与 iOS CloudDocumentMediaResourceId.uniqueId 完全对应）
 *
 * headerSize = 0（iOS CloudDocumentMediaResource 不覆写 TelegramMediaResource.headerSize，
 * 继承协议扩展默认值 0；分块头部尺寸仅适用于流式/本地视频/音频资源）
 */
public class CloudDocumentMediaResource {
    public var datacenterId: Int32
    public var fileId: Int64
    public var accessHash: Int64
    public var size: Option<Int64>
    public var fileReference: Array<Byte>
    public var fileName: Option<String>

    /** 分块下载头部尺寸：继承 iOS 协议默认值 0（iOS CloudDocumentMediaResource 不覆写 headerSize） */
    public let headerSize: Int32 = 0

    public init(
        datacenterId: Int32,
        fileId: Int64,
        accessHash: Int64,
        size: Option<Int64>,
        fileReference: Array<Byte>,
        fileName: Option<String>
    ) {
        this.datacenterId = datacenterId
        this.fileId = fileId
        this.accessHash = accessHash
        this.size = size
        this.fileReference = fileReference
        this.fileName = fileName
    }

    /**
     * 资源唯一 ID，用于本地缓存键派生。
     * 格式："telegram-cloud-document-<datacenterId>-<fileId>"
     * 对应 iOS CloudDocumentMediaResourceId.uniqueId
     */
    public func uniqueId(): String {
        return "telegram-cloud-document-${datacenterId}-${fileId}"
    }

    /** 文件大小（字节），None = 未知 */
    public func sizeBytes(): Option<Int64> {
        return size
    }
}

// ─── LocalFileMediaResource ───────────────────────────────────────────────────

/**
 * LocalFileMediaResource — 本地临时/中间文件媒体资源
 *
 * 对应 iOS LocalFileMediaResource（TelegramCore/SyncCore_CloudFileMediaResource.swift）：
 *   - fileId：随机 Int64，标识本地文件
 *   - size：文件大小（None = 未知）
 *   - isSecretRelated：是否与秘密聊天加密相关
 *
 * uniqueId() 格式："telegram-local-file-<fileId>"
 * （与 iOS LocalFileMediaResourceId.uniqueId 完全对应）
 *
 * headerSize 不适用（本地文件无分块下载，iOS 层该字段不适用于 LocalFileMediaResource）
 */
public class LocalFileMediaResource {
    public var fileId: Int64
    public var size: Option<Int64>
    public var isSecretRelated: Bool

    public init(fileId: Int64, size: Option<Int64>, isSecretRelated!: Bool = false) {
        this.fileId = fileId
        this.size = size
        this.isSecretRelated = isSecretRelated
    }

    /**
     * 资源唯一 ID，用于本地缓存键派生。
     * 格式："telegram-local-file-<fileId>"
     * 对应 iOS LocalFileMediaResourceId.uniqueId
     */
    public func uniqueId(): String {
        return "telegram-local-file-${fileId}"
    }

    /** 文件大小（字节），None = 未知 */
    public func sizeBytes(): Option<Int64> {
        return size
    }
}

// ─── PhotoLibraryMediaResource ────────────────────────────────────────────────

/**
 * PhotoLibraryMediaResource — 手机相册图片资源（发送消息/媒体附件时使用）
 *
 * 对应 iOS PhotoLibraryMediaResource（LocalMediaResources/MediaResources.swift）：
 *   - localIdentifier：PHAsset.localIdentifier（HarmonyOS 端为 photoAsset.uri）
 *   - uniqueId：资源唯一 Int64（用于去重，0 = 无额外区分）
 *   - width/height：发送时目标尺寸（None = 原始尺寸）
 *   - format：编码格式（None = JPEG 默认）
 *   - quality：压缩质量 0-100（None = 使用默认值 60）
 *
 * HarmonyOS 特别说明：
 *   iOS 使用 PHImageManager.requestImage + vImage resize；
 *   HarmonyOS 端通过 photoAccessHelper.getThumbnail(size) 或
 *   ImageSource.createPixelMap(DecodingOptions(desiredSize)) 实现等效缩放。
 *   JXL 格式在 HarmonyOS 上不存在，iOS jxl 对应到 PNG（MediaImageFormat.Png）。
 *
 * uniqueResourceId() 格式："ph-<localIdentifier>[-<uniqueId>]"
 * （与 iOS PhotoLibraryMediaResourceId.uniqueId 对应）
 */
public class PhotoLibraryMediaResource {
    /** 资产本地标识符（HarmonyOS 对应 photoAsset.uri 或 localIdentifier） */
    public var localIdentifier: String
    /** 资源唯一整数 ID（用于去重/缓存区分，0 = 无额外区分） */
    public var uniqueId: Int64
    /** 发送时目标宽度（像素），None = 使用原始宽度 */
    public var width: Option<Int32>
    /** 发送时目标高度（像素），None = 使用原始高度 */
    public var height: Option<Int32>
    /** 编码格式，None = 默认 JPEG */
    public var format: Option<MediaImageFormat>
    /** 压缩质量（0-100），None = 60（默认） */
    public var quality: Option<Int32>

    public init(
        localIdentifier: String,
        uniqueId: Int64,
        width: Option<Int32>,
        height: Option<Int32>,
        format: Option<MediaImageFormat>,
        quality: Option<Int32>
    ) {
        this.localIdentifier = localIdentifier
        this.uniqueId = uniqueId
        this.width = width
        this.height = height
        this.format = format
        this.quality = quality
    }

    /**
     * 资源唯一 ID，用于本地缓存键派生。
     * 格式："ph-<localIdentifier>"（uniqueId != 0 时追加 "-<uniqueId>"）
     * 对应 iOS PhotoLibraryMediaResourceId.uniqueId
     */
    public func uniqueResourceId(): String {
        let safeId = localIdentifier.replace("/", "_")
        if (uniqueId != 0) {
            return "ph-${safeId}-${uniqueId}"
        }
        return "ph-${safeId}"
    }

    /**
     * 文件大小（字节）。
     * PhotoLibraryMediaResource 取自本地相册，大小依赖实际文件；
     * 服务层不预先知道大小，返回 None。
     */
    public func sizeBytes(): Option<Int64> {
        return None
    }
}

// ─── VideoLibraryMediaResource ────────────────────────────────────────────────

/**
 * VideoLibraryMediaResource — 相册视频资源
 *
 * 对应 iOS VideoLibraryMediaResource（LocalMediaResources/MediaResources.swift）：
 *   - localIdentifier：PHAsset.localIdentifier
 *   - conversion：视频转码模式（passthrough = 直传；compress = 重编码）
 *
 * HarmonyOS 特别说明：
 *   iOS 侧 VideoLibraryMediaResourceConversion 含 VideoMediaResourceAdjustments（滤镜/裁剪参数）。
 *   HarmonyOS 端不支持等效的复杂视频处理 SDK，仅保留 passthrough（直传）/ compress（转码）两种模式，
 *   VideoMediaResourceAdjustments 参数部分 defer（平台能力缺失）。
 *
 * uniqueId() 格式："vi-<localIdentifier_normalized>"
 * （与 iOS VideoLibraryMediaResourceId.uniqueId 对应）
 *
 * headerSize = 32 * 1024（对应 iOS VideoLibraryMediaResource.headerSize = 32 * 1024）
 */
public enum VideoLibraryConversion {
    | Passthrough   // 直传，不重编码
    | Compress      // 重编码（adjustments digest defer 到平台支持后完整实现）
}

public class VideoLibraryMediaResource {
    public var localIdentifier: String
    public var conversion: VideoLibraryConversion

    /** 分块下载头部尺寸（对应 iOS headerSize = 32 * 1024） */
    public let headerSize: Int32 = 32768

    public init(localIdentifier: String, conversion: VideoLibraryConversion) {
        this.localIdentifier = localIdentifier
        this.conversion = conversion
    }

    /**
     * 资源唯一 ID，用于本地缓存键派生。
     * 格式："vi-<localIdentifier_normalized>"
     * 对应 iOS VideoLibraryMediaResourceId.uniqueId
     */
    public func uniqueId(): String {
        let safeId = localIdentifier.replace("/", "_")
        return "vi-${safeId}"
    }

    /** 文件大小，取决于实际视频文件，返回 None */
    public func sizeBytes(): Option<Int64> {
        return None
    }
}

// ─── LocalFileVideoMediaResource ─────────────────────────────────────────────

/**
 * LocalFileVideoMediaResource — 本地视频文件资源（临时/中间文件）
 *
 * 对应 iOS LocalFileVideoMediaResource（LocalMediaResources/MediaResources.swift）：
 *   - randomId：Int64 随机 ID（唯一标识这次本地文件操作）
 *   - paths：文件路径列表（分片或单文件）
 *
 * HarmonyOS 特别说明：
 *   iOS 侧含 VideoMediaResourceAdjustments（视频滤镜/裁剪），HarmonyOS defer 该字段。
 *
 * uniqueId() 格式："lvi-<randomId>"
 * headerSize = 32 * 1024
 */
public class LocalFileVideoMediaResource {
    public var randomId: Int64
    public var paths: Array<String>

    /** 分块下载头部尺寸 */
    public let headerSize: Int32 = 32768

    public init(randomId: Int64, paths: Array<String>) {
        this.randomId = randomId
        this.paths = paths
    }

    public init(randomId: Int64, path: String) {
        this.randomId = randomId
        this.paths = [path]
    }

    /**
     * 资源唯一 ID，格式："lvi-<randomId>"
     * 对应 iOS LocalFileVideoMediaResourceId.uniqueId
     */
    public func uniqueId(): String {
        return "lvi-${randomId}"
    }

    /** 本地文件大小，返回 None（需 stat 获取）*/
    public func sizeBytes(): Option<Int64> {
        return None
    }
}

// ─── LocalFileAudioMediaResource ─────────────────────────────────────────────

/**
 * LocalFileAudioMediaResource — 本地音频文件资源（临时录音/音频附件）
 *
 * 对应 iOS LocalFileAudioMediaResource（LocalMediaResources/MediaResources.swift）：
 *   - randomId：Int64 随机 ID
 *   - path：音频文件路径
 *   - trimRange：剪辑区间 [start, end)（秒），None = 不剪辑
 *
 * uniqueId() 格式："lad-<randomId>"
 * headerSize = 32 * 1024
 */
public class LocalFileAudioMediaResource {
    public var randomId: Int64
    public var path: String
    /** 剪辑区间：[trimStart, trimEnd)（秒），None = 不剪辑 */
    public var trimStart: Option<Float64>
    public var trimEnd: Option<Float64>

    /** 分块下载头部尺寸 */
    public let headerSize: Int32 = 32768

    public init(randomId: Int64, path: String, trimStart: Option<Float64>, trimEnd: Option<Float64>) {
        this.randomId = randomId
        this.path = path
        this.trimStart = trimStart
        this.trimEnd = trimEnd
    }

    /**
     * 资源唯一 ID，格式："lad-<randomId>"
     * 对应 iOS LocalFileAudioMediaResourceId.uniqueId
     */
    public func uniqueId(): String {
        return "lad-${randomId}"
    }

    /** 本地文件大小，返回 None（需 stat 获取）*/
    public func sizeBytes(): Option<Int64> {
        return None
    }
}

// ─────────────────────────────────────────────────────────────────

/**
 * MediaResourcesService — 缓存媒体资源表示服务
 *
 * 对应 iOS submodules/MediaResources/Sources/CachedResourceRepresentations.swift
 *
 * 功能：
 * - 定义各类缓存资源表示（CachedRepresentation）的参数与属性
 * - 计算每种表示的唯一缓存键（uniqueId）— 完全对应 iOS 各类的 uniqueId 字段
 * - 提供缓存路径派生（buildCachePath）
 * - 查询缓存文件是否已存在（hasCachedFile）
 * - 委托 FileDownloadService 执行实际媒体下载（MTProto getFile/uploadGetFile）
 * - 将下载结果写入磁盘，更新内存路径缓存
 *
 * MTProto 调用说明（N/A 理由）：
 *   CachedResourceRepresentations 层本身不包含 TL 方法。
 *   网络请求由 FileDownloadService 通过 MTProto 完成，本服务仅进行路径派生与缓存管理。
 */

// ─────────────────────────────────────────────────────────────────
// 媒体尺寸
// ─────────────────────────────────────────────────────────────────

/** 媒体宽高尺寸（像素），用于缓存键计算 */
public class MediaSize {
    public var width: Int32
    public var height: Int32

    public init(width: Int32, height: Int32) {
        this.width = width
        this.height = height
    }
}

// ─────────────────────────────────────────────────────────────────
// 缩放模式（对应 iOS CachedScaledImageRepresentationMode）
// ─────────────────────────────────────────────────────────────────

/** 图片缩放/填充模式 */
public enum ScaledImageMode {
    | Fill       // rawValue = 0
    | AspectFit  // rawValue = 1
}

/** 将 ScaledImageMode 转为 Int32 原始值（对应 iOS rawValue） */
func scaledImageModeValue(mode: ScaledImageMode): Int32 {
    match (mode) {
        case ScaledImageMode.Fill => return 0
        case ScaledImageMode.AspectFit => return 1
    }
}

// ─────────────────────────────────────────────────────────────────
// Emoji 肤色修饰（对应 iOS EmojiFitzModifier）
// ─────────────────────────────────────────────────────────────────

/** Emoji Fitzpatrick 肤色修饰 */
public enum EmojiFitzModifier {
    | Type12  // rawValue = 1
    | Type3   // rawValue = 2
    | Type4   // rawValue = 3
    | Type5   // rawValue = 4
    | Type6   // rawValue = 5
}

/** 将 EmojiFitzModifier 转为 Int32 原始值（对应 iOS rawValue） */
func fitzModifierValue(fm: EmojiFitzModifier): Int32 {
    match (fm) {
        case EmojiFitzModifier.Type12 => return 1
        case EmojiFitzModifier.Type3  => return 2
        case EmojiFitzModifier.Type4  => return 3
        case EmojiFitzModifier.Type5  => return 4
        case EmojiFitzModifier.Type6  => return 5
    }
}

// ─────────────────────────────────────────────────────────────────
// 缓存保持时长（对应 iOS EngineCachedMediaRepresentationKeepDuration）
// ─────────────────────────────────────────────────────────────────

/** 缓存保持时长策略 */
public enum CachedRepresentationKeepDuration {
    /** 通用保持（长期缓存），对应 iOS .general */
    | General
    /** 短暂保持（运行时缓存，可优先清理），对应 iOS .shortLived */
    | ShortLived
}

// ─────────────────────────────────────────────────────────────────
// 缓存资源表示类（对应 iOS 各 Cached*Representation 类）
// ─────────────────────────────────────────────────────────────────

/**
 * 缓存资源表示。
 *
 * 每个实例描述"媒体原始文件的某种派生形式"的参数，
 * uniqueId() 计算唯一字符串缓存键。
 *
 * 对应 iOS 类映射：
 *   kind="sticker-ajpeg"               → CachedStickerAJpegRepresentation
 *   kind="scaled-image"                → CachedScaledImageRepresentation
 *   kind="first-frame"                 → CachedVideoFirstFrameRepresentation
 *   kind="prefix-first-frame"          → CachedVideoPrefixFirstFrameRepresentation
 *   kind="scaled-frame"                → CachedScaledVideoFirstFrameRepresentation
 *   kind="blurred-wallpaper"           → CachedBlurredWallpaperRepresentation
 *   kind="album-artwork"               → CachedAlbumArtworkRepresentation
 *   kind="emoji-thumb"                 → CachedEmojiThumbnailRepresentation
 *   kind="emoji"                       → CachedEmojiRepresentation
 *   kind="animated-sticker-first-frame"→ CachedAnimatedStickerFirstFrameRepresentation
 *   kind="animated-sticker"            → CachedAnimatedStickerRepresentation
 *   kind="video-sticker"               → CachedVideoStickerRepresentation
 *   kind="prepared-pattern-wallpaper"  → CachedPreparedPatternWallpaperRepresentation
 *   kind="prepared-svg"                → CachedPreparedSvgRepresentation
 */
public class CachedRepresentation {
    // 表示类型标签
    private var _kind: String = ""
    // 可选宽度（px），0 = 未设置
    private var _width: Int32 = 0
    // 可选高度（px），0 = 未设置
    private var _height: Int32 = 0
    // 缩放模式原始值（0=Fill, 1=AspectFit）
    private var _scaleMode: Int32 = 0
    // 布尔参数（outline 等）
    private var _boolParam: Bool = false
    // 整型参数（tile 值 / prefixLength 等）
    private var _intParam: Int32 = 0
    // Fitzpatrick 修饰原始值（-1 = 无修饰）
    private var _fitzModifier: Int32 = -1
    // 版本号（用于贴纸/视频贴纸缓存键）
    private var _version: Int32 = 1

    private init() {}

    // ── 工厂方法 ──────────────────────────────────────────────────

    /**
     * 贴纸 AJPEG 表示（可选尺寸）。
     * 对应 iOS CachedStickerAJpegRepresentation(size: CGSize?)。
     * keepDuration = .general
     */
    public static func stickerAJpeg(size: Option<MediaSize>): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "sticker-ajpeg"
        match (size) {
            case Some(s) =>
                r._width = s.width
                r._height = s.height
            case None => ()
        }
        return r
    }

    /**
     * 缩放图片表示。
     * 对应 iOS CachedScaledImageRepresentation(size: CGSize, mode: CachedScaledImageRepresentationMode)。
     * keepDuration = .general
     */
    public static func scaledImage(size: MediaSize, mode: ScaledImageMode): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "scaled-image"
        r._width = size.width
        r._height = size.height
        r._scaleMode = scaledImageModeValue(mode)
        return r
    }

    /**
     * 视频首帧表示。
     * 对应 iOS CachedVideoFirstFrameRepresentation()。
     * keepDuration = .general
     */
    public static func videoFirstFrame(): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "first-frame"
        return r
    }

    /**
     * 视频前缀首帧表示。
     * 对应 iOS CachedVideoPrefixFirstFrameRepresentation(prefixLength: Int32)。
     * keepDuration = .general
     */
    public static func videoPrefixFirstFrame(prefixLength: Int32): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "prefix-first-frame"
        r._intParam = prefixLength
        return r
    }

    /**
     * 缩放视频首帧表示。
     * 对应 iOS CachedScaledVideoFirstFrameRepresentation(size: CGSize)。
     * keepDuration = .general
     */
    public static func scaledVideoFirstFrame(size: MediaSize): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "scaled-frame"
        r._width = size.width
        r._height = size.height
        return r
    }

    /**
     * 模糊壁纸表示。
     * 对应 iOS CachedBlurredWallpaperRepresentation()。
     * keepDuration = .general
     */
    public static func blurredWallpaper(): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "blurred-wallpaper"
        return r
    }

    /**
     * 专辑封面表示（可选尺寸）。
     * 对应 iOS CachedAlbumArtworkRepresentation(size: CGSize)。
     * keepDuration = .general
     */
    public static func albumArtwork(size: Option<MediaSize>): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "album-artwork"
        match (size) {
            case Some(s) =>
                r._width = s.width
                r._height = s.height
            case None => ()
        }
        return r
    }

    /**
     * Emoji 缩略图表示。
     * 对应 iOS CachedEmojiThumbnailRepresentation(outline: Bool)。
     * keepDuration = .general
     */
    public static func emojiThumbnail(outline: Bool): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "emoji-thumb"
        r._boolParam = outline
        return r
    }

    /**
     * Emoji 完整表示。
     * 对应 iOS CachedEmojiRepresentation(tile: UInt8, outline: Bool)。
     * keepDuration = .general
     */
    public static func emoji(tile: Int32, outline: Bool): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "emoji"
        r._intParam = tile
        r._boolParam = outline
        return r
    }

    /**
     * 动画贴纸首帧表示（版本 v1）。
     * 对应 iOS CachedAnimatedStickerFirstFrameRepresentation(width:height:fitzModifier?)
     * keepDuration = .general
     */
    public static func animatedStickerFirstFrame(
        width: Int32,
        height: Int32,
        fitzModifier: Option<EmojiFitzModifier>
    ): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "animated-sticker-first-frame"
        r._width = width
        r._height = height
        r._version = 1
        match (fitzModifier) {
            case Some(fm) => r._fitzModifier = fitzModifierValue(fm)
            case None => r._fitzModifier = -1
        }
        return r
    }

    /**
     * 动画贴纸完整表示（版本 v8）。
     * 对应 iOS CachedAnimatedStickerRepresentation(width:height:fitzModifier?)
     * keepDuration = .shortLived
     */
    public static func animatedSticker(
        width: Int32,
        height: Int32,
        fitzModifier: Option<EmojiFitzModifier>
    ): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "animated-sticker"
        r._width = width
        r._height = height
        r._version = 8
        match (fitzModifier) {
            case Some(fm) => r._fitzModifier = fitzModifierValue(fm)
            case None => r._fitzModifier = -1
        }
        return r
    }

    /**
     * 视频贴纸表示（版本 v3）。
     * 对应 iOS CachedVideoStickerRepresentation(width: Int32, height: Int32)
     * keepDuration = .shortLived
     */
    public static func videoSticker(width: Int32, height: Int32): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "video-sticker"
        r._width = width
        r._height = height
        r._version = 3
        return r
    }

    /**
     * Pattern 壁纸预处理表示。
     * 对应 iOS CachedPreparedPatternWallpaperRepresentation()
     * keepDuration = .general
     */
    public static func patternWallpaper(): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "prepared-pattern-wallpaper"
        return r
    }

    /**
     * 预处理 SVG 表示。
     * 对应 iOS CachedPreparedSvgRepresentation()
     * keepDuration = .general
     */
    public static func preparedSvg(): CachedRepresentation {
        let r = CachedRepresentation()
        r._kind = "prepared-svg"
        return r
    }

    // ── uniqueId（缓存键）计算 ────────────────────────────────────

    /**
     * 返回该缓存表示的唯一字符串键。
     *
     * 逻辑完全对应 iOS 各 Cached*Representation.uniqueId 属性。
     * 此键用于磁盘路径派生：<cacheDir>/<mediaId>/<uniqueId()>
     */
    public func uniqueId(): String {
        if (_kind == "sticker-ajpeg") {
            if (_width > 0 && _height > 0) {
                return "sticker-ajpeg-${_width}x${_height}"
            }
            return "sticker-ajpeg"
        }
        if (_kind == "scaled-image") {
            return "scaled-image-${_width}x${_height}-${_scaleMode}"
        }
        if (_kind == "first-frame") {
            return "first-frame"
        }
        if (_kind == "prefix-first-frame") {
            return "prefix-first-frame"
        }
        if (_kind == "scaled-frame") {
            return "scaled-frame-${_width}x${_height}"
        }
        if (_kind == "blurred-wallpaper") {
            return "blurred-wallpaper"
        }
        if (_kind == "album-artwork") {
            if (_width > 0 && _height > 0) {
                return "album-artwork-${_width}x${_height}"
            }
            return "album-artwork"
        }
        if (_kind == "emoji-thumb") {
            let flag: Int32 = if (_boolParam) { 1 } else { 0 }
            return "emoji-thumb-${flag}"
        }
        if (_kind == "emoji") {
            let flag: Int32 = if (_boolParam) { 1 } else { 0 }
            return "emoji-${_intParam}-${flag}"
        }
        if (_kind == "animated-sticker-first-frame") {
            if (_fitzModifier >= 0) {
                return "animated-sticker-first-frame-${_width}x${_height}-fitz${_fitzModifier}-v${_version}"
            }
            return "animated-sticker-first-frame-${_width}x${_height}-v${_version}"
        }
        if (_kind == "animated-sticker") {
            if (_fitzModifier >= 0) {
                return "animated-sticker-${_width}x${_height}-fitz${_fitzModifier}-v${_version}"
            }
            return "animated-sticker-${_width}x${_height}-v${_version}"
        }
        if (_kind == "video-sticker") {
            return "video-sticker-${_width}x${_height}-v${_version}"
        }
        if (_kind == "prepared-pattern-wallpaper") {
            return "prepared-pattern-wallpaper"
        }
        if (_kind == "prepared-svg") {
            return "prepared-svg"
        }
        return "unknown"
    }

    /**
     * 返回该表示的缓存保持时长策略。
     *
     * ShortLived 对应 iOS .shortLived：动画贴纸、视频贴纸（运行时缓存，优先清理）。
     * General 对应 iOS .general：其余所有表示。
     */
    public func keepDuration(): CachedRepresentationKeepDuration {
        if (_kind == "animated-sticker" || _kind == "video-sticker") {
            return CachedRepresentationKeepDuration.ShortLived
        }
        return CachedRepresentationKeepDuration.General
    }

    /** 返回表示类型标签（调试/日志用） */
    public func kind(): String {
        return _kind
    }
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _mediaResourcesServiceInstance: Option<MediaResourcesService> = None

/** 获取 MediaResourcesService 单例 */
public func getMediaResourcesService(): MediaResourcesService {
    match (_mediaResourcesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MediaResourcesService()
            _mediaResourcesServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// MediaResourcesService
// ─────────────────────────────────────────────────────────────────

/**
 * MediaResourcesService — 缓存媒体资源服务核心
 *
 * 职责：
 * 1. 维护各媒体 ID 到其缓存表示的磁盘路径映射（内存缓存）
 * 2. 计算缓存文件路径（基于 mediaId + uniqueId）
 * 3. 检查缓存文件是否已在磁盘存在
 * 4. 委托 FileDownloadService 执行网络下载
 * 5. 将下载结果写入磁盘，更新内存缓存
 *
 * 调用链：
 *   MediaResourcesService.downloadRepresentation()
 *     → FileDownloadService.downloadDocument()     (MTProto 分块下载)
 *       → MTProtoClient.sendRequest(UploadGetFile)  (实际 TL 调用)
 *
 * MTProto 说明（N/A 理由）：
 *   CachedResourceRepresentations 层自身不含 TL 方法；
 *   TL 通信由 FileDownloadService 完成，本服务作为"缓存描述 + 路径派生"层。
 */
public class MediaResourcesService {
    // 缓存根目录路径
    private var _cacheDir: String = ""
    // 内存路径缓存：key = "<mediaId>/<uniqueId>"，value = 磁盘绝对路径
    private var _pathCache: HashMap<String, String> = HashMap<String, String>()

    public init() {
        _cacheDir = getAppFilesDir() + "/media_representations"
        ensureDirAt(_cacheDir)
    }

    // ── 路径派生 ──────────────────────────────────────────────────

    /**
     * 计算指定媒体资源派生表示的磁盘缓存路径。
     *
     * 路径格式：<cacheDir>/<mediaId>/<repr.uniqueId()>
     *
     * 对应 iOS TelegramEngine.Resources.cachedMediaResourceRepresentation 路径策略：
     * MediaBox 以 resourceId + representationId 构建本地路径，本方法完整实现该逻辑。
     *
     * @param mediaId  媒体文件 ID（TL file_id）
     * @param repr     缓存资源表示
     * @return 完整磁盘文件路径
     */
    public func buildCachePath(mediaId: Int64, repr: CachedRepresentation): String {
        return _cacheDir + "/" + mediaId.toString() + "/" + repr.uniqueId()
    }

    // ── 缓存命中检查 ──────────────────────────────────────────────

    /**
     * 查询指定派生表示的本地缓存路径。
     *
     * 先查内存缓存，命中则直接返回；否则检查磁盘文件是否存在。
     *
     * @param mediaId  媒体文件 ID
     * @param repr     缓存资源表示
     * @return 已缓存文件的本地路径；若不存在则返回空字符串
     */
    public func getCachedPath(mediaId: Int64, repr: CachedRepresentation): String {
        let cacheKey = mediaId.toString() + "/" + repr.uniqueId()
        if (_pathCache.contains(cacheKey)) {
            let cached = _pathCache[cacheKey]
            if (cached.size > 0) {
                return cached
            }
        }
        let diskPath = buildCachePath(mediaId, repr)
        var exists = false
        try {
            exists = FileIo.access(diskPath)
        } catch (_: Exception) {
            exists = false
        }
        if (exists) {
            _pathCache[cacheKey] = diskPath
            return diskPath
        }
        return ""
    }

    /**
     * 判断指定派生表示是否有本地缓存文件。
     *
     * @param mediaId  媒体文件 ID
     * @param repr     缓存资源表示
     * @return true = 本地已有缓存；false = 需要下载
     */
    public func hasCachedFile(mediaId: Int64, repr: CachedRepresentation): Bool {
        return getCachedPath(mediaId, repr).size > 0
    }

    // ── 下载与存储 ─────────────────────────────────────────────────

    /**
     * 下载指定媒体资源的派生表示并写入磁盘缓存。
     *
     * 若本地已有缓存，直接返回已有路径，不重复下载。
     *
     * 调用链（完整）：
     *   downloadRepresentation()
     *     → FileDownloadService.downloadDocument()   (services 包)
     *       → MTProtoClient.sendRequest(UploadGetFile)
     *
     * @param mediaId       媒体文件 ID
     * @param accessHash    访问 hash
     * @param fileReference 文件引用（用于 MTProto getFile）
     * @param dcId          数据中心 ID
     * @param fileSize      文件大小（字节），0 表示未知
     * @param repr          目标派生表示
     * @return 下载后的本地文件路径；下载失败则返回空字符串
     */
    public func downloadRepresentation(
        mediaId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        dcId: Int32,
        fileSize: Int64,
        repr: CachedRepresentation
    ): String {
        let cached = getCachedPath(mediaId, repr)
        if (cached.size > 0) {
            Hilog.info(0, "CjTelegram", "[MediaResources] Cache hit: id=${mediaId} repr=${repr.uniqueId()}")
            return cached
        }

        Hilog.info(0, "CjTelegram", "[MediaResources] Downloading: id=${mediaId} repr=${repr.uniqueId()}")

        let downloadSvc = getFileDownloadService()
        let data = downloadSvc.downloadDocument(
            mediaId,
            accessHash,
            fileReference,
            dcId,
            fileSize: fileSize
        )

        if (data.size == 0) {
            Hilog.info(0, "CjTelegram", "[MediaResources] Empty download: id=${mediaId}")
            return ""
        }

        let targetPath = buildCachePath(mediaId, repr)
        let parentDir = _cacheDir + "/" + mediaId.toString()
        ensureDirAt(parentDir)

        let saved = writeBytes(data, targetPath)
        if (saved) {
            let cacheKey = mediaId.toString() + "/" + repr.uniqueId()
            _pathCache[cacheKey] = targetPath
            // 持久化缓存元数据索引（供缓存 GC + 存储用量统计；接 P2-293 MediaResourceIndexTable）。
            // resourceId = cacheKey（mediaId/uniqueId 稳定串，与内存路径缓存键同口径）；
            // size = 落盘字节数；complete = true（完整下载落盘）；keepDuration 由 repr 映射。
            recordCacheIndex(cacheKey, targetPath, Int64(data.size), repr.keepDuration())
            Hilog.info(0, "CjTelegram", "[MediaResources] Saved: ${targetPath}")
            return targetPath
        }
        Hilog.info(0, "CjTelegram", "[MediaResources] Write failed: ${targetPath}")
        return ""
    }

    /**
     * 把一条缓存落盘记录写入持久化元数据索引（MediaResourceIndexTable, P2-293）。
     *
     * 接线点：downloadRepresentation 缓存写盘成功后调用。DB 不可用 / 索引表未就绪时
     * try/catch 吞掉异常并记日志 —— 索引仅为 GC/统计辅助，绝不能拖垮主下载路径。
     *
     * @param resourceId   稳定缓存键（"<mediaId>/<uniqueId>"）。
     * @param localPath    缓存文件磁盘路径。
     * @param size         落盘字节数。
     * @param keep         该表示的缓存保持时长策略（映射成索引表的 Int32 原始值）。
     */
    private func recordCacheIndex(
        resourceId: String,
        localPath: String,
        size: Int64,
        keep: CachedRepresentationKeepDuration
    ): Unit {
        try {
            let keepValue: Int32 = match (keep) {
                case CachedRepresentationKeepDuration.ShortLived =>
                    MediaResourceCacheEntry.KEEP_SHORT_LIVED
                case CachedRepresentationKeepDuration.General =>
                    MediaResourceCacheEntry.KEEP_GENERAL
            }
            let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
            let entry = MediaResourceCacheEntry(
                resourceId: resourceId,
                localPath: localPath,
                size: size,
                timestamp: now,
                complete: true,
                keepDuration: keepValue
            )
            MediaResourceIndexTable().recordCached(entry)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram",
                "[MediaResources] Cache index record skipped (db unavailable): ${resourceId}")
        }
    }

    // ── 缓存清理 ───────────────────────────────────────────────────

    /**
     * 清理指定媒体 ID 的内存缓存条目（不删除磁盘文件）。
     *
     * 适用于媒体更新后强制重查场景。
     *
     * @param mediaId 媒体文件 ID
     */
    public func invalidateMemoryCache(mediaId: Int64): Unit {
        let prefix = mediaId.toString() + "/"
        let toRemove = ArrayList<String>()
        for ((k, _) in _pathCache) {
            if (k.startsWith(prefix)) {
                toRemove.add(k)
            }
        }
        let newCache = HashMap<String, String>()
        for ((k, v) in _pathCache) {
            if (!k.startsWith(prefix)) {
                newCache[k] = v
            }
        }
        _pathCache = newCache
        Hilog.info(0, "CjTelegram", "[MediaResources] Invalidated in-memory cache for id=${mediaId} (${toRemove.size} entries)")
    }

    /**
     * 清空全部内存路径缓存（不删除磁盘文件）。
     *
     * 对应 iOS MediaBox clearCaches() 触发 ShortLived 清理时的内存缓存重置。
     */
    public func clearAllMemoryCache(): Unit {
        _pathCache = HashMap<String, String>()
        Hilog.info(0, "CjTelegram", "[MediaResources] All in-memory cache cleared")
    }

    // ── 相册封面预取（Gap 7: fetchAlbumCover）─────────────────────────────────

    /**
     * 获取专辑封面（对应 iOS TelegramEngine.Resources.fetchAlbumCover(file:title:performer:isThumbnail:)）
     *
     * iOS fetchAlbumCover 从 Telegram 服务端获取音乐文件关联的专辑封面图片。
     * Cangjie 实现：通过现有 FileDownloadService.downloadDocument() 下载封面媒体文件，
     * 然后以 CachedRepresentation.albumArtwork() 派生表示路径存入 _pathCache。
     *
     * Signal-async 取舍说明：
     *   iOS 返回 Signal<EngineMediaResource.Fetch.Result>（通过 bufferedFetch 缓冲）。
     *   Cangjie 无 Signal，改用同步执行 + onComplete 回调；调用方如需异步，
     *   在 spawn{} 中调用，完成后 spawn(UIThread) 更新 @State（S-001）。
     *
     * @param mediaId        音乐媒体文件 ID（TL file_id，对应 AlbumCoverResource 的 file）
     * @param accessHash     访问 hash
     * @param fileReference  文件引用
     * @param dcId           数据中心 ID
     * @param fileSize       文件大小（字节，0 = 未知）
     * @param isThumbnail    是否为缩略图版本（true → 缩略图尺寸，false → 完整封面）
     * @param onComplete     完成回调 (localPath: String)；空字符串 = 失败
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
        let reprSize: Option<MediaSize> = if (isThumbnail) {
            Some(MediaSize(96, 96))
        } else {
            Some(MediaSize(512, 512))
        }
        let repr = CachedRepresentation.albumArtwork(reprSize)

        let cached = getCachedPath(mediaId, repr)
        if (cached.size > 0) {
            Hilog.info(0, "CjTelegram", "[MediaResources] fetchAlbumCover cache hit: id=${mediaId}")
            onComplete(cached)
            return
        }

        let svc = this
        let capturedMediaId = mediaId
        let capturedAccessHash = accessHash
        let capturedFileRef = fileReference
        let capturedDcId = dcId
        let capturedFileSize = fileSize
        let capturedRepr = repr
        let capturedOnComplete = onComplete
        let _ = spawn {
            =>
            let localPath = svc.downloadRepresentation(
                capturedMediaId,
                capturedAccessHash,
                capturedFileRef,
                capturedDcId,
                capturedFileSize,
                capturedRepr
            )
            capturedOnComplete(localPath)
        }
    }

    // ── 私有辅助 ───────────────────────────────────────────────────

    /**
     * 确保目录存在；不存在时尝试创建（单层，参见 S-#58 FileIo.mkdir）。
     */
    private func ensureDirAt(dir: String): Unit {
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
                Hilog.info(0, "CjTelegram", "[MediaResources] mkdir failed: ${dir}")
            }
        }
    }

    /**
     * 将字节数组写入磁盘路径（覆盖写，O_CREAT|O_WRONLY|O_TRUNC = 0o1101）。
     *
     * 使用 FileIo.open/write/close 模式，与 main_ability.cj 保持一致。
     *
     * @return true = 写入成功；false = 失败
     */
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
}
