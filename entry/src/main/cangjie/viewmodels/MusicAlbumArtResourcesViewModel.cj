package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.services.getMusicAlbumArtResourcesService
import ohos_app_cangjie_entry.services.AlbumArtResult

/**
 * MusicAlbumArtResourcesViewModel — 专辑封面资源 ViewModel
 *
 * iOS 对应: ExternalMusicAlbumArtResource + fetchExternalMusicAlbumArtResource
 * (submodules/MusicAlbumArtResources/Sources/ExternalMusicAlbumArtResources.swift)
 *
 * 职责:
 * - 封装异步加载逻辑（spawn + MusicAlbumArtResourcesService.fetchAlbumArt）
 * - 暴露 @Publish 可观察状态（artworkDataUrl, isLoading, errorMessage）
 * - 上层 UI 通过 loadAlbumArt() 触发加载，订阅 artworkDataUrl 渲染图片
 */
@Observed
public class MusicAlbumArtResourcesViewModel {
    // 当前专辑封面的 data:image/jpeg;base64,... URL（空字符串表示未加载）
    @Publish public var artworkDataUrl: String = ""

    // 当前 uniqueId，对应 iOS ExternalMusicAlbumArtResourceId.uniqueId
    @Publish public var currentUniqueId: String = ""

    // 是否正在加载
    @Publish public var isLoading: Bool = false

    // 错误信息（空字符串表示无错误）
    @Publish public var errorMessage: String = ""

    // 当前正在加载的请求 key（防止旧请求覆盖新结果）
    private var pendingKey: String = ""

    /**
     * 触发专辑封面异步加载
     *
     * 调用链: loadAlbumArt → spawn → getMusicAlbumArtResourcesService().fetchAlbumArt()
     *         → update artworkDataUrl / isLoading / errorMessage
     *
     * isThumbnail=true  → 拉取低分辨率缩略图（100x100）
     * isThumbnail=false → 拉取高分辨率封面（600x600）
     */
    public func loadAlbumArt(title!: String, performer!: String, isThumbnail!: Bool): Unit {
        let service = getMusicAlbumArtResourcesService()
        let uid = service.buildUniqueId(title: title, performer: performer, isThumbnail: isThumbnail)

        // 避免重复加载同一首曲目
        if (this.currentUniqueId == uid && this.artworkDataUrl.size > 0) {
            Hilog.info(0, "CjTelegram", "[AlbumArtVM] Already loaded, skip")
            return
        }

        // 重置状态
        this.isLoading = true
        this.errorMessage = ""
        this.pendingKey = uid

        let capturedTitle = title
        let capturedPerformer = performer
        let capturedIsThumbnail = isThumbnail
        let capturedUid = uid

        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[AlbumArtVM] Starting fetch")
            let result = getMusicAlbumArtResourcesService().fetchAlbumArt(
                title: capturedTitle,
                performer: capturedPerformer,
                isThumbnail: capturedIsThumbnail
            )
            launch {
                this.onFetchComplete(result, capturedUid)
            }
        }
    }

    /**
     * 处理 fetchAlbumArt 完成回调
     * 仅在 expectedUid 与当前 pendingKey 一致时更新状态（防止竞态）
     */
    private func onFetchComplete(result: AlbumArtResult, expectedUid: String): Unit {
        if (this.pendingKey != expectedUid) {
            Hilog.info(0, "CjTelegram", "[AlbumArtVM] Stale result, discard")
            return
        }

        this.isLoading = false

        if (result.success) {
            this.artworkDataUrl = result.imageDataUrl
            this.currentUniqueId = result.uniqueId
            this.errorMessage = ""
            Hilog.info(0, "CjTelegram", "[AlbumArtVM] Artwork loaded successfully")
        } else {
            this.artworkDataUrl = ""
            this.errorMessage = result.errorMessage
            Hilog.info(0, "CjTelegram", "[AlbumArtVM] Artwork load failed")
        }
    }

    /**
     * 重置 ViewModel 状态（切换曲目时调用）
     */
    public func reset(): Unit {
        this.artworkDataUrl = ""
        this.currentUniqueId = ""
        this.isLoading = false
        this.errorMessage = ""
        this.pendingKey = ""
    }
}
