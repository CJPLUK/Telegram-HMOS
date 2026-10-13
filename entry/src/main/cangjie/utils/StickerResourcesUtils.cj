package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.getStickerResourcesBinding
import ohos_app_cangjie_entry.bindings.StickerResourceDescriptor

/**
 * StickerResourcesUtils — 贴纸资源上层工具接口
 *
 * 对应 Telegram-iOS StickerResources.swift 公开函数的上层调用接口：
 *   chatMessageStickerResource(file:small:)  → getStickerResource
 *   缓存键派生逻辑                            → getStickerCacheKey / getStickerPackThumbnailCacheKey
 *   thumbSize 路由决策                        → resolveStickerThumbSize
 *
 * 层次说明：
 *   utils 层位于 services 层之下（services 导入 utils，不可反向）。
 *   因此本层只提供纯逻辑封装，实际 MTProto 下载由上层（services / viewmodels）
 *   通过 FileDownloadService 完成，调用方示例：
 *
 *     // 在 services 层使用：
 *     let desc = getStickerResource(fileId, accessHash, fileRef, small: true)
 *     let thumbSize = resolveStickerThumbSize(desc.isSmall, animated: false)
 *     let data = getFileDownloadService().downloadDocumentThumb(
 *         desc.fileId, desc.accessHash, desc.fileReference, thumbSize: thumbSize)
 *
 * S-64/R-69 自查（N/A）：
 *   本文件为纯逻辑工具函数，无 @Component / build() / aboutToAppear，
 *   S-64（aboutToAppear 必须 public）和 R-69（spawn 返回值）均不适用。
 */

/**
 * 按 small 标志获取贴纸资源描述符
 *
 * 对应 iOS chatMessageStickerResource(file:small:)。
 * small == true  → 缩略图资源描述符（isSmall=true，下载时使用 thumbSize="s"）
 * small == false → 完整贴纸资源描述符（isSmall=false，下载时使用 downloadDocument）
 *
 * @param fileId      TelegramMediaFile.id
 * @param accessHash  TelegramMediaFile.accessHash
 * @param fileRef     TelegramMediaFile.fileReference
 * @param small       true 时返回缩略图资源描述符
 * @return            StickerResourceDescriptor，由调用方传给 FileDownloadService 完成下载
 */
public func getStickerResource(
    fileId: Int64,
    accessHash: Int64,
    fileRef: Array<Byte>,
    small: Bool
): StickerResourceDescriptor {
    return getStickerResourcesBinding().getStickerResource(
        fileId,
        accessHash,
        fileRef,
        small
    )
}

/**
 * 派生贴纸资源缓存键
 *
 * 对应 iOS chatMessageStickerDatas 中 thumbnailResource / resource 的 id 路由：
 *   small == true  → 缩略图缓存键（fileId XOR 1，避免与完整资源键冲突）
 *   small == false → 完整资源缓存键（直接使用 fileId）
 *
 * @param fileId  TelegramMediaFile.id
 * @param small   是否为缩略图资源
 * @return        Int64 缓存键
 */
public func getStickerCacheKey(fileId: Int64, small: Bool): Int64 {
    return getStickerResourcesBinding().getStickerCacheKey(fileId, small)
}

/**
 * 计算贴纸包封面缩略图的缓存键
 *
 * 对应 iOS chatMessageStickerPackThumbnailData 中资源 ID 的缓存键。
 * 贴纸包封面使用独立键（fileId XOR 2），避免与贴纸自身缓存冲突。
 *
 * @param fileId  贴纸包缩略图资源 ID
 * @return        Int64 缓存键
 */
public func getStickerPackThumbnailCacheKey(fileId: Int64): Int64 {
    return getStickerResourcesBinding().getStickerPackThumbnailCacheKey(fileId)
}

/**
 * 解析贴纸下载时应使用的 thumbSize 参数
 *
 * 对应 iOS chatMessageStickerDatas / chatMessageAnimatedStickerDatas 中
 * CachedStickerAJpegRepresentation(size:) 的 size 参数路由：
 *   isSmall == true,  animated == false → "s"（~100x100 静态缩略图）
 *   isSmall == false, animated == false → "" （完整贴纸，使用 downloadDocument）
 *   isSmall == true,  animated == true  → "s"（动画贴纸缩略图）
 *   isSmall == false, animated == true  → "" （完整动画贴纸，使用 downloadDocument）
 *
 * 空字符串 "" 表示调用方应使用 downloadDocument（完整下载），而非 downloadDocumentThumb。
 *
 * @param isSmall   是否请求缩略图
 * @param animated  是否为动画贴纸（Lottie / WebM）
 * @return          thumbSize 字符串；"" 表示需要完整下载
 */
public func resolveStickerThumbSize(isSmall: Bool, animated: Bool): String {
    if (isSmall) {
        return "s"
    }
    return ""
}

/**
 * 解析贴纸包封面下载时应使用的 thumbSize 参数
 *
 * 对应 iOS chatMessageStickerPackThumbnailData 中
 * CachedStickerAJpegRepresentation(size: CGSize(160, 160)) 的路由。
 * 贴纸包封面始终使用中等缩略图（~160x160）。
 *
 * @return "m"（medium，约 160x160）
 */
public func stickerPackThumbnailThumbSize(): String {
    return "m"
}
