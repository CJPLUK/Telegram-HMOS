package ohos_app_cangjie_entry.models

import std.collection.ArrayList

public class ChatFolderPeer {
    public var id: Int64 = 0
    public var peerType: String = "user"
    public var accessHash: Int64 = 0
    public var name: String = ""
    public var avatarPath: String = ""
    public var avatarColor: Int64 = 0xFF317AFF
    public var isVerified: Bool = false
    public var canShareLink: Bool = false
    public var isMigrated: Bool = false

    public init() {}

    public func copy(): ChatFolderPeer {
        let result = ChatFolderPeer()
        result.id = this.id
        result.peerType = this.peerType
        result.accessHash = this.accessHash
        result.name = this.name
        result.avatarPath = this.avatarPath
        result.avatarColor = this.avatarColor
        result.isVerified = this.isVerified
        result.canShareLink = this.canShareLink
        result.isMigrated = this.isMigrated
        return result
    }
}

public class ChatFolder {
    public var id: Int32 = 0
    public var name: String = ""
    public var description: String = ""
    public var icon: String = ""
    public var filterType: String = ""
    // P2-101 r1: server include/exclude peer ID sets for real folder filtering
    public var includePeers: ArrayList<Int64> = ArrayList<Int64>()
    public var excludePeers: ArrayList<Int64> = ArrayList<Int64>()
    public var includePeerRefs: ArrayList<ChatFolderPeer> = ArrayList<ChatFolderPeer>()
    public var excludePeerRefs: ArrayList<ChatFolderPeer> = ArrayList<ChatFolderPeer>()
    // S029 文件夹编辑器：dialogFilter#aa472651 布尔位与 pinned_peers（iOS ChatListFilterData）
    public var pinnedPeers: ArrayList<Int64> = ArrayList<Int64>()
    public var includeContacts: Bool = false
    public var includeNonContacts: Bool = false
    public var includeGroups: Bool = false
    public var includeChannels: Bool = false
    public var includeBots: Bool = false
    public var excludeMuted: Bool = false
    public var excludeRead: Bool = false
    public var excludeArchived: Bool = false
    // 服务端 emoticon（flags.25），仅当来自服务端/用户明确设置时回传；icon 为本地展示用
    public var emoticon: String = ""
    public var color: Int32 = -1
    public var hasColor: Bool = false
    public var isShared: Bool = false
    public var hasSharedLinks: Bool = false

    public init() {}

    /** Return a snapshot whose peer lists can be consumed independently. */
    public func copy(): ChatFolder {
        let result = ChatFolder()
        result.id = this.id
        result.name = this.name
        result.description = this.description
        result.icon = this.icon
        result.filterType = this.filterType
        for (peerId in this.includePeers) { result.includePeers.add(peerId) }
        for (peerId in this.excludePeers) { result.excludePeers.add(peerId) }
        for (peer in this.includePeerRefs) { result.includePeerRefs.add(peer.copy()) }
        for (peer in this.excludePeerRefs) { result.excludePeerRefs.add(peer.copy()) }
        for (peerId in this.pinnedPeers) { result.pinnedPeers.add(peerId) }
        result.includeContacts = this.includeContacts
        result.includeNonContacts = this.includeNonContacts
        result.includeGroups = this.includeGroups
        result.includeChannels = this.includeChannels
        result.includeBots = this.includeBots
        result.excludeMuted = this.excludeMuted
        result.excludeRead = this.excludeRead
        result.excludeArchived = this.excludeArchived
        result.emoticon = this.emoticon
        result.color = this.color
        result.hasColor = this.hasColor
        result.isShared = this.isShared
        result.hasSharedLinks = this.hasSharedLinks
        return result
    }
}
