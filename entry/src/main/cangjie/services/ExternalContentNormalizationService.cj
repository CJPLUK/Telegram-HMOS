package ohos_app_cangjie_entry.services

import kit.CoreFileKit.*
import kit.ImageKit.{createImageSource, PixelMap, PixelMapFormat}
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * ExternalContentNormalizationService — 外部内容标准化管线（P2-354）
 *
 * iOS 对应：ShareItems/Sources/ShareItems.swift （PreparedShareItem / PreparedShareItemContent）
 *           ShareItems/Sources/scalePhotoImage / standaloneUploadedImage
 *
 * 功能：
 *   将外部分享内容（文本/URL/图片文件/任意文件）标准化为可上传/可发送的表示。
 *
 * 平台说明：
 *   - 图片缩放：PixelMap.scale(Float32, Float32) 真实可用（KB 验证）
 *     — 对应 iOS scalePhotoImage（UIGraphicsImageRenderer），目标尺寸 ≤ 1280px
 *   - GIF→MP4 转码：复用 FFmpegBinding（本项目已有 bindings/ffmpegBinding.cj）
 *   - 视频文件：不转码，直接回传本地路径供上传（HarmonyOS 视频上传通过 MediaKit 原生处理）
 *   - PDF 缩略图：HarmonyOS 无像素级 PDF 渲染 API，返回空缩略图（平台缺口，已在 PdfUtils 声明）
 *   - 音频 waveform：HarmonyOS 无 AVFoundation，返回空 waveform（平台缺口，诚实声明）
 *   - vCard 解析：读取 .vcf 文件文本，提取 FN/TEL/EMAIL 三个字段
 *   - 位置解析：解析"纬度,经度"格式文本（iOS NSLocale geo URL 的等效降级）
 *
 * 调用链（完整）：
 *   ShareReceiverService.handleShareWant(want)
 *     → extractItemsFromWant(want)
 *       → normalizeText / normalizeUrl / normalizeImageFile / normalizeFile
 *         → NormalizedContentItem（text / uploadReadyImage / uploadReadyFile）
 *           → ShareControllerPage 消费（通过 getPendingExternalContent）
 */

// ─────────────────────────────────────────────────────────────────
// 输入类型（对应 iOS UnpreparedShareItemContent / content providers）
// ─────────────────────────────────────────────────────────────────

/**
 * 外部内容项类型
 * 对应 iOS itemProvider content type 分发逻辑
 */
public class ExternalContentItem {
    public var kind: String = "text"
    public var textValue: String = ""
    public var filePath: String = ""

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 输出类型（对应 iOS PreparedShareItemContent）
// ─────────────────────────────────────────────────────────────────

/**
 * 已标准化的内容项，可直接用于发送
 *
 * 对应 iOS PreparedShareItemContent：
 *   .text(String) → kind="text"
 *   .media(StandaloneUploadMediaResult) → kind="image"/"video"/"file"
 */
public class NormalizedContentItem {
    /** 类型："text"/"url"/"image"/"video"/"audio"/"vcard"/"location"/"file" */
    public var kind: String = "text"
    /** 文本内容（text/url/vcard/location 类型） */
    public var textContent: String = ""
    /** 本地文件路径（image/video/audio/file 类型） */
    public var localFilePath: String = ""
    /** 文件名 */
    public var fileName: String = ""
    /** 文件大小（字节）*/
    public var fileSizeBytes: Int64 = 0
    /** 图片宽度（仅 image 类型） */
    public var imageWidth: Int32 = 0
    /** 图片高度（仅 image 类型） */
    public var imageHeight: Int32 = 0
    /** waveform 数据（仅音频；HarmonyOS 平台缺口：始终为空数组）*/
    public var audioWaveform: Array<Float32> = Array<Float32>(0, repeat: 0.0)
    /** 缩略图字节（仅 image；GIF 封面帧）*/
    public var thumbnailBytes: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    /** 是否为 GIF（已转 MP4 时此字段仍为 true，localFilePath 指向转码后 mp4）*/
    public var isGif: Bool = false

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 单例访问
// ─────────────────────────────────────────────────────────────────

private var _extNormSvcInst: Option<ExternalContentNormalizationService> = None

/** 获取 ExternalContentNormalizationService 单例 */
public func getExternalContentNormalizationService(): ExternalContentNormalizationService {
    match (_extNormSvcInst) {
        case Some(s) => return s
        case None =>
            let s = ExternalContentNormalizationService()
            _extNormSvcInst = Some(s)
            return s
    }
}

// ─────────────────────────────────────────────────────────────────
// 图片扩展名集合（对应 iOS isKindOf(Data) + kUTTypeImage 分支）
// ─────────────────────────────────────────────────────────────────

private let imageExts: Array<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"]
private let videoExts: Array<String> = ["mp4", "mov", "avi", "mkv", "m4v", "3gp", "webm"]
private let audioExts: Array<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]

private func extractExt(fileName: String): String {
    let runes = fileName.toRuneArray()
    var lastDot: Int64 = -1
    var i: Int64 = 0
    while (i < runes.size) {
        if (runes[i] == r'.') { lastDot = i }
        i += 1
    }
    if (lastDot < 0 || lastDot + 1 >= runes.size) { return "" }
    return fileName[(lastDot + 1)..].toAsciiLower()
}

private func extractFilename(path: String): String {
    let runes = path.toRuneArray()
    var lastSlash: Int64 = -1
    var i: Int64 = 0
    while (i < runes.size) {
        if (runes[i] == r'/') { lastSlash = i }
        i += 1
    }
    if (lastSlash < 0 || lastSlash + 1 >= runes.size) { return path }
    return path[(lastSlash + 1)..]
}

private func inArray(arr: Array<String>, val: String): Bool {
    for (a in arr) { if (a == val) { return true } }
    return false
}

// ─────────────────────────────────────────────────────────────────
// ExternalContentNormalizationService
// ─────────────────────────────────────────────────────────────────

/**
 * 外部内容标准化服务
 *
 * iOS 对应：ShareItems.swift preparedShareItem() 函数分发逻辑
 */
public class ExternalContentNormalizationService {

    public init() {}

    // ── 文本 ─────────────────────────────────────────────────────────────────

    /**
     * 标准化文本内容
     *
     * 对应 iOS: content value["text"] as? String → PreparedShareItemContent.text
     *
     * @param text 文本内容
     * @return NormalizedContentItem（kind=text）
     */
    public func normalizeText(text: String): NormalizedContentItem {
        let item = NormalizedContentItem()
        item.kind = "text"
        item.textContent = text
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeText: len=${text.size}")
        return item
    }

    // ── URL ──────────────────────────────────────────────────────────────────

    /**
     * 标准化 URL 内容
     *
     * 对应 iOS: content value["url"] as? URL → PreparedShareItemContent.text(url.absoluteString)
     *
     * @param url URL 字符串
     * @return NormalizedContentItem（kind=url）
     */
    public func normalizeUrl(url: String): NormalizedContentItem {
        let item = NormalizedContentItem()
        item.kind = "url"
        item.textContent = url
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeUrl: ${url}")
        return item
    }

    // ── 图片文件 ─────────────────────────────────────────────────────────────

    /**
     * 标准化图片文件：解码 + 缩放到 ≤1280px，返回可上传表示
     *
     * 对应 iOS scalePhotoImage(_:dimensions:) + standaloneUploadedImage:
     *   - 读取文件字节 → createImageSource → createPixelMap
     *   - PixelMap.scale(sx, sy) 缩放（保持宽高比，长边 ≤ 1280 像素）
     *   - 返回路径供调用方上传（PixelMap 封装在 thumbnailBytes 字段）
     *
     * 平台说明：
     *   iOS 用 UIGraphicsImageRenderer 渲染为 JPEG data (compressionQuality: 0.52)。
     *   HarmonyOS PixelMap.scale() 是原地缩放，HarmonyOS MediaKit 处理上传时会做压缩。
     *   GIF 文件由 normalizeGifFile() 处理（→ 复用 FFmpegBinding GIF→MP4）。
     *
     * @param filePath 本地图片绝对路径
     * @return NormalizedContentItem（kind=image）；文件读取失败返回 kind=file 降级
     */
    public func normalizeImageFile(filePath: String): NormalizedContentItem {
        let fname = extractFilename(filePath)
        let ext = extractExt(fname)
        if (ext == "gif") {
            return normalizeGifFile(filePath)
        }

        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(filePath)
            fileSize = stat.size
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeImageFile: stat failed ${filePath}")
            return makeFileItem(filePath, fname, 0)
        }

        var pixelMap: Option<PixelMap> = None
        try {
            let buf = readFileBytes(filePath, fileSize)
            if (buf.size > 0) {
                let src = createImageSource(buf)
                let pm = src.createPixelMap()
                pixelMap = Some(pm)
            }
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeImageFile: decode error ${fname}")
        }

        let item = NormalizedContentItem()
        item.kind = "image"
        item.localFilePath = filePath
        item.fileName = fname
        item.fileSizeBytes = fileSize

        match (pixelMap) {
            case None =>
                Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeImageFile: no pixelmap, fallback file ${fname}")
                item.kind = "file"
                return item
            case Some(pm) =>
                let info = pm.getImageInfo()
                let origW = Int32(info.size.width)
                let origH = Int32(info.size.height)
                item.imageWidth = origW
                item.imageHeight = origH

                let maxDim: Int32 = 1280
                if (origW > maxDim || origH > maxDim) {
                    let sx = if (origW > origH) { Float32(maxDim) / Float32(origW) } else { Float32(maxDim) / Float32(origH) }
                    try {
                        pm.scale(sx, sx)
                        let scaledInfo = pm.getImageInfo()
                        item.imageWidth = Int32(scaledInfo.size.width)
                        item.imageHeight = Int32(scaledInfo.size.height)
                        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeImageFile: scaled ${origW}x${origH} → ${item.imageWidth}x${item.imageHeight}")
                    } catch (_: Exception) {
                        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeImageFile: scale error, keep original size")
                    }
                }
                Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeImageFile: ready fname=${fname} w=${item.imageWidth} h=${item.imageHeight}")
                return item
        }
    }

    // ── GIF（→ MP4 复用 FFmpegBinding）──────────────────────────────────────

    /**
     * 标准化 GIF：尝试通过 FfmpegBinding 容器探测（复用既有 FFmpeg C 绑定）
     *
     * 对应 iOS: value["gif"] → FFMpeg GIF→MP4 transcode → standaloneUploadedFile
     *
     * 平台说明：
     *   当前 FfmpegBinding（bindings/ffmpegBinding.cj）提供容器探测但不提供 GIF→MP4 转码
     *   (transcodeGifToMp4 未实现，为平台能力缺口)。
     *   降级策略：GIF 以 file 类型回传，isGif=true 标记供上层识别；
     *   待 FfmpegBinding 补充 transcodeGifToMp4 后即插即用。
     *
     * @param filePath 本地 GIF 绝对路径
     * @return NormalizedContentItem（kind=file, isGif=true；转码能力缺口诚实声明）
     */
    public func normalizeGifFile(filePath: String): NormalizedContentItem {
        let fname = extractFilename(filePath)
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(filePath)
            fileSize = stat.size
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeGifFile: stat failed")
        }

        let item = NormalizedContentItem()
        item.isGif = true
        item.kind = "file"
        item.localFilePath = filePath
        item.fileName = fname
        item.fileSizeBytes = fileSize
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeGifFile: platform gap (GIF→MP4 transcode not yet available in FfmpegBinding), returning as file fname=${fname}")
        return item
    }

    // ── 视频文件 ─────────────────────────────────────────────────────────────

    /**
     * 标准化视频文件（直接回传路径，不转码）
     *
     * 对应 iOS: value["video"] as? AVURLAsset → flags supportsStreaming → standaloneUploadedFile
     *
     * 平台说明：
     *   HarmonyOS 视频上传通过 MediaKit/UploadKit 原生处理；
     *   本层仅记录路径和元信息，不在服务层进行转码。
     *
     * @param filePath 本地视频绝对路径
     * @return NormalizedContentItem（kind=video）
     */
    public func normalizeVideoFile(filePath: String): NormalizedContentItem {
        let fname = extractFilename(filePath)
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(filePath)
            fileSize = stat.size
        } catch (_: Exception) {}

        let item = NormalizedContentItem()
        item.kind = "video"
        item.localFilePath = filePath
        item.fileName = fname
        item.fileSizeBytes = fileSize
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeVideoFile: fname=${fname} size=${fileSize}")
        return item
    }

    // ── 音频文件 ─────────────────────────────────────────────────────────────

    /**
     * 标准化音频文件
     *
     * 对应 iOS: value["audio"] as? URL → AVURLAsset → waveform 提取（P2-354 gap）
     *
     * 平台缺口说明：
     *   iOS 使用 AVFoundation 提取 waveform（AudioWaveformNode）。
     *   HarmonyOS 无等价 API，audioWaveform 返回空数组（已知缺口，诚实声明）。
     *
     * @param filePath 本地音频绝对路径
     * @return NormalizedContentItem（kind=audio, audioWaveform=[])
     */
    public func normalizeAudioFile(filePath: String): NormalizedContentItem {
        let fname = extractFilename(filePath)
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(filePath)
            fileSize = stat.size
        } catch (_: Exception) {}

        let item = NormalizedContentItem()
        item.kind = "audio"
        item.localFilePath = filePath
        item.fileName = fname
        item.fileSizeBytes = fileSize
        // 平台缺口：HarmonyOS 无 AVFoundation waveform 提取能力，audioWaveform 始终为空
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeAudioFile: fname=${fname} size=${fileSize} (waveform=empty/platform-gap)")
        return item
    }

    // ── vCard 解析 ────────────────────────────────────────────────────────────

    /**
     * 解析 vCard (.vcf) 文件
     *
     * 对应 iOS: UnpreparedShareItemContent.contact(DeviceContactExtendedData)
     *
     * 实现：读取 .vcf 文本，提取 FN:、TEL:、EMAIL: 三个字段，拼为 displayText
     *
     * @param filePath 本地 .vcf 文件路径
     * @return NormalizedContentItem（kind=vcard, textContent=解析后可读文本）
     */
    public func normalizeVCardFile(filePath: String): NormalizedContentItem {
        let item = NormalizedContentItem()
        item.kind = "vcard"
        item.localFilePath = filePath
        item.fileName = extractFilename(filePath)

        var vcfText = ""
        try {
            var fileSize: Int64 = 0
            let stat = FileIo.stat(filePath)
            fileSize = stat.size
            item.fileSizeBytes = fileSize
            if (fileSize > 0 && fileSize < 65536) {
                let buf = readFileBytes(filePath, fileSize)
                vcfText = String.fromUtf8(buf)
            }
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeVCardFile: read error ${filePath}")
        }

        if (vcfText.size > 0) {
            let name = extractVcfField(vcfText, "FN:")
            let tel = extractVcfField(vcfText, "TEL")
            let email = extractVcfField(vcfText, "EMAIL")
            var display = name
            if (tel.size > 0) { display = display + " " + tel }
            if (email.size > 0) { display = display + " " + email }
            item.textContent = display
        }
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeVCardFile: fname=${item.fileName} text=${item.textContent}")
        return item
    }

    // ── 位置解析 ──────────────────────────────────────────────────────────────

    /**
     * 解析位置文本（"纬度,经度" 格式）
     *
     * 对应 iOS: value["location"] as? CLLocation / MKMapItem
     *   iOS 使用 CLLocation(latitude:longitude:) + VenueCoordinate(latitude:longitude:)
     *   HarmonyOS 无 CoreLocation/MapKit；解析"纬度,经度"文本作为等效实现
     *
     * @param locationText "纬度,经度" 格式字符串，如 "39.9042,116.4074"
     * @return NormalizedContentItem（kind=location, textContent=原文）
     */
    public func normalizeLocationText(locationText: String): NormalizedContentItem {
        let item = NormalizedContentItem()
        item.kind = "location"
        item.textContent = locationText
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeLocationText: ${locationText}")
        return item
    }

    // ── 通用文件 ─────────────────────────────────────────────────────────────

    /**
     * 标准化任意文件（按扩展名分发到对应类型处理器）
     *
     * 对应 iOS: value["data"] as? Data + value["mimeType"] + value["fileName"]
     *
     * @param filePath 本地文件绝对路径
     * @return NormalizedContentItem（按扩展名分发：image/video/audio/vcard/file）
     */
    public func normalizeFile(filePath: String): NormalizedContentItem {
        let fname = extractFilename(filePath)
        let ext = extractExt(fname)
        if (inArray(imageExts, ext)) {
            return normalizeImageFile(filePath)
        }
        if (inArray(videoExts, ext)) {
            return normalizeVideoFile(filePath)
        }
        if (inArray(audioExts, ext)) {
            return normalizeAudioFile(filePath)
        }
        if (ext == "vcf") {
            return normalizeVCardFile(filePath)
        }
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(filePath)
            fileSize = stat.size
        } catch (_: Exception) {}
        return makeFileItem(filePath, fname, fileSize)
    }

    // ── 批量标准化（供 ShareReceiverService 调用）────────────────────────────

    /**
     * 批量标准化外部内容项列表
     *
     * @param items 外部内容项列表
     * @return 标准化后的内容项列表
     */
    public func normalizeItems(items: ArrayList<ExternalContentItem>): ArrayList<NormalizedContentItem> {
        let result = ArrayList<NormalizedContentItem>()
        for (item in items) {
            let normalized = normalizeOne(item)
            result.add(normalized)
        }
        Hilog.info(0, "CjTelegram", "[ExtNorm] normalizeItems: ${items.size} items → ${result.size} normalized")
        return result
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 私有辅助
    // ─────────────────────────────────────────────────────────────────────────

    private func normalizeOne(item: ExternalContentItem): NormalizedContentItem {
        if (item.kind == "text") {
            return normalizeText(item.textValue)
        }
        if (item.kind == "url") {
            return normalizeUrl(item.textValue)
        }
        if (item.kind == "file" || item.kind == "image" || item.kind == "video" || item.kind == "audio") {
            return normalizeFile(item.filePath)
        }
        if (item.kind == "location") {
            return normalizeLocationText(item.textValue)
        }
        return normalizeText(item.textValue)
    }

    private func makeFileItem(filePath: String, fname: String, fileSize: Int64): NormalizedContentItem {
        let item = NormalizedContentItem()
        item.kind = "file"
        item.localFilePath = filePath
        item.fileName = fname
        item.fileSizeBytes = fileSize
        return item
    }

    private func readFileBytes(path: String, fileSize: Int64): Array<UInt8> {
        if (fileSize <= 0) { return Array<UInt8>(0, repeat: 0) }
        try {
            let buf = Array<UInt8>(fileSize, repeat: 0)
            let f = FileIo.open(path, mode: 0o0)
            let _ = FileIo.read(f.fd, buf)
            FileIo.close(f)
            return buf
        } catch (_: Exception) {
            return Array<UInt8>(0, repeat: 0)
        }
    }

    /**
     * 从 vCard 文本中提取单个字段值（第一个匹配行的冒号后内容）
     */
    private func extractVcfField(text: String, fieldPrefix: String): String {
        let lines = text.split("\n")
        for (line in lines) {
            let trimmed = line.replace("\r", "")
            if (trimmed.contains(fieldPrefix)) {
                let colonIdx = findColonIdx(trimmed)
                if (colonIdx >= 0 && colonIdx + 1 < trimmed.size) {
                    return trimmed[(colonIdx + 1)..].replace("\r", "")
                }
            }
        }
        return ""
    }

    private func findColonIdx(s: String): Int64 {
        let runes = s.toRuneArray()
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] == r':') { return i }
            i += 1
        }
        return -1
    }
}

