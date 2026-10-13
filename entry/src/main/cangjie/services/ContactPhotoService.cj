package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * ContactPhotoService — 联系人个人头像（仅自己可见）与「建议头像」
 *
 * 对位 iOS TelegramCore PeerPhotoUpdater.swift `_internal_updateContactPhoto`：
 *   - mode .custom  → photos.uploadContactProfilePhoto flags |= 1<<4 (save)
 *   - mode .suggest → photos.uploadContactProfilePhoto flags |= 1<<3 (suggest)
 *   - reset（resource == nil）→ flags = 1<<4，不带 file（PeerPhotoUpdater.swift:443）
 *
 * photos.uploadContactProfilePhoto#e14c4a71
 *   flags:# suggest:flags.3?true save:flags.4?true user_id:InputUser
 *   file:flags.0?InputFile video:flags.1?InputFile video_start_ts:flags.2?double
 *   video_emoji_markup:flags.5?VideoSize = photos.Photo
 * （iOS Api42.swift:12870 appendInt32(-515093903) == 0xe14c4a71）
 */

private class PhotosUploadContactProfilePhoto <: TLObject {
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var file: Option<TLObject> = None   // flags.0 InputFile
    public var suggest: Bool = false           // flags.3
    public var save: Bool = false              // flags.4

    public func getConstructorId(): UInt32 { return 0xe14c4a71 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        match (this.file) {
            case Some(_) => flags = flags | 1
            case None => ()
        }
        if (this.suggest) { flags = flags | (1 << 3) }
        if (this.save) { flags = flags | (1 << 4) }
        serializer.writeInt32(flags)
        let inputUser = InputUser()
        inputUser.userId = this.userId
        inputUser.accessHash = this.accessHash
        serializer.writeRawBytes(inputUser.toBytes())
        match (this.file) {
            case Some(f) => serializer.writeRawBytes(f.toBytes())
            case None => ()
        }
    }
}

public class ContactPhotoService {
    /**
     * 从相册路径设置联系人个人头像（save）或向对方建议头像（suggest）。
     * 返回成功后本地可直接渲染的头像 URI（suggest 模式成功返回 "ok"），失败返回 ""。
     */
    public func uploadContactPhoto(userId: Int64, accessHash: Int64, imagePath: String, suggest: Bool): String {
        var realPath = imagePath
        if (realPath.startsWith("file://")) {
            realPath = realPath[7..]
        }
        // 与 EditProfilePage 同一条链路：先压成头像用 JPEG 再分片上传
        let photoData = getImageCompressionService().compressToMaxPixelSize(realPath, Int32(1280), UInt8(86))
        if (photoData.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[ContactPhotoService] compress failed for ${realPath}")
            return ""
        }
        let inputFileOpt = getFileUploadService().uploadFile(photoData, "contact_photo.jpg")
        match (inputFileOpt) {
            case None =>
                Hilog.info(0, "CjTelegram", "[ContactPhotoService] file upload failed")
                return ""
            case Some(inputFile) =>
                let req = PhotosUploadContactProfilePhoto()
                req.userId = userId
                req.accessHash = accessHash
                req.file = Some(inputFile)
                req.suggest = suggest
                req.save = !suggest
                if (!this.sendAndCheck(req, if (suggest) { "suggest" } else { "set" })) {
                    return ""
                }
                if (suggest) {
                    return "ok"
                }
                let localUri = this.cacheLocalCopy(userId, photoData)
                // 刷新 user 缓存：服务端此后在 user.photo 里返回个人头像（personal 标志），
                // photoId 变化会让 UserPhotoService 丢弃旧路径缓存。
                this.refreshUser(userId, accessHash)
                if (localUri.size > 0) {
                    getUserPhotoService().setUserPhotoPath(userId, localUri)
                    return localUri
                }
                getUserPhotoService().requestFullPhotoDownload(userId)
                return getUserPhotoService().getUserPhotoPath(userId)
        }
    }

    /**
     * 恢复原始头像（iOS UserInfo.ResetCustomPhoto）：flags = save，不带 file。
     * 返回恢复后的本地头像 URI（可能为空，全量头像随后异步到达）。
     */
    public func resetContactPhoto(userId: Int64, accessHash: Int64): Bool {
        let req = PhotosUploadContactProfilePhoto()
        req.userId = userId
        req.accessHash = accessHash
        req.save = true
        if (!this.sendAndCheck(req, "reset")) {
            return false
        }
        this.refreshUser(userId, accessHash)
        getUserPhotoService().clearUserPhoto(userId)
        let _ = getUserPhotoService().getUserPhotoPath(userId)
        getUserPhotoService().requestFullPhotoDownload(userId)
        return true
    }

    private func sendAndCheck(req: TLObject, tag: String): Bool {
        let data = getMTProtoClient().sendRequest(req.toBytes())
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[ContactPhotoService] ${tag}: empty response")
            return false
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[ContactPhotoService] ${tag} RPC error ${code}: ${msg}")
            return false
        }
        // photos.photo#20212ca8 photo:Photo users:Vector<User>
        Hilog.info(0, "CjTelegram", "[ContactPhotoService] ${tag}: ok ctor=${ctor}")
        return true
    }

    /** users.getUsers 重新拉取该用户并写回缓存（photo/photoId 以服务端现值为准）。 */
    private func refreshUser(userId: Int64, accessHash: Int64): Unit {
        try {
            let request = UsersGetUsers()
            let inputUser = InputUser()
            inputUser.userId = userId
            inputUser.accessHash = accessHash
            request.ids.add(inputUser)
            let responseData = getMTProtoClient().sendRequest(request.toBytes())
            if (responseData.size < 8) { return }
            let d = TLDeserializer(responseData)
            let vectorConstructor = d.readUInt32()
            if (vectorConstructor != TLConstructors.VECTOR) {
                Hilog.info(0, "CjTelegram", "[ContactPhotoService] refreshUser unexpected ctor=${vectorConstructor}")
                return
            }
            let count = d.readInt32()
            var index: Int32 = 0
            while (index < count) {
                let user = UserResponse.deserializeBoxed(d)
                if (user.id == userId && !user.isEmpty) {
                    getRealChatListService().cacheUserResponse(user)
                }
                index += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ContactPhotoService] refreshUser error: ${e}")
        }
    }

    /** 把上传用的 JPEG 落盘，返回 file:// URI；失败返回 ""。 */
    private func cacheLocalCopy(userId: Int64, photoData: Array<Byte>): String {
        let filesDir = getAppFilesDir()
        if (filesDir.size == 0) { return "" }
        let avatarDir = filesDir + "/avatars"
        try { FileIo.mkdir(avatarDir) } catch (_e: Exception) {}
        let avatarPath = avatarDir + "/contact_personal_${userId}.jpg"
        try {
            let outFile = FileIo.open(avatarPath, mode: 0o1101)
            FileIo.write(outFile.fd, photoData)
            FileIo.close(outFile)
            return "file://" + avatarPath
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ContactPhotoService] local cache save error: ${e}")
            return ""
        }
    }
}

private var _contactPhotoService: Option<ContactPhotoService> = None

public func getContactPhotoService(): ContactPhotoService {
    match (_contactPhotoService) {
        case Some(s) => return s
        case None =>
            let s = ContactPhotoService()
            _contactPhotoService = Some(s)
            return s
    }
}
