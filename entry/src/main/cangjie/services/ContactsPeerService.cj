package ohos_app_cangjie_entry.services

import std.collection.ArrayList

/**
 * ContactsPeerService — 联系人项数据层（Facade）
 *
 * 对应 iOS ContactsPeerItem 所需的数据接口。
 * anti_pattern: 不重复实现联系人逻辑，委托 RealContactService 和 UserPhotoService。
 *
 * 提供:
 * - 头像 URL（委托 UserPhotoService）
 * - 头像颜色（用于无头像时的首字母背景）
 * - 联系人列表（委托 RealContactService）
 * - 请求联系人头像下载（委托 UserPhotoService）
 *
 * 调用链: ContactsPeerService → RealContactService/UserPhotoService → MTProtoClient
 */
private var _contactsPeerServiceInstance: Option<ContactsPeerService> = None

public func getContactsPeerService(): ContactsPeerService {
    match (_contactsPeerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ContactsPeerService()
            _contactsPeerServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 根据 userId 生成一致的头像颜色（iOS Telegram 风格）
 * 用于无头像时显示首字母的背景色
 */
public func getAvatarColorForPeer(userId: Int64): UInt32 {
    let colors: Array<UInt32> = [
        0xE91E63,  // Pink
        0x9C27B0,  // Purple
        0x3F51B5,  // Indigo
        0x03A9F4,  // Light Blue
        0x009688,  // Teal
        0x4CAF50,  // Green
        0xFF9800,  // Orange
        0xFF5722   // Deep Orange
    ]
    let index = Int64(userId % 8)
    if (index < 0) {
        return colors[Int64(-index)]
    }
    return colors[index]
}

public class ContactsPeerService {

    /**
     * 获取联系人头像 URL（data URL 或 file 路径）
     * 委托 UserPhotoService
     */
    public func getAvatarUrl(userId: Int64): String {
        return getUserPhotoService().getUserPhotoPath(userId)
    }

    /**
     * 获取头像背景色（无头像时首字母显示用）
     */
    public func getAvatarColor(userId: Int64): UInt32 {
        return getAvatarColorForPeer(userId)
    }

    /**
     * 获取联系人列表
     * 委托 RealContactService
     */
    public func getContacts(): ArrayList<ContactDisplayData> {
        return getRealContactService().getContacts()
    }

    /**
     * 搜索联系人
     * 委托 RealContactService
     */
    public func searchContacts(query: String, limit!: Int32 = 20): ArrayList<ContactDisplayData> {
        return getRealContactService().searchContacts(query, limit: limit)
    }

    /**
     * 请求批量用户头像下载
     * 委托 UserPhotoService
     */
    public func requestPhotosForUserIds(userIds: ArrayList<Int64>): Unit {
        if (!userIds.isEmpty()) {
            getUserPhotoService().requestFullPhotosForUsers(userIds)
        }
    }

    /**
     * 注册头像就绪回调（下载完成时通知 UI 刷新）
     */
    public func addPhotoReadyCallback(callback: (Int64, String) -> Unit): Unit {
        getUserPhotoService().addPhotoReadyCallback(callback)
    }
}
