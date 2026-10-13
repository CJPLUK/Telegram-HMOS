package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.HashMap
import std.collection.ArrayList
import stdx.encoding.base64.*
import std.sync.*

/**
 * UserPhotoService — 用户头像服务 (Phase L1)
 * 
 * 对应 TelegramHarmony UserPhotoService.ets (316 行)
 * 
 * 功能:
 * - 缓存用户 UserResponse（含 strippedThumb）
 * - 解码 strippedThumb 为 JPEG data URL
 * - 提供 getUserPhotoPath(userId) 返回 data:image/jpeg;base64,... URL
 * - 纯内存缓存
 * 
 * Telegram stripped thumbnail 格式:
 * - Byte 0: 版本号 (0x01)
 * - Byte 1: 宽度
 * - Byte 2: 高度
 * - 剩余: JPEG scan data (插入标准 JPEG header/footer)
 */
private var _userPhotoServiceInstance: Option<UserPhotoService> = None

public func getUserPhotoService(): UserPhotoService {
    match (_userPhotoServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = UserPhotoService()
            _userPhotoServiceInstance = Some(inst)
            return inst
    }
}

public class UserPhotoService {
    private var userCache = HashMap<Int64, UserResponse>()
    private var chatCache = HashMap<Int64, ChatResponse>()
    private var photoPathCache = HashMap<Int64, String>()
    private var chatPhotoPathCache = HashMap<Int64, String>()
    private var fullPhotoRequested = HashMap<Int64, Bool>()
    private var fullChatPhotoRequested = HashMap<Int64, Bool>()
    private var currentUserProfileRequestedId: Int64 = 0
    private var photoReadyCallbacks = ArrayList<(Int64, String) -> Unit>()
    private let downloadMonitor: Monitor = Monitor()
    // Incoming call updates arrive on the MTProto receive thread while chat/contact refreshes may
    // replace userCache entries. Protect the identity lookup used by CallService from concurrent
    // HashMap access.
    private let identityMonitor: Monitor = Monitor()

    public func cacheUser(user: UserResponse): Unit {
        synchronized(this.identityMonitor) {
            if (this.userCache.contains(user.id)) {
                let previous = this.userCache[user.id]
                if (previous.photoId != user.photoId) {
                    this.photoPathCache.remove(user.id)
                    this.fullPhotoRequested.remove(user.id)
                }
            }
            this.userCache[user.id] = user
        }
    }

    public func cacheUsers(users: ArrayList<UserResponse>): Unit {
        for (user in users) {
            this.cacheUser(user)
        }
        Hilog.info(0, "CjTelegram", "[UserPhotoService] Cached ${users.size} users")
    }

    public func cacheChat(chat: ChatResponse): Unit {
        if (this.chatCache.contains(chat.id)) {
            let previous = this.chatCache[chat.id]
            if (previous.photoId != chat.photoId) {
                this.chatPhotoPathCache.remove(chat.id)
                this.fullChatPhotoRequested.remove(chat.id)
            }
        }
        this.chatCache[chat.id] = chat
    }

    public func getCachedUser(userId: Int64): Option<UserResponse> {
        synchronized(this.identityMonitor) {
            if (this.userCache.contains(userId)) {
                return Some(this.userCache[userId])
            }
            return None
        }
        return None
    }

    /**
     * 注册头像就绪回调，下载完成时通知 UI 层刷新
     */
    public func addPhotoReadyCallback(callback: (Int64, String) -> Unit): Unit {
        this.photoReadyCallbacks.add(callback)
    }

    /**
     * Hydrate the current account as a normal Telegram User peer.
     *
     * AuthStorage intentionally restores only the small identity record needed
     * for login.  Reactions, however, render the reactor peer just like iOS and
     * therefore need its UserProfilePhoto.  Fetching inputUserSelf here avoids
     * inventing a "Me" avatar and also keeps the same cache path used by every
     * other peer avatar.
     */
    public func requestCurrentUserProfile(userId: Int64): Unit {
        if (userId <= 0) { return }
        synchronized(this.identityMonitor) {
            if (this.currentUserProfileRequestedId == userId) { return }
            if (this.userCache.contains(userId) && this.userCache[userId].hasPhoto) {
                this.requestFullPhotoDownload(userId)
                return
            }
            // Track the account id rather than a process-global Bool so logout
            // followed by login to another account hydrates the new self peer.
            this.currentUserProfileRequestedId = userId
        }

        let expectedUserId = userId
        spawn {
            getUserPhotoService().performCurrentUserProfileRequest(expectedUserId)
        }
    }

    private func performCurrentUserProfileRequest(expectedUserId: Int64): Unit {
        try {
            let request = UsersGetUsers()
            request.ids.add(InputUserSelf())
            let responseData = getMTProtoClient().sendRequest(request.toBytes())
            let d = TLDeserializer(responseData)
            let vectorConstructor = d.readUInt32()
            if (vectorConstructor != 0x1cb5c415) {
                Hilog.info(0, "CjTelegram", "[AVT] self profile unexpected response=${vectorConstructor}")
                return
            }
            let count = d.readInt32()
            var index: Int32 = 0
            while (index < count) {
                let user = UserResponse.deserializeBoxed(d)
                this.cacheUser(user)
                if (user.id == expectedUserId || user.isSelf) {
                    let previewPath = this.getUserPhotoPath(user.id)
                    if (previewPath.size > 0) {
                        // A stripped thumbnail is already sufficient for the
                        // 20vp reaction avatar; the full image replaces it later.
                        this.onFullPhotoReady(user.id, previewPath)
                    }
                    this.requestFullPhotoDownload(user.id)
                    Hilog.info(0, "CjTelegram", "[AVT] hydrated self user=${user.id}, hasPhoto=${user.hasPhoto}")
                }
                index += 1
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AVT] self profile request failed: ${e}")
            synchronized(this.identityMonitor) {
                // Allow a later chat session to retry transient transport errors.
                if (this.currentUserProfileRequestedId == expectedUserId) {
                    this.currentUserProfileRequestedId = 0
                }
            }
        }
    }

    /**
     * 获取用户头像的 data URL
     * 
     * 优先级：磁盘缓存全量头像 > 内存缓存 > strippedThumb 生成
     */
    public func getUserPhotoPath(userId: Int64): String {
        synchronized(this.identityMonitor) {
            if (this.photoPathCache.contains(userId)) {
                let cached = this.photoPathCache[userId]
                return cached
            }

            var photoId: Int64 = 0
            if (this.userCache.contains(userId)) {
                photoId = this.userCache[userId].photoId
            }
            let diskUrl = loadFullPhotoFromDisk(userId, photoId)
            if (diskUrl.size > 0) {
                this.photoPathCache[userId] = diskUrl
                Hilog.info(0, "CjTelegram", "[AVT] path(${userId}): diskCache")
                return diskUrl
            }

            if (this.userCache.contains(userId)) {
                let user = this.userCache[userId]
                if (user.hasPhoto && user.strippedThumb.size > 0) {
                    let jpegData = decodeStrippedThumb(user.strippedThumb)
                    if (jpegData.size > 0) {
                        let b64 = toBase64String(jpegData)
                        let dataUrl = "data:image/jpeg;base64," + b64
                        this.photoPathCache[userId] = dataUrl
                        return dataUrl
                    }
                }
            }
            return ""
        }
        return ""
    }

    public func getChatPhotoPath(chatId: Int64): String {
        if (this.chatPhotoPathCache.contains(chatId)) {
            return this.chatPhotoPathCache[chatId]
        }
        if (!this.chatCache.contains(chatId)) { return "" }
        let chat = this.chatCache[chatId]
        let diskUrl = loadPeerPhotoFromDisk("chat", chatId, chat.photoId)
        if (diskUrl.size > 0) {
            this.chatPhotoPathCache[chatId] = diskUrl
            Hilog.info(0, "CjTelegram", "[AVT] chatPath(${chatId}): diskCache")
            return diskUrl
        }
        if (chat.hasPhoto && chat.strippedThumb.size > 0) {
            let jpegData = decodeStrippedThumb(chat.strippedThumb)
            if (jpegData.size > 0) {
                let dataUrl = "data:image/jpeg;base64," + toBase64String(jpegData)
                this.chatPhotoPathCache[chatId] = dataUrl
                return dataUrl
            }
        }
        return ""
    }

    /**
     * 异步下载用户全量头像并缓存到磁盘
     * 下载完成后通过 photoReadyCallbacks 通知 UI
     */
    public func requestFullPhotoDownload(userId: Int64): Unit {
        if (this.fullPhotoRequested.contains(userId)) {
            return
        }
        if (!this.userCache.contains(userId)) {
            return
        }
        let user = this.userCache[userId]
        if (!user.hasPhoto || user.photoId == 0) {
            return
        }

        let diskUrl = loadFullPhotoFromDisk(userId, user.photoId)
        if (diskUrl.size > 0) {
            return
        }

        this.fullPhotoRequested[userId] = true

        let userIdCopy = userId
        let accessHashCopy = user.accessHash
        let photoIdCopy = user.photoId
        let dcIdCopy = user.photoDcId

        spawn {
            getUserPhotoService().performFullPhotoDownload(
                userIdCopy, accessHashCopy, photoIdCopy, dcIdCopy
            )
        }
    }

    /**
     * 全量头像下载完成后更新缓存并通知 UI
     */
    public func onFullPhotoReady(userId: Int64, dataUrl: String): Unit {
        synchronized(this.identityMonitor) {
            this.photoPathCache[userId] = dataUrl
        }
        for (cb in this.photoReadyCallbacks) {
            try {
                cb(userId, dataUrl)
            } catch (_e: Exception) {}
        }
    }

    /**
     * 批量请求全量头像下载
     */
    public func requestFullPhotosForUsers(userIds: ArrayList<Int64>): Unit {
        let queued = ArrayList<Int64>()
        var requested: Int64 = 0
        for (userId in userIds) {
            if (this.userCache.contains(userId)) {
                let user = this.userCache[userId]
                if (user.hasPhoto && user.photoId != 0 &&
                    !this.fullPhotoRequested.contains(userId) &&
                    loadFullPhotoFromDisk(userId, user.photoId).size == 0) {
                    this.fullPhotoRequested[userId] = true
                    queued.add(userId)
                    requested += 1
                }
            }
        }
        if (requested > 0) {
            Hilog.info(0, "CjTelegram", "[AVT] requestFullPhotos: ${requested} downloads queued")
            spawn {
                // MTProtoClient 的媒体请求共用一个连接；列表预取按顺序发送，避免冷启动时
                // 与同 DC 的多个 upload.getFile 互相阻塞。
                for (userId in queued) {
                    let service = getUserPhotoService()
                    if (service.userCache.contains(userId)) {
                        let user = service.userCache[userId]
                        service.performFullPhotoDownload(
                            userId, user.accessHash, user.photoId, user.photoDcId
                        )
                    }
                }
            }
        }
    }

    public func requestFullPhotosForChats(chatIds: ArrayList<Int64>): Unit {
        let queued = ArrayList<Int64>()
        for (chatId in chatIds) {
            if (this.chatCache.contains(chatId)) {
                let chat = this.chatCache[chatId]
                if (chat.hasPhoto && chat.photoId != 0 &&
                    !this.fullChatPhotoRequested.contains(chatId) &&
                    loadPeerPhotoFromDisk("chat", chatId, chat.photoId).size == 0) {
                    this.fullChatPhotoRequested[chatId] = true
                    queued.add(chatId)
                }
            }
        }
        if (!queued.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[AVT] requestChatPhotos: ${queued.size} downloads queued")
            spawn {
                for (chatId in queued) {
                    let service = getUserPhotoService()
                    if (service.chatCache.contains(chatId)) {
                        let chat = service.chatCache[chatId]
                        service.performChatPhotoDownload(chat)
                    }
                }
            }
        }
    }

    private func performChatPhotoDownload(chat: ChatResponse): Unit {
        synchronized(this.downloadMonitor) {
          try {
            let peerType = if (chat.isChannel) { "channel" } else { "chat" }
            Hilog.info(0, "CjTelegram", "[AVT] chatDownload(${chat.id}): start photoId=${chat.photoId} dc=${chat.photoDcId}")
            let bytes = getFileDownloadService().downloadUserPhoto(
                chat.id, chat.accessHash, chat.photoId, chat.photoDcId,
                big: true,
                peerType: peerType
            )
            if (bytes.size > 0) {
                let fileUrl = savePeerPhotoToDisk("chat", chat.id, chat.photoId, bytes)
                if (fileUrl.size > 0) {
                    this.chatPhotoPathCache[chat.id] = fileUrl
                    for (cb in this.photoReadyCallbacks) {
                        try { cb(chat.id, fileUrl) } catch (_e: Exception) {}
                    }
                }
                Hilog.info(0, "CjTelegram", "[AVT] chatDownload(${chat.id}): done ${bytes.size} bytes")
            } else {
                this.fullChatPhotoRequested.remove(chat.id)
                Hilog.info(0, "CjTelegram", "[AVT] chatDownload(${chat.id}): empty response, retry enabled")
            }
          } catch (_e: Exception) {
            this.fullChatPhotoRequested.remove(chat.id)
            Hilog.info(0, "CjTelegram", "[AVT] chatDownload(${chat.id}): error, retry enabled")
          }
        }
    }

    private func performFullPhotoDownload(
        userId: Int64,
        accessHash: Int64,
        photoId: Int64,
        dcId: Int32
    ): Unit {
        synchronized(this.downloadMonitor) {
          try {
            Hilog.info(0, "CjTelegram", "[AVT] fullDownload(${userId}): start photoId=${photoId} dc=${dcId}")
            let photoBytes = getFileDownloadService().downloadUserPhoto(
                userId, accessHash, photoId, dcId,
                big: true
            )
            if (photoBytes.size > 0) {
                let fileUrl = saveFullPhotoToDisk(userId, photoId, photoBytes)
                if (fileUrl.size > 0) {
                    this.onFullPhotoReady(userId, fileUrl)
                }
                Hilog.info(0, "CjTelegram", "[AVT] fullDownload(${userId}): done ${photoBytes.size} bytes")
            } else {
                this.fullPhotoRequested.remove(userId)
                Hilog.info(0, "CjTelegram", "[AVT] fullDownload(${userId}): empty response, retry enabled")
            }
          } catch (e: Exception) {
            this.fullPhotoRequested.remove(userId)
            Hilog.info(0, "CjTelegram", "[AVT] fullDownload(${userId}): error, retry enabled")
          }
        }
    }

    public func loadAvatarsForUserIds(userIds: ArrayList<Int64>): Unit {
        var loaded: Int64 = 0
        for (userId in userIds) {
            let path = this.getUserPhotoPath(userId)
            if (path.size > 0) {
                loaded += 1
            }
        }
        Hilog.info(0, "CjTelegram", "[UserPhotoService] Loaded ${loaded}/${userIds.size} avatars")
    }

    public func setUserPhotoPath(userId: Int64, path: String): Unit {
        synchronized(this.identityMonitor) {
            this.photoPathCache[userId] = path
        }
        for (callback in this.photoReadyCallbacks) {
            callback(userId, path)
        }
    }

    public func clearUserPhoto(userId: Int64): Unit {
        synchronized(this.identityMonitor) {
            if (this.photoPathCache.contains(userId)) {
                this.photoPathCache.remove(userId)
            }
        }
        if (this.fullPhotoRequested.contains(userId)) {
            this.fullPhotoRequested.remove(userId)
        }
        for (callback in this.photoReadyCallbacks) {
            callback(userId, "")
        }
    }

    public func clearCache(): Unit {
        synchronized(this.identityMonitor) {
            this.userCache = HashMap<Int64, UserResponse>()
            this.chatCache = HashMap<Int64, ChatResponse>()
            this.photoPathCache = HashMap<Int64, String>()
            this.chatPhotoPathCache = HashMap<Int64, String>()
            this.fullPhotoRequested = HashMap<Int64, Bool>()
            this.fullChatPhotoRequested = HashMap<Int64, Bool>()
        }
        Hilog.info(0, "CjTelegram", "[UserPhotoService] Cache cleared")
    }

    public func clearDiskCache(): Unit {
        let filesDir = getAppFilesDir()
        if (filesDir.size > 0) {
            let avatarDir = filesDir + "/avatars"
            try { FileIo.rmdir(avatarDir) } catch (_e: Exception) {}
            let fullDir = filesDir + "/avatars_full"
            try { FileIo.rmdir(fullDir) } catch (_e: Exception) {}
            Hilog.info(0, "CjTelegram", "[UserPhotoService] Disk avatar cache cleared")
        }
    }

    public func getCacheStats(): (Int64, Int64) {
        synchronized(this.identityMonitor) {
            return (Int64(this.userCache.size), Int64(this.photoPathCache.size))
        }
        return (0, 0)
    }
}

func getAvatarFullDir(): String {
    let filesDir = getAppFilesDir()
    if (filesDir.size == 0) { return "" }
    let dir = filesDir + "/avatars_full"
    try {
        if (!FileIo.access(dir)) {
            FileIo.mkdir(dir)
        }
    } catch (_e: Exception) {
        try { FileIo.mkdir(dir) } catch (_e2: Exception) {}
    }
    return dir
}

func loadFullPhotoFromDisk(userId: Int64, photoId: Int64): String {
    let dir = getAvatarFullDir()
    if (dir.size == 0 || photoId == 0) { return "" }
    let filePath = dir + "/" + userId.toString() + "_" + photoId.toString() + "_big.jpg"
    try {
        if (FileIo.access(filePath)) {
            let stat = FileIo.stat(filePath)
            if (stat.size > 100) {
                return "file://" + filePath
            }
        }
    } catch (_e: Exception) {}
    return ""
}

func saveFullPhotoToDisk(userId: Int64, photoId: Int64, data: Array<Byte>): String {
    let dir = getAvatarFullDir()
    if (dir.size == 0 || photoId == 0) { return "" }
    let filePath = dir + "/" + userId.toString() + "_" + photoId.toString() + "_big.jpg"
    try {
        let fd = FileIo.open(filePath, mode: 0o1101)
        FileIo.write(fd.fd, data)
        FileIo.close(fd)
        return "file://" + filePath
    } catch (_e: Exception) {
        Hilog.info(0, "CjTelegram", "[AVT] saveFullPhoto(${userId}): write error")
    }
    return ""
}

func loadPeerPhotoFromDisk(prefix: String, peerId: Int64, photoId: Int64): String {
    let dir = getAvatarFullDir()
    if (dir.size == 0 || photoId == 0) { return "" }
    let filePath = dir + "/" + prefix + "_" + peerId.toString() + "_" + photoId.toString() + "_big.jpg"
    try {
        if (FileIo.access(filePath) && FileIo.stat(filePath).size > 100) {
            return "file://" + filePath
        }
    } catch (_e: Exception) {}
    return ""
}

func savePeerPhotoToDisk(prefix: String, peerId: Int64, photoId: Int64, data: Array<Byte>): String {
    let dir = getAvatarFullDir()
    if (dir.size == 0 || photoId == 0) { return "" }
    let filePath = dir + "/" + prefix + "_" + peerId.toString() + "_" + photoId.toString() + "_big.jpg"
    try {
        let fd = FileIo.open(filePath, mode: 0o1101)
        FileIo.write(fd.fd, data)
        FileIo.close(fd)
        return "file://" + filePath
    } catch (_e: Exception) {}
    return ""
}

func byteHex(data: Array<Byte>, idx: Int64): String {
    if (idx < 0 || idx >= data.size) { return "??" }
    let b = Int64(data[idx])
    let hexChars = "0123456789ABCDEF"
    let hexRunes = hexChars.toRuneArray()
    let hi = hexRunes[(b >> 4) & 0xF]
    let lo = hexRunes[b & 0xF]
    return String(hi) + String(lo)
}

func decodeStrippedThumb(data: Array<Byte>): Array<Byte> {
    if (data.size < 3) {
        return Array<Byte>(0, repeat: 0)
    }

    let version = data[0]
    if (version != 1) {
        Hilog.info(0, "CjTelegram", "[AVT] Unknown stripped thumb version: ${version}")
        return Array<Byte>(0, repeat: 0)
    }

    let header = getTinyThumbnailHeader()
    let footer = getTinyThumbnailFooter()

    let width = data[1]
    let height = data[2]
    Hilog.info(0, "CjTelegram", "[AVT] decode: w=${Int64(width)} h=${Int64(height)} headerSz=${header.size} scanSz=${data.size - 3}")

    let scanData = Array<Byte>(data.size - 3, { i: Int64 => data[i + 3] })

    var headerCopy = Array<Byte>(header.size, { i: Int64 => header[i] })

    // 动态查找 SOF0 标记 (FF C0) 并写入宽高
    var sof0Set = false
    for (i in 0..(headerCopy.size - 9)) {
        if (headerCopy[i] == UInt8(0xFF) && headerCopy[i + 1] == UInt8(0xC0)) {
            // SOF0: FF C0 <len 2B> <precision 1B> <height 2B> <width 2B>
            headerCopy[i + 5] = UInt8(0)
            headerCopy[i + 6] = height
            headerCopy[i + 7] = UInt8(0)
            headerCopy[i + 8] = width
            Hilog.info(0, "CjTelegram", "[AVT] SOF0 found at ${i}, set h=${Int64(height)} w=${Int64(width)}")
            sof0Set = true
            break
        }
    }
    if (!sof0Set) {
        Hilog.info(0, "CjTelegram", "[AVT] WARNING: SOF0 not found in header!")
    }

    let totalSize = headerCopy.size + scanData.size + footer.size
    let result = Array<Byte>(totalSize, repeat: 0)
    var offset: Int64 = 0

    for (i in 0..headerCopy.size) {
        result[offset] = headerCopy[i]
        offset += 1
    }
    for (i in 0..scanData.size) {
        result[offset] = scanData[i]
        offset += 1
    }
    for (i in 0..footer.size) {
        result[offset] = footer[i]
        offset += 1
    }

    return result
}

/**
 * Telegram tiny thumbnail JPEG header (623 bytes)
 * 
 * 直接使用 iOS TinyThumbnail.swift 的 base64 编码
 * 避免 hexToBytes 在仓颉中丢字节的问题
 */
func getTinyThumbnailHeader(): Array<Byte> {
    let b64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlk" +
        "kYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl" +
        "+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/" +
        "wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA" +
        "AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcY" +
        "GRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKT" +
        "lJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP0" +
        "9fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQA" +
        "AQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2" +
        "Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOk" +
        "paanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMB" +
        "AAIRAxEAPwA="
    match (fromBase64String(b64)) {
        case Some(bytes) => return bytes
        case None =>
            Hilog.info(0, "CjTelegram", "[AVT] FATAL: base64 decode header failed")
            return Array<Byte>(0, repeat: 0)
    }
}

func getTinyThumbnailFooter(): Array<Byte> {
    return Array<Byte>(2, { i: Int64 =>
        if (i == 0) { UInt8(0xFF) } else { UInt8(0xD9) }
    })
}
