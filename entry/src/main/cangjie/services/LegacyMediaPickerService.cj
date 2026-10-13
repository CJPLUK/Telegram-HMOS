package ohos_app_cangjie_entry.services

import kit.CoreFileKit.*
import kit.MediaLibraryKit.*
import kit.AbilityKit.UIAbilityContext
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos.business_exception.BusinessException

/**
 * LegacyMediaPickerService — 旧版媒体选择器服务（本地文件 / 文档）
 *
 * iOS 对应：LegacyMediaPickerUI（LegacyAttachmentMenu.swift / LegacyICloudFilePicker.swift）
 *
 * 平台说明：
 *   - iOS 的 UIDocumentPickerViewController (iCloud Files) 在 HarmonyOS 上等效实现为：
 *     从应用沙盒 documents 目录扫描本地文件。
 *   - iOS 的 UIImagePickerController 相册选取已由 LocalMediaResourcesService 覆盖。
 *   - 本 service 专注于：文档文件列表、文件元信息查询、文件字节读取。
 *   - 无 MTProto 依赖（implementation_kind: local_state，tl_methods=[]）。
 *
 * 调用链（完整）：
 *   DocumentPickerViewPage.aboutToAppear()
 *     → LegacyMediaPickerService.scanDocumentFiles(ctx)
 *       → context.filesDir → FileIo.listFile()
 *         → Array<DocumentFileInfo>
 *
 *   DocumentPickerViewPage.onSelectFile(info)
 *     → LegacyMediaPickerService.readFileBytes(path)
 *       → FileIo.stat(path) → size
 *       → FileIo.open(path) → FileIo.read() → Array<Byte>
 *
 *   LegacyICloudFilePage.aboutToAppear()
 *     → LegacyMediaPickerService.scanDocumentFiles(ctx)
 *       → (同上) → Array<DocumentFileInfo>
 */

// ─────────────────────────────────────────────────────────────────
// 文件信息模型
// ─────────────────────────────────────────────────────────────────

/**
 * 文档文件信息
 *
 * 对应 iOS LegacyICloudFilePicker 中的文件条目（URL → 本地路径）
 */
public class DocumentFileInfo {
    /** 文件名（含后缀）*/
    public var fileName: String = ""
    /** 文件绝对路径 */
    public var filePath: String = ""
    /** 文件大小（字节）*/
    public var fileSize: Int64 = 0
    /** 文件扩展名（小写，不含点） */
    public var fileExt: String = ""
    /** 是否为图片类型 */
    public var isImage: Bool = false
    /** 是否为视频类型 */
    public var isVideo: Bool = false
    /** 是否为音频类型 */
    public var isAudio: Bool = false
    /** 是否为 PDF */
    public var isPdf: Bool = false

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 单例
// ─────────────────────────────────────────────────────────────────

private var _legacyMediaPickerServiceInstance: Option<LegacyMediaPickerService> = None

/** 获取 LegacyMediaPickerService 单例 */
public func getLegacyMediaPickerService(): LegacyMediaPickerService {
    match (_legacyMediaPickerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LegacyMediaPickerService()
            _legacyMediaPickerServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// 辅助函数
// ─────────────────────────────────────────────────────────────────

/**
 * 从文件路径提取文件名（含后缀）
 */
private func extractDocFileName(path: String): String {
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
 */
private func extractDocFileExt(fileName: String): String {
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

private let imageExts: Array<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "bmp"]
private let videoExts: Array<String> = ["mp4", "mov", "avi", "mkv", "m4v", "3gp"]
private let audioExts: Array<String> = ["mp3", "m4a", "aac", "flac", "ogg", "wav"]

private func isImageExt(ext: String): Bool {
    for (e in imageExts) { if (e == ext) { return true } }
    return false
}

private func isVideoExt(ext: String): Bool {
    for (e in videoExts) { if (e == ext) { return true } }
    return false
}

private func isAudioExt(ext: String): Bool {
    for (e in audioExts) { if (e == ext) { return true } }
    return false
}

// ─────────────────────────────────────────────────────────────────
// LegacyMediaPickerService
// ─────────────────────────────────────────────────────────────────

/**
 * LegacyMediaPickerService — 本地文档文件选择服务
 *
 * 从 HarmonyOS 应用沙盒（filesDir）扫描文件列表，提供文件元信息查询和字节读取能力。
 * 对应 iOS LegacyICloudFilePicker（UIDocumentPickerViewController）的本地等效实现。
 */
public class LegacyMediaPickerService {

    public init() {}

    // ── 文件列表扫描 ─────────────────────────────────────────────────────

    /**
     * 扫描应用沙盒 filesDir 中的文档文件
     *
     * 对应 iOS UIDocumentPickerViewController 展示可选文档列表的等效实现。
     * HarmonyOS 沙盒 filesDir 对应 iOS 的 NSDocumentDirectory。
     *
     * @param filesDir 应用文件目录路径（使用 getAppFilesDir() 获取）
     * @return 文档文件信息列表；扫描失败时返回空列表
     */
    public func scanDocumentFiles(filesDir: String): ArrayList<DocumentFileInfo> {
        let result = ArrayList<DocumentFileInfo>()
        if (filesDir.size == 0) {
            Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] scanDocumentFiles: empty filesDir")
            return result
        }
        try {
            let fileNames = FileIo.listFile(filesDir)
            for (name in fileNames) {
                let fullPath = filesDir + "/" + name
                var fileSize: Int64 = 0
                try {
                    let stat = FileIo.stat(fullPath)
                    fileSize = stat.size
                } catch (_: Exception) {
                    Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] stat failed: " + name)
                }
                let ext = extractDocFileExt(name)
                let info = DocumentFileInfo()
                info.fileName = name
                info.filePath = fullPath
                info.fileSize = fileSize
                info.fileExt = ext
                info.isImage = isImageExt(ext)
                info.isVideo = isVideoExt(ext)
                info.isAudio = isAudioExt(ext)
                info.isPdf = (ext == "pdf")
                result.add(info)
            }
            Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] scanDocumentFiles: found " + result.size.toString() + " files")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] scanDocumentFiles error: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] scanDocumentFiles unexpected error")
        }
        return result
    }

    /**
     * 按扩展名过滤文件列表
     *
     * 对应 iOS documentTypes 参数（UTType 白名单）的等效实现。
     *
     * @param files 文件列表
     * @param allowedExts 允许的扩展名数组（小写，不含点），空数组表示全部允许
     * @return 过滤后的文件列表
     */
    public func filterByExtensions(
        files: ArrayList<DocumentFileInfo>,
        allowedExts: Array<String>
    ): ArrayList<DocumentFileInfo> {
        if (allowedExts.size == 0) {
            return files
        }
        let result = ArrayList<DocumentFileInfo>()
        for (f in files) {
            for (ext in allowedExts) {
                if (f.fileExt == ext) {
                    result.add(f)
                    break
                }
            }
        }
        return result
    }

    // ── 文件读取 ─────────────────────────────────────────────────────────

    /**
     * 读取文件原始字节数据
     *
     * 对应 iOS URLSession dataTask + NSData 从本地文件读取数据。
     * 供发送文件附件时使用（上层由 FileUploadService 负责 MTProto 上传）。
     *
     * @param filePath 文件绝对路径
     * @return 文件字节数组；读取失败时返回空数组
     */
    public func readFileBytes(filePath: String): Array<Byte> {
        if (filePath.size == 0) {
            return Array<Byte>(0, repeat: 0)
        }
        var fileSize: Int64 = 0
        try {
            let stat = FileIo.stat(filePath)
            fileSize = stat.size
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] readFileBytes: stat failed: " + filePath)
            return Array<Byte>(0, repeat: 0)
        }
        if (fileSize <= 0) {
            return Array<Byte>(0, repeat: 0)
        }
        try {
            let buf = Array<Byte>(fileSize, repeat: 0)
            let f = FileIo.open(filePath, mode: 0o0)
            let _ = FileIo.read(f.fd, buf)
            FileIo.close(f)
            Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] readFileBytes: read " + fileSize.toString() + " bytes")
            return buf
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LegacyMediaPicker] readFileBytes: read failed: " + filePath)
            return Array<Byte>(0, repeat: 0)
        }
    }

    /**
     * 格式化文件大小为可读字符串
     *
     * 对应 iOS ByteCountFormatter 的简化等效实现。
     *
     * @param bytes 文件字节数
     * @return 格式化字符串（例如 "1.2 MB"、"345 KB"、"512 B"）
     */
    public func formatFileSize(bytes: Int64): String {
        if (bytes < 1024) {
            return bytes.toString() + " B"
        } else if (bytes < 1024 * 1024) {
            let kb = bytes / 1024
            return kb.toString() + " KB"
        } else if (bytes < 1024 * 1024 * 1024) {
            let mb = bytes / (1024 * 1024)
            return mb.toString() + " MB"
        } else {
            let gb = bytes / (1024 * 1024 * 1024)
            return gb.toString() + " GB"
        }
    }

    /**
     * 获取文件类型显示标签
     *
     * 对应 iOS 文件图标类型判断（文件 UTType → 展示用分类标签）。
     *
     * @param info 文件信息
     * @return 类型标签字符串
     */
    public func fileTypeLabel(info: DocumentFileInfo): String {
        if (info.isImage) {
            return "Image"
        } else if (info.isVideo) {
            return "Video"
        } else if (info.isAudio) {
            return "Audio"
        } else if (info.isPdf) {
            return "PDF"
        } else {
            return "File"
        }
    }
}
