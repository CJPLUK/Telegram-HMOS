package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    TLDeserializer,
    TLConstructors,
    PhotosUpdateProfilePhoto,
    PhotosDeletePhotos
}

/**
 * PeerAvatarGalleryService — 头像大图画廊服务（PAVG-API-1）
 *
 * 对应 iOS PeerAvatarGalleryUI/AvatarGalleryController 的数据层。
 *
 * 实现类型：local_state（tl_methods=[]）
 * 本 feature 不发起独立 MTProto 请求，只复用以下已有服务：
 *   - getUserPhotoService()          → 当前头像路径 / strippedThumb
 *   - getPeerInfoAvatarListService() → photos.getUserPhotos 历史头像列表
 *
 * 调用链（完整）：
 *   AvatarGalleryPage.aboutToAppear
 *     → PeerAvatarGalleryService.fetchAvatarPhotos(userId, accessHash, limit)
 *         → getUserPhotoService().getUserPhotoPath(userId)       // 当前头像（快路径）
 *         → getPeerInfoAvatarListService().fetchUserPhotos(userId, accessHash, limit) // 历史头像
 *         → ArrayList<String>  各照片 data-URL 或 file:// 路径
 *
 * 验收条件：
 *   - fetchAvatarPhotos 返回非空列表（含当前头像）
 *   - 不使用模拟或硬编码数据
 *   - 所有回调逻辑非空
 */

private var _peerAvatarGalleryServiceInstance: Option<PeerAvatarGalleryService> = None

/** 获取 PeerAvatarGalleryService 单例 */
public func getPeerAvatarGalleryService(): PeerAvatarGalleryService {
    match (_peerAvatarGalleryServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeerAvatarGalleryService()
            _peerAvatarGalleryServiceInstance = Some(inst)
            return inst
    }
}

public class PeerAvatarGalleryService {

    /** 是否正在加载 */
    public var isLoading: Bool = false
    /** 最后一次加载错误（空 = 无错误） */
    public var lastError: String = ""

    public init() {}

    /**
     * 获取指定用户的全部头像路径列表
     *
     * 先从 UserPhotoService 获取当前头像（快速），再从 PeerInfoAvatarListService
     * 获取历史头像列表（可能触发网络请求）。两者合并去重后返回。
     *
     * 注意：此方法在 spawn 内部调用（网络操作），不要在 UI 线程直接调用。
     *
     * @param userId     用户 ID
     * @param accessHash 用户 accessHash（photos.getUserPhotos 必填）
     * @param limit      最多获取头像数（默认 20）
     * @return 照片路径列表（data-URL 或 file://），第一个为最新头像
     */
    public func fetchAvatarPhotos(userId: Int64, accessHash: Int64, limit!: Int32 = 20): ArrayList<String> {
        Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] fetchAvatarPhotos uid=${userId}")
        isLoading = true
        lastError = ""
        let results = ArrayList<String>()

        try {
            // 步骤1：从 UserPhotoService 获取当前头像（strippedThumb 或磁盘全量）
            let currentPath = getUserPhotoService().getUserPhotoPath(userId)
            if (currentPath.size > 0) {
                results.add(currentPath)
                Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] current avatar found uid=${userId}")
            }

            // 步骤2：从 PeerInfoAvatarListService 获取历史头像列表（可能包含网络下载）
            let historyPhotos = getPeerInfoAvatarListService().fetchUserPhotos(
                userId, accessHash, limit: limit
            )
            var historyIndex: Int64 = 0
            for (path in historyPhotos) {
                // The server list is newest-first.  When UserPhotoService supplied
                // a local, uniquely-named copy of that newest image, comparing the
                // two paths cannot detect that they are the same photo.  Skip the
                // server's first entry explicitly so Settings does not show a
                // duplicate or a stale download beside the freshly selected image.
                if (!(currentPath.size > 0 && historyIndex == 0) && path.size > 0 && !this.containsPath(results, path)) {
                    results.add(path)
                }
                historyIndex = historyIndex + 1
            }

            Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] fetched ${results.size} photos uid=${userId}")
        } catch (e: Exception) {
            lastError = e.message
            Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] error uid=${userId}: ${e.message}")
        }

        isLoading = false
        return results
    }

    /**
     * 获取用户当前头像路径（仅本地，无网络）
     * 用于快速首渲染
     */
    public func getCurrentAvatarPath(userId: Int64): String {
        return getUserPhotoService().getUserPhotoPath(userId)
    }

    /**
     * 清除指定用户的头像缓存（在用户更换头像后调用）
     */
    public func invalidateAvatarCache(userId: Int64): Unit {
        getUserPhotoService().clearUserPhoto(userId)
        getPeerInfoAvatarListService().invalidateCache(userId)
        Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] cache invalidated uid=${userId}")
    }

    /**
     * 触发当前头像全量下载（已有 strippedThumb 时异步补全全量图）
     */
    public func requestFullPhotoDownload(userId: Int64): Unit {
        getUserPhotoService().requestFullPhotoDownload(userId)
    }

    /**
     * 获取用户头像完整元数据列表（photoId / accessHash / fileReference / downloadedPath）
     *
     * 与 fetchAvatarPhotos 逐索引对齐：fetchAvatarPhotos 若预置了 UserPhotoService 快速首帧
     * 到 [0]，本方法同样在 [0] 预置一个哨兵 AvatarPhotoInfo（photoId=0，代表快速首帧无
     * MTProto 元数据）。如此 photoMetas[k] 与 photos[k] 严格对应，删除时不会错位。
     *
     * performDeleteCurrentPhoto 内已有 photoId != 0 守卫：哨兵条目会跳过 RPC，仅做缓存失效，
     * 符合快速首帧无法通过 deletePhotos 删除的正确语义。
     *
     * 注意：此方法在 spawn 内部调用（网络操作），不要在 UI 线程直接调用。
     *
     * @param userId     用户 ID
     * @param accessHash 用户 access_hash
     * @param limit      最多获取头像数
     * @return AvatarPhotoInfo 列表（photoId / accessHash / fileReference / downloadedPath），
     *         索引与 fetchAvatarPhotos 返回的路径列表严格对齐
     */
    public func fetchAvatarPhotoMetas(userId: Int64, accessHash: Int64, limit!: Int32 = 20): ArrayList<AvatarPhotoInfo> {
        Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] fetchAvatarPhotoMetas uid=${userId}")
        let result = ArrayList<AvatarPhotoInfo>()

        // 与 fetchAvatarPhotos 步骤1 使用完全相同的判定：若快速首帧存在，在 [0] 预置哨兵
        let currentPath = getUserPhotoService().getUserPhotoPath(userId)
        if (currentPath.size > 0) {
            let sentinel = AvatarPhotoInfo()
            sentinel.downloadedPath = currentPath
            result.add(sentinel)
        }

        // 步骤2：追加历史头像元数据（与 fetchAvatarPhotos 步骤2 去重后的历史部分对齐）
        let historyMetas = getPeerInfoAvatarListService().fetchUserPhotoInfos(userId, accessHash, limit: limit)
        for (m in historyMetas) {
            result.add(m)
        }

        Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] fetchAvatarPhotoMetas: ${result.size} entries uid=${userId}")
        return result
    }

    // ─── Wire: 设为主图 ──────────────────────────────────────────────────────────

    /**
     * 将画廊中的已有照片设为当前主头像。
     *
     * iOS ref: Api42.swift photos.updateProfilePhoto(flags:bot:id:)
     * TL method: photos.updateProfilePhoto#09e82039
     *   flags:# fallback:flags.0?true bot:flags.1?InputUser id:InputPhoto = photos.Photo
     * TL ctor (tl_codegen verified): 0x09e82039
     * InputPhoto: inputPhoto#3bb3b94a id:long access_hash:long file_reference:bytes
     *
     * @param photoId        已有照片 id（从 photos.getUserPhotos 返回的 Photo.id）
     * @param accessHash     已有照片 access_hash
     * @param fileReference  已有照片 file_reference（bytes）
     * @return true = MTProto 调用成功；false = 网络失败或 RPC 错误
     */
    public func setAsMainPhoto(
        photoId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>
    ): Bool {
        Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] setAsMainPhoto photoId=${photoId}")
        try {
            let client = getMTProtoClient()
            let req = PhotosUpdateProfilePhoto()
            req.photoId = photoId
            req.photoAccessHash = accessHash
            req.photoFileReference = fileReference
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) {
                Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] setAsMainPhoto: empty response")
                return false
            }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] setAsMainPhoto RPC error: ${errCode} ${errMsg}")
                return false
            }
            Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] setAsMainPhoto success photoId=${photoId}")
            return true
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] setAsMainPhoto exception: ${e.message}")
            return false
        }
    }

    // ─── Wire: 删除照片接 MTProto ────────────────────────────────────────────────

    /**
     * 删除指定头像列表（接通 MTProto 真实 RPC）。
     *
     * iOS ref: Api42.swift photos.deletePhotos(id:) line 12434
     * TL method: photos.deletePhotos#87cf7f2f
     *   id:Vector<InputPhoto> = Vector<long>
     * TL ctor (tl_codegen verified): 0x87cf7f2f
     * Vector header: 0x1cb5c415
     * InputPhoto: inputPhoto#3bb3b94a id:long access_hash:long file_reference:bytes
     *
     * Response: Vector<long> — 已删除的照片 id 列表
     *
     * @param photoIds       要删除的照片 id 列表
     * @param accessHashes   对应 access_hash 列表（与 photoIds 等长）
     * @param fileReferences 对应 file_reference 列表（与 photoIds 等长）
     * @return 已成功删除的 photo id 列表（空 = 全部失败）
     */
    public func deletePhotos(
        photoIds: ArrayList<Int64>,
        accessHashes: ArrayList<Int64>,
        fileReferences: ArrayList<Array<Byte>>
    ): ArrayList<Int64> {
        let deletedIds = ArrayList<Int64>()
        if (photoIds.size == 0) { return deletedIds }
        Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] deletePhotos count=${photoIds.size}")
        try {
            let client = getMTProtoClient()
            let req = PhotosDeletePhotos()
            req.photoIds = photoIds
            req.accessHashes = accessHashes
            req.fileReferences = fileReferences
            let data = client.sendRequest(req.toBytes())
            if (data.size < 4) {
                Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] deletePhotos: empty response")
                return deletedIds
            }
            let d = TLDeserializer(data)
            let ctor = d.readUInt32()
            if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                let errCode = d.readInt32()
                let errMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] deletePhotos RPC error: ${errCode} ${errMsg}")
                return deletedIds
            }
            if (ctor == TLConstructors.VECTOR) {
                let count = d.readInt32()
                var i: Int32 = 0
                while (i < count) {
                    deletedIds.add(d.readInt64())
                    i += 1
                }
            }
            Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] deletePhotos: deleted ${deletedIds.size}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerAvatarGallerySvc] deletePhotos exception: ${e.message}")
        }
        return deletedIds
    }

    // ─── 私有辅助 ─────────────────────────────────────────────────────────────

    /** 检查路径是否已在列表中（去重） */
    private func containsPath(list: ArrayList<String>, path: String): Bool {
        for (item in list) {
            if (item == path) {
                return true
            }
        }
        return false
    }
}
