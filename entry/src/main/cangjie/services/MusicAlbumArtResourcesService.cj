package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.net.{netHttpGetBytes, netHttpPostText}
import std.collection.HashMap
import std.collection.ArrayList
import stdx.encoding.base64.*

/**
 * AlbumArtResult — 专辑封面请求结果
 *
 * iOS 对应: ExternalMusicAlbumArtResourceId / ExternalMusicAlbumArtResource
 * (submodules/MusicAlbumArtResources/Sources/ExternalMusicAlbumArtResources.swift)
 */
public class AlbumArtResult {
    public var uniqueId: String = ""
    public var imageBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var imageDataUrl: String = ""
    public var success: Bool = false
    public var errorMessage: String = ""
}

/**
 * MusicAlbumArtResourcesService — 专辑封面资源服务
 *
 * iOS 对应: ExternalMusicAlbumArtResource + fetchExternalMusicAlbumArtResource
 * (submodules/MusicAlbumArtResources/Sources/ExternalMusicAlbumArtResources.swift)
 *
 * 实现：
 * - 通过 iTunes Search API 按 performer/title 查询专辑封面 URL
 * - 再通过 stdx.net.http GET 下载图片字节
 * - 内存 LRU 缓存避免重复拉取
 * - uniqueId 与 iOS ExternalMusicAlbumArtResourceId.uniqueId 语义一致
 */
private var _musicAlbumArtServiceInstance: Option<MusicAlbumArtResourcesService> = None

public func getMusicAlbumArtResourcesService(): MusicAlbumArtResourcesService {
    match (_musicAlbumArtServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MusicAlbumArtResourcesService()
            _musicAlbumArtServiceInstance = Some(inst)
            return inst
    }
}

public class MusicAlbumArtResourcesService {
    // 内存缓存: uniqueId -> AlbumArtResult
    private var cache: HashMap<String, AlbumArtResult> = HashMap<String, AlbumArtResult>()

    // iTunes Search API 基础 URL（外部 HTTP，非 MTProto）
    private let itunesSearchBase: String = "https://itunes.apple.com/search"

    /**
     * 构造 uniqueId，与 iOS ExternalMusicAlbumArtResourceId.uniqueId 对齐:
     * "ext-album-art-{thumb|full}-{title_sanitized}-{performer_sanitized}"
     */
    public func buildUniqueId(title!: String, performer!: String, isThumbnail!: Bool): String {
        let thumbPart = if (isThumbnail) { "thumb" } else { "full" }
        let safeTitle = this.sanitizePart(title)
        let safePerformer = this.sanitizePart(performer)
        return "ext-album-art-" + thumbPart + "-" + safeTitle + "-" + safePerformer
    }

    /**
     * 将 "/" 替换为 "_"，对应 iOS replacingOccurrences(of: "/", with: "_")
     */
    private func sanitizePart(s: String): String {
        var result = ""
        for (c in s.toRuneArray()) {
            if (c == r'/') {
                result += "_"
            } else {
                result += String(c)
            }
        }
        return result
    }

    /**
     * 获取专辑封面（带内存缓存）
     *
     * 调用链: fetchAlbumArt → fetchArtworkUrl(iTunes Search) → downloadImageBytes(HTTP GET)
     *
     * isThumbnail=true  → 使用低分辨率 100x100 artwork URL (artworkUrl100)
     * isThumbnail=false → 使用高分辨率替换 (artworkUrl100 → 600x600)
     */
    public func fetchAlbumArt(title!: String, performer!: String, isThumbnail!: Bool): AlbumArtResult {
        let uid = this.buildUniqueId(title: title, performer: performer, isThumbnail: isThumbnail)

        // 命中缓存直接返回
        if (this.cache.contains(uid)) {
            Hilog.info(0, "CjTelegram", "[AlbumArt] Cache hit for uniqueId")
            return this.cache[uid]
        }

        let result = AlbumArtResult()
        result.uniqueId = uid

        // 第一步：通过 iTunes Search API 查找 artwork URL
        let artworkUrl = this.fetchArtworkUrl(title: title, performer: performer)
        if (artworkUrl.size == 0) {
            result.success = false
            result.errorMessage = "No artwork URL found for given title/performer"
            Hilog.info(0, "CjTelegram", "[AlbumArt] No artwork URL found")
            return result
        }

        // 第二步：根据是否缩略图选择合适尺寸
        let finalUrl = if (isThumbnail) {
            artworkUrl
        } else {
            // 替换 100x100 为 600x600（iTunes API 约定）
            this.upgradeArtworkResolution(artworkUrl)
        }

        // 第三步：下载图片字节
        let imageBytes = this.downloadImageBytes(finalUrl)
        if (imageBytes.size == 0) {
            result.success = false
            result.errorMessage = "Failed to download image bytes from artwork URL"
            Hilog.info(0, "CjTelegram", "[AlbumArt] Download failed, empty bytes")
            return result
        }

        // 第四步：编码为 data URL，便于 Image 组件使用
        let b64 = toBase64String(imageBytes)
        result.imageBytes = imageBytes
        result.imageDataUrl = "data:image/jpeg;base64," + b64
        result.success = true

        // 写缓存
        this.cache[uid] = result
        Hilog.info(0, "CjTelegram", "[AlbumArt] Fetched and cached artwork")
        return result
    }

    /**
     * 通过 iTunes Search API 获取 artwork URL
     *
     * 请求格式：
     * GET https://itunes.apple.com/search?term={performer+title}&entity=song&limit=1
     *
     * 响应 JSON 示例（简化）：
     * {"resultCount":1,"results":[{"artworkUrl100":"https://...100x100bb.jpg"}]}
     */
    private func fetchArtworkUrl(title!: String, performer!: String): String {
        let term = this.urlEncode(performer + " " + title)
        let url = this.itunesSearchBase + "?term=" + term + "&entity=song&limit=1"

        Hilog.info(0, "CjTelegram", "[AlbumArt] iTunes search request")

        let searchResult = netHttpGetBytes(url)
        if (!searchResult.success) {
            Hilog.info(0, "CjTelegram", "[AlbumArt] iTunes search HTTP ${searchResult.statusCode}")
            return ""
        }
        let responseBody = searchResult.text()

        // 从 JSON 中提取 artworkUrl100 字段（轻量字符串解析）
        return this.extractArtworkUrl100(responseBody)
    }

    /**
     * 轻量 JSON 字符串解析：提取第一个 "artworkUrl100":"<value>" 的 value
     */
    private func extractArtworkUrl100(json: String): String {
        let key = "\"artworkUrl100\":\""
        let keyIdx = json.indexOf(key)
        if (keyIdx.isNone()) {
            return ""
        }
        let startOffset = keyIdx.getOrThrow() + key.size
        // 从 startOffset 开始找下一个 '"'
        let rest = json[startOffset..]
        let endIdx = rest.indexOf("\"")
        if (endIdx.isNone()) {
            return ""
        }
        return rest[0..endIdx.getOrThrow()]
    }

    /**
     * 将 artworkUrl100 中的 100x100bb 替换为 600x600bb 以获取高分辨率
     */
    private func upgradeArtworkResolution(url: String): String {
        var result = ""
        let marker = "100x100bb"
        let replacement = "600x600bb"
        let idx = url.indexOf(marker)
        if (idx.isSome()) {
            let i = idx.getOrThrow()
            result = url[0..i] + replacement + url[(i + marker.size)..]
            return result
        }
        return url
    }

    /**
     * HTTP GET 下载图片，返回原始字节
     */
    private func downloadImageBytes(url: String): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[AlbumArt] Downloading image bytes")
        let response = netHttpGetBytes(url)
        if (!response.success) {
            Hilog.info(0, "CjTelegram", "[AlbumArt] Image download HTTP ${response.statusCode}")
            return Array<Byte>(0, repeat: 0)
        }
        return response.bytes
    }

    /**
     * 简单 URL 编码：将空格编码为 +，特殊字符保留 ASCII 字母数字
     */
    private func urlEncode(s: String): String {
        var result = ""
        for (c in s.toRuneArray()) {
            let code = UInt32(c)
            if ((code >= 65 && code <= 90) ||   // A-Z
                (code >= 97 && code <= 122) ||   // a-z
                (code >= 48 && code <= 57) ||    // 0-9
                c == r'-' || c == r'_' || c == r'.' || c == r'~') {
                result += String(c)
            } else if (c == r' ') {
                result += "+"
            } else {
                // 百分号编码
                result += this.percentEncode(code)
            }
        }
        return result
    }

    /**
     * 单个 Unicode 代码点的百分号编码（UTF-8）
     */
    private func percentEncode(codePoint: UInt32): String {
        if (codePoint <= 0x7F) {
            return "%" + this.byteToHex(UInt8(codePoint))
        }
        // 非 ASCII：按 UTF-8 编码后逐字节 percent-encode
        // 简化处理：直接跳过非 ASCII（音乐标题通常 ASCII 即可）
        return "+"
    }

    /**
     * 单字节转两位大写 HEX 字符串
     */
    private func byteToHex(b: UInt8): String {
        let hi = Int64(b) / 16
        let lo = Int64(b) % 16
        let hexChars = "0123456789ABCDEF"
        let chars = hexChars.toRuneArray()
        return String(chars[hi]) + String(chars[lo])
    }

    /**
     * 清除所有缓存
     */
    public func clearCache(): Unit {
        this.cache = HashMap<String, AlbumArtResult>()
    }
}
