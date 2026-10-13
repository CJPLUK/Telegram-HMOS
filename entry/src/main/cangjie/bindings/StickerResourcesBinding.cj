package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog

/**
 * StickerResourcesBinding — 贴纸资源描述符与缓存键派生封装层
 *
 * 对应 Telegram-iOS StickerResources.swift 中的：
 *   - chatMessageStickerResource(file:small:) — 按 small 选择资源（缩略图 vs 完整）
 *   - resource.id 驱动的缓存键逻辑（thumbnailResource vs resource）
 *
 * 职责（纯逻辑，无 MTProto 调用）：
 *   1. 构建 StickerResourceDescriptor（包含 fileId / accessHash / fileRef / isSmall）
 *   2. 派生缓存键（small 缩略图与完整资源使用不同键以避免冲突）
 *
 * 不引用 services 层，避免 bindings ↔ services 循环依赖。
 * 实际下载由 StickerResourcesUtils（utils 层）协调 FileDownloadService 完成。
 *
 * S-64/R-69 自查（N/A）：
 *   本文件为纯逻辑服务类，无 @Component / build() / aboutToAppear，
 *   S-64（aboutToAppear 必须 public）和 R-69（spawn 返回值）均不适用。
 */

private var _stickerResourcesBindingInstance: Option<StickerResourcesBinding> = None

/**
 * 获取 StickerResourcesBinding 单例
 */
public func getStickerResourcesBinding(): StickerResourcesBinding {
    match (_stickerResourcesBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = StickerResourcesBinding()
            _stickerResourcesBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 贴纸资源描述符 — 对应 iOS chatMessageStickerResource 的返回值
 *
 * 包含下载所需的全部字段，替代 iOS MediaResource 协议对象。
 * isSmall == true  → 对应 thumbnailResource（缩略图，~160x160）
 * isSmall == false → 对应 resource（完整贴纸数据）
 */
public class StickerResourceDescriptor {
    public var fileId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: UInt8(0))
    public var isSmall: Bool = false

    public init() {}

    public init(
        fileId!: Int64,
        accessHash!: Int64,
        fileReference!: Array<Byte>,
        isSmall!: Bool
    ) {
        this.fileId = fileId
        this.accessHash = accessHash
        this.fileReference = fileReference
        this.isSmall = isSmall
    }
}

/**
 * 贴纸资源绑定层（纯逻辑：描述符构建 + 缓存键派生）
 */
public class StickerResourcesBinding {

    /**
     * 按 small 标志选择贴纸资源描述符
     *
     * 对应 iOS chatMessageStickerResource(file:small:)：
     *   small == true  → 选择缩略图预览资源（thumbSize = "s"）
     *   small == false → 选择完整贴纸资源（原始文档）
     *
     * @param fileId      TelegramMediaFile.id
     * @param accessHash  TelegramMediaFile.accessHash
     * @param fileRef     TelegramMediaFile.fileReference
     * @param small       true 时返回缩略图资源描述符
     * @return            StickerResourceDescriptor
     */
    public func getStickerResource(
        fileId: Int64,
        accessHash: Int64,
        fileRef: Array<Byte>,
        small: Bool
    ): StickerResourceDescriptor {
        Hilog.info(0, "CjTelegram", "[StickerResourcesBinding] getStickerResource small=${small}")
        return StickerResourceDescriptor(
            fileId: fileId,
            accessHash: accessHash,
            fileReference: fileRef,
            isSmall: small
        )
    }

    /**
     * 派生贴纸资源缓存键
     *
     * 对应 iOS chatMessageStickerDatas 中对 thumbnailResource.id 和 resource.id 的使用：
     *   small == true  → 缩略图缓存键（fileId XOR 1，避免与完整资源键冲突）
     *   small == false → 完整资源缓存键（直接使用 fileId）
     *
     * @param fileId  TelegramMediaFile.id
     * @param small   是否为缩略图
     * @return        Int64 缓存键
     */
    public func getStickerCacheKey(fileId: Int64, small: Bool): Int64 {
        if (small) {
            return fileId ^ Int64(1)
        }
        return fileId
    }

    /**
     * 计算贴纸包封面缩略图的缓存键
     *
     * 对应 iOS chatMessageStickerPackThumbnailData 中资源 ID 的使用。
     * 贴纸包封面使用独立键（fileId XOR 2）避免与贴纸自身缓存冲突。
     *
     * @param fileId  贴纸包缩略图资源 ID
     * @return        Int64 缓存键
     */
    public func getStickerPackThumbnailCacheKey(fileId: Int64): Int64 {
        return fileId ^ Int64(2)
    }
}
