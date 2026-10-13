package ohos_app_cangjie_entry.services

import kit.MediaLibraryKit.*
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import kit.ImageKit.PixelMap
import kit.ImageKit.Size
import kit.PerformanceAnalysisKit.Hilog
import ohos.business_exception.BusinessException
import std.collection.ArrayList

/**
 * MediaPickerService — 本地相册选择器服务（media_picker feature / MPICK-API-1）
 *
 * iOS 对应：
 *   submodules/MediaPickerUI/Sources/MediaGroupsScreen.swift   — 相册分组列表
 *   submodules/MediaPickerUI/Sources/MediaPickerScreen.swift   — 相册内媒体选择
 *   submodules/MediaPickerUI/Sources/LegacyMediaPickerGallery.swift — 照片网格选择
 *   submodules/MediaPickerUI/Sources/AvatarEditorPreviewView.swift  — 头像裁剪预览
 *
 * 本 feature 为 local_state，tl_methods=[]：
 *   仅调用 HarmonyOS 本地相册 API（photoAccessHelper），无 MTProto 依赖。
 *
 * 相册 URI 约定（P2-208）：
 *   "system:all"       — 全部照片（Camera Roll，fetchAllAssets 路径）
 *   "system:favorite"  — 收藏夹（AlbumType.System, AlbumSubtype.Favorite）
 *   "system:video"     — 视频相册（AlbumType.System, AlbumSubtype.Video）
 *   其余字符串           — 用户相册 albumUri，走 User/UserGeneric 路径
 *
 * 调用链（完整）：
 *   MediaGroupsScreen.aboutToAppear()
 *     → MediaPickerService.fetchAlbumGroups(ctx)
 *       系统相册段：
 *         phHelper.getAlbums(AlbumType.System, AlbumSubtype.Favorite)
 *         phHelper.getAlbums(AlbumType.System, AlbumSubtype.Video)
 *       用户相册段：
 *         phHelper.getAlbums(AlbumType.User, AlbumSubtype.UserGeneric)
 *       → ArrayList<MediaAlbumGroup>
 *
 *   MediaPickerScreen.aboutToAppear(albumUri)
 *     → "system:all"     → fetchAllAssets(ctx)
 *     → "system:favorite"→ fetchSystemAlbumAssets(ctx, AlbumSubtype.Favorite)
 *     → "system:video"   → fetchSystemAlbumAssets(ctx, AlbumSubtype.Video)
 *     → 其余             → fetchAssetsInAlbum(ctx, albumUri)
 */

// ─────────────────────────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────────────────────────

/** 选中上限（对应 iOS selectionContext.selectionLimit = 100，Telegram 实际 UI 限制为 10）*/
public let MEDIA_PICKER_SELECTION_LIMIT: Int32 = 10

/** 特殊系统相册 URI 常量 */
public let MEDIA_ALBUM_URI_ALL: String = "system:all"
public let MEDIA_ALBUM_URI_FAVORITE: String = "system:favorite"
public let MEDIA_ALBUM_URI_VIDEO: String = "system:video"

// ─────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────

/**
 * 相册分组信息
 * 对应 iOS MediaGroupsScreen 的 PHAssetCollection 元数据
 */
public class MediaAlbumGroup {
    /** 相册名称（对应 iOS PHAssetCollection.localizedTitle）*/
    public var albumName: String = ""
    /** 相册 URI（用于后续 getAssets 过滤；系统相册用特殊前缀 "system:*"）*/
    public var albumUri: String = ""
    /** 相册中的图片数量 */
    public var imageCount: Int32 = 0
    /** 相册中的视频数量 */
    public var videoCount: Int32 = 0
    /** 总媒体数量 */
    public var totalCount: Int32 = 0
    /** 相册封面缩略图 URI（空表示无封面） */
    public var coverUri: String = ""

    public init() {}
}

/**
 * 媒体选择器资产条目
 * 对应 iOS MediaPickerScreen 的 PHAsset 单元
 *
 * P2-207：selectionOrder 表示多选序号（0 = 未选中，1/2/3... = 选中顺序角标）
 */
public class MediaPickerAsset {
    /** 资产 URI（file://media/... 格式）*/
    public var uri: String = ""
    /** 显示文件名（含后缀）*/
    public var displayName: String = ""
    /** 媒体类型："image" | "video" */
    public var mediaType: String = ""
    /** 是否已选中（多选模式）*/
    public var isSelected: Bool = false
    /**
     * 选中序号（P2-207）：0 = 未选中，1 = 第一个选中，2 = 第二个...
     * 对应 iOS MediaPickerGridItem.selectionIndex
     */
    public var selectionOrder: Int32 = 0

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _mediaPickerServiceInstance: Option<MediaPickerService> = None

/** 获取 MediaPickerService 单例 */
public func getMediaPickerService(): MediaPickerService {
    match (_mediaPickerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MediaPickerService()
            _mediaPickerServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// MediaPickerService
// ─────────────────────────────────────────────────────────────────

/**
 * MediaPickerService — 本地相册选择器服务
 *
 * 封装 HarmonyOS photoAccessHelper 能力，为 MediaGroupsScreen 和
 * MediaPickerScreen 提供相册分组列表和相册内资产列表的查询接口。
 *
 * P2-208：fetchAlbumGroups 返回系统相册（Camera Roll / Favorites / Videos）
 *          + 用户自定义相册。
 * P2-206：图片缩略图通过 asset.uri 在 UI 层直接传给 Image() 组件渲染。
 * P2-207：MEDIA_PICKER_SELECTION_LIMIT 上限常量供 UI 层调用。
 */
public class MediaPickerService {

    public init() {}

    // ── 相册分组查询（P2-208）─────────────────────────────────────────────

    /**
     * 获取用户相册分组列表（含系统相册 Camera Roll / Favorites / Videos）
     *
     * iOS 对应：MediaGroupsScreen 枚举 .smartAlbumUserLibrary / .smartAlbumFavorites /
     *           .smartAlbumVideos / 用户 albums。
     *
     * HarmonyOS：
     *   - Camera Roll（全部）: 虚拟条目，uri = MEDIA_ALBUM_URI_ALL，通过 fetchAllAssets 实现
     *   - 收藏夹: AlbumType.System, AlbumSubtype.Favorite
     *   - 视频: AlbumType.System, AlbumSubtype.Video
     *   - 用户自定义相册: AlbumType.User, AlbumSubtype.UserGeneric
     *
     * @param ctx  UIAbilityContext
     * @return 相册分组列表（先系统相册，后用户相册）
     */
    public func fetchAlbumGroups(ctx: UIAbilityContext): ArrayList<MediaAlbumGroup> {
        let result = ArrayList<MediaAlbumGroup>()
        let phHelper = getPhotoAccessHelper(ctx)
        let predicates = DataSharePredicates()
        let fetchOptions = FetchOptions([], predicates)

        // ── Camera Roll（全部照片）虚拟条目 ────────────────────────────────
        // 实际数量通过 fetchAllAssets 计算；此处近似为相册总计数
        let allGroup = MediaAlbumGroup()
        allGroup.albumName = "Camera Roll"
        allGroup.albumUri = MEDIA_ALBUM_URI_ALL
        allGroup.totalCount = 0
        // 先加占位，后续可通过 fetchAllAssets 补数量；UI 直接用 totalCount=0 也安全
        result.add(allGroup)

        // ── 收藏夹（Favorites）─────────────────────────────────────────────
        try {
            let favResult = phHelper.getAlbums(AlbumType.System, AlbumSubtype.Favorite)
            let favAlbums = favResult.getAllObjects()
            for (album in favAlbums) {
                let group = MediaAlbumGroup()
                group.albumName = "Favorites"
                group.albumUri = MEDIA_ALBUM_URI_FAVORITE
                group.totalCount = album.count
                group.coverUri = album.coverUri
                result.add(group)
                break
            }
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAlbumGroups Favorites error: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAlbumGroups Favorites unexpected error")
        }

        // ── 视频相册（Videos）──────────────────────────────────────────────
        try {
            let videoResult = phHelper.getAlbums(AlbumType.System, AlbumSubtype.Video)
            let videoAlbums = videoResult.getAllObjects()
            for (album in videoAlbums) {
                let group = MediaAlbumGroup()
                group.albumName = "Videos"
                group.albumUri = MEDIA_ALBUM_URI_VIDEO
                group.totalCount = album.count
                group.coverUri = album.coverUri
                result.add(group)
                break
            }
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAlbumGroups Videos error: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAlbumGroups Videos unexpected error")
        }

        // ── 用户自定义相册 ─────────────────────────────────────────────────
        try {
            let albumResult = phHelper.getAlbums(AlbumType.User, AlbumSubtype.UserGeneric, options: fetchOptions)
            let albums = albumResult.getAllObjects()
            for (album in albums) {
                let group = MediaAlbumGroup()
                group.albumName = album.albumName
                group.albumUri = album.albumUri
                group.imageCount = album.imageCount
                group.videoCount = album.videoCount
                group.totalCount = album.count
                group.coverUri = album.coverUri
                result.add(group)
            }
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAlbumGroups: " + result.size.toString() + " total groups")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAlbumGroups User error: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAlbumGroups User unexpected error")
        }

        return result
    }

    // ── 相册内资产查询 ─────────────────────────────────────────────────────

    /**
     * 获取所有图片和视频的合并列表（Camera Roll / "全部" 相册）
     *
     * 对应 iOS "所有照片" PHAssetCollection 中的 PHFetchResult 列举。
     * HarmonyOS 等效：photoAccessHelper.getAssets(FetchOptions([], DataSharePredicates()))
     *
     * @param ctx   UIAbilityContext
     * @param limit 最大条数（0 = 无限制，取前 200 条）
     * @return 资产列表
     */
    public func fetchAllAssets(ctx: UIAbilityContext, limit!: Int32 = 200): ArrayList<MediaPickerAsset> {
        let result = ArrayList<MediaPickerAsset>()
        try {
            let phHelper = getPhotoAccessHelper(ctx)
            let predicates = DataSharePredicates()
            let fetchOptions = FetchOptions([], predicates)
            let fetchResult = phHelper.getAssets(fetchOptions)
            let allAssets = fetchResult.getAllObjects()
            var count: Int32 = 0
            for (asset in allAssets) {
                if (limit > 0 && count >= limit) { break }
                let item = buildAssetItem(asset)
                result.add(item)
                count += 1
            }
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAllAssets: " + result.size.toString() + " assets")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAllAssets BusinessException: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAllAssets unexpected error")
        }
        return result
    }

    /**
     * 获取系统相册（收藏夹 / 视频）内的资产列表（P2-208）
     *
     * @param ctx       UIAbilityContext
     * @param subtype   AlbumSubtype.Favorite 或 AlbumSubtype.Video
     * @param limit     最大条数
     * @return 资产列表
     */
    public func fetchSystemAlbumAssets(ctx: UIAbilityContext, subtype: AlbumSubtype, limit!: Int32 = 200): ArrayList<MediaPickerAsset> {
        let result = ArrayList<MediaPickerAsset>()
        try {
            let phHelper = getPhotoAccessHelper(ctx)
            let albumResult = phHelper.getAlbums(AlbumType.System, subtype)
            let albums = albumResult.getAllObjects()
            for (album in albums) {
                let predicates = DataSharePredicates()
                let fetchOptions = FetchOptions([], predicates)
                let assetResult = album.getAssets(fetchOptions)
                let assets = assetResult.getAllObjects()
                var count: Int32 = 0
                for (asset in assets) {
                    if (limit > 0 && count >= limit) { break }
                    let item = buildAssetItem(asset)
                    result.add(item)
                    count += 1
                }
                break
            }
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchSystemAlbumAssets: " + result.size.toString() + " assets")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchSystemAlbumAssets BusinessException: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchSystemAlbumAssets unexpected error")
        }
        return result
    }

    /**
     * 获取指定用户相册内的媒体资产列表
     *
     * 对应 iOS MediaPickerScreen 通过 PHAsset.fetchAssets(in:options:) 获取相册内照片。
     * HarmonyOS 等效：获取目标 Album 对象后调用 album.getAssets(fetchOptions)。
     *
     * @param ctx        UIAbilityContext
     * @param albumUri   用户相册 URI（来自 MediaAlbumGroup.albumUri，非 "system:*" 前缀）
     * @param limit      最大条数（0 = 无限制，默认取前 200 条）
     * @return 资产列表；失败时返回空列表
     */
    public func fetchAssetsInAlbum(ctx: UIAbilityContext, albumUri: String, limit!: Int32 = 200): ArrayList<MediaPickerAsset> {
        let result = ArrayList<MediaPickerAsset>()
        if (albumUri.size == 0) {
            return result
        }
        try {
            let phHelper = getPhotoAccessHelper(ctx)
            let albumPredicates = DataSharePredicates()
            let albumFetchOptions = FetchOptions([], albumPredicates)
            let albumResult = phHelper.getAlbums(AlbumType.User, AlbumSubtype.UserGeneric, options: albumFetchOptions)
            let allAlbums = albumResult.getAllObjects()
            var targetAlbum: Option<Album> = None
            for (album in allAlbums) {
                if (album.albumUri == albumUri) {
                    targetAlbum = Some(album)
                    break
                }
            }
            match (targetAlbum) {
                case None =>
                    Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAssetsInAlbum: album not found " + albumUri)
                case Some(album) =>
                    let predicates = DataSharePredicates()
                    let fetchOptions = FetchOptions([], predicates)
                    let assetResult = album.getAssets(fetchOptions)
                    let assets = assetResult.getAllObjects()
                    var count: Int32 = 0
                    for (asset in assets) {
                        if (limit > 0 && count >= limit) { break }
                        let item = buildAssetItem(asset)
                        result.add(item)
                        count += 1
                    }
                    Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAssetsInAlbum: " + result.size.toString() + " assets")
            }
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAssetsInAlbum BusinessException: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAssetsInAlbum unexpected error")
        }
        return result
    }

    /**
     * 获取指定资产的缩略图（PixelMap）
     *
     * 对应 iOS PHImageManager.requestImage(for:targetSize:) 缩略图请求。
     * HarmonyOS 等效：PhotoAsset.getThumbnail(size: Size(256, 256))
     * 注：此方法在 spawn 中调用；UI 层直接用 asset.uri 传给 Image() 通常更高效。
     *
     * @param ctx  UIAbilityContext
     * @param assetUri 资产 URI
     * @return 缩略图 PixelMap（None = 加载失败）
     */
    public func fetchThumbnail(ctx: UIAbilityContext, assetUri: String): Option<PixelMap> {
        if (assetUri.size == 0) { return None }
        try {
            let phHelper = getPhotoAccessHelper(ctx)
            let predicates = DataSharePredicates()
            let fetchOptions = FetchOptions([], predicates)
            let fetchResult = phHelper.getAssets(fetchOptions)
            let assets = fetchResult.getAllObjects()
            for (asset in assets) {
                if (asset.uri == assetUri) {
                    let pixm = asset.getThumbnail(size: Size(256, 256))
                    return Some(pixm)
                }
            }
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchThumbnail BusinessException: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchThumbnail unexpected error")
        }
        return None
    }

    /**
     * 读取供媒体编辑器使用的高质量等比图像。源端 MediaEditor.textureSource 对静态
     * PHAsset 请求 1920×1920、aspectFit、highQualityFormat，并拒绝 degraded 结果；
     * PhotoAsset 的仓颉接口不暴露同形的原图 fd/open，因此先读取资产宽高，再请求长边
     * 1920 且保持原始宽高比的 thumbnail，等价实现 aspectFit，不能传固定方形尺寸。
     */
    public func fetchAvatarEditingImage(ctx: UIAbilityContext, assetUri: String): Option<PixelMap> {
        if (assetUri.size == 0) { return None }
        try {
            let phHelper = getPhotoAccessHelper(ctx)
            let predicates = DataSharePredicates()
            let fetchOptions = FetchOptions([PhotoKeys.Width.toString(), PhotoKeys.Height.toString()], predicates)
            let fetchResult = phHelper.getAssets(fetchOptions)
            let assets = fetchResult.getAllObjects()
            for (asset in assets) {
                if (asset.uri == assetUri) {
                    var sourceWidth: Int64 = 1920
                    var sourceHeight: Int64 = 1920
                    match (asset.get(PhotoKeys.Width.toString())) {
                        case MemberType.Int64Value(value) => sourceWidth = value
                        case _ => ()
                    }
                    match (asset.get(PhotoKeys.Height.toString())) {
                        case MemberType.Int64Value(value) => sourceHeight = value
                        case _ => ()
                    }
                    var targetWidth: Int32 = 1920
                    var targetHeight: Int32 = 1920
                    if (sourceWidth > 0 && sourceHeight > 0) {
                        if (sourceWidth >= sourceHeight) {
                            targetHeight = Int32(max(1, 1920 * sourceHeight / sourceWidth))
                            if (targetHeight % 2 != 0) { targetHeight += 1 }
                        } else {
                            targetWidth = Int32(max(1, 1920 * sourceWidth / sourceHeight))
                            if (targetWidth % 2 != 0) { targetWidth += 1 }
                        }
                    }
                    return Some(asset.getThumbnail(size: Size(targetWidth, targetHeight)))
                }
            }
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAvatarEditingImage BusinessException: " + e.message)
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[MediaPickerService] fetchAvatarEditingImage unexpected error")
        }
        return None
    }

    // ── 私有辅助方法 ──────────────────────────────────────────────────────

    /**
     * 从 PhotoAsset 构建 MediaPickerAsset 条目
     */
    private func buildAssetItem(asset: PhotoAsset): MediaPickerAsset {
        let item = MediaPickerAsset()
        item.uri = asset.uri
        item.displayName = asset.displayName
        item.mediaType = match (asset.photoType) {
            case PhotoType.Image => "image"
            case PhotoType.Video => "video"
            case _ => "image"
        }
        item.isSelected = false
        item.selectionOrder = 0
        return item
    }
}
