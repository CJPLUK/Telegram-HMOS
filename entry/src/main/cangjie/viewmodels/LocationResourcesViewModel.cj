package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*

/**
 * LocationResourcesViewModel — 地图静态快照 + 场所图标资源视图模型
 *
 * iOS 对应:
 *   submodules/LocationResources/Sources/MapResources.swift
 *   - MapSnapshotMediaResource + chatMapSnapshotData / chatMapSnapshotImage
 *
 *   submodules/LocationResources/Sources/VenueIconResources.swift
 *   - VenueIconResource + fetchVenueIconResource / venueIconData
 *
 * P2-235 地图静态快照职责:
 *   - 接受地图坐标与尺寸参数，异步拉取静态地图图片
 *   - 管理加载状态（isLoading / lastError）和结果路径（snapshotPath）
 *   - 委托 LocationResourcesService 完成 URL 构造、HTTP 下载、磁盘缓存
 *   - 向 UI 层暴露 file:// 路径供 Image 组件直接使用
 *
 * P2-236 场所图标资源职责:
 *   - 接受 Foursquare 场所类别类型，异步拉取 PNG 图标
 *   - 管理场所图标加载状态（isLoadingIcon / iconError）和结果路径（venueIconPath）
 *   - 委托 LocationResourcesService 完成 CDN URL 构造、HTTP 下载、磁盘缓存
 *   - 向 UI 层暴露 file:// 路径供 Image 组件直接使用
 *
 * 调用链（P2-235 完整）:
 *   fetchSnapshot(lat, lng, width, height)
 *     → spawn
 *       → LocationResourcesService.fetchMapSnapshot(lat, lng, width, height)
 *         → deriveMapCacheKey(lat, lng, width, height)
 *         → getCachedSnapshotPath(cacheKey)      [磁盘缓存命中则直接返回]
 *         → buildStaticMapUrl(lat, lng, w, h)    [构造 OSM staticmap URL]
 *         → downloadImageBytes(url)               [stdx.net.http GET]
 *         → saveSnapshotData(cacheKey, bytes)     [FileIo write 到磁盘]
 *       → this.snapshotPath / this.lastResult 更新
 *
 * 调用链（P2-236 完整）:
 *   fetchVenueIcon(type_)
 *     → spawn
 *       → LocationResourcesService.fetchVenueIconResource(type_)
 *         → deriveVenueIconCacheKey(type_)
 *         → getVenueIconCachedPath(cacheKey)     [磁盘缓存命中则直接返回]
 *         → buildVenueIconUrl(type_)             [Foursquare CDN URL]
 *         → downloadImageBytes(url)               [stdx.net.http HTTPS GET]
 *         → saveVenueIconData(cacheKey, bytes)    [FileIo write 到磁盘]
 *       → this.venueIconPath / this.lastIconResult 更新
 */
@Observed
public class LocationResourcesViewModel {

    /** 最近一次成功获取的快照本地路径（file:// 前缀）；空字符串表示未加载 */
    @Publish public var snapshotPath: String = ""

    /** 最近一次下载结果的完整信息 */
    @Publish public var lastResult: MapSnapshotResult = MapSnapshotResult()

    /** 是否正在加载地图快照 */
    @Publish public var isLoading: Bool = false

    /** 最近一次错误描述（空字符串 = 无错误） */
    @Publish public var lastError: String = ""

    /** 当前已请求的缓存键（用于 UI 识别对应的图片） */
    @Publish public var currentCacheKey: String = ""

    /** 是否已完成至少一次成功加载 */
    @Publish public var hasLoaded: Bool = false

    /** P2-236: 最近一次成功获取的场所图标本地路径（file:// 前缀）；空字符串表示未加载 */
    @Publish public var venueIconPath: String = ""

    /** P2-236: 最近一次场所图标下载结果 */
    @Publish public var lastIconResult: VenueIconResult = VenueIconResult()

    /** P2-236: 是否正在加载场所图标 */
    @Publish public var isLoadingIcon: Bool = false

    /** P2-236: 场所图标最近一次错误描述（空字符串 = 无错误） */
    @Publish public var iconError: String = ""

    /** P2-236: 当前场所图标类型 */
    @Publish public var currentIconType: String = ""

    /** P2-236: 是否已完成至少一次场所图标成功加载 */
    @Publish public var hasLoadedIcon: Bool = false

    // ── 核心方法 ─────────────────────────────────────────────────

    /**
     * 异步获取地图静态快照（缓存 → HTTP 下载 → 写盘 → 更新 UI 状态）
     *
     * 对应 iOS chatMapSnapshotData(engine:resource:) 的客户端调用入口。
     *
     * @param lat    纬度（对应 iOS MapSnapshotMediaResource.latitude）
     * @param lng    经度（对应 iOS MapSnapshotMediaResource.longitude）
     * @param width  快照宽度像素（对应 iOS resource.width）
     * @param height 快照高度像素（对应 iOS resource.height）
     * @param zoom   缩放级别（默认 15，对应 iOS adjustGMapLatitude zoom=15）
     */
    public func fetchSnapshot(lat: Float64, lng: Float64, width: Int32, height: Int32, zoom!: Int32 = 15): Unit {
        if (this.isLoading) {
            Hilog.info(0, "CjTelegram", "[LocationResVM] fetchSnapshot: already loading, skip")
            return
        }
        this.isLoading = true
        this.lastError = ""
        let service = getLocationResourcesService()
        let cacheKey = service.deriveMapCacheKey(lat, lng, width, height)
        this.currentCacheKey = cacheKey
        Hilog.info(0, "CjTelegram", "[LocationResVM] fetchSnapshot: start key=" + cacheKey)
        let _ = spawn {
            let result = service.fetchMapSnapshot(lat, lng, width, height, zoom: zoom)
            let resultSuccess = result.success
            let resultLocalPath = result.localPath
            let resultErrorMessage = result.errorMessage
            launch {
                this.isLoading = false
                this.lastResult = result
                if (resultSuccess) {
                    this.snapshotPath = resultLocalPath
                    this.hasLoaded = true
                    Hilog.info(0, "CjTelegram", "[LocationResVM] fetchSnapshot: ok path=" + resultLocalPath)
                } else {
                    this.lastError = resultErrorMessage
                    Hilog.info(0, "CjTelegram", "[LocationResVM] fetchSnapshot: failed=" + resultErrorMessage)
                }
            }
        }
    }

    /**
     * 检查指定坐标的快照是否已有本地缓存
     *
     * @param lat    纬度
     * @param lng    经度
     * @param width  快照宽度
     * @param height 快照高度
     * @return 本地缓存路径（file:// 前缀）；无缓存时返回空字符串
     */
    public func getCachedPath(lat: Float64, lng: Float64, width: Int32, height: Int32): String {
        let service = getLocationResourcesService()
        let key = service.deriveMapCacheKey(lat, lng, width, height)
        return service.getCachedSnapshotPath(key)
    }

    /**
     * 清除内存缓存（磁盘文件保留）
     *
     * 适用于内存紧张时主动释放内存缓存，不影响下次冷启动的磁盘缓存命中。
     */
    public func clearMemoryCache(): Unit {
        let service = getLocationResourcesService()
        service.clearMemoryCache()
        Hilog.info(0, "CjTelegram", "[LocationResVM] clearMemoryCache done")
    }

    /**
     * 重置视图模型状态（不清除磁盘缓存）
     *
     * 适用于 UI 切换到不同坐标时清空旧状态，再调用 fetchSnapshot。
     */
    public func reset(): Unit {
        this.snapshotPath = ""
        this.lastError = ""
        this.isLoading = false
        this.hasLoaded = false
        this.currentCacheKey = ""
        this.lastResult = MapSnapshotResult()
    }

    // ── P2-236 场所图标方法 ───────────────────────────────────────

    /**
     * 异步获取场所图标（缓存 → HTTP 下载 → 写盘 → 更新 UI 状态）
     *
     * 对应 iOS venueIconData(engine:resource:) 的客户端调用入口。
     * Foursquare CDN URL: https://ss3.4sqi.net/img/categories_v2/{type}_88.png
     *
     * @param type_ Foursquare 场所类别字符串（对应 iOS VenueIconResource.type）
     */
    public func fetchVenueIcon(type_: String): Unit {
        if (this.isLoadingIcon) {
            Hilog.info(0, "CjTelegram", "[LocationResVM] fetchVenueIcon: already loading, skip")
            return
        }
        this.isLoadingIcon = true
        this.iconError = ""
        this.currentIconType = type_
        Hilog.info(0, "CjTelegram", "[LocationResVM] fetchVenueIcon: start type=" + type_)
        let service = getLocationResourcesService()
        let _ = spawn {
            let result = service.fetchVenueIconResource(type_)
            let resultSuccess = result.success
            let resultLocalPath = result.localPath
            let resultErrorMessage = result.errorMessage
            launch {
                this.isLoadingIcon = false
                this.lastIconResult = result
                if (resultSuccess) {
                    this.venueIconPath = resultLocalPath
                    this.hasLoadedIcon = true
                    Hilog.info(0, "CjTelegram", "[LocationResVM] fetchVenueIcon: ok path=" + resultLocalPath)
                } else {
                    this.iconError = resultErrorMessage
                    Hilog.info(0, "CjTelegram", "[LocationResVM] fetchVenueIcon: failed=" + resultErrorMessage)
                }
            }
        }
    }

    /**
     * 检查指定类型的场所图标是否已有本地缓存
     *
     * @param type_ Foursquare 场所类别字符串
     * @return 本地缓存路径（file:// 前缀）；无缓存时返回空字符串
     */
    public func getCachedVenueIconPath(type_: String): String {
        let service = getLocationResourcesService()
        let key = service.deriveVenueIconCacheKey(type_)
        return service.getVenueIconCachedPath(key)
    }

    /**
     * 重置场所图标视图模型状态（不清除磁盘缓存）
     */
    public func resetIcon(): Unit {
        this.venueIconPath = ""
        this.iconError = ""
        this.isLoadingIcon = false
        this.hasLoadedIcon = false
        this.currentIconType = ""
        this.lastIconResult = VenueIconResult()
    }
}
