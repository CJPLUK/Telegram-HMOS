package ohos_app_cangjie_entry.services

import kit.CoreFileKit.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * ICloudResourcesService — iCloud 文件资源服务（HarmonyOS 本地文件管理等效实现）
 *
 * iOS 对应：ICloudResources.swift（submodules/ICloudResources/Sources/ICloudResources.swift）
 *
 * 平台缺口声明：
 *   - iOS 使用 iCloud Drive（ubiquitous item）通过 NSMetadataQuery 和 NSFileCoordinator
 *     实现云端文件描述和下载。HarmonyOS 无 iCloud 等效平台云存储 API（Drive Kit 未在
 *     本工程中配置），因此本实现使用本地文件系统（CoreFileKit）作为等效实现。
 *   - iOS 的 `AVFoundation` 音频元数据提取（标题、艺术家、专辑图）在 HarmonyOS 上
 *     无直接等效 API，音频元数据字段在 HarmonyOS 上始终为空（hasAudioArtwork=false），
 *     此为已知平台能力缺口。
 *   - iOS 的 `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`
 *     沙盒授权机制在 HarmonyOS 无对应概念，本实现直接访问文件路径。
 *   - 云端同步状态（ubiquitousItemDownloadingStatus）在 HarmonyOS 上无对应，
 *     本实现视所有文件为 Local（本地可用）状态。
 *
 * 功能：
 *   - 从本地文件路径构建 ICloudFileDescription（文件名、大小、音频元数据占位）
 *   - 从 base64 编码的文件路径（书签数据等效）解析本地路径
 *   - 读取本地文件字节数据（对应 iOS fetchICloudFileResource）
 *   - 生成缩略图路径（图片类型）或返回空（视频/PDF/音频）
 *
 * MTProto 说明（N/A）：
 *   iCloud 文件资源读取不涉及 MTProto 协议，无需 MTProtoClient。
 *
 * 调用链（完整）：
 *   ICloudResourcesViewModel.loadFileDescription(localPath)
 *     → ICloudResourcesService.describeLocalFile(localPath)
 *       → FileIo.stat(localPath) → size
 *       → 路径解析 → fileName
 *       → ICloudFileDescription（音频元数据为 None）
 *
 *   ICloudResourcesViewModel.fetchFileData(urlData)
 *     → ICloudResourcesService.fetchFileData(urlData)
 *       → decodeUrlData(urlData) → localPath
 *         → FileIo.open(localPath) → read → Array<Byte>
 */

// ─────────────────────────────────────────────────────────────────
// 音频元数据（对应 iOS ICloudFileDescription.AudioMetadata）
// ─────────────────────────────────────────────────────────────────

/**
 * 音频元数据描述
 *
 * 对应 iOS ICloudFileDescription.AudioMetadata
 * HarmonyOS 平台限制：title/performer 始终为空，hasAudioArtwork 始终为 false
 */
public class ICloudAudioMetadata {
    /** 曲目标题（HarmonyOS 平台限制：始终为空字符串）*/
    public var title: String = ""
    /** 艺术家（HarmonyOS 平台限制：始终为空字符串）*/
    public var performer: String = ""
    /** 时长（秒），0 表示未知 */
    public var duration: Int32 = 0
    /** 是否有专辑封面（HarmonyOS 平台限制：始终为 false）*/
    public var hasAudioArtwork: Bool = false

    public init(durationSecs: Int32) {
        this.duration = durationSecs
    }
}

// ─────────────────────────────────────────────────────────────────
// 文件描述（对应 iOS ICloudFileDescription）
// ─────────────────────────────────────────────────────────────────

/**
 * iCloud 文件描述
 *
 * 对应 iOS ICloudFileDescription（struct）
 * urlData: base64 编码的本地文件路径（对应 iOS bookmark data base64）
 */
public class ICloudFileDescription {
    /** base64 编码的本地文件路径（对应 iOS bookmark data base64）*/
    public var urlData: String = ""
    /** 文件名（含后缀）*/
    public var fileName: String = ""
    /** 文件大小（字节）*/
    public var fileSize: Int64 = 0
    /** 音频元数据（非音频文件为 None）*/
    public var audioMetadata: Option<ICloudAudioMetadata> = None

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 文件资源标识（对应 iOS ICloudFileResourceId）
// ─────────────────────────────────────────────────────────────────

/**
 * iCloud 文件资源标识
 *
 * 对应 iOS ICloudFileResourceId（struct）
 * 在 HarmonyOS 上以本地文件路径的 base64 编码作为 urlData
 */
public class ICloudFileResourceId {
    /** base64 编码的文件路径（对应 iOS bookmark data base64）*/
    public var urlData: String = ""
    /** 是否为缩略图 */
    public var thumbnail: Bool = false

    public init(urlData: String, thumbnail: Bool) {
        this.urlData = urlData
        this.thumbnail = thumbnail
    }

    /**
     * 唯一标识符（对应 iOS ICloudFileResourceId.uniqueId）
     *
     * iOS 使用 enginePersistentHash32；HarmonyOS 用简单哈希替代。
     */
    public func uniqueId(): String {
        let hash = simpleStringHash(this.urlData)
        if (this.thumbnail) {
            return "icloud-thumb-" + hash.toString()
        } else {
            return "icloud-" + hash.toString()
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// 已知音频扩展名集合
// ─────────────────────────────────────────────────────────────────

private let audioExtensions: Array<String> = ["mp3", "m4a", "aac", "flac"]

/** 检查文件扩展名是否为音频类型 */
private func isAudioExtension(ext: String): Bool {
    for (audioExt in audioExtensions) {
        if (ext == audioExt) {
            return true
        }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────
// 辅助函数
// ─────────────────────────────────────────────────────────────────

/**
 * 简单字符串哈希（对应 iOS enginePersistentHash32 的等效替代）
 *
 * 采用 djb2 变体哈希，保证相同输入输出相同结果。
 */
private func simpleStringHash(s: String): Int64 {
    var hash: Int64 = 5381
    for (r in s.toRuneArray()) {
        let code = Int64(UInt32(r))
        hash = ((hash * 33) ^ code) & 0x7FFFFFFFFFFFFFFF
    }
    return hash
}

/**
 * 将本地文件路径编码为 base64（对应 iOS URL.bookmarkData base64）
 *
 * HarmonyOS 无 URL bookmark；直接将路径的 UTF-8 字节进行 base64 编码作为等效标识。
 *
 * P2-357 修复：原实现用 toRuneArray()（Unicode 码点）当作字节处理，
 * 对非 ASCII 路径（如中文文件名）会产生错误的 base64。
 * 修复为先将每个 Rune 转为 UTF-8 字节序列，再对字节做 base64。
 */
public func encodeLocalPathToUrlData(path: String): String {
    let base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    let charArr = base64Chars.toRuneArray()

    let runes = path.toRuneArray()
    var byteList: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    var totalBytes: Int64 = 0
    for (r in runes) {
        let cap = Array<UInt8>(4, { _ => 0u8 })
        let len = Int64(Rune.intoUtf8Array(r, cap, 0))
        totalBytes += len
    }
    let bytes = Array<UInt8>(totalBytes, repeat: 0)
    var offset: Int64 = 0
    for (r in runes) {
        let cap = Array<UInt8>(4, { _ => 0u8 })
        let len = Int64(Rune.intoUtf8Array(r, cap, 0))
        var k: Int64 = 0
        while (k < len) {
            bytes[offset] = cap[k]
            offset += 1
            k += 1
        }
    }

    var result = ""
    var i: Int64 = 0
    while (i < bytes.size) {
        let b0 = Int64(bytes[i])
        var b1: Int64 = 0
        var b2: Int64 = 0
        var tripletLen = 1
        if (i + 1 < bytes.size) {
            b1 = Int64(bytes[i + 1])
            tripletLen = 2
        }
        if (i + 2 < bytes.size) {
            b2 = Int64(bytes[i + 2])
            tripletLen = 3
        }
        let idx0 = (b0 >> 2) & 0x3F
        let idx1 = ((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0F)
        let idx2 = ((b1 & 0x0F) << 2) | ((b2 >> 6) & 0x03)
        let idx3 = b2 & 0x3F
        result = result + charArr[idx0].toString()
        result = result + charArr[idx1].toString()
        if (tripletLen >= 2) {
            result = result + charArr[idx2].toString()
        } else {
            result = result + "="
        }
        if (tripletLen == 3) {
            result = result + charArr[idx3].toString()
        } else {
            result = result + "="
        }
        i += 3
    }
    return result
}

/**
 * 从 base64 编码的 urlData 解码出本地文件路径
 *
 * 对应 iOS Data(base64Encoded:) + URL(resolvingBookmarkData:)
 *
 * P2-357 修复：原实现将每个解码字节用 Rune(UInt32(byte)) 转为单字符，
 * 这对多字节 UTF-8 序列（如中文路径）会解析为垃圾字符。
 * 修复为先收集所有解码字节，再整体用 String.fromUtf8() 解析。
 */
public func decodeUrlDataToLocalPath(urlData: String): String {
    if (urlData.size == 0) {
        return ""
    }
    let base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    let charArr = base64Chars.toRuneArray()
    let input = urlData.toRuneArray()

    let maxBytes: Int64 = (Int64(input.size) / 4) * 3 + 4
    let outBuf = Array<UInt8>(maxBytes, repeat: 0)
    var outLen: Int64 = 0

    var i: Int64 = 0
    while (i + 3 < input.size) {
        let c0 = input[i]
        let c1 = input[i + 1]
        let c2 = input[i + 2]
        let c3 = input[i + 3]
        var v0: Int64 = -1
        var v1: Int64 = -1
        var v2: Int64 = -1
        var v3: Int64 = -1
        var j: Int64 = 0
        while (j < charArr.size) {
            if (charArr[j] == c0) { v0 = j }
            if (charArr[j] == c1) { v1 = j }
            if (charArr[j] == c2) { v2 = j }
            if (charArr[j] == c3) { v3 = j }
            j += 1
        }
        if (v0 < 0 || v1 < 0) {
            i += 4
            continue
        }
        let byte0 = UInt8((Int64((v0 << 2) | (v1 >> 4)) & 0xFF))
        outBuf[outLen] = byte0
        outLen += 1
        if (v2 >= 0) {
            let byte1 = UInt8(Int64(((v1 & 0x0F) << 4) | (v2 >> 2)) & 0xFF)
            outBuf[outLen] = byte1
            outLen += 1
        }
        if (v2 >= 0 && v3 >= 0) {
            let byte2 = UInt8(Int64(((v2 & 0x03) << 6) | v3) & 0xFF)
            outBuf[outLen] = byte2
            outLen += 1
        }
        i += 4
    }

    let utf8Bytes = outBuf[0..outLen]
    return String.fromUtf8(utf8Bytes)
}

/**
 * 从文件路径提取文件名（含后缀）
 *
 * 对应 iOS url.lastPathComponent.removingPercentEncoding
 */
private func extractFileName(path: String): String {
    let runes = path.toRuneArray()
    var lastSlash: Int64 = -1
    var i: Int64 = 0
    while (i < runes.size) {
        if (runes[i] == r'/') {
            lastSlash = i
        }
        i += 1
    }
    if (lastSlash < 0 || lastSlash + 1 >= runes.size) {
        return path
    }
    return path[(lastSlash + 1)..]
}

/**
 * 从文件名提取小写扩展名（不含点）
 *
 * 对应 iOS url.pathExtension.lowercased()
 */
private func extractExtension(fileName: String): String {
    let runes = fileName.toRuneArray()
    var lastDot: Int64 = -1
    var i: Int64 = 0
    while (i < runes.size) {
        if (runes[i] == r'.') {
            lastDot = i
        }
        i += 1
    }
    if (lastDot < 0 || lastDot + 1 >= runes.size) {
        return ""
    }
    return fileName[(lastDot + 1)..].toAsciiLower()
}

// ─────────────────────────────────────────────────────────────────
// 单例访问
// ─────────────────────────────────────────────────────────────────

private var _iCloudResourcesServiceInstance: Option<ICloudResourcesService> = None

/** 获取 ICloudResourcesService 单例 */
public func getICloudResourcesService(): ICloudResourcesService {
    match (_iCloudResourcesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ICloudResourcesService()
            _iCloudResourcesServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// ICloudResourcesService
// ─────────────────────────────────────────────────────────────────

/**
 * ICloudResourcesService — iCloud 文件资源服务
 *
 * iOS 对应：ICloudResources.swift 中的以下函数：
 *   - descriptionWithUrl(_:)     → describeLocalFile(localPath)
 *   - iCloudFileDescription(_:)  → getFileDescription(urlData)
 *   - fetchICloudFileResource(resource:) → fetchFileData(urlData) / fetchThumbnailData(urlData)
 *
 * 平台说明：
 *   iOS 使用 NSMetadataQuery 检测 iCloud 同步状态并等待下载，
 *   HarmonyOS 此处视所有本地文件为已就绪状态，直接同步读取。
 */
public class ICloudResourcesService {

    public init() {}

    // ── 文件描述 ─────────────────────────────────────────────────────────────

    /**
     * 从本地文件路径构建文件描述
     *
     * 对应 iOS descriptionWithUrl(_:)：
     *   - url.startAccessingSecurityScopedResource → HarmonyOS 无此概念
     *   - url.bookmarkData → encodeLocalPathToUrlData(path)（base64 等效）
     *   - url.resourceValues(forKeys:[.fileSizeKey]) → FileIo.stat(path).size
     *   - AVURLAsset 音频元数据 → HarmonyOS 平台缺口：音频元数据始终为空
     *
     * @param localPath 本地文件的绝对路径
     * @return 文件描述；路径无效或文件不存在时返回 None
     */
    public func describeLocalFile(localPath: String): Option<ICloudFileDescription> {
        if (localPath.size == 0) {
            return None
        }
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(localPath)
            fileSize = stat.size
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ICloudResources] describeLocalFile: stat failed path=${localPath}")
            return None
        }
        if (fileSize <= 0) {
            Hilog.info(0, "CjTelegram", "[ICloudResources] describeLocalFile: file empty or missing")
            return None
        }
        let fileName = extractFileName(localPath)
        let urlData = encodeLocalPathToUrlData(localPath)
        let desc = ICloudFileDescription()
        desc.urlData = urlData
        desc.fileName = fileName
        desc.fileSize = fileSize
        let ext = extractExtension(fileName)
        if (isAudioExtension(ext)) {
            let audioMeta = ICloudAudioMetadata(0)
            desc.audioMetadata = Some(audioMeta)
        }
        Hilog.info(0, "CjTelegram", "[ICloudResources] describeLocalFile: fileName=${fileName} size=${fileSize}")
        return Some(desc)
    }

    /**
     * 通过 urlData（base64 路径）获取文件描述
     *
     * 对应 iOS iCloudFileDescription(_:url:URL) Signal 函数的同步等效版本：
     *   - Data(base64Encoded: resource.urlData) → decodeUrlDataToLocalPath(urlData)
     *   - url.resourceValues(ubiquitousItemDownloadingStatus) → HarmonyOS 无云同步状态，直接读取
     *
     * @param urlData base64 编码的本地路径
     * @return 文件描述；解码或读取失败时返回 None
     */
    public func getFileDescription(urlData: String): Option<ICloudFileDescription> {
        let localPath = decodeUrlDataToLocalPath(urlData)
        if (localPath.size == 0) {
            Hilog.info(0, "CjTelegram", "[ICloudResources] getFileDescription: decode failed")
            return None
        }
        return describeLocalFile(localPath)
    }

    // ── 文件数据读取 ─────────────────────────────────────────────────────────

    /**
     * 读取文件原始字节数据
     *
     * 对应 iOS fetchICloudFileResource(resource:) 非缩略图分支：
     *   - ICloudFileResourceCopyItem.copyTo(url:) — 复制文件到临时目录
     *   HarmonyOS 等效：直接读取文件内容字节
     *
     * @param urlData base64 编码的本地路径
     * @return 文件字节数组；读取失败返回空数组
     */
    public func fetchFileData(urlData: String): Array<Byte> {
        let localPath = decodeUrlDataToLocalPath(urlData)
        if (localPath.size == 0) {
            Hilog.info(0, "CjTelegram", "[ICloudResources] fetchFileData: decode failed")
            return Array<Byte>(0, repeat: 0)
        }
        return readLocalFile(localPath)
    }

    /**
     * 读取文件缩略图字节数据（图片类型）
     *
     * 对应 iOS fetchICloudFileResource(resource:) thumbnail=true 分支：
     *   - 图片文件：读取完整文件作为缩略图（HarmonyOS 降级：不做 256x256 缩放，直接返回原图数据）
     *   - 音频文件：HarmonyOS 平台缺口（AVFoundation 无等效），返回空数组
     *   - PDF 文件：HarmonyOS 平台缺口（generatePdfPreviewImage 无等效），返回空数组
     *
     * @param urlData base64 编码的本地路径
     * @return 缩略图字节数组；不支持缩略图时返回空数组
     */
    public func fetchThumbnailData(urlData: String): Array<Byte> {
        let localPath = decodeUrlDataToLocalPath(urlData)
        if (localPath.size == 0) {
            Hilog.info(0, "CjTelegram", "[ICloudResources] fetchThumbnailData: decode failed")
            return Array<Byte>(0, repeat: 0)
        }
        let fileName = extractFileName(localPath)
        let ext = extractExtension(fileName)
        if (isAudioExtension(ext) || ext == "pdf") {
            Hilog.info(0, "CjTelegram", "[ICloudResources] fetchThumbnailData: audio/pdf thumb not supported on HarmonyOS")
            return Array<Byte>(0, repeat: 0)
        }
        let imageExts: Array<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "bmp"]
        var isImage = false
        for (imgExt in imageExts) {
            if (ext == imgExt) {
                isImage = true
            }
        }
        if (!isImage) {
            return Array<Byte>(0, repeat: 0)
        }
        return readLocalFile(localPath)
    }

    // ── 批量文件描述 ─────────────────────────────────────────────────────────

    /**
     * 批量获取多个本地文件路径的描述信息
     *
     * @param localPaths 本地文件路径列表
     * @return 成功描述的文件列表（失败的条目被跳过）
     */
    public func describeLocalFiles(localPaths: ArrayList<String>): ArrayList<ICloudFileDescription> {
        let results = ArrayList<ICloudFileDescription>()
        for (path in localPaths) {
            let descOpt = describeLocalFile(path)
            match (descOpt) {
                case Some(desc) => results.add(desc)
                case None =>
                    Hilog.info(0, "CjTelegram", "[ICloudResources] describeLocalFiles: skip failed path")
            }
        }
        Hilog.info(0, "CjTelegram", "[ICloudResources] describeLocalFiles: ${results.size} / ${localPaths.size}")
        return results
    }

    // ── 私有辅助 ─────────────────────────────────────────────────────────────

    /**
     * 读取本地文件字节（先 stat 确定大小，再一次性 read）
     *
     * 对应 iOS ICloudFileResourceCopyItem.copyTo + Data(contentsOf:) 模式
     */
    private func readLocalFile(path: String): Array<Byte> {
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(path)
            fileSize = stat.size
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ICloudResources] readLocalFile: stat failed path=${path}")
            return Array<Byte>(0, repeat: 0)
        }
        if (fileSize <= 0) {
            return Array<Byte>(0, repeat: 0)
        }
        try {
            let buf = Array<Byte>(fileSize, repeat: 0)
            let f = FileIo.open(path, mode: 0o0)
            let _ = FileIo.read(f.fd, buf)
            FileIo.close(f)
            Hilog.info(0, "CjTelegram", "[ICloudResources] readLocalFile: read ${fileSize} bytes from ${path}")
            return buf
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ICloudResources] readLocalFile: read failed path=${path}")
            return Array<Byte>(0, repeat: 0)
        }
    }
}
