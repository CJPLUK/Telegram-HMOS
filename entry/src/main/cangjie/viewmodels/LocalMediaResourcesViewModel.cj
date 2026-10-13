package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.ImageKit.PixelMap
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*

/**
 * LocalMediaResourcesViewModel — 本地图库资源视图模型
 *
 * iOS 对应：PHAsset / PHImageManager 客户端使用层（FetchPhotoLibraryImageResource.swift）
 *
 * 职责：
 * - 从 LocalMediaResourcesService 异步加载本地图库资产列表
 * - 按需获取指定 URI 资产的缩略图（PixelMap），通过回调通知 UI 层
 * - 向 UI 层暴露加载状态（isLoading）、资产列表（photoAssets）
 *
 * 调用链（完整）：
 *   UI 触发 loadPhotoAssets()
 *     → spawn 后台
 *       → LocalMediaResourcesService.fetchAllPhotoAssets(ctx)
 *         → getPhotoAccessHelper(ctx) → phAccessHelper.getAssets() → getAllObjects()
 *     → launch 主线程 → 更新 @Publish photoAssets / isLoading
 *
 *   UI 触发 loadThumbnail(uri, onLoaded)
 *     → spawn 后台
 *       → LocalMediaResourcesService.fetchThumbnailByUri(ctx, uri, w, h)
 *         → phAccessHelper.getAssets() → asset.getThumbnail(size: Size(w, h))
 *     → launch 主线程 → 回调 onLoaded(pixmap)
 *
 * 线程安全：
 *   所有 @Publish 变量赋值均在 launch {} 主线程执行（遵循修复 #69 规范）。
 *   spawn 返回值用 let _ = spawn { ... } 丢弃（遵循 S-64/R-69）。
 *
 * Size 歧义规避（#87）：
 *   getThumbnail() 调用及 Size() 构造放在 services 包（只 import kit.MediaLibraryKit.*），
 *   ViewModel 只 import kit.MediaLibraryKit.PixelMap 避免 Size 与 kit.ArkUI.Size 冲突。
 */
@Observed
public class LocalMediaResourcesViewModel {

    /** 是否正在加载资产列表 */
    @Publish public var isLoading: Bool = false

    /** 已加载的本地图库资产列表 */
    @Publish public var photoAssets: ArrayList<LocalPhotoAssetInfo> = ArrayList<LocalPhotoAssetInfo>()

    /** 是否已完成首次加载 */
    @Publish public var hasLoaded: Bool = false

    /** 最近一次错误描述（空字符串 = 无错误）*/
    @Publish public var lastError: String = ""

    // ── 资产列表加载 ────────────────────────────────────────────────

    /**
     * 异步加载本地图库所有图片/视频资产列表。
     *
     * 对应 iOS fetchPhotoLibraryResource 中 PHAsset.fetchAssets 批量版本。
     * 需要 READ_IMAGEVIDEO 权限；在 module.json5 中声明 + 运行时已授权。
     *
     * 调用链：
     *   loadPhotoAssets()
     *     → LocalMediaResourcesService.fetchAllPhotoAssets(ctx)
     *       → photoAccessHelper.getAssets() → getAllObjects() → LocalPhotoAssetInfo 列表
     */
    public func loadPhotoAssets(): Unit {
        if (this.isLoading) {
            Hilog.info(0, "CjTelegram", "[LocalMediaResVM] loadPhotoAssets: already loading")
            return
        }
        this.isLoading = true
        this.lastError = ""
        Hilog.info(0, "CjTelegram", "[LocalMediaResVM] loadPhotoAssets: start")
        let _ = spawn {
            let svc = getLocalMediaResourcesService()
            var assets = ArrayList<LocalPhotoAssetInfo>()
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    assets = svc.fetchAllPhotoAssets(ctx)
                case None =>
                    Hilog.info(0, "CjTelegram", "[LocalMediaResVM] loadPhotoAssets: no context")
            }
            let loadedAssets = assets
            launch {
                this.photoAssets = loadedAssets
                this.isLoading = false
                this.hasLoaded = true
                Hilog.info(0, "CjTelegram", "[LocalMediaResVM] loadPhotoAssets: loaded ${loadedAssets.size}")
            }
        }
    }

    // ── 缩略图加载 ─────────────────────────────────────────────────

    /**
     * 异步加载指定 URI 资产的缩略图（默认 128x128）。
     *
     * 对应 iOS:
     *   fetchPhotoLibraryImage(localIdentifier:thumbnail:true)
     *   PHImageManager.default().requestImage(for:, targetSize:CGSize(128,128), contentMode:.aspectFill)
     *
     * 降级说明：
     *   iOS 使用 PHImageRequestID 可取消请求；HarmonyOS 的 getThumbnail() 是同步调用，无取消机制。
     *   Size / getThumbnail() 调用委托给 LocalMediaResourcesService（services 包，仅 import MediaLibraryKit），
     *   以规避 ViewModel 中 kit.ArkUI.Size 与 kit.MediaLibraryKit.Size 的命名冲突（参见修复 #87）。
     *
     * @param uri              资产 URI（来自 LocalPhotoAssetInfo.uri）
     * @param thumbnailWidth   缩略图宽度（像素），默认 128
     * @param thumbnailHeight  缩略图高度（像素），默认 128
     * @param onLoaded         主线程回调，参数为缩略图 PixelMap（失败时为 None）
     *
     * 调用链：
     *   loadThumbnail(uri)
     *     → LocalMediaResourcesService.fetchThumbnailByUri(ctx, uri, w, h)
     *       → photoAccessHelper.getAssets() → asset.getThumbnail(size: Size(w, h))
     *     → launch { onLoaded(pixmap) }
     */
    public func loadThumbnail(
        uri: String,
        thumbnailWidth!: Int32 = 128,
        thumbnailHeight!: Int32 = 128,
        onLoaded!: (Option<PixelMap>) -> Unit = { _pixmap: Option<PixelMap> => }
    ): Unit {
        if (uri.size == 0) {
            onLoaded(None)
            return
        }
        Hilog.info(0, "CjTelegram", "[LocalMediaResVM] loadThumbnail: uri=${uri}")
        let uriCopy = uri
        let wCopy = thumbnailWidth
        let hCopy = thumbnailHeight
        let _ = spawn {
            let svc = getLocalMediaResourcesService()
            var resultPixmap: Option<PixelMap> = None
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    resultPixmap = svc.fetchThumbnailByUri(
                        ctx,
                        uriCopy,
                        thumbnailWidth: wCopy,
                        thumbnailHeight: hCopy
                    )
                case None =>
                    Hilog.info(0, "CjTelegram", "[LocalMediaResVM] loadThumbnail: no context")
            }
            let finalPixmap = resultPixmap
            launch {
                onLoaded(finalPixmap)
            }
        }
    }

    /**
     * 异步加载指定 URI 资产的高分辨率原图（用于发送前预览）。
     *
     * 对应 iOS fetchPhotoLibraryResource(localIdentifier:width:height:...) 高质量版本。
     * iOS 使用 PHImageManagerMaximumSize 或 1280x1280 请求原始图像；
     * HarmonyOS 对应 fetchThumbnailByUri 使用大尺寸 Size(1280, 1280)。
     *
     * @param uri      资产 URI
     * @param onLoaded 主线程回调（参数为 PixelMap Option）
     */
    public func loadOriginalImage(
        uri: String,
        onLoaded!: (Option<PixelMap>) -> Unit = { _pixmap: Option<PixelMap> => }
    ): Unit {
        loadThumbnail(
            uri,
            thumbnailWidth: 1280,
            thumbnailHeight: 1280,
            onLoaded: onLoaded
        )
    }
}
