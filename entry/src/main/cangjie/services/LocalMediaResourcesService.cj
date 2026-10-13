package ohos_app_cangjie_entry.services

import kit.MediaLibraryKit.*
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import kit.ImageKit.PixelMap
import kit.ImageKit.Size
import kit.ImageKit.DecodingOptions
import kit.ImageKit.PackingOption
import kit.ImageKit.createImagePacker
import kit.ImageKit.createImageSource
import kit.PerformanceAnalysisKit.Hilog
import ohos.business_exception.BusinessException
import std.collection.ArrayList

/**
 * LocalMediaResourcesService — 本地相册 / 图库媒体资源读取服务
 *
 * iOS 对应：PHAsset / PHImageManager (FetchPhotoLibraryImageResource.swift)
 *
 * 功能：
 * - 通过 HarmonyOS photoAccessHelper 读取本地图库资产（图片/视频）
 * - 获取所有资产的元信息列表（uri、displayName、mediaType）
 * - 按需获取指定资产的缩略图（返回 PixelMap 字节数据存为路径，或直接暴露 getAsset）
 *
 * MTProto 说明（N/A）：
 *   本地相册读取不涉及 MTProto 协议。iOS 的 PHAsset/PHImageManager 对应
 *   HarmonyOS 的 photoAccessHelper API，均为本地系统 API 调用，无网络请求。
 *
 * 权限要求：
 *   ohos.permission.READ_IMAGEVIDEO — 读取图库资产
 *
 * 调用链（完整）：
 *   LocalMediaResourcesViewModel.loadPhotoAssets()
 *     → LocalMediaResourcesService.fetchAllPhotoAssets(ctx)
 *       → getPhotoAccessHelper(ctx)
 *         → phAccessHelper.getAssets(fetchOptions)
 *           → fetchResult.getAllObjects()
 *             → PhotoAsset.uri / displayName / photoType
 *
 *   LocalMediaResourcesViewModel.loadThumbnailForAsset(uri)
 *     → LocalMediaResourcesService.fetchPhotoAssetByUri(ctx, uri)
 *       → phAccessHelper.getAssets(fetchOptions filtered by uri)
 *         → fetchResult.getFirstObject()
 *           → ViewModel calls asset.getThumbnail(size)
 */

// ─────────────────────────────────────────────────────────────────
// 本地图库资产信息（对应 iOS PHAsset 元数据）
// ─────────────────────────────────────────────────────────────────

/**
 * 本地图库资产元信息
 *
 * 对应 iOS PHAsset 的基本属性
 */
public class LocalPhotoAssetInfo {
    /** 资产 URI（如：file://media/Photo/1/IMG_xxx/photo.jpg）*/
    public var uri: String = ""
    /** 显示文件名（含后缀）*/
    public var displayName: String = ""
    /** 资产类型："image" | "video" */
    public var mediaType: String = ""

    public init() {}
}

// ─────────────────────────────────────────────────────────────────
// 服务单例
// ─────────────────────────────────────────────────────────────────

private var _localMediaResourcesServiceInstance: Option<LocalMediaResourcesService> = None

/** 获取 LocalMediaResourcesService 单例 */
public func getLocalMediaResourcesService(): LocalMediaResourcesService {
    match (_localMediaResourcesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LocalMediaResourcesService()
            _localMediaResourcesServiceInstance = Some(inst)
            return inst
    }
}

// ─────────────────────────────────────────────────────────────────
// LocalMediaResourcesService
// ─────────────────────────────────────────────────────────────────

/**
 * LocalMediaResourcesService — 本地相册媒体资源服务
 *
 * 提供从 HarmonyOS 本地图库读取图片/视频资产元信息和 PhotoAsset 对象的能力。
 * 缩略图/原图的 PixelMap 获取由 ViewModel 直接调用 PhotoAsset.getThumbnail()。
 *
 * 对应 iOS FetchPhotoLibraryImageResource.swift 中：
 *   - fetchPhotoLibraryResource() → fetchAllPhotoAssets() 批量获取
 *   - fetchPhotoLibraryImage()    → fetchPhotoAssetByUri() 单资产查找
 */
public class LocalMediaResourcesService {

    public init() {}

    // ── 获取所有图库资产 ────────────────────────────────────────────

    /**
     * 获取本地图库中所有图片和视频资产的元信息列表。
     *
     * 对应 iOS:
     *   PHAsset.fetchAssets(with: .all, options: nil) 批量获取
     *
     * 需要权限：ohos.permission.READ_IMAGEVIDEO
     *
     * @param ctx UIAbilityContext 实例（由 getGlobalAbilityContext() 提供）
     * @return 资产信息数组；读取失败时返回空数组
     */
    public func fetchAllPhotoAssets(ctx: UIAbilityContext): ArrayList<LocalPhotoAssetInfo> {
        let result = ArrayList<LocalPhotoAssetInfo>()
        try {
            let phAccessHelper = getPhotoAccessHelper(ctx)
            let predicates = DataSharePredicates()
            let fetchOptions = FetchOptions([], predicates)
            let fetchResultObj: PhotoAssetResult = phAccessHelper.getAssets(fetchOptions)
            let assets = fetchResultObj.getAllObjects()
            for (asset in assets) {
                let info = LocalPhotoAssetInfo()
                info.uri = asset.uri
                info.displayName = asset.displayName
                let isImage = match (asset.photoType) {
                    case PhotoType.Image => true
                    case _ => false
                }
                if (isImage) {
                    info.mediaType = "image"
                } else {
                    info.mediaType = "video"
                }
                result.add(info)
            }
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchAllPhotoAssets: found ${result.size} assets")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchAllPhotoAssets error: ${e.message}")
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchAllPhotoAssets unexpected error")
        }
        return result
    }

    // ── 按 URI 获取缩略图 ──────────────────────────────────────────

    /**
     * 按 URI 获取指定资产的缩略图 PixelMap。
     *
     * 对应 iOS:
     *   fetchPhotoLibraryImage(localIdentifier:thumbnail:true)
     *   PHImageManager.default().requestImage(for:, targetSize:CGSize(w,h), contentMode:.aspectFill)
     *
     * 说明：仅在 services 包（只 import kit.MediaLibraryKit.*）中解析 Size / PixelMap，
     * 避免 ViewModel 中同时 import kit.ArkUI.* 与 kit.MediaLibraryKit.* 导致 Size 歧义（#87）。
     *
     * @param ctx             UIAbilityContext 实例
     * @param assetUri        资产 URI
     * @param thumbnailWidth  缩略图宽度（像素），默认 128
     * @param thumbnailHeight 缩略图高度（像素），默认 128
     * @return 缩略图 PixelMap；获取失败时返回 None
     */
    public func fetchThumbnailByUri(
        ctx: UIAbilityContext,
        assetUri: String,
        thumbnailWidth!: Int32 = 128,
        thumbnailHeight!: Int32 = 128
    ): Option<PixelMap> {
        let notFound: Option<PixelMap> = None
        if (assetUri.size == 0) {
            return notFound
        }
        try {
            let phAccessHelper = getPhotoAccessHelper(ctx)
            let predicates = DataSharePredicates()
            let fetchOptions = FetchOptions([], predicates)
            let fetchResultObj: PhotoAssetResult = phAccessHelper.getAssets(fetchOptions)
            // 遍历找到匹配 uri 的资产
            let assets = fetchResultObj.getAllObjects()
            for (asset in assets) {
                if (asset.uri == assetUri) {
                    let thumbSize = Size(thumbnailWidth, thumbnailHeight)
                    let pixmap = asset.getThumbnail(size: thumbSize)
                    Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchThumbnailByUri ok: ${assetUri}")
                    return Some(pixmap)
                }
            }
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchThumbnailByUri: asset not found: ${assetUri}")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchThumbnailByUri error: ${e.message}")
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchThumbnailByUri unexpected error")
        }
        return notFound
    }

    // ── P2-221: 带格式/质量控制的 PixelMap 编码字节（相册 asset 取图 + 缩放 + 编码）────────

    /**
     * 从相册按 URI 取图、缩放到指定尺寸，并编码为字节（可控格式/质量）。
     *
     * P2-221 fidelity gap — 对应 iOS fetchPhotoLibraryResource()：
     *   1. PHImageManager.requestImage(for:targetSize:contentMode:.aspectFit) 取图
     *   2. resizedImage(image, for: scaledSize)（Accelerate vImage 高质量插值）
     *   3. compressImageToJPEG / compressImageToJPEGXL 编码
     *
     * HarmonyOS 实现：
     *   1. photoAsset.getThumbnail(size) 取指定尺寸 PixelMap（平台负责缩放，等效 targetSize）
     *   2. ImagePacker.packToData(pixelMap, PackingOption(mime, quality)) 编码
     *      格式：JPEG = "image/jpeg"；PNG = "image/png"（HarmonyOS 无 JXL，defer → PNG）
     *      质量：0-100（UInt8），对应 iOS quality Int32（钳位到 [0,100]）
     *
     * 分辨率取舍说明：
     *   - iOS 先请求全尺寸 PHImageManagerMaximumSize，再 resizedImage 手工缩放（vImage 高质量）；
     *   - HarmonyOS getThumbnail(size) 直接请求目标尺寸，缩放质量由平台决定；
     *   - 二者效果等效（均为最终目标尺寸），此为合理平台差异，无需 defer。
     *
     * @param ctx           UIAbilityContext 实例
     * @param assetUri      资产 URI
     * @param targetWidth   目标宽度（像素）；0 = 使用平台默认 256
     * @param targetHeight  目标高度（像素）；0 = 使用平台默认 256
     * @param format        编码格式（MediaImageFormat.Jpeg 或 .Png）
     * @param quality       压缩质量（0-100）；JPEG 常用 60（iOS 默认 0.6）
     * @return 编码后字节数组；失败时返回空数组
     */
    public func fetchResizedPhotoBytes(
        ctx: UIAbilityContext,
        assetUri: String,
        targetWidth!: Int32 = 1280,
        targetHeight!: Int32 = 1280,
        format!: MediaImageFormat = MediaImageFormat.Jpeg,
        quality!: Int32 = 60
    ): Array<Byte> {
        let empty: Array<Byte> = Array<Byte>(0, repeat: 0)
        if (assetUri.size == 0) {
            return empty
        }
        try {
            let phAccessHelper = getPhotoAccessHelper(ctx)
            let predicates = DataSharePredicates()
            let fetchOptions = FetchOptions([], predicates)
            let fetchResultObj: PhotoAssetResult = phAccessHelper.getAssets(fetchOptions)
            let assets = fetchResultObj.getAllObjects()
            for (asset in assets) {
                if (asset.uri == assetUri) {
                    let w: Int32 = if (targetWidth > 0) { targetWidth } else { 256 }
                    let h: Int32 = if (targetHeight > 0) { targetHeight } else { 256 }
                    let thumbSize = Size(w, h)
                    let pixmap = asset.getThumbnail(size: thumbSize)

                    let clampedQuality: UInt8 = if (quality < 0) {
                        0u8
                    } else if (quality > 100) {
                        100u8
                    } else {
                        UInt8(quality)
                    }
                    let mime = mediaImageFormatMIME(format)
                    let packOpts = PackingOption(mime, clampedQuality)
                    let imagePacker = createImagePacker()
                    let encoded = imagePacker.packToData(pixmap, packOpts)
                    imagePacker.release()
                    Hilog.info(0, "CjTelegram",
                        "[LocalMediaRes] fetchResizedPhotoBytes ok: uri=${assetUri} fmt=${mime} q=${quality} sz=${encoded.size}")
                    return encoded
                }
            }
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchResizedPhotoBytes: asset not found: ${assetUri}")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchResizedPhotoBytes error: ${e.message}")
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchResizedPhotoBytes unexpected error")
        }
        return empty
    }

    /**
     * 获取相册资产的 PhotoAsset 对象（供 ViewModel 直接操作）。
     *
     * 对应 iOS fetchPhotoLibraryImage(localIdentifier:thumbnail:false) 中取 PHAsset 对象的步骤。
     * HarmonyOS 端 ViewModel 可通过该对象调用 asset.getThumbnail() / asset.uri 等成员。
     *
     * @param ctx       UIAbilityContext 实例
     * @param assetUri  资产 URI
     * @return 找到的 PhotoAsset；None = 未找到或出错
     */
    public func fetchPhotoAssetByUri(ctx: UIAbilityContext, assetUri: String): Option<PhotoAsset> {
        let notFound: Option<PhotoAsset> = None
        if (assetUri.size == 0) {
            return notFound
        }
        try {
            let phAccessHelper = getPhotoAccessHelper(ctx)
            let predicates = DataSharePredicates()
            let fetchOptions = FetchOptions([], predicates)
            let fetchResultObj: PhotoAssetResult = phAccessHelper.getAssets(fetchOptions)
            let assets = fetchResultObj.getAllObjects()
            for (asset in assets) {
                if (asset.uri == assetUri) {
                    Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchPhotoAssetByUri found: ${assetUri}")
                    return Some(asset)
                }
            }
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchPhotoAssetByUri not found: ${assetUri}")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchPhotoAssetByUri error: ${e.message}")
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[LocalMediaRes] fetchPhotoAssetByUri unexpected error")
        }
        return notFound
    }
}
