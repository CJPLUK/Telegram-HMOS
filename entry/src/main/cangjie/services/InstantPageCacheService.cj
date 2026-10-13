package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.HashMap
import std.time.DateTime

/**
 * InstantPageCacheService — Instant View 页面缓存服务
 *
 * 对应 iOS InstantPageCache/Sources/CachedInstantPages.swift
 *
 * 功能:
 * - 内存层缓存已加载的 Instant View 页面内容（避免重复拉取）
 * - TTL 12 小时（对应 iOS refreshTimeout = 60 * 60 * 12）
 * - URL 作为 key，缓存页面正文内容 + 时间戳
 * - 提供 get / put / remove / isFresh 操作
 * - 委托 ItemCacheService 做持久化（Preferences 层）
 *
 * 注意：此 feature 纯属缓存层，不直接发起 TL/MTProto 请求（N/A 说明：
 * iOS CachedInstantPages.swift 本身只做 itemCache get/put，
 * TL 网络请求由上层 cachedInternalInstantPage 内的 resolveInstantViewUrl 负责，
 * 不属于本 feature 范围）。
 */

private let REFRESH_TIMEOUT_SECONDS: Int64 = 43200  // 60 * 60 * 12，对应 iOS refreshTimeout

private var _instantPageCacheServiceInstance: Option<InstantPageCacheService> = None

public func getInstantPageCacheService(): InstantPageCacheService {
    match (_instantPageCacheServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = InstantPageCacheService()
            _instantPageCacheServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 缓存条目：存储页面内容字符串 + 缓存时间戳（Unix 秒）
 */
public class CachedInstantPageEntry {
    public var url: String
    public var content: String
    public var timestamp: Int64

    public init(url: String, content: String, timestamp: Int64) {
        this.url = url
        this.content = content
        this.timestamp = timestamp
    }
}

public class InstantPageCacheService {
    // 内存缓存：url -> entry
    private var cache = HashMap<String, CachedInstantPageEntry>()

    /**
     * 获取指定 URL 的缓存条目（不论新鲜度）
     * 返回 None 表示缓存未命中
     */
    public func getCachedPage(url: String): Option<CachedInstantPageEntry> {
        let trimmedUrl = instPageStripAnchor(url)
        if (this.cache.contains(trimmedUrl)) {
            match (this.cache.get(trimmedUrl)) {
                case Some(entry) =>
                    Hilog.info(0, "CjTelegram", "[InstantPageCache] cache hit for url")
                    return Some(entry)
                case None => return None
            }
        }
        // 尝试从持久化层恢复
        let itemCache = getTelegramEngineItemCacheService()
        let persistedContent = itemCache.get("ipc:" + trimmedUrl)
        match (persistedContent) {
            case Some(combined) =>
                let sepIdx = instPageFindSeparator(combined, "||")
                if (sepIdx >= 0) {
                    let runes = combined.toRuneArray()
                    let tsStr = String(runes[0..sepIdx])
                    let pageContent = String(runes[(sepIdx + 2)..runes.size])
                    let ts = instPageParseInt64(tsStr)
                    match (ts) {
                        case Some(t) =>
                            let entry = CachedInstantPageEntry(trimmedUrl, pageContent, t)
                            this.cache[trimmedUrl] = entry
                            Hilog.info(0, "CjTelegram", "[InstantPageCache] restored from persistent cache")
                            return Some(entry)
                        case None => return None
                    }
                } else {
                    return None
                }
            case None => return None
        }
    }

    /**
     * 判断指定 URL 的缓存是否仍在 TTL 内（12 小时）
     */
    public func isFresh(url: String): Bool {
        let trimmedUrl = instPageStripAnchor(url)
        match (this.getCachedPage(trimmedUrl)) {
            case Some(entry) =>
                let nowSeconds = DateTime.now().toUnixTimeStamp().toSeconds()
                let age = nowSeconds - entry.timestamp
                return age < REFRESH_TIMEOUT_SECONDS
            case None => return false
        }
    }

    /**
     * 更新（写入）缓存：存储页面内容，时间戳设为当前时间
     * content 为空字符串时视为清除操作
     */
    public func updateCachedPage(url: String, content: String): Unit {
        let trimmedUrl = instPageStripAnchor(url)
        if (content.size == 0) {
            this.removeCachedPage(trimmedUrl)
            return
        }
        let nowSeconds = DateTime.now().toUnixTimeStamp().toSeconds()
        let entry = CachedInstantPageEntry(trimmedUrl, content, nowSeconds)
        this.cache[trimmedUrl] = entry
        // 持久化到 ItemCacheService
        let itemCache = getTelegramEngineItemCacheService()
        let combined = nowSeconds.toString() + "||" + content
        itemCache.put("ipc:" + trimmedUrl, combined)
        Hilog.info(0, "CjTelegram", "[InstantPageCache] cached page for url")
    }

    /**
     * 移除指定 URL 的缓存条目（内存 + 持久化层）
     */
    public func removeCachedPage(url: String): Unit {
        let trimmedUrl = instPageStripAnchor(url)
        this.cache.remove(trimmedUrl)
        let itemCache = getTelegramEngineItemCacheService()
        itemCache.remove("ipc:" + trimmedUrl)
        Hilog.info(0, "CjTelegram", "[InstantPageCache] removed cache for url")
    }

    /**
     * 清空所有内存缓存（不清持久化层）
     */
    public func clearMemoryCache(): Unit {
        this.cache.clear()
        Hilog.info(0, "CjTelegram", "[InstantPageCache] memory cache cleared")
    }

    /**
     * 获取当前内存缓存条目数量
     */
    public func cacheSize(): Int64 {
        return this.cache.size
    }
}

// ───────────────────────────── 模块级辅助函数 ─────────────────────────────

/**
 * 从 URL 中去除 # 锚点部分（对应 iOS extractAnchor）
 */
private func instPageStripAnchor(url: String): String {
    let runes = url.toRuneArray()
    var hashIdx: Int64 = -1
    var i: Int64 = 0
    for (r in runes) {
        if (r == r'#') {
            hashIdx = i
            break
        }
        i += 1
    }
    if (hashIdx <= 0) {
        return url
    }
    return String(runes[0..hashIdx])
}

/**
 * 在字符串 s 中查找子串 sep 的首个出现位置（按 Rune 索引）
 * 返回 -1 表示未找到
 */
private func instPageFindSeparator(s: String, sep: String): Int64 {
    let sRunes = s.toRuneArray()
    let sepRunes = sep.toRuneArray()
    let sLen = sRunes.size
    let sepLen = sepRunes.size
    if (sepLen == 0 || sLen < sepLen) {
        return -1
    }
    var i: Int64 = 0
    while (i <= sLen - sepLen) {
        var matched = true
        var j: Int64 = 0
        while (j < sepLen) {
            if (sRunes[i + j] != sepRunes[j]) {
                matched = false
                break
            }
            j += 1
        }
        if (matched) {
            return i
        }
        i += 1
    }
    return -1
}

/**
 * 解析 Int64 字符串（仅处理非负十进制）
 */
private func instPageParseInt64(s: String): Option<Int64> {
    if (s.size == 0) {
        return None
    }
    var result: Int64 = 0
    for (r in s.toRuneArray()) {
        let c = UInt32(r)
        if (c < 48 || c > 57) {
            return None
        }
        result = result * 10 + Int64(c - 48)
    }
    return Some(result)
}
