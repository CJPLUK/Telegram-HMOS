package ohos_app_cangjie_entry.viewmodels

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*

/**
 * InstantPageCacheViewModel — Instant View 页面缓存视图模型
 *
 * 对应 iOS InstantPageCache/Sources/CachedInstantPages.swift 的上层调用方
 *
 * 职责：
 * - 封装 InstantPageCacheService 的缓存 get/put/remove 操作
 * - 对调用方暴露 getCachedPage / updateCachedPage / removeCachedPage / isFresh
 * - 维护当前 URL 对应的缓存内容状态（cachedContent / hasFreshCache）
 */
public class InstantPageCacheViewModel {
    // 当前被访问的 URL
    public var currentUrl: String = ""
    // 当前 URL 对应的缓存页面内容（空串表示未命中）
    public var cachedContent: String = ""
    // 当前 URL 的缓存是否在 TTL 内
    public var hasFreshCache: Bool = false
    // 缓存操作是否进行中
    public var isLoading: Bool = false

    private var service: InstantPageCacheService = getInstantPageCacheService()

    /**
     * 查询指定 URL 的缓存内容
     * 命中时更新 cachedContent 和 hasFreshCache；未命中时清空 cachedContent
     */
    public func getCachedPage(url: String): Option<String> {
        this.currentUrl = url
        this.isLoading = true
        let entry = this.service.getCachedPage(url)
        match (entry) {
            case Some(e) =>
                this.cachedContent = e.content
                this.hasFreshCache = this.service.isFresh(url)
                this.isLoading = false
                Hilog.info(0, "CjTelegram", "[InstantPageCacheVM] cache hit")
                return Some(e.content)
            case None =>
                this.cachedContent = ""
                this.hasFreshCache = false
                this.isLoading = false
                Hilog.info(0, "CjTelegram", "[InstantPageCacheVM] cache miss")
                return None
        }
    }

    /**
     * 写入或更新指定 URL 的缓存页面内容
     * content 为空字符串时等效于 removeCachedPage
     */
    public func updateCachedPage(url: String, content: String): Unit {
        this.service.updateCachedPage(url, content)
        if (url == this.currentUrl) {
            this.cachedContent = content
            this.hasFreshCache = content.size > 0
        }
        Hilog.info(0, "CjTelegram", "[InstantPageCacheVM] updated cache")
    }

    /**
     * 移除指定 URL 的缓存条目
     */
    public func removeCachedPage(url: String): Unit {
        this.service.removeCachedPage(url)
        if (url == this.currentUrl) {
            this.cachedContent = ""
            this.hasFreshCache = false
        }
        Hilog.info(0, "CjTelegram", "[InstantPageCacheVM] removed cache")
    }

    /**
     * 判断指定 URL 的缓存是否仍在 TTL（12 小时）内
     */
    public func isFresh(url: String): Bool {
        return this.service.isFresh(url)
    }

    /**
     * 获取当前内存缓存条目数（调试用）
     */
    public func cacheSize(): Int64 {
        return this.service.cacheSize()
    }

    /**
     * 清空内存缓存
     */
    public func clearMemoryCache(): Unit {
        this.service.clearMemoryCache()
        this.cachedContent = ""
        this.hasFreshCache = false
        Hilog.info(0, "CjTelegram", "[InstantPageCacheVM] memory cache cleared")
    }
}
