package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.net.{netHttpGetBytes, netHttpPostText}
import kit.CoreFileKit.*
import std.collection.HashMap
import std.math.*
import kit.ImageKit.*

import std.collection.ArrayList

// 同包的 LocationDistanceService 已有一个文件私有的 PI，这里另起名避免歧义
private let MAP_PI: Float64 = 3.141592653589793

/**
 * LocationResourcesService — 地图静态快照 + 场所图标资源服务
 *
 * iOS 对应:
 *   submodules/LocationResources/Sources/MapResources.swift
 *   - MapSnapshotMediaResourceId / MapSnapshotMediaResource
 *   - fetchMapSnapshotResource / chatMapSnapshotData
 *
 *   submodules/LocationResources/Sources/VenueIconResources.swift
 *   - VenueIconResourceId / VenueIconResource
 *   - fetchVenueIconResource / venueIconData
 *
 * P2-235 地图静态快照:
 *   - 按 (纬度, 经度, 宽, 高, 缩放) 构造静态地图图片 URL
 *   - HTTP GET 下载地图图片字节
 *   - 磁盘缓存写入 <filesDir>/map_snapshots/map-{lat}-{lng}-{w}x{h}
 *   - 缓存键派生与 iOS MapSnapshotMediaResourceId.uniqueId 对齐:
 *     "map-{latitude}-{longitude}-{width}x{height}"
 *   - iOS 使用 MKMapSnapshotter 进程内渲染; HarmonyOS 无对应 API,
 *     改用 OSM staticmap 公共 HTTP 服务（真实 URL + fetch）。
 *
 * P2-236 场所图标资源:
 *   - 按 Foursquare 类别类型构造 CDN 图标 URL
 *     https://ss3.4sqi.net/img/categories_v2/{type}_88.png
 *   - HTTP GET 下载 PNG 图标字节
 *   - 磁盘缓存写入 <filesDir>/venue_icons/venue-icon-{type}
 *   - 缓存键与 iOS VenueIconResourceId.uniqueId 对齐:
 *     "venue-icon-{type.replace('/', '_')}"
 *
 * MTProto 说明: N/A (两者均通过公共 HTTP 接口获取)
 *
 * 调用链（P2-235 完整）:
 *   LocationResourcesViewModel.fetchSnapshot(lat, lng, width, height)
 *     → LocationResourcesService.fetchMapSnapshot(lat, lng, width, height)
 *       → deriveMapCacheKey(lat, lng, width, height)
 *       → getCachedSnapshotPath(cacheKey)  [命中则直接返回]
 *       → buildStaticMapUrl(lat, lng, width, height, zoom)
 *       → downloadImageBytes(url)           [HTTP GET via ohos.net.http]
 *       → saveSnapshotData(cacheKey, bytes) [FileIo write 到磁盘]
 *       → 返回 "file://<path>"
 *
 * 调用链（P2-236 完整）:
 *   LocationResourcesViewModel.fetchVenueIcon(type)
 *     → LocationResourcesService.fetchVenueIconResource(type)
 *       → deriveVenueIconCacheKey(type)
 *       → getVenueIconCachedPath(cacheKey)  [命中则直接返回]
 *       → buildVenueIconUrl(type)
 *       → downloadImageBytes(url)            [HTTP GET via ohos.net.http]
 *       → saveVenueIconData(cacheKey, bytes) [FileIo write 到磁盘]
 *       → 返回 VenueIconResult
 */

// ─────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────

/**
 * 地图快照资源标识符
 *
 * 对应 iOS MapSnapshotMediaResourceId:
 *   uniqueId = "map-\(latitude)-\(longitude)-\(width)x\(height)"
 */
public class MapSnapshotResourceId {
    public var latitude: Float64 = 0.0
    public var longitude: Float64 = 0.0
    public var width: Int32 = 0
    public var height: Int32 = 0

    public init(lat: Float64, lng: Float64, w: Int32, h: Int32) {
        this.latitude = lat
        this.longitude = lng
        this.width = w
        this.height = h
    }

    /**
     * 唯一标识字符串，与 iOS MapSnapshotMediaResourceId.uniqueId 对齐
     * 格式: "map-{lat}-{lng}-{w}x{h}"
     */
    public func uniqueId(): String {
        return "map-" + this.latitude.toString() + "-" + this.longitude.toString() +
               "-" + this.width.toString() + "x" + this.height.toString()
    }
}

/**
 * 地图快照请求结果
 */
public class MapSnapshotResult {
    /** 是否成功 */
    public var success: Bool = false
    /** 本地缓存文件路径（file:// 前缀） */
    public var localPath: String = ""
    /** 图片字节（可选，内存中） */
    public var imageBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    /** 错误信息 */
    public var errorMessage: String = ""
    /** 对应缓存键 */
    public var cacheKey: String = ""

    public init() {}

    public static func ok(path: String, key: String, bytes: Array<Byte>): MapSnapshotResult {
        let r = MapSnapshotResult()
        r.success = true
        r.localPath = path
        r.cacheKey = key
        r.imageBytes = bytes
        return r
    }

    public static func fail(message: String): MapSnapshotResult {
        let r = MapSnapshotResult()
        r.success = false
        r.errorMessage = message
        return r
    }
}

// ─────────────────────────────────────────────────────────────────
// P2-236 场所图标资源数据模型
// ─────────────────────────────────────────────────────────────────

/**
 * 场所图标资源标识符
 *
 * 对应 iOS VenueIconResourceId:
 *   uniqueId = "venue-icon-\(type.replacingOccurrences(of: "/", with: "_"))"
 */
public class VenueIconResourceId {
    public var venueType: String = ""

    public init(venueType: String) {
        this.venueType = venueType
    }

    /**
     * 唯一标识字符串，与 iOS VenueIconResourceId.uniqueId 对齐
     * 格式: "venue-icon-{type.replace('/', '_')}"
     */
    public func uniqueId(): String {
        return "venue-icon-" + this.venueType.replace("/", "_")
    }
}

/**
 * 场所图标资源描述符
 *
 * 对应 iOS VenueIconResource (type: String)
 * Foursquare 图标 CDN: https://ss3.4sqi.net/img/categories_v2/{type}_88.png
 */
public class VenueIconResource {
    public var venueType: String = ""

    public init(venueType: String) {
        this.venueType = venueType
    }

    /**
     * 构造 Foursquare CDN 图标 URL
     * 对应 iOS: "https://ss3.4sqi.net/img/categories_v2/\(resource.type)_88.png"
     *
     * @return 完整 HTTPS URL 字符串
     */
    public func iconUrl(): String {
        return "https://ss3.4sqi.net/img/categories_v2/" + this.venueType + "_88.png"
    }

    /**
     * 缓存键 (与 VenueIconResourceId.uniqueId 对齐)
     */
    public func cacheKey(): String {
        let rid = VenueIconResourceId(this.venueType)
        return rid.uniqueId()
    }
}

/**
 * 场所图标资源获取结果
 */
public class VenueIconResult {
    /** 是否成功 */
    public var success: Bool = false
    /** 本地缓存文件路径（file:// 前缀） */
    public var localPath: String = ""
    /** 图标字节（可选，内存中） */
    public var imageBytes: Array<Byte> = Array<Byte>(0, repeat: 0)
    /** 错误信息 */
    public var errorMessage: String = ""
    /** 对应缓存键 */
    public var cacheKey: String = ""
    /** 图标场所类型 (对应 iOS VenueIconResource.type) */
    public var venueType: String = ""

    public init() {}

    public static func ok(path: String, key: String, venueType: String, bytes: Array<Byte>): VenueIconResult {
        let r = VenueIconResult()
        r.success = true
        r.localPath = path
        r.cacheKey = key
        r.venueType = venueType
        r.imageBytes = bytes
        return r
    }

    public static func fail(message: String): VenueIconResult {
        let r = VenueIconResult()
        r.success = false
        r.errorMessage = message
        return r
    }
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _locationResourcesServiceInstance: Option<LocationResourcesService> = None

/** 获取 LocationResourcesService 单例 */
public func getLocationResourcesService(): LocationResourcesService {
    match (_locationResourcesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LocationResourcesService()
            _locationResourcesServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// LocationResourcesService
// ─────────────────────────────────────────────────────────────────

/**
 * LocationResourcesService — 地图静态快照资源服务
 *
 * 通过 OSM staticmap 兼容 HTTP 接口获取地图图片并缓存到本地磁盘。
 * 对应 iOS MapSnapshotMediaResource + fetchMapSnapshotResource 逻辑:
 *   iOS 使用 MKMapSnapshotter 在设备本地渲染地图，
 *   HarmonyOS 无对应 API，改用公共静态地图 HTTP 服务获取等效图片。
 */
public class LocationResourcesService {

    // OSM 瓦片服务（公共服务，无需 API Key）。
    // 原来用的两个 staticmap 聚合服务（staticmap.openstreetmap.de / .fr）都已下线，
    // 真机上直接是 DNS 解析失败（NetStack 2300006），所以改成自己取瓦片本地拼图。
    private let tileBase: String = "https://tile.openstreetmap.org"
    // OSM 瓦片使用政策要求带可识别的 User-Agent，缺省 UA 会被拒
    private let tileUserAgent: String = "TelegramCangjie/1.0 (HarmonyOS)"

    // 默认缩放级别（对应 iOS adjustGMapLatitude zoom=15）
    private let defaultZoom: Int32 = 15

    // 内存缓存: cacheKey -> file:// path
    private var memCache: HashMap<String, String> = HashMap<String, String>()

    /**
     * 构造缓存键，与 iOS MapSnapshotMediaResourceId.uniqueId 对齐
     *
     * @param lat    纬度
     * @param lng    经度
     * @param width  图片宽度（像素）
     * @param height 图片高度（像素）
     * @return "map-{lat}-{lng}-{w}x{h}"
     */
    public func deriveMapCacheKey(lat: Float64, lng: Float64, width: Int32, height: Int32): String {
        return "map-" + lat.toString() + "-" + lng.toString() +
               "-" + width.toString() + "x" + height.toString()
    }

    /**
     * 单张瓦片的 URL（Web 墨卡托 XYZ 方案）
     */
    public func buildTileUrl(zoom: Int32, tileX: Int64, tileY: Int64): String {
        return this.tileBase + "/" + zoom.toString() + "/" + tileX.toString() + "/" + tileY.toString() + ".png"
    }

    /**
     * 经纬度 → 该缩放级别下的世界像素坐标（Web 墨卡托，256px 瓦片）
     *
     * 与 iOS MKMapSnapshotter 的取景等价：以该点为中心裁出 width×height 的窗口。
     */
    private func lngToWorldPx(lng: Float64, zoom: Int32): Float64 {
        let worldPx = 256.0 * pow(2.0, Float64(zoom))
        return (lng + 180.0) / 360.0 * worldPx
    }

    private func latToWorldPx(lat: Float64, zoom: Int32): Float64 {
        let worldPx = 256.0 * pow(2.0, Float64(zoom))
        var clamped = lat
        // 墨卡托在极区发散，按 OSM 惯例夹到 ±85.05112878
        if (clamped > 85.05112878) { clamped = 85.05112878 }
        if (clamped < -85.05112878) { clamped = -85.05112878 }
        let latRad = clamped * MAP_PI / 180.0
        return (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / MAP_PI) / 2.0 * worldPx
    }

    /**
     * 查询本地磁盘缓存路径（不触发下载）
     *
     * @param cacheKey 由 deriveMapCacheKey 派生
     * @return file:// 路径；若无缓存返回空字符串
     */
    public func getCachedSnapshotPath(cacheKey: String): String {
        if (this.memCache.contains(cacheKey)) {
            return this.memCache[cacheKey]
        }
        let path = this.buildSnapshotFilePath(cacheKey)
        if (path.size == 0) { return "" }
        var exists = false
        try {
            exists = FileIo.access(path)
        } catch (_: Exception) {
            exists = false
        }
        if (exists) {
            let uri = "file://" + path
            this.memCache[cacheKey] = uri
            return uri
        }
        return ""
    }

    /**
     * 获取地图静态快照（缓存 → HTTP 下载 → 写盘）
     *
     * 调用链:
     *   fetchMapSnapshot → getCachedSnapshotPath [命中则直接返回]
     *                    → composeTileSnapshot (取 OSM 瓦片 → 拼图 → JPEG)
     *                    → saveSnapshotData (FileIo write)
     *                    → 返回 file:// URI
     *
     * @param lat    纬度
     * @param lng    经度
     * @param width  快照宽度（像素，对应 iOS resource.width）
     * @param height 快照高度（像素，对应 iOS resource.height）
     * @param zoom   缩放级别（默认 15，对应 iOS zoom=15）
     * @return MapSnapshotResult（success=true 时 localPath 有效）
     */
    public func fetchMapSnapshot(lat: Float64, lng: Float64, width: Int32, height: Int32, zoom!: Int32 = 15): MapSnapshotResult {
        let key = this.deriveMapCacheKey(lat, lng, width, height)

        // 1. 系统地图（HMS Map Kit staticMap，ArkTS 侧渲染）优先：本会话内存缓存 → 调 Map Kit
        //    （ArkTS 侧对同参数图片有文件级复用）。放在 OSM 磁盘缓存之前，旧的 OSM 快照才会被替换。
        let sysKey = "sys:" + key
        if (this.memCache.contains(sysKey)) {
            return MapSnapshotResult.ok(this.memCache[sysKey], key, Array<Byte>(0, repeat: 0))
        }
        let sysPath = getMapKitBridgeService().fetchSystemMapImage(lat, lng, width, height, zoom)
        if (sysPath.size > 0) {
            let sysUri = "file://" + sysPath
            this.memCache[sysKey] = sysUri
            Hilog.info(0, "CjTelegram", "[LocationRes] fetchMapSnapshot: system map key=" + key)
            return MapSnapshotResult.ok(sysUri, key, Array<Byte>(0, repeat: 0))
        }

        // 2. Map Kit 不可用：OSM 磁盘缓存
        let cached = this.getCachedSnapshotPath(key)
        if (cached.size > 0) {
            Hilog.info(0, "CjTelegram", "[LocationRes] fetchMapSnapshot: cache hit key=" + key)
            return MapSnapshotResult.ok(cached, key, Array<Byte>(0, repeat: 0))
        }

        // 3. 取瓦片并拼出以该点为中心的窗口
        Hilog.info(0, "CjTelegram", "[LocationRes] fetchMapSnapshot: composing snapshot key=" + key)
        let bytes = this.composeTileSnapshot(lat, lng, width, height, zoom)
        if (bytes.size == 0) {
            Hilog.info(0, "CjTelegram", "[LocationRes] fetchMapSnapshot: compose failed, empty bytes")
            return MapSnapshotResult.fail("Failed to download map snapshot: empty response")
        }

        // 4. 写入磁盘缓存
        let localPath = this.saveSnapshotData(key, bytes)
        if (localPath.size == 0) {
            Hilog.info(0, "CjTelegram", "[LocationRes] fetchMapSnapshot: disk write failed")
            return MapSnapshotResult.fail("Failed to save map snapshot to disk")
        }

        let uri = "file://" + localPath
        this.memCache[key] = uri
        Hilog.info(0, "CjTelegram", "[LocationRes] fetchMapSnapshot: saved to " + localPath)
        return MapSnapshotResult.ok(uri, key, bytes)
    }

    /**
     * 取 OSM 瓦片拼出以 (lat,lng) 为中心、width×height 的快照，编码为 JPEG 字节。
     *
     * 没有系统级 Map Kit，也没有可用的 staticmap 聚合服务，只能自己做 iOS
     * MKMapSnapshotter 那一步：算出中心点在该缩放级别下的世界像素坐标，取窗口覆盖到的
     * 每一张 256px 瓦片（220×140 的窗口最多 2×2 张），按偏移量贴进目标位图再编码。
     */
    private func composeTileSnapshot(
        lat: Float64, lng: Float64, width: Int32, height: Int32, zoom: Int32
    ): Array<Byte> {
        let w = Int64(width)
        let h = Int64(height)
        if (w <= 0 || h <= 0) { return Array<Byte>(0, repeat: 0) }

        let centerX = this.lngToWorldPx(lng, zoom)
        let centerY = this.latToWorldPx(lat, zoom)
        let left = centerX - Float64(w) / 2.0
        let top = centerY - Float64(h) / 2.0
        let tileCount = Int64(pow(2.0, Float64(zoom)))

        let firstTileX = Int64(floor(left / 256.0))
        let lastTileX = Int64(floor((left + Float64(w) - 1.0) / 256.0))
        let firstTileY = Int64(floor(top / 256.0))
        let lastTileY = Int64(floor((top + Float64(h) - 1.0) / 256.0))

        var canvas = Option<PixelMap>.None
        var painted = false
        let headers = HashMap<String, String>()
        headers["User-Agent"] = this.tileUserAgent

        var ty = firstTileY
        while (ty <= lastTileY) {
            var tx = firstTileX
            while (tx <= lastTileX) {
                // 横向跨 180° 经线时回绕，纵向超界的瓦片不存在，直接跳过
                if (ty < 0 || ty >= tileCount) { tx = tx + 1; continue }
                var wrappedX = tx % tileCount
                if (wrappedX < 0) { wrappedX = wrappedX + tileCount }

                let response = netHttpGetBytes(this.buildTileUrl(zoom, wrappedX, ty), headers: headers)
                if (!response.success) {
                    Hilog.info(0, "CjTelegram",
                        "[LocationRes] tile ${zoom}/${wrappedX}/${ty} failed http=${response.statusCode}")
                    tx = tx + 1
                    continue
                }

                try {
                    let source = createImageSource(response.bytes)
                    let tile = source.createPixelMap()
                    let tileBuffer = Array<UInt8>(256 * 256 * 4, repeat: 0)
                    tile.readPixelsToBuffer(tileBuffer)

                    // 该瓦片左上角在目标位图中的位置（可能为负 = 需要从瓦片内部裁起）
                    let destX = Float64(tx) * 256.0 - left
                    let destY = Float64(ty) * 256.0 - top
                    let srcX = if (destX < 0.0) { Int64(-destX) } else { 0 }
                    let srcY = if (destY < 0.0) { Int64(-destY) } else { 0 }
                    let dstX = if (destX > 0.0) { Int64(destX) } else { 0 }
                    let dstY = if (destY > 0.0) { Int64(destY) } else { 0 }
                    var copyW = 256 - srcX
                    var copyH = 256 - srcY
                    if (dstX + copyW > w) { copyW = w - dstX }
                    if (dstY + copyH > h) { copyH = h - dstY }

                    if (copyW > 0 && copyH > 0) {
                        if (canvas.isNone()) {
                            canvas = Some(createPixelMap(
                                Array<UInt8>(Int64(w * h * 4), repeat: 0),
                                InitializationOptions(
                                    Size(Int32(h), Int32(w)),
                                    editable: true,
                                    srcPixelFormat: PixelMapFormat.Rgba8888,
                                    pixelFormat: PixelMapFormat.Rgba8888,
                                    alphaType: AlphaType.Opaque
                                )
                            ))
                        }
                        match (canvas) {
                            case Some(target) =>
                                target.writePixels(PositionArea(
                                    tileBuffer,
                                    UInt32((srcY * 256 + srcX) * 4),
                                    UInt32(256 * 4),
                                    Region(Size(Int32(copyH), Int32(copyW)), Int32(dstX), Int32(dstY))
                                ))
                                painted = true
                            case None => ()
                        }
                    }
                    tile.release()
                    source.release()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[LocationRes] tile decode failed: ${e.message}")
                }
                tx = tx + 1
            }
            ty = ty + 1
        }

        if (!painted) { return Array<Byte>(0, repeat: 0) }
        match (canvas) {
            case Some(target) =>
                var encoded = Array<Byte>(0, repeat: 0)
                try {
                    let packer = createImagePacker()
                    encoded = packer.packToData(target, PackingOption("image/jpeg", 90))
                    packer.release()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[LocationRes] snapshot encode failed: ${e.message}")
                }
                target.release()
                return encoded
            case None => return Array<Byte>(0, repeat: 0)
        }
    }

    /**
     * 使指定缓存键的内存缓存失效（磁盘文件保留）
     *
     * @param cacheKey 缓存键
     */
    public func invalidateMemoryCache(cacheKey: String): Unit {
        if (this.memCache.contains(cacheKey)) {
            this.memCache.remove(cacheKey)
        }
    }

    /**
     * 清空所有内存缓存
     */
    public func clearMemoryCache(): Unit {
        this.memCache = HashMap<String, String>()
    }

    // ── P2-236 场所图标资源方法 ──────────────────────────────────

    /**
     * 构造场所图标缓存键，与 iOS VenueIconResourceId.uniqueId 对齐
     *
     * @param type_ Foursquare 场所类别字符串（如 "food/pizza"）
     * @return "venue-icon-{type_.replace('/', '_')}"
     */
    public func deriveVenueIconCacheKey(type_: String): String {
        return "venue-icon-" + type_.replace("/", "_")
    }

    /**
     * 构造 Foursquare CDN 场所图标 URL
     *
     * iOS 对应: "https://ss3.4sqi.net/img/categories_v2/\(resource.type)_88.png"
     *
     * @param type_ Foursquare 场所类别字符串（如 "food/pizza"）
     * @return 完整 HTTPS URL 字符串
     */
    public func buildVenueIconUrl(type_: String): String {
        return "https://ss3.4sqi.net/img/categories_v2/" + type_ + "_88.png"
    }

    /**
     * 查询场所图标本地磁盘缓存路径（不触发下载）
     *
     * @param cacheKey 由 deriveVenueIconCacheKey 派生
     * @return file:// 路径；若无缓存返回空字符串
     */
    public func getVenueIconCachedPath(cacheKey: String): String {
        if (this.memCache.contains(cacheKey)) {
            return this.memCache[cacheKey]
        }
        let path = this.buildVenueIconFilePath(cacheKey)
        if (path.size == 0) { return "" }
        var exists = false
        try {
            exists = FileIo.access(path)
        } catch (_: Exception) {
            exists = false
        }
        if (exists) {
            let uri = "file://" + path
            this.memCache[cacheKey] = uri
            return uri
        }
        return ""
    }

    /**
     * 获取场所图标资源（缓存 → HTTP 下载 → 写盘）
     *
     * 对应 iOS fetchVenueIconResource(engine:resource:) + venueIconData(engine:resource:)
     * iOS 从 Foursquare CDN 取 PNG 图标: https://ss3.4sqi.net/img/categories_v2/{type}_88.png
     *
     * 调用链:
     *   fetchVenueIconResource → deriveVenueIconCacheKey
     *                          → getVenueIconCachedPath [命中则直接返回]
     *                          → buildVenueIconUrl
     *                          → downloadImageBytes (ohos.net.http HTTPS GET)
     *                          → saveVenueIconData (FileIo write)
     *                          → 返回 VenueIconResult
     *
     * @param type_ Foursquare 场所类别字符串（如 "food/pizza"）
     * @return VenueIconResult（success=true 时 localPath 有效）
     */
    public func fetchVenueIconResource(type_: String): VenueIconResult {
        let key = this.deriveVenueIconCacheKey(type_)

        let cached = this.getVenueIconCachedPath(key)
        if (cached.size > 0) {
            Hilog.info(0, "CjTelegram", "[LocationRes] fetchVenueIconResource: cache hit key=" + key)
            return VenueIconResult.ok(cached, key, type_, Array<Byte>(0, repeat: 0))
        }

        let url = this.buildVenueIconUrl(type_)
        Hilog.info(0, "CjTelegram", "[LocationRes] fetchVenueIconResource: downloading icon type=" + type_)

        let bytes = this.downloadImageBytes(url)
        if (bytes.size == 0) {
            Hilog.info(0, "CjTelegram", "[LocationRes] fetchVenueIconResource: download failed, empty bytes for type=" + type_)
            return VenueIconResult.fail("Failed to download venue icon: empty response for type=" + type_)
        }

        let localPath = this.saveVenueIconData(key, bytes)
        if (localPath.size == 0) {
            Hilog.info(0, "CjTelegram", "[LocationRes] fetchVenueIconResource: disk write failed for key=" + key)
            return VenueIconResult.fail("Failed to save venue icon to disk for type=" + type_)
        }

        let uri = "file://" + localPath
        this.memCache[key] = uri
        Hilog.info(0, "CjTelegram", "[LocationRes] fetchVenueIconResource: saved to " + localPath)
        return VenueIconResult.ok(uri, key, type_, bytes)
    }

    /**
     * 使场所图标内存缓存失效（磁盘文件保留）
     *
     * @param type_ Foursquare 场所类别字符串
     */
    public func invalidateVenueIconMemoryCache(type_: String): Unit {
        let key = this.deriveVenueIconCacheKey(type_)
        if (this.memCache.contains(key)) {
            this.memCache.remove(key)
        }
    }

    // ── 私有辅助方法 ─────────────────────────────────────────────

    /**
     * HTTP GET 下载图片字节
     * 走系统 NetStack（见 NetHttpClient）——stdx.net.http 会让运行时在装配接口表时 abort。
     */
    private func downloadImageBytes(url: String): Array<Byte> {
        let response = netHttpGetBytes(url)
        if (!response.success) {
            Hilog.info(0, "CjTelegram",
                "[LocationRes] downloadImageBytes: HTTP ${response.statusCode} for url=" + url)
            return Array<Byte>(0, repeat: 0)
        }
        return response.bytes
    }

    /**
     * 构造磁盘缓存文件完整路径，确保目录存在
     * 模式与 WallpaperResourcesService.buildWallpaperFilePath 一致
     *
     * @param cacheKey 缓存键
     * @return 文件完整路径；getAppFilesDir 失败时返回空字符串
     */
    private func buildSnapshotFilePath(cacheKey: String): String {
        let filesDir = getAppFilesDir()
        if (filesDir.size == 0) { return "" }
        let dir = filesDir + "/map_snapshots"
        try {
            if (!FileIo.access(dir)) {
                FileIo.mkdir(dir)
            }
        } catch (_: Exception) {
            try { FileIo.mkdir(dir) } catch (_: Exception) {}
        }
        return dir + "/" + cacheKey
    }

    /**
     * 将图片字节写入磁盘缓存文件
     * 模式与 WallpaperResourcesService.saveWallpaperData 一致
     *
     * @param cacheKey 缓存键
     * @param data     图片字节
     * @return 写入成功的文件路径；失败返回空字符串
     */
    private func saveSnapshotData(cacheKey: String, data: Array<Byte>): String {
        let path = this.buildSnapshotFilePath(cacheKey)
        if (path.size == 0) { return "" }
        try {
            let fd = FileIo.open(path, mode: 0o1101)
            FileIo.write(fd.fd, data)
            FileIo.close(fd)
            return path
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LocationRes] saveSnapshotData: write failed for " + cacheKey)
            return ""
        }
    }

    /**
     * 构造场所图标磁盘缓存文件完整路径，确保目录存在
     *
     * @param cacheKey 缓存键（由 deriveVenueIconCacheKey 生成）
     * @return 文件完整路径；getAppFilesDir 失败时返回空字符串
     */
    private func buildVenueIconFilePath(cacheKey: String): String {
        let filesDir = getAppFilesDir()
        if (filesDir.size == 0) { return "" }
        let dir = filesDir + "/venue_icons"
        try {
            if (!FileIo.access(dir)) {
                FileIo.mkdir(dir)
            }
        } catch (_: Exception) {
            try { FileIo.mkdir(dir) } catch (_: Exception) {}
        }
        return dir + "/" + cacheKey
    }

    /**
     * 将场所图标字节写入磁盘缓存文件
     *
     * @param cacheKey 缓存键
     * @param data     图标字节（PNG）
     * @return 写入成功的文件路径；失败返回空字符串
     */
    private func saveVenueIconData(cacheKey: String, data: Array<Byte>): String {
        let path = this.buildVenueIconFilePath(cacheKey)
        if (path.size == 0) { return "" }
        try {
            let fd = FileIo.open(path, mode: 0o1101)
            FileIo.write(fd.fd, data)
            FileIo.close(fd)
            return path
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LocationRes] saveVenueIconData: write failed for " + cacheKey)
            return ""
        }
    }
}
