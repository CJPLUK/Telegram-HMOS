package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap
import stdx.encoding.base64.*

/**
 * PeerInfoAvatarListService — 资料页头像列表服务
 *
 * 对应 iOS PeerInfoAvatarListNode (资料页头像轮播数据层)
 *
 * 功能:
 * - 调用 photos.getUserPhotos TL 方法获取用户全部头像列表
 * - 通过 FileDownloadService.downloadUserPhoto 下载各头像
 * - 缓存已下载的头像路径列表
 *
 * 调用链: fetchUserPhotos() → MTProtoClient.sendRequest() →
 *         TLDeserializer 解析 photos.Photos → downloadUserPhoto() → paths
 */

// photos.getUserPhotos#91cd32a8
// flags:# user_id:InputUser offset:int max_id:long limit:int = photos.Photos
private let PHOTOS_GET_USER_PHOTOS: UInt32 = 0x91cd32a8

// photos.photos#8dca6aa5  count:int photos:Vector<Photo> users:Vector<User>
private let PHOTOS_PHOTOS: UInt32 = 0x8dca6aa5
// photos.photosSlice#15051f54  count:int next_rate:int photos:Vector<Photo> users:Vector<User>
private let PHOTOS_PHOTOS_SLICE: UInt32 = 0x15051f54

private var _peerInfoAvatarListServiceInstance: Option<PeerInfoAvatarListService> = None

public func getPeerInfoAvatarListService(): PeerInfoAvatarListService {
    match (_peerInfoAvatarListServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = PeerInfoAvatarListService()
            _peerInfoAvatarListServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 一条头像记录：photo_id + access_hash + file_reference + dc_id
 * 用于驱动 downloadUserPhoto 和 deletePhotos / setAsMainPhoto 调用
 */
public class AvatarPhotoInfo {
    public var photoId: Int64 = 0
    public var accessHash: Int64 = 0
    public var dcId: Int32 = 0
    public var date: Int32 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var thumbSize: String = "x"
    public var downloadedPath: String = ""
    public var emojiDocumentId: Int64 = 0
    public var emojiBackgroundColors: ArrayList<Int32> = ArrayList<Int32>()
    // Photo.sizes 中 w*h 最大的一档（photoSize / photoSizeProgressive）；空串表示无可下载档。
    public var largestSizeType: String = ""
    public var largestW: Int32 = 0
    public var largestH: Int32 = 0
}

public class PeerInfoAvatarListService {
    // userId → 主头像原图本地路径（file://）
    private var fullPhotoPathCache: HashMap<Int64, String> = HashMap<Int64, String>()

    // peerId → ArrayList<String> (photo file:// or data-url paths, in order)
    private var photosCache: HashMap<Int64, ArrayList<String>> = HashMap<Int64, ArrayList<String>>()
    private var currentPhotoInfoCache: HashMap<Int64, AvatarPhotoInfo> = HashMap<Int64, AvatarPhotoInfo>()

    public func getCurrentPhotoInfo(userId: Int64): Option<AvatarPhotoInfo> {
        return this.currentPhotoInfoCache.get(userId)
    }

    /**
     * 获取用户头像列表（同步，在 spawn 中调用）
     *
     * @param userId   用户 ID（对应 photos.getUserPhotos user_id）
     * @param accessHash 用户 access_hash
     * @param limit    最多请求头像数（通常 10）
     * @return ArrayList<String>  各头像的 data-URL 或 file:// 路径，按从新到旧排列
     */
    public func fetchUserPhotos(userId: Int64, accessHash: Int64, limit!: Int32 = 10): ArrayList<String> {
        if (this.photosCache.contains(userId)) {
            return this.photosCache[userId]
        }

        Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] fetchUserPhotos uid=${userId}")

        // 先尝试获取当前已缓存的 strippedThumb 作为第一张（快速渲染）
        let results = ArrayList<String>()
        let firstPath = getUserPhotoService().getUserPhotoPath(userId)
        if (firstPath.size > 0) {
            results.add(firstPath)
        }

        // 调用 photos.getUserPhotos 获取完整头像列表
        let photoInfoList = this.callGetUserPhotos(userId, accessHash, limit: limit)
        if (photoInfoList.isEmpty()) {
            if (results.isEmpty()) {
                Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] no photos for uid=${userId}")
            }
            this.photosCache[userId] = results
            return results
        }

        // 下载各头像
        let downloadService = getFileDownloadService()
        var isCurrentUser = false
        match (getRealAuthService().getCurrentUser()) {
            case Some(me) => isCurrentUser = me.id == userId
            case None => ()
        }
        var photoIndex: Int64 = 0
        for (info in photoInfoList) {
            // The response is newest-first. The locally seeded image above is
            // that same first photo, but its URI differs from the downloaded
            // thumbnail, so string comparison cannot remove the duplicate.
            if (isCurrentUser && firstPath.size > 0 && photoIndex == 0) {
                photoIndex += 1
                continue
            }
            photoIndex += 1
            let photoBytes = downloadService.downloadPhoto(
                info.photoId,
                info.accessHash,
                info.fileReference,
                thumbSize: info.thumbSize
            )
            if (photoBytes.size > 0) {
                let b64 = toBase64String(photoBytes)
                let dataUrl = "data:image/jpeg;base64," + b64
                // 避免重复添加与第一张相同的缩略图
                var isDuplicate = false
                for (existing in results) {
                    if (existing == dataUrl) {
                        isDuplicate = true
                        break
                    }
                }
                if (!isDuplicate) {
                    results.add(dataUrl)
                }
            }
        }

        if (results.isEmpty() && firstPath.size == 0) {
            Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] download failed for uid=${userId}")
        } else {
            Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] loaded ${results.size} photos uid=${userId}")
        }

        this.photosCache[userId] = results
        return results
    }

    /**
     * 获取用户头像完整元数据列表（含 photoId / accessHash / fileReference / downloadedPath）
     *
     * 供 AvatarGalleryPage 存储元数据以驱动 deletePhotos / setAsMainPhoto RPC 调用。
     * 调用前提：在 spawn 内部（网络操作）。
     *
     * @param userId     用户 ID
     * @param accessHash 用户 access_hash
     * @param limit      最多获取头像数
     * @return AvatarPhotoInfo 列表，downloadedPath 为已下载路径或空串
     */
    public func fetchUserPhotoInfos(userId: Int64, accessHash: Int64, limit!: Int32 = 20): ArrayList<AvatarPhotoInfo> {
        let result = ArrayList<AvatarPhotoInfo>()
        let photoInfoList = this.callGetUserPhotos(userId, accessHash, limit: limit)
        if (photoInfoList.isEmpty()) {
            return result
        }
        let downloadService = getFileDownloadService()
        for (info in photoInfoList) {
            let photoBytes = downloadService.downloadPhoto(
                info.photoId,
                info.accessHash,
                info.fileReference,
                thumbSize: info.thumbSize
            )
            if (photoBytes.size > 0) {
                let b64 = toBase64String(photoBytes)
                info.downloadedPath = "data:image/jpeg;base64," + b64
                result.add(info)
            }
            // 下载失败的照片跳过(不 add),与 fetchUserPhotos 过滤行为一致
        }
        return result
    }

    /**
     * 使缓存失效，下次 fetchUserPhotos 将重新请求
     */
    public func invalidateCache(userId: Int64): Unit {
        if (this.photosCache.contains(userId)) {
            this.photosCache.remove(userId)
        }
        let _ = this.currentPhotoInfoCache.remove(userId)
    }

    // ======== 私有方法 ========

    /**
     * 序列化并发送 photos.getUserPhotos，解析返回的 Photo 列表中的 photoId/accessHash/dcId
     */
    private func callGetUserPhotos(userId: Int64, accessHash: Int64, limit!: Int32 = 10): ArrayList<AvatarPhotoInfo> {
        let result = ArrayList<AvatarPhotoInfo>()
        try {
            let serializer = TLSerializer()
            // photos.getUserPhotos#91cd32a8 user_id:InputUser offset:int max_id:long limit:int
            serializer.writeUInt32(PHOTOS_GET_USER_PHOTOS)
            // The settings header requests the signed-in user's own photos. Telegram
            // requires inputUserSelf here; serializing an explicit inputUser with the
            // restored account's incomplete access hash is rejected as
            // INPUT_CONSTRUCTOR_INVALID. Keep explicit inputUser for peer profiles.
            var isCurrentUser = false
            match (getRealAuthService().getCurrentUser()) {
                case Some(me) => isCurrentUser = me.id == userId
                case None => ()
            }
            if (isCurrentUser) {
                serializer.writeUInt32(0xf7c1b13f) // inputUserSelf
            } else {
                serializer.writeUInt32(0xf21158c6) // inputUser
                serializer.writeInt64(userId)
                serializer.writeInt64(accessHash)
            }
            serializer.writeInt32(0)   // offset
            serializer.writeInt64(0)   // max_id
            serializer.writeInt32(limit)

            let client = getMTProtoClient()
            let responseData = client.sendRequest(serializer.getBytes())

            if (responseData.size < 4) {
                return result
            }

            let d = TLDeserializer(responseData)
            let constructor = d.readUInt32()

            if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                let errorCode = d.readInt32()
                let errorMsg = d.readString()
                Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] RPC error ${errorCode}: ${errorMsg}")
                return result
            }

            if (constructor != PHOTOS_PHOTOS && constructor != PHOTOS_PHOTOS_SLICE) {
                Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] Unknown constructor: 0x${constructor}")
                return result
            }

            // photos.photosSlice has count:int before the vector. photos.photos
            // starts directly with photos:Vector<Photo>.
            if (constructor == PHOTOS_PHOTOS_SLICE) {
                let _ = d.readInt32()
            }

            // photos: Vector<Photo>
            let vecCtor = d.readUInt32()
            if (vecCtor != TLConstructors.VECTOR) {
                return result
            }
            let photoCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] Got ${photoCount} photos for uid=${userId}")

            for (_i in 0..Int64(photoCount)) {
                let photoInfo = parsePhotoEntry(d)
                match (photoInfo) {
                    case Some(info) => result.add(info)
                    case None => Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] skip empty photo")
                }
            }
            if (!result.isEmpty()) { this.currentPhotoInfoCache[userId] = result[0] }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] callGetUserPhotos error uid=${userId}")
        }
        return result
    }

    /**
     * 解析单个 Photo TL 对象，提取 photoId / accessHash / dcId
     *
     * photo#fb197a65 flags:# has_stickers:flags.0?true id:long access_hash:long
     *   file_reference:bytes date:int sizes:Vector<PhotoSize> video_sizes:flags.1?Vector<VideoSize>
     *   dc_id:int = Photo
     *
     * photoEmpty#2331b22d id:long = Photo
     */
    private func parsePhotoEntry(d: TLDeserializer): Option<AvatarPhotoInfo> {
        let ctor = d.readUInt32()

        // photoEmpty#2331b22d
        if (ctor == 0x2331b22d) {
            let _ = d.readInt64()  // id
            return None
        }

        // photo#fb197a65
        if (ctor != 0xfb197a65) {
            // Unknown photo constructor — cannot parse safely
            Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] Unknown photo ctor: 0x${ctor}")
            return None
        }

        let flags = d.readInt32()
        let photoId = d.readInt64()
        let photoAccessHash = d.readInt64()
        let fileRef = d.readBytes()   // file_reference — retained for deletePhotos / setAsMainPhoto
        let date = d.readInt32()
        let info = AvatarPhotoInfo()
        // sizes: Vector<PhotoSize> — keep the largest representation's type so
        // historical photos can be fetched through inputPhotoFileLocation.
        let thumbSize = parsePhotoSizeVector(d, info)
        // video_sizes carries animated-video representations as well as the
        // custom-emoji markup used by emoji profile photos.
        if ((flags & 2) != 0) {
            readVideoSizeVector(d, info)
        }
        let dcId = d.readInt32()

        info.photoId = photoId
        info.accessHash = photoAccessHash
        info.date = date
        info.fileReference = fileRef
        info.thumbSize = if (thumbSize.size > 0) { thumbSize } else { "x" }
        info.dcId = Int32(dcId)
        return Some(info)
    }

    /**
     * 遍历 Vector<PhotoSize>，把 w*h 最大的 photoSize / photoSizeProgressive 记到 info，
     * 其它构造器只跳过。
     */
    private func parsePhotoSizeVector(d: TLDeserializer, info: AvatarPhotoInfo): String {
        let vecCtor = d.readUInt32()
        if (vecCtor != TLConstructors.VECTOR) { return "" }
        let count = d.readInt32()
        var lastType = ""
        for (_i in 0..Int64(count)) {
            let ctor = d.readUInt32()
            if (ctor == 0x75c78e60) {
                // photoSize: type w h size
                let t = d.readString()
                let w = d.readInt32()
                let h = d.readInt32()
                let _ = d.readInt32()
                lastType = t
                if (Int64(w) * Int64(h) > Int64(info.largestW) * Int64(info.largestH)) {
                    info.largestSizeType = t
                    info.largestW = w
                    info.largestH = h
                }
            } else if (ctor == 0xfa3efb95) {
                // photoSizeProgressive: type w h sizes:Vector<int>
                let t = d.readString()
                let w = d.readInt32()
                let h = d.readInt32()
                let sizeVec = d.readUInt32()
                if (sizeVec == TLConstructors.VECTOR) {
                    let cnt = d.readInt32()
                    for (_j in 0..Int64(cnt)) {
                        let _ = d.readInt32()
                    }
                }
                if (Int64(w) * Int64(h) > Int64(info.largestW) * Int64(info.largestH)) {
                    info.largestSizeType = t
                    info.largestW = w
                    info.largestH = h
                }
                lastType = t
            } else if (ctor == 0xe17e23c) {
                let _ = d.readString()
            } else if (ctor == 0x021e1ad6) {
                let _ = d.readString()
                let _ = d.readInt32()
                let _ = d.readInt32()
                let _ = d.readBytes()
            } else if (ctor == 0xe0b0bc2e) {
                let _ = d.readString()
                let _ = d.readBytes()
            } else if (ctor == 0xd8214d41) {
                let _ = d.readString()
                let _ = d.readBytes()
            } else {
                Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] unknown PhotoSize ctor=0x${ctor}")
                return lastType
            }
        }
        return lastType
    }

    /**
     * 取用户当前主头像的原图（photos.getUserPhotos 第一张 Photo 的最大尺寸档，走
     * inputPhotoFileLocation），对位 iOS PeerInfo 展开态头部的画廊图。磁盘缓存前缀 "orig"，
     * 失败返回空串。须在 spawn 内调用。
     */
    /** 同步查主头像原图的本地缓存（内存 / 磁盘），未命中返回空串。 */
    public func cachedPrimaryFullPhotoPath(userId: Int64, photoId: Int64): String {
        if (this.fullPhotoPathCache.contains(userId)) {
            return this.fullPhotoPathCache[userId]
        }
        let cached = loadPeerPhotoFromDisk("orig", userId, photoId)
        if (cached.size > 0) {
            this.fullPhotoPathCache[userId] = cached
        }
        return cached
    }

    public func fetchPrimaryFullPhotoPath(userId: Int64, accessHash: Int64): String {
        if (this.fullPhotoPathCache.contains(userId)) {
            return this.fullPhotoPathCache[userId]
        }
        let infos = this.callGetUserPhotos(userId, accessHash, limit: 1)
        if (infos.isEmpty()) { return "" }
        let info = infos[0]
        if (info.largestSizeType.size == 0 || info.photoId == 0) { return "" }
        let cached = loadPeerPhotoFromDisk("orig", userId, info.photoId)
        if (cached.size > 0) {
            this.fullPhotoPathCache[userId] = cached
            return cached
        }
        let bytes = getFileDownloadService().downloadPhoto(
            info.photoId, info.accessHash, info.fileReference, thumbSize: info.largestSizeType
        )
        if (bytes.size == 0) { return "" }
        let path = savePeerPhotoToDisk("orig", userId, info.photoId, bytes)
        if (path.size > 0) {
            this.fullPhotoPathCache[userId] = path
        }
        Hilog.info(0, "CjTelegram", "[PeerInfoAvatarSvc] full photo uid=${userId} ${info.largestW}x${info.largestH} type=${info.largestSizeType}")
        return path
    }

    /**
     * 跳过 Vector<PhotoSize>
     */
    private func readPhotoSizeVector(d: TLDeserializer): String {
        let vecCtor = d.readUInt32()
        if (vecCtor != TLConstructors.VECTOR) { return "" }
        let count = d.readInt32()
        var lastType = ""
        for (_i in 0..Int64(count)) {
            let sizeType = readPhotoSize(d)
            if (sizeType.size > 0) { lastType = sizeType }
        }
        return lastType
    }

    /**
     * 跳过单个 PhotoSize
     *
     * photoSize#75c78e60: type:string w:int h:int size:int
     * photoSizeEmpty#e17e23c: type:string
     * photoCachedSize#021e1ad6: type:string w:int h:int bytes:bytes
     * photoStrippedSize#e0b0bc2e: type:string bytes:bytes
     * photoSizeProgressive#fa3efb95: type:string w:int h:int sizes:Vector<int>
     * photoPathSize#d8214d41: type:string bytes:bytes
     */
    private func readPhotoSize(d: TLDeserializer): String {
        let ctor = d.readUInt32()
        if (ctor == 0xe17e23c) {
            // photoSizeEmpty: type:string
            let _ = d.readString()
            return ""
        } else if (ctor == 0x75c78e60) {
            // photoSize: type w h size
            let sizeType = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readInt32()
            return sizeType
        } else if (ctor == 0x021e1ad6) {
            // photoCachedSize: type w h bytes
            let _ = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let _ = d.readBytes()
            return ""
        } else if (ctor == 0xe0b0bc2e) {
            // photoStrippedSize: type bytes
            let _ = d.readString()
            let _ = d.readBytes()
            return ""
        } else if (ctor == 0xfa3efb95) {
            // photoSizeProgressive: type w h sizes:Vector<int>
            let sizeType = d.readString()
            let _ = d.readInt32()
            let _ = d.readInt32()
            let sizeVec = d.readUInt32()
            if (sizeVec == TLConstructors.VECTOR) {
                let cnt = d.readInt32()
                for (_j in 0..Int64(cnt)) {
                    let _ = d.readInt32()
                }
            }
            return sizeType
        } else if (ctor == 0xd8214d41) {
            // photoPathSize: type bytes
            let _ = d.readString()
            let _ = d.readBytes()
            return ""
        }
        // Unknown constructor — stop; caller will likely get wrong data but we
        // prefer partial parse to a crash
        return ""
    }

    /**
     * 跳过 Vector<VideoSize>
     *
     * videoSize#de33b094 flags:# type:string w:int h:int size:int video_start_ts:flags.0?double
     */
    private func readVideoSizeVector(d: TLDeserializer, info: AvatarPhotoInfo): Unit {
        let vecCtor = d.readUInt32()
        if (vecCtor != TLConstructors.VECTOR) { return }
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            let constructor = d.readUInt32()
            if (constructor == 0xf85c413c) {
                info.emojiDocumentId = d.readInt64()
                let colorsCtor = d.readUInt32()
                if (colorsCtor == TLConstructors.VECTOR) {
                    let colorCount = d.readInt32()
                    for (_j in 0..Int64(colorCount)) {
                        info.emojiBackgroundColors.add(d.readInt32())
                    }
                }
            } else if (constructor == 0xde33b094) {
                let flags = d.readInt32()
                let _ = d.readString()
                let _ = d.readInt32()
                let _ = d.readInt32()
                let _ = d.readInt32()
                if ((flags & 1) != 0) { let _ = d.readInt64() }
            } else if (constructor == 0x0da082fe) {
                // videoSizeStickerMarkup#da082fe stickerset:InputStickerSet
                // sticker_id:long background_colors:Vector<int>
                let setCtor = d.readUInt32()
                if (setCtor == 0x9de7a269) {
                    let _ = d.readInt64()
                    let _ = d.readInt64()
                } else if (setCtor == 0x861cc8a0) {
                    let _ = d.readString()
                }
                let _ = d.readInt64()
                let colorsCtor = d.readUInt32()
                if (colorsCtor == TLConstructors.VECTOR) {
                    let colorCount = d.readInt32()
                    for (_j in 0..Int64(colorCount)) { let _ = d.readInt32() }
                }
            }
        }
    }
}
