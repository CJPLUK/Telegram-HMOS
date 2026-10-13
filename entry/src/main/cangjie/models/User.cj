package ohos_app_cangjie_entry.models

import kit.ArkUI.*

/**
 * 用户数据模型
 * 对应 iOS TelegramCore 的 User 数据结构
 * 
 * iOS 文件参考:
 * - submodules/TelegramCore/Sources/TelegramEngine/Peers/TelegramUser.swift
 * 
 * 纯数据类，不使用 @Observed（在后台线程创建，@Publish 会触发主线程检查异常）
 */
public class User {
    public var id: Int64 = 0
    public var username: String = ""
    public var displayName: String = ""
    public var phoneNumber: String = ""
    public var avatarUrl: String = ""
    public var avatarText: String = ""
    public var avatarColor: Int64 = 0x317AFF
    public var isOnline: Bool = false
    public var lastSeenTime: String = ""
    public var bio: String = ""
}
