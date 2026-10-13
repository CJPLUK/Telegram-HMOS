package ohos_app_cangjie_entry.models

import std.collection.ArrayList

/**
 * 已导出的聊天文件夹邀请链接模型（P2-174）
 *
 * 对应 iOS TelegramCore/Communities.swift ExportedChatFolderLink
 * 以及 Api7.swift Api.ExportedChatlistInvite.exportedChatlistInvite
 *   (flags: Int32, title: String, url: String, peers: [Api.Peer])
 *
 * iOS TL response: ExportedChatlistInvite#0c5181ac
 *   flags bit 0: isRevoked
 *   title: String
 *   url: String (e.g. "https://t.me/addlist/SLUG")
 *   peers: Vector<Peer> (boxed peer IDs)
 */
public class ExportedChatFolderLink {
    public var title: String = ""
    public var url: String = ""
    public var peerIds: ArrayList<Int64> = ArrayList<Int64>()
    public var isRevoked: Bool = false

    public init() {}

    /**
     * slug 是 url 去掉 "https://t.me/addlist/" 前缀后的部分
     * 对应 iOS ExportedChatFolderLink.slug computed var
     */
    public func slug(): String {
        let prefix = "https://t.me/addlist/"
        if (this.url.size > prefix.size) {
            return this.url[prefix.size..this.url.size]
        }
        return this.url
    }
}

/**
 * 可分享的 peer 条目（P2-174）
 * 用于 folder 邀请链接 peer 多选列表
 * isAvailable=false 时该 peer 无法分享（无邀请权限），UI 灰显
 */
public class FolderShareablePeer {
    public var peerId: Int64 = 0
    public var peerType: String = ""
    public var accessHash: Int64 = 0
    public var title: String = ""
    public var isAvailable: Bool = true
    public var isSelected: Bool = false

    public init() {}
}
