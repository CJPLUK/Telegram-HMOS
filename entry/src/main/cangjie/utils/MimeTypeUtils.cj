package ohos_app_cangjie_entry.utils

import std.collection.HashMap

/**
 * MimeTypeUtils — 扩展名 ↔ MIME 类型统一映射表
 *
 * 对应 Telegram-iOS submodules/MimeTypes。收敛工程中散落的 MIME 推断：
 *   - components/FileBrowser.cj 的 guessMimeType（内联 endsWith 链）
 *   - pages/ChatRoomPage.cj 的 mimeToUtdType（MIME → 系统类型）
 * 做成一张统一、够全的双向表。本单元不强改既有调用点，仅提供更全的工具。
 *
 * 覆盖类别：图片 / 视频 / 音频 / 文档 / 压缩 / 文本 / 字体 / 通用。
 * 未知扩展名 → "application/octet-stream"；未知 MIME → ""（空串表示无对应扩展名）。
 */

// ===== 统一表：扩展名（小写、无点）→ MIME =====
// 同一 MIME 可能对应多个扩展名（如 jpg/jpeg）；反向取第一个登记的规范扩展名。

private let EXT_TO_MIME: HashMap<String, String> = buildExtToMime()
private let MIME_TO_EXT: HashMap<String, String> = buildMimeToExt()

private func buildExtToMime(): HashMap<String, String> {
    let m = HashMap<String, String>()
    // --- 图片 ---
    m["jpg"] = "image/jpeg"
    m["jpeg"] = "image/jpeg"
    m["jpe"] = "image/jpeg"
    m["png"] = "image/png"
    m["gif"] = "image/gif"
    m["webp"] = "image/webp"
    m["bmp"] = "image/bmp"
    m["tif"] = "image/tiff"
    m["tiff"] = "image/tiff"
    m["heic"] = "image/heic"
    m["heif"] = "image/heif"
    m["svg"] = "image/svg+xml"
    m["ico"] = "image/x-icon"
    // --- 视频 ---
    m["mp4"] = "video/mp4"
    m["m4v"] = "video/x-m4v"
    m["mov"] = "video/quicktime"
    m["avi"] = "video/x-msvideo"
    m["mkv"] = "video/x-matroska"
    m["webm"] = "video/webm"
    m["3gp"] = "video/3gpp"
    m["wmv"] = "video/x-ms-wmv"
    m["flv"] = "video/x-flv"
    m["mpeg"] = "video/mpeg"
    m["mpg"] = "video/mpeg"
    // --- 音频 ---
    m["mp3"] = "audio/mpeg"
    m["m4a"] = "audio/mpeg"
    m["aac"] = "audio/aac"
    m["ogg"] = "audio/ogg"
    m["oga"] = "audio/ogg"
    m["opus"] = "audio/opus"
    m["wav"] = "audio/x-wav"
    m["flac"] = "audio/flac"
    m["wma"] = "audio/x-ms-wma"
    m["mid"] = "audio/midi"
    m["midi"] = "audio/midi"
    // --- 文档 ---
    m["pdf"] = "application/pdf"
    m["doc"] = "application/msword"
    m["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    m["xls"] = "application/vnd.ms-excel"
    m["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    m["ppt"] = "application/vnd.ms-powerpoint"
    m["pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    m["rtf"] = "application/rtf"
    m["epub"] = "application/epub+zip"
    // --- 文本 / 标记 / 数据 ---
    m["txt"] = "text/plain"
    m["log"] = "text/plain"
    m["csv"] = "text/csv"
    m["html"] = "text/html"
    m["htm"] = "text/html"
    m["css"] = "text/css"
    m["js"] = "text/javascript"
    m["json"] = "application/json"
    m["xml"] = "text/xml"
    m["md"] = "text/markdown"
    // --- 压缩 ---
    m["zip"] = "application/zip"
    m["rar"] = "application/x-rar-compressed"
    m["7z"] = "application/x-7z-compressed"
    m["tar"] = "application/x-tar"
    m["gz"] = "application/gzip"
    m["bz2"] = "application/x-bzip2"
    // --- 字体 / 其他 ---
    m["ttf"] = "font/ttf"
    m["otf"] = "font/otf"
    m["woff"] = "font/woff"
    m["woff2"] = "font/woff2"
    m["apk"] = "application/vnd.android.package-archive"
    // --- Telegram 专有 ---
    m["tgs"] = "application/x-tgsticker"
    return m
}

private func buildMimeToExt(): HashMap<String, String> {
    let m = HashMap<String, String>()
    // 反向规范扩展名（每个 MIME 取一个最常用的）
    m["image/jpeg"] = "jpg"
    m["image/png"] = "png"
    m["image/gif"] = "gif"
    m["image/webp"] = "webp"
    m["image/bmp"] = "bmp"
    m["image/tiff"] = "tiff"
    m["image/heic"] = "heic"
    m["image/heif"] = "heif"
    m["image/svg+xml"] = "svg"
    m["image/x-icon"] = "ico"
    m["video/mp4"] = "mp4"
    m["video/x-m4v"] = "m4v"
    m["video/quicktime"] = "mov"
    m["video/x-msvideo"] = "avi"
    m["video/x-matroska"] = "mkv"
    m["video/webm"] = "webm"
    m["video/3gpp"] = "3gp"
    m["video/x-ms-wmv"] = "wmv"
    m["video/x-flv"] = "flv"
    m["video/mpeg"] = "mpg"
    m["audio/mpeg"] = "m4a"
    m["audio/mp4"] = "m4a"
    m["audio/aac"] = "aac"
    m["audio/ogg"] = "ogg"
    m["audio/opus"] = "opus"
    m["audio/x-wav"] = "wav"
    m["audio/flac"] = "flac"
    m["audio/x-ms-wma"] = "wma"
    m["audio/midi"] = "mid"
    m["application/pdf"] = "pdf"
    m["application/msword"] = "doc"
    m["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx"
    m["application/vnd.ms-excel"] = "xls"
    m["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"] = "xlsx"
    m["application/vnd.ms-powerpoint"] = "ppt"
    m["application/vnd.openxmlformats-officedocument.presentationml.presentation"] = "pptx"
    m["application/rtf"] = "rtf"
    m["application/epub+zip"] = "epub"
    m["text/plain"] = "txt"
    m["text/csv"] = "csv"
    m["text/html"] = "html"
    m["text/css"] = "css"
    m["text/javascript"] = "js"
    m["application/json"] = "json"
    m["text/xml"] = "xml"
    m["text/markdown"] = "md"
    m["application/zip"] = "zip"
    m["application/x-rar-compressed"] = "rar"
    m["application/x-7z-compressed"] = "7z"
    m["application/x-tar"] = "tar"
    m["application/gzip"] = "gz"
    m["application/x-bzip2"] = "bz2"
    m["font/ttf"] = "ttf"
    m["font/otf"] = "otf"
    m["font/woff"] = "woff"
    m["font/woff2"] = "woff2"
    m["application/vnd.android.package-archive"] = "apk"
    // --- Telegram 专有 ---
    m["application/x-tgsticker"] = "tgs"
    return m
}

/**
 * 把传入串规范化成纯小写扩展名（去掉前导 '.'、去掉路径与文件名只留最后一段后缀）。
 * 输入既可以是 "jpg"、".jpg"，也可以是 "photo.JPG" 或 "a/b/c.tar.gz"。
 */
private func normalizeExt(input: String): String {
    var s = input.toAsciiLower()
    // 若含路径分隔，取最后一段
    match (s.lastIndexOf("/")) {
        case Some(i) => s = s[(i + 1)..]
        case None => ()
    }
    // 取最后一个 '.' 之后
    match (s.lastIndexOf(".")) {
        case Some(i) => s = s[(i + 1)..]
        case None => ()
    }
    return s
}

// ===== 公共 API =====

/**
 * 扩展名 → MIME。ext 可带或不带前导点，可大小写，也可传完整文件名。
 * 未知扩展名返回 "application/octet-stream"。
 */
public func mimeTypeForExtension(ext: String): String {
    let key = normalizeExt(ext)
    if (key.isEmpty()) {
        return "application/octet-stream"
    }
    return EXT_TO_MIME.get(key) ?? "application/octet-stream"
}

/**
 * MIME → 规范扩展名（小写、无点）。
 * 大小写不敏感；带参数的 MIME（如 "text/plain; charset=utf-8"）只取 ';' 前主类型。
 * 未知 MIME 返回 ""。
 */
public func extensionForMimeType(mime: String): String {
    var m = mime.toAsciiLower().trimAscii()
    match (m.indexOf(";")) {
        case Some(i) => m = m[..i].trimAscii()
        case None => ()
    }
    return MIME_TO_EXT.get(m) ?? ""
}

// ===== 自检 =====

/**
 * 自检：正向已知样例 + 反向一致性。返回 true 表示全部通过。
 * 函数名加 mimeType 前缀避免 utils 包内顶层冲突。
 */
public func mimeTypeUtilsSelfCheck(): Bool {
    // --- 正向 ---
    if (mimeTypeForExtension("jpg") != "image/jpeg") { return false }
    if (mimeTypeForExtension(".JPG") != "image/jpeg") { return false }
    if (mimeTypeForExtension("photo.png") != "image/png") { return false }
    if (mimeTypeForExtension("mp4") != "video/mp4") { return false }
    if (mimeTypeForExtension("pdf") != "application/pdf") { return false }
    if (mimeTypeForExtension("zip") != "application/zip") { return false }
    if (mimeTypeForExtension("mp3") != "audio/mpeg") { return false }
    if (mimeTypeForExtension("nonsense_ext") != "application/octet-stream") { return false }

    // --- 反向一致：mime→ext→mime 必须回到同一 MIME ---
    let mimes: Array<String> = [
        "image/jpeg", "image/png", "video/mp4", "application/pdf",
        "audio/mpeg", "application/zip"
    ]
    for (mt in mimes) {
        let ext = extensionForMimeType(mt)
        if (ext.isEmpty()) { return false }
        if (mimeTypeForExtension(ext) != mt) { return false }
    }
    // 带参数 MIME
    if (extensionForMimeType("text/plain; charset=utf-8") != "txt") { return false }
    // 未知 MIME
    if (extensionForMimeType("application/x-unknown-xyz") != "") { return false }

    return true
}
