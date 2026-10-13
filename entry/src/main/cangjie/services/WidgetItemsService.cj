package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.Chat
import std.collection.ArrayList
import std.time.DateTime

/**
 * 桌面小组件数据条目
 *
 * 对应 iOS WidgetItems/Sources/WidgetItems.swift WidgetDataPeer，
 * 保存供桌面小组件展示的最近会话快照。
 */
public class WidgetPeerItem {
    public var peerId: Int64 = 0
    public var name: String = ""
    public var avatarText: String = ""
    public var lastMessage: String = ""
    public var unreadCount: Int64 = 0
    public var isMuted: Bool = false
    public var isGroup: Bool = false
    public var isChannel: Bool = false
    public var timestamp: Int64 = 0
    public var avatarLocalPath: String = ""

    public func toJson(): String {
        let escaped = this.lastMessage
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        let nameEsc = this.name
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        let avatarEsc = this.avatarText
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        let pathEsc = this.avatarLocalPath
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
        return "{\"peerId\":${this.peerId},\"name\":\"${nameEsc}\",\"avatarText\":\"${avatarEsc}\",\"lastMessage\":\"${escaped}\",\"unreadCount\":${this.unreadCount},\"isMuted\":${this.isMuted},\"isGroup\":${this.isGroup},\"isChannel\":${this.isChannel},\"timestamp\":${this.timestamp},\"avatarLocalPath\":\"${pathEsc}\"}"
    }
}

/**
 * 桌面小组件数据服务
 *
 * 对应 iOS WidgetItems 的数据层：
 *   iOS: 写入 AppGroup shared container 供 WidgetKit extension 读取
 *   HarmonyOS: 调用 RealChatListService.getDialogs()（内部通过 MTProtoClient.sendRequest()）
 *              构造 WidgetPeerItem 列表并缓存到内存，
 *              供 WidgetItemsComponent 渲染（主屏 widget 渲染由系统 FormExtensionAbility 负责）。
 *
 * 调用链: refreshWidgetItems() → getRealChatListService().getDialogs()
 *           → getMTProtoClient().sendRequest() → MTProto服务器
 */
private var _widgetItemsServiceInstance: Option<WidgetItemsService> = None

public func getWidgetItemsService(): WidgetItemsService {
    match (_widgetItemsServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = WidgetItemsService()
            _widgetItemsServiceInstance = Some(inst)
            return inst
    }
}

public class WidgetItemsService {
    private var cachedItems: ArrayList<WidgetPeerItem> = ArrayList<WidgetPeerItem>()
    private var lastRefreshTimestamp: Int64 = 0
    private static let MAX_WIDGET_ITEMS: Int32 = 8

    /**
     * 获取当前缓存的小组件条目列表（不触发网络请求）
     */
    public func getWidgetItems(): ArrayList<WidgetPeerItem> {
        return this.cachedItems
    }

    /**
     * 刷新小组件数据
     *
     * 调用链: refreshWidgetItems()
     *   → getRealChatListService().getDialogs()（limit=8）
     *   → MTProtoClient.sendRequest(MessagesGetDialogs.toBytes())
     *
     * @return 更新后的条目列表
     */
    public func refreshWidgetItems(): ArrayList<WidgetPeerItem> {
        Hilog.info(0, "CjTelegram", "[WidgetItemsService] refreshWidgetItems: fetching dialogs via MTProto...")
        let chatService = getRealChatListService()
        let dialogs: ArrayList<Chat> = chatService.getDialogs(limit: 8)
        Hilog.info(0, "CjTelegram", "[WidgetItemsService] received ${dialogs.size} dialogs")

        let items = ArrayList<WidgetPeerItem>()
        var count: Int32 = 0
        for (chat in dialogs) {
            if (count >= WidgetItemsService.MAX_WIDGET_ITEMS) { break }
            let item = this.chatToWidgetPeerItem(chat)
            items.add(item)
            count = count + 1
        }

        this.cachedItems = items
        let now = DateTime.now()
        this.lastRefreshTimestamp = now.toUnixTimeStamp().toMilliseconds()
        Hilog.info(0, "CjTelegram", "[WidgetItemsService] widget cache updated: ${items.size} items")
        return items
    }

    /**
     * 将 Chat 模型转换为 WidgetPeerItem
     */
    private func chatToWidgetPeerItem(chat: Chat): WidgetPeerItem {
        let item = WidgetPeerItem()
        item.peerId = chat.id
        item.name = chat.name
        item.avatarText = chat.avatarText
        item.lastMessage = chat.lastMessage
        item.unreadCount = chat.unreadCount
        item.isMuted = chat.isMuted
        item.isGroup = chat.isGroup
        item.isChannel = chat.isChannel
        item.timestamp = chat.lastMessageTimestamp
        item.avatarLocalPath = chat.avatarLocalPath
        return item
    }

    /**
     * 序列化当前 widget 数据为 JSON 字符串（供调试 / 共享存储使用）
     */
    public func serializeToJson(): String {
        if (this.cachedItems.isEmpty()) {
            return "[]"
        }
        var json = "["
        var first = true
        for (item in this.cachedItems) {
            if (!first) { json = json + "," }
            json = json + item.toJson()
            first = false
        }
        json = json + "]"
        return json
    }

    /**
     * 获取最后刷新时间戳（毫秒）
     */
    public func getLastRefreshTimestamp(): Int64 {
        return this.lastRefreshTimestamp
    }
}
