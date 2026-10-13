package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.{inflate, ByteUtils}
import std.collection.ArrayList

/**
 * P2-091: 聊天导入文件全局存储 — 跨 NavDestination 传递 zip 文件数据与媒体条目
 *
 * iOS 对应: ImportManager.archivePath / entries (SSZipEntry 列表)
 *
 * 分工:
 *   - ChatImportPeerSelectScreen 或调用方写入 importIsZip / importFileData / importFileName
 *   - ChatImportActivityScreen 读取后触发 extractMediaEntriesFromZip + startImport
 *
 * PKzip 读取器实现说明（诚实声明）：
 *   stdx.compress 仅支持 deflate-raw/gzip，不支持 PKzip 格式（无 libzip）。
 *   本模块用纯仓颉实现最小 PKzip Local File Header 读取器：
 *     - 读取签名 0x04034b50，解析 name/extra/data 字段偏移
 *     - compression method 0 (stored): 直接切片返回
 *     - compression method 8 (deflated): 调用 inflate() 做 raw deflate 解压
 *       inflate() 已在 core/mtproto/Inflate.cj 实现，基于 RFC 1951 纯仓颉 Huffman 树
 *   不支持: ZIP64、加密条目（跳过）、method != 0/8（跳过）
 *
 * Haptic 声明（N-A）：
 *   HarmonyOS 振动 API 在仓颉标准库中无直接绑定，需要 ArkTS 桥接（arkinterop）。
 *   当前实现诚实注明 N-A：不实现 haptic，以 ConfettiView 撒花动画替代成功反馈。
 */

private var _chatImportFileStoreInst: Option<ChatImportFileStore> = None

public func getChatImportFileStore(): ChatImportFileStore {
    match (_chatImportFileStoreInst) {
        case Some(s) => return s
        case None =>
            let s = ChatImportFileStore()
            _chatImportFileStoreInst = Some(s)
            return s
    }
}

/**
 * 导入文件全局存储
 * importFileData: 原始文件字节（zip 或 txt）
 * importFileName: 主导入文件名
 * importIsZip: 是否为 zip 包
 */
public class ChatImportFileStore {
    public var importFileData: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var importFileName: String = ""
    public var importIsZip: Bool = false
}

// ============================================================
// MIME 类型推导（按扩展名映射，对应 iOS TGMimeTypeMap）
// ============================================================

/**
 * P2-091: 按文件名扩展名推导 MIME 类型。
 * 对应 iOS: TGMimeTypeMap.mimeType(forExtension:)
 *
 * 扩展名比较用手动后缀检查（R-101: hasSuffix N/A）。
 * 比较逻辑: 从文件名尾部扫描 '.' 找扩展名，再 toAsciiLower 后逐一匹配。
 */
public func deriveMimeType(fileName: String): String {
    let lower = fileName.toAsciiLower()
    var ext = ""

    var i: Int64 = lower.size - 1
    while (i >= 0) {
        let ch = lower[i..i+1]
        if (ch == ".") {
            ext = lower[i+1..lower.size]
            break
        }
        i -= 1
    }

    if (ext.size == 0) { return "application/octet-stream" }

    if (ext == "jpg" || ext == "jpeg") { return "image/jpeg" }
    if (ext == "png") { return "image/png" }
    if (ext == "gif") { return "image/gif" }
    if (ext == "webp") { return "image/webp" }
    if (ext == "heic") { return "image/heic" }
    if (ext == "heif") { return "image/heif" }
    if (ext == "tiff" || ext == "tif") { return "image/tiff" }
    if (ext == "bmp") { return "image/bmp" }
    if (ext == "mp4") { return "video/mp4" }
    if (ext == "mov") { return "video/quicktime" }
    if (ext == "avi") { return "video/x-msvideo" }
    if (ext == "mkv") { return "video/x-matroska" }
    if (ext == "m4v") { return "video/x-m4v" }
    if (ext == "3gp") { return "video/3gpp" }
    if (ext == "webm") { return "video/webm" }
    if (ext == "mp3") { return "audio/mpeg" }
    if (ext == "m4a") { return "audio/x-m4a" }
    if (ext == "ogg") { return "audio/ogg" }
    if (ext == "flac") { return "audio/flac" }
    if (ext == "wav") { return "audio/wav" }
    if (ext == "aac") { return "audio/aac" }
    if (ext == "opus") { return "audio/opus" }
    if (ext == "pdf") { return "application/pdf" }
    if (ext == "doc") { return "application/msword" }
    if (ext == "docx") {
        return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    }
    if (ext == "xls") { return "application/vnd.ms-excel" }
    if (ext == "xlsx") {
        return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }
    if (ext == "ppt") { return "application/vnd.ms-powerpoint" }
    if (ext == "pptx") {
        return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    }
    if (ext == "zip") { return "application/zip" }
    if (ext == "txt") { return "text/plain" }
    return "application/octet-stream"
}

// ============================================================
// 极简 PKzip 读取器（仅支持 stored(0) 和 deflated(8)）
// ============================================================

/**
 * ZIP 条目信息（解析阶段使用）
 */
public class ZipEntryInfo {
    public var name: String = ""
    public var compressedSize: Int64 = 0
    public var uncompressedSize: Int64 = 0
    public var compressionMethod: Int32 = 0
    public var dataOffset: Int64 = 0

    public init() {}
}

/**
 * 从小端字节数组中读取 16 位无符号整数
 */
private func readU16LE(data: Array<Byte>, offset: Int64): Int64 {
    let lo = Int64(UInt8(data[offset]))
    let hi = Int64(UInt8(data[offset + 1]))
    return lo | (hi << 8)
}

/**
 * 从小端字节数组中读取 32 位无符号整数
 */
private func readU32LE(data: Array<Byte>, offset: Int64): Int64 {
    let b0 = Int64(UInt8(data[offset]))
    let b1 = Int64(UInt8(data[offset + 1]))
    let b2 = Int64(UInt8(data[offset + 2]))
    let b3 = Int64(UInt8(data[offset + 3]))
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

/**
 * P2-091: 纯仓颉极简 PKzip Local File Header 解析器。
 *
 * PKzip Local File Header 结构（APPNOTE.TXT 4.3.7）:
 *   Offset  Size  Description
 *   0       4     Local file header signature = 0x04034b50
 *   4       2     version needed to extract
 *   6       2     general purpose bit flag
 *   8       2     compression method (0=stored, 8=deflated)
 *   10      2     last mod file time
 *   12      2     last mod file date
 *   14      4     crc-32
 *   18      4     compressed size
 *   22      4     uncompressed size
 *   26      2     file name length
 *   28      2     extra field length
 *   30      n     file name (UTF-8 or CP437)
 *   30+n    m     extra field
 *   30+n+m  compressed_size  file data
 *
 * 返回所有非目录条目的 ZipEntryInfo 数组（数据偏移+长度，未解压）。
 */
public func parseZipEntries(data: Array<Byte>): Array<ZipEntryInfo> {
    let localSig: Int64 = 0x04034b50
    var pos: Int64 = 0
    let dataSize = Int64(data.size)
    let results = ArrayList<ZipEntryInfo>()

    while (pos + 30 <= dataSize) {
        let sig = readU32LE(data, pos)
        if (sig != localSig) {
            break
        }

        let bitFlag = Int32(readU16LE(data, pos + 6))
        let method = Int32(readU16LE(data, pos + 8))
        let compressedSize = readU32LE(data, pos + 18)
        let uncompressedSize = readU32LE(data, pos + 22)
        let nameLen = readU16LE(data, pos + 26)
        let extraLen = readU16LE(data, pos + 28)

        let nameStart = pos + 30
        let dataStart = nameStart + nameLen + extraLen

        if (nameStart + nameLen > dataSize) {
            Hilog.info(0, "CjTelegram", "[ZipReader] truncated name field at pos=${pos}")
            break
        }

        let nameBytes = ByteUtils.slice(data, nameStart, nameStart + nameLen)
        let entryName = String.fromUtf8(nameBytes)

        pos = dataStart + compressedSize

        if (pos > dataSize) {
            Hilog.info(0, "CjTelegram", "[ZipReader] entry data exceeds archive at ${entryName}")
            break
        }

        let isEncrypted = (bitFlag & 1) != 0
        if (isEncrypted) {
            Hilog.info(0, "CjTelegram", "[ZipReader] skipping encrypted entry: ${entryName}")
            continue
        }

        if (entryName.size > 0 && entryName[entryName.size - 1..entryName.size] == "/") {
            continue
        }

        if (method != 0 && method != 8) {
            Hilog.info(0, "CjTelegram", "[ZipReader] unsupported method=${method} for ${entryName}, skipping")
            continue
        }

        let entry = ZipEntryInfo()
        entry.name = entryName
        entry.compressedSize = compressedSize
        entry.uncompressedSize = uncompressedSize
        entry.compressionMethod = method
        entry.dataOffset = dataStart

        results.add(entry)
    }

    let out = Array<ZipEntryInfo>(results.size, { idx: Int64 => results[idx] })
    Hilog.info(0, "CjTelegram", "[ZipReader] parsed ${out.size} entries")
    return out
}

/**
 * P2-091: 从 zip 字节数据中提取单个条目内容。
 *
 * compression method 0 (stored): 直接返回字节切片（ByteUtils.slice 复制）。
 * compression method 8 (deflated): 使用 inflate() 做 raw DEFLATE 解压
 *   （inflate 位于 core/mtproto/Inflate.cj，纯仓颉 Huffman 实现，已在 gzip 解压中验证）。
 */
public func extractZipEntry(zipData: Array<Byte>, entry: ZipEntryInfo): Array<Byte> {
    let start = entry.dataOffset
    let end = entry.dataOffset + entry.compressedSize
    if (end > Int64(zipData.size)) {
        Hilog.info(0, "CjTelegram", "[ZipReader] extractZipEntry: out of bounds for ${entry.name}")
        return Array<Byte>(0, repeat: 0)
    }

    let compressedBytes = ByteUtils.slice(zipData, start, end)

    if (entry.compressionMethod == 0) {
        return compressedBytes
    }

    if (entry.compressionMethod == 8) {
        Hilog.info(0, "CjTelegram", "[ZipReader] inflating deflate-raw entry ${entry.name}: compressed=${compressedBytes.size}")
        let result = inflate(compressedBytes)
        Hilog.info(0, "CjTelegram", "[ZipReader] inflated ${result.size} bytes (expected ${entry.uncompressedSize})")
        return result
    }

    return Array<Byte>(0, repeat: 0)
}

/**
 * P2-091: 从 zip 文件字节数组中提取所有媒体条目。
 *
 * 过滤规则（对应 iOS ChatImportActivityScreen otherEntries 构建逻辑）：
 *   - 跳过 __MACOSX/ 目录下的条目
 *   - 跳过以 "." 开头的隐藏文件
 *   - 跳过根目录下的 .txt 文件（主导出文本，通过 extractMainTextFromZip 单独读取）
 *   - 保留其余所有文件条目，推导 MIME 类型
 */
public func extractMediaEntriesFromZip(zipData: Array<Byte>): Array<ChatImportMediaEntry> {
    let entries = parseZipEntries(zipData)
    Hilog.info(0, "CjTelegram", "[ZipReader] extractMediaEntries: total entries=${entries.size}")

    let mediaList = ArrayList<ChatImportMediaEntry>()

    for (entry in entries) {
        let name = entry.name
        if (name.size == 0) { continue }

        if (name.contains("__MACOSX/")) { continue }

        let baseName: String
        if (name.contains("/")) {
            let parts = name.split("/")
            if (parts.size > 0) {
                baseName = parts[parts.size - 1]
            } else {
                baseName = name
            }
        } else {
            baseName = name
        }

        if (baseName.size == 0) { continue }
        if (baseName.startsWith(".")) { continue }

        let isRootTxt = !name.contains("/") && baseName.size >= 4 &&
            baseName[baseName.size - 4..baseName.size].toAsciiLower() == ".txt"
        if (isRootTxt) {
            Hilog.info(0, "CjTelegram", "[ZipReader] skipping main text entry: ${name}")
            continue
        }

        let rawData = extractZipEntry(zipData, entry)
        if (rawData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ZipReader] skipping empty/failed entry: ${name}")
            continue
        }

        let mime = deriveMimeType(baseName)
        let mediaEntry = ChatImportMediaEntry(data: rawData, fileName: baseName, mimeType: mime)
        mediaList.add(mediaEntry)
        Hilog.info(0, "CjTelegram", "[ZipReader] added media entry: ${baseName} mime=${mime} size=${rawData.size}")
    }

    let out = Array<ChatImportMediaEntry>(mediaList.size, { idx: Int64 => mediaList[idx] })
    Hilog.info(0, "CjTelegram", "[ZipReader] extractMediaEntries: returning ${out.size} media entries")
    return out
}

/**
 * P2-091: 从 zip 文件中提取主导出文本内容（根目录下的 .txt 文件）。
 * 返回空字节数组 (size == 0) 如果未找到，调用方使用原始 zipData 作为 fallback。
 */
public func extractMainTextFromZip(zipData: Array<Byte>): Array<Byte> {
    let entries = parseZipEntries(zipData)
    for (entry in entries) {
        let name = entry.name
        if (name.contains("/")) { continue }
        if (name.size < 4) { continue }
        if (name[name.size - 4..name.size].toAsciiLower() != ".txt") { continue }
        let rawData = extractZipEntry(zipData, entry)
        if (rawData.size > 0) {
            Hilog.info(0, "CjTelegram", "[ZipReader] main text found: ${name} size=${rawData.size}")
            return rawData
        }
    }
    return Array<Byte>(0, repeat: 0)
}
