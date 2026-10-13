package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * TelegramEngine_DataService — 通用数据引擎服务层
 *
 * 对应 iOS TelegramCore/Sources/TelegramEngine/Data/
 *   - ConfigurationData.swift (help.getAppConfig, help.getConfig)
 *   - ContactsData.swift      (contacts.getCountries / help.getCountriesList)
 *   - ChatListData.swift      (EngineData.Item.Messages.ChatList)
 *   - MessageData.swift       (EngineData.Item.Messages.TotalReadCounters)
 *   - ItemCache.swift         (EngineData.Item.ItemCache.Item)
 *   - OrderedLists.swift      (EngineData.Item.OrderedLists.ListItems)
 *   - NoticesData.swift       (EngineData.Item.Notices.Notice)
 *
 * TL 方法：
 *   help.getAppConfig#61e3f854 hash:int = help.AppConfig
 *   help.getCountriesList#735787a8 lang_code:string hash:int = help.CountriesList
 *   help.getConfig#c4f9186b = Config
 *
 * 调用链：
 *   TelegramEngine_DataService → getMTProtoClient() → sendRequest(TLObject.toBytes())
 *   → TLDeserializer → 返回结构化数据
 *
 * P2-158 聚合扩展（响应式→命令式取舍说明）：
 *   iOS EngineData 是响应式订阅（Postbox Signal 驱动，数据变更自动推送）。
 *   Cangjie 无 Postbox 响应式机制，拍板为"命令式等价"——
 *     get 方法一次性拉取当前快照（含本地 + 网络降级）；
 *     subscribe 语义由 DataDataProvider.EngineDataFacade 的 listener 注册 + 显式 notify 替代：
 *       调用 refreshAll() 触发重新聚合并回调所有已注册 listener。
 *   上层（UI / Provider）若需持续感知变化，应在状态变化后显式调用 refreshAll()，
 *   而非依赖自动推送。取舍已在交付报告 "已知限制" 中说明，响应式降级已完整实现。
 */

// ============================================================
// TL 方法定义（本文件内使用，遵循 TLMethods.cj 规范）
// ============================================================

/**
 * help.getAppConfig#61e3f854 hash:int = help.AppConfig
 * 获取应用级配置 JSON（含 user limits、feature flags 等）
 *
 * H-1（diag-suite_settings_data_storage-round4）：旧构造子 0x98914110 是废弃的零参形式
 * （help.getAppConfig#98914110 = help.AppConfig，无参数），当时序列化却仍写了 4 字节 hash，
 * 服务端按零参解析后发现多余字节 ⇒ 400 INPUT_REQUEST_TOO_LONG（6/6 复现）。
 * 当前 schema 是带 hash 参数的 help.getAppConfig#61e3f854 hash:int = help.AppConfig
 * （源侧 Api42.swift:5395 buffer.appendInt32(1642330196) = 0x61e3f854）；serialize() 写 hash 不变。
 */
class HelpGetAppConfig <: TLObject {
    public var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x61e3f854 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/**
 * help.getCountriesList#735787a8 lang_code:string hash:int = help.CountriesList
 * 获取国家列表（含电话区号）
 */
class HelpGetCountriesList <: TLObject {
    public var langCode: String = ""
    public var hash: Int32 = 0

    public func getConstructorId(): UInt32 { return 0x735787a8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeString(this.langCode)
        serializer.writeInt32(this.hash)
    }
}

// ============================================================
// 数据模型（供 DataDataProvider 使用）
// ============================================================

/**
 * AppConfig — 对应 iOS AppConfiguration
 * hash 用于增量更新（not_modified 响应时保留本地缓存）
 */
public class AppConfigData {
    public var hash: Int32 = 0
    public var configJson: String = ""
    public var maxPinnedChatCount: Int32 = 5
    public var maxGroupMemberCount: Int32 = 200
    public var maxSupergroupMemberCount: Int32 = 200000
    public var maxMessageEditingInterval: Int32 = 172800
    public var maxMessageRevokeInterval: Int32 = 172800
    public var maxMessageRevokeIntervalInPrivateChats: Int32 = 172800
    public var canRemoveIncomingMessagesInPrivateChats: Bool = false
    public var maxRecentStickerCount: Int32 = 15
    public var maxMessageForwardBatchSize: Int32 = 100
}

/**
 * ConfigLimits — 对应 iOS EngineConfiguration.Limits
 */
public class ConfigLimitsData {
    public var maxGroupMemberCount: Int32 = 200
    public var maxSupergroupMemberCount: Int32 = 200000
    public var maxMessageForwardBatchSize: Int32 = 100
    public var maxRecentStickerCount: Int32 = 15
    public var maxMessageEditingInterval: Int32 = 172800
    public var canRemoveIncomingMessagesInPrivateChats: Bool = false
    public var maxMessageRevokeInterval: Int32 = 172800
    public var maxMessageRevokeIntervalInPrivateChats: Int32 = 172800
    // Config.call_receive_timeout_ms / call_ring_timeout_ms（源侧 Api5.swift Cons_config
    // callReceiveTimeoutMs / callRingTimeoutMs）。0 = 服务器未下发 / 解析失败。
    public var callReceiveTimeoutMs: Int32 = 0
    public var callRingTimeoutMs: Int32 = 0
}

/**
 * CountryCallingCodeData — 单个国家电话区号
 */
public class CountryCallingCodeData {
    public var callingCode: String = ""
    public var prefixes: ArrayList<String> = ArrayList<String>()
    public var patterns: ArrayList<String> = ArrayList<String>()
}

/**
 * CountryData — 对应 iOS CountriesListState.Country
 */
public class CountryData {
    public var iso2: String = ""
    public var defaultName: String = ""
    public var localName: String = ""
    public var callingCodes: ArrayList<CountryCallingCodeData> = ArrayList<CountryCallingCodeData>()
    public var hidden: Bool = false
}

// ============================================================
// P2-158 新增聚合数据模型
// ============================================================

/**
 * ChatListItemData — EngineData.Item.Messages.ChatList 快照条目
 *
 * 对应 iOS EngineData.Item.Messages.ChatList 订阅项（一次性命令式快照）。
 * 聚合自 RealChatListService.getDialogsLocalFirst（本地优先，命令式取舍）。
 */
public class ChatListItemData {
    public var peerId: Int64 = 0
    public var peerType: String = ""
    public var name: String = ""
    public var unreadCount: Int64 = 0
    public var lastMessageTimestamp: Int64 = 0
    public var lastMessagePreview: String = ""
    public var isPinned: Bool = false
    public var isMuted: Bool = false
}

/**
 * TopPeerData — EngineData.Item.Contacts.TopPeers 聚合条目
 *
 * 对应 iOS EngineData.Item.Contacts.TopPeers（top inlined peers / frequent contacts）。
 * Cangjie 层从 RealContactService.getContacts() 取前 N 名联系人作为近似（命令式）。
 * iOS 原为 Postbox TopPeersTable driven by interaction frequency；
 * 此处以联系人列表首 N 项近似，诚实说明取舍。
 */
public class TopPeerData {
    public var peerId: Int64 = 0
    public var accessHash: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var rating: Float64 = 0.0
}

/**
 * TotalReadCountersData — EngineData.Item.Messages.TotalReadCounters 聚合
 *
 * 对应 iOS TotalUnreadState（totalChats, totalMessages 未读数）。
 * 聚合自当前会话列表快照（命令式，非响应式）：遍历所有会话 unreadCount 累加。
 */
public class TotalReadCountersData {
    public var totalUnreadChats: Int64 = 0
    public var totalUnreadMessages: Int64 = 0
}

/**
 * ItemCacheQueryResult — EngineData.Item.ItemCache.Item 查询结果
 *
 * 对应 iOS EngineData.Item.ItemCache.Item(id:namespace:) → Optional<CodableEntry>。
 * Cangjie 层从 ItemCacheService 命令式查询。
 */
public class ItemCacheQueryResult {
    public var key: String = ""
    public var value: Option<String> = None
    public var found: Bool = false
}

/**
 * OrderedListQueryResult — EngineData.Item.OrderedLists.ListItems 查询结果
 *
 * 对应 iOS EngineData.Item.OrderedLists.ListItems(collectionId:) → [OrderedItemListEntry]。
 * Cangjie 层从 OrderedListsService 命令式查询。
 */
public class OrderedListQueryResult {
    public var collectionId: Int32 = 0
    public var ids: ArrayList<String> = ArrayList<String>()
    public var contents: ArrayList<String> = ArrayList<String>()
    public var count: Int32 = 0
}

/**
 * NoticeQueryResult — EngineData.Item.Notices.Notice 查询结果
 *
 * 对应 iOS EngineData.Item.Notices.Notice(id:) → Optional<CodableEntry>。
 * Cangjie 层从 NoticesService.getNoticeEntry 命令式查询。
 */
public class NoticeQueryResult {
    public var key: String = ""
    public var value: Option<String> = None
    public var found: Bool = false
}

// ============================================================
// 服务层
// ============================================================

private var _dataServiceInstance: Option<TelegramEngine_DataService> = None

public func getTelegramEngineDataService(): TelegramEngine_DataService {
    match (_dataServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramEngine_DataService()
            _dataServiceInstance = Some(inst)
            return inst
    }
}

/**
 * TelegramEngine_DataService
 *
 * 封装 TelegramEngine.Data 命名空间的 TL 调用：
 *   - help.getAppConfig  — 应用配置（feature flags、limits）
 *   - help.getCountriesList — 国家/区号列表
 *   - help.getConfig     — 全局服务器配置（HelpGetConfig 已在 TLMethods.cj 定义）
 *
 * P2-158 聚合扩展：
 *   - getChatListItems()       — 从 RealChatListService 聚合会话列表快照
 *   - getContactsList()        — 从 ContactsService / RealContactService 聚合联系人
 *   - getTopPeers()            — 从 RealContactService 取前 N 联系人作为 top peers 近似
 *   - getTotalReadCounters()   — 遍历会话列表累加未读数
 *   - getItemCacheEntry()      — 从 ItemCacheService 查询单条缓存
 *   - getOrderedListItems()    — 从 OrderedListsService 查询有序列表
 *   - getNoticeEntry()         — 从 NoticesService 查询通知条目
 */
public class TelegramEngine_DataService {

    // ==================== AppConfig ====================

    /**
     * 获取 AppConfig
     * help.getAppConfig#61e3f854 hash:int = help.AppConfig
     *
     * 响应解析：
     *   help.appConfig#dd18782e hash:int config:JSONValue;（源侧 Api0.swift:1478 dict[-585598930]）
     *   help.appConfigNotModified#7cde641d = (not modified，返回 None)（源侧 Api0.swift:1479 dict[2094949405]，未改，本就正确）
     * `config` 是 boxed TL JSONValue 联合体（jsonNull/jsonBool/jsonNumber/jsonString/jsonArray/jsonObject，
     * 六个构造子逐个核自源侧 Api0.swift:567-573），不是 TL string，见 parseAppConfigJsonValue()。
     */
    public func getAppConfig(hash!: Int32 = 0): Option<AppConfigData> {
        let client = getMTProtoClient()
        let req = HelpGetAppConfig()
        req.hash = hash

        Hilog.info(0, "CjTelegram", "[DataService] Sending help.getAppConfig hash=${hash}")
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[DataService] Empty response for help.getAppConfig")
            return None
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[DataService] help.getAppConfig RPC Error: ${errorCode} - ${errorMsg}")
            return None
        }

        // help.appConfigNotModified#7cde641d
        if (constructor == 0x7cde641d) {
            Hilog.info(0, "CjTelegram", "[DataService] help.getAppConfig: not modified")
            return None
        }

        // help.appConfig#dd18782e hash:int config:JSONValue
        if (constructor == 0xdd18782e) {
            let data = AppConfigData()
            data.hash = d.readInt32()
            data.configJson = parseAppConfigJsonValue(d)
            Hilog.info(0, "CjTelegram", "[DataService] help.getAppConfig: got config, hash=${data.hash}")
            return Some(data)
        }

        Hilog.info(0, "CjTelegram", "[DataService] help.getAppConfig: unknown constructor 0x${constructor}")
        return None
    }

    /**
     * 获取服务器全局配置（help.getConfig）
     * 返回 ConfigLimitsData（从 Config 字段提取）
     *
     * help.getConfig#c4f9186b = Config
     * Config#cc1a241e = ...（包含 chat_size_max、megagroup_size_max 等字段）
     * D-186 全文件扫描发现：旧值 0x330b4067 在当前 schema 里查无此构造子
     * （源侧 Api0.swift:244 唯一登记 dict[-870702050] = Config#cc1a241e），
     * 与本函数一直未被测出的 H-1 同类——恒不匹配 ⇒ getConfigLimits() 恒落入 unknown 分支返回 None。
     */
    public func getConfigLimits(): Option<ConfigLimitsData> {
        let client = getMTProtoClient()
        let req = HelpGetConfig()

        Hilog.info(0, "CjTelegram", "[DataService] Sending help.getConfig")
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[DataService] Empty response for help.getConfig")
            return None
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[DataService] help.getConfig RPC Error: ${errorCode} - ${errorMsg}")
            return None
        }

        // Config#cc1a241e
        if (constructor == 0xcc1a241e) {
            let limits = parseConfigLimits(d)
            Hilog.info(0, "CjTelegram", "[DataService] help.getConfig: maxGroup=${limits.maxGroupMemberCount}, maxSupergroup=${limits.maxSupergroupMemberCount}")
            return Some(limits)
        }

        Hilog.info(0, "CjTelegram", "[DataService] help.getConfig: unknown constructor 0x${constructor}")
        return None
    }

    /**
     * 获取国家列表
     * help.getCountriesList#735787a8 lang_code:string hash:int = help.CountriesList
     *
     * 响应：
     *   help.countriesList#87d0759e hash:int countries:Vector<help.Country>
     *   help.countriesListNotModified#93cc1f32 (not modified)（源侧 Api0.swift:1483 dict[-1815339214]）
     * D-186 全文件扫描发现：旧值 0x7f985d42 查无此构造子（源侧登记的唯一值是 0x93cc1f32），
     * 与 Config 同类的历史错配 ⇒ 服务端返回真实 not-modified 时会落入 unknown 分支丢弃缓存判定。
     */
    public func getCountriesList(langCode!: String = "en", hash!: Int32 = 0): Option<ArrayList<CountryData>> {
        let client = getMTProtoClient()
        let req = HelpGetCountriesList()
        req.langCode = langCode
        req.hash = hash

        Hilog.info(0, "CjTelegram", "[DataService] Sending help.getCountriesList lang=${langCode}")
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[DataService] Empty response for help.getCountriesList")
            return None
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[DataService] help.getCountriesList RPC Error: ${errorCode} - ${errorMsg}")
            return None
        }

        // help.countriesListNotModified#93cc1f32
        if (constructor == 0x93cc1f32) {
            Hilog.info(0, "CjTelegram", "[DataService] help.getCountriesList: not modified")
            return None
        }

        // help.countriesList#87d0759e hash:int countries:Vector<help.Country>
        if (constructor == 0x87d0759e) {
            let _hash = d.readInt32()
            let countries = parseCountriesVector(d)
            Hilog.info(0, "CjTelegram", "[DataService] help.getCountriesList: ${countries.size} countries")
            return Some(countries)
        }

        Hilog.info(0, "CjTelegram", "[DataService] help.getCountriesList: unknown constructor 0x${constructor}")
        return None
    }

    // ============================================================
    // P2-158 Gap 2: ChatList items 聚合
    // ============================================================

    /**
     * 获取会话列表快照（EngineData.Item.Messages.ChatList 命令式等价）
     *
     * 对应 iOS EngineData.Item.Messages.ChatList(peerId:groupId:) 订阅项。
     * 响应式→命令式取舍：从 RealChatListService.getDialogsLocalFirst() 取本地优先快照，
     * 无 Postbox Signal 自动推送；上层通过 EngineDataFacade.refreshAll() 触发重新拉取。
     *
     * @param limit 最多返回会话数，默认 20
     * @return ChatListItemData 列表（按置顶+时间降序）
     */
    public func getChatListItems(limit!: Int32 = 20): ArrayList<ChatListItemData> {
        Hilog.info(0, "CjTelegram", "[DataService] getChatListItems limit=${limit}")
        let chats = getRealChatListService().getDialogsLocalFirst(limit: limit)
        let result = ArrayList<ChatListItemData>()
        for (chat in chats) {
            let item = ChatListItemData()
            item.peerId = chat.id
            item.peerType = chat.peerType
            item.name = chat.name
            item.unreadCount = chat.unreadCount
            item.lastMessageTimestamp = chat.lastMessageTimestamp
            item.lastMessagePreview = chat.lastMessage
            item.isPinned = chat.isPinned
            // isMuted 恒为 false：RealChatListService.getDialogsLocalFirst() 不返回静音状态，
            // 上游无静音字段来源；如需准确值须接入 account.getNotifySettings TL。
            result.add(item)
        }
        Hilog.info(0, "CjTelegram", "[DataService] getChatListItems: ${result.size} items")
        return result
    }

    // ============================================================
    // P2-158 Gap 3: Contacts.List / Top 聚合
    // ============================================================

    /**
     * 获取联系人列表（EngineData.Item.Contacts.List 命令式等价）
     *
     * 对应 iOS EngineData.Item.Contacts.List 订阅。
     * 命令式：从 ContactsService.getContacts() 一次性拉取当前联系人列表。
     *
     * @return ContactDisplayData 列表
     */
    public func getContactsList(): ArrayList<ContactDisplayData> {
        Hilog.info(0, "CjTelegram", "[DataService] getContactsList")
        let contacts = getContactsService().getContacts()
        Hilog.info(0, "CjTelegram", "[DataService] getContactsList: ${contacts.size} contacts")
        return contacts
    }

    /**
     * 获取 Top Peers（EngineData.Item.Contacts.TopPeers）
     *
     * P2-157b: 升级为真实 contacts.getTopPeers RPC（correspondents 分类）。
     * 之前近似：取前 topN 联系人 + rating=0.0。
     * 现在：通过 ContactListService.getTopPeers() → RealContactService.getTopPeers() 调用
     *   contacts.getTopPeers#973478b6（带 hash 增量缓存），返回真实 rating 降序排列的热门联系人。
     *
     * @param topN 最多返回条目数，默认 8（iOS Top Peers 行一般显示 8 个）
     * @return TopPeerData 列表（rating 字段为真实服务端评分，非 0.0 近似）
     */
    public func getTopPeers(topN!: Int32 = 8): ArrayList<TopPeerData> {
        Hilog.info(0, "CjTelegram", "[DataService] getTopPeers topN=${topN} (real RPC via ContactListService)")
        let contacts = getContactListService().getTopPeers()
        let result = ArrayList<TopPeerData>()
        var count: Int32 = 0
        for (contact in contacts) {
            if (count >= topN) {
                break
            }
            let tp = TopPeerData()
            tp.peerId = contact.userId
            tp.accessHash = contact.accessHash
            tp.firstName = contact.firstName
            tp.lastName = contact.lastName
            tp.username = contact.username
            tp.rating = contact.rating
            result.add(tp)
            count = count + 1
        }
        Hilog.info(0, "CjTelegram", "[DataService] getTopPeers: ${result.size} peers")
        return result
    }

    // ============================================================
    // P2-158 Gap 4: Messages.TotalReadCounters 聚合
    // ============================================================

    /**
     * 获取全局未读计数（EngineData.Item.Messages.TotalReadCounters 命令式等价）
     *
     * 对应 iOS EngineData.Item.Messages.TotalReadCounters 订阅。
     * 命令式：遍历当前会话列表快照，累加每条会话的 unreadCount。
     *   totalUnreadChats = 有未读消息的会话数；
     *   totalUnreadMessages = 所有会话未读消息总数。
     * 非响应式：调用时读一次，变化不自动推送。
     *
     * @param limit 用于拉取会话列表的 limit（影响覆盖面，默认 100）
     * @return TotalReadCountersData
     */
    public func getTotalReadCounters(limit!: Int32 = 100): TotalReadCountersData {
        Hilog.info(0, "CjTelegram", "[DataService] getTotalReadCounters")
        let counters = TotalReadCountersData()
        let chats = getRealChatListService().getDialogsLocalFirst(limit: limit)
        for (chat in chats) {
            if (chat.unreadCount > 0) {
                counters.totalUnreadChats = counters.totalUnreadChats + 1
                counters.totalUnreadMessages = counters.totalUnreadMessages + chat.unreadCount
            }
        }
        Hilog.info(0, "CjTelegram", "[DataService] getTotalReadCounters: chats=${counters.totalUnreadChats}, msgs=${counters.totalUnreadMessages}")
        return counters
    }

    // ============================================================
    // P2-158 Gap 5: ItemCache / OrderedLists / Notices 聚合接线
    // ============================================================

    /**
     * 查询 ItemCache 单条（EngineData.Item.ItemCache.Item 命令式等价）
     *
     * 对应 iOS EngineData.Item.ItemCache.Item(id:namespace:) → Optional<CodableEntry>。
     * 命令式：从 ItemCacheService 一次性读取。
     *
     * @param key 完整缓存 key（由上层按 iOS NoticeEntryKey / ItemCacheKey 规范构造）
     */
    public func getItemCacheEntry(key: String): ItemCacheQueryResult {
        let result = ItemCacheQueryResult()
        result.key = key
        let cacheVal = getTelegramEngineItemCacheService().get(key)
        match (cacheVal) {
            case Some(v) =>
                result.value = Some(v)
                result.found = true
            case None =>
                result.found = false
        }
        Hilog.info(0, "CjTelegram", "[DataService] getItemCacheEntry key=${key} found=${result.found}")
        return result
    }

    /**
     * 查询有序列表条目（EngineData.Item.OrderedLists.ListItems 命令式等价）
     *
     * 对应 iOS EngineData.Item.OrderedLists.ListItems(collectionId:) → [OrderedItemListEntry]。
     * 命令式：从 OrderedListsService 一次性读取。
     *
     * collectionId 语义（与 iOS TelegramEngine.OrderedLists 保持一致）:
     *   0 = recentGifs, 1 = recentStickers, 2 = inlineBots, 其他 = 业务自定义
     *
     * @param collectionId 集合 ID
     */
    public func getOrderedListItems(collectionId: Int32): OrderedListQueryResult {
        let result = OrderedListQueryResult()
        result.collectionId = collectionId
        let svcResult = getOrderedListsService().getItems(collectionId)
        if (svcResult.success) {
            for (entry in svcResult.entries) {
                result.ids.add(entry.id)
                result.contents.add(entry.contents)
            }
            result.count = Int32(svcResult.entries.size)
        }
        Hilog.info(0, "CjTelegram", "[DataService] getOrderedListItems colId=${collectionId} count=${result.count}")
        return result
    }

    /**
     * 查询 Notice 条目（EngineData.Item.Notices.Notice 命令式等价）
     *
     * 对应 iOS EngineData.Item.Notices.Notice(id:) → Optional<CodableEntry>。
     * 命令式：从 NoticesService.getNoticeEntry 一次性读取。
     *
     * @param key notice key（由上层按 iOS NoticeEntryKey 规范构造）
     */
    public func getNoticeEntry(key: String): NoticeQueryResult {
        let result = NoticeQueryResult()
        result.key = key
        let noticeVal = getNoticesService().getNoticeEntry(key)
        match (noticeVal) {
            case Some(v) =>
                result.value = Some(v)
                result.found = true
            case None =>
                result.found = false
        }
        Hilog.info(0, "CjTelegram", "[DataService] getNoticeEntry key=${key} found=${result.found}")
        return result
    }

    // ==================== Private parse helpers ====================

    /**
     * rework round1 修法（Reviewer kb_cross_check FAIL 复核）：与 `core/mtproto/TLResponses.cj`
     * 的 `toHex32()` 同源实现（该函数未对外 `public`，且该文件不在本 feature 的
     * `tasks[].target_files` 内，不能为了复用去改它的可见性）。按本仓已确立的范式
     * （`services/StickersService.cj:1049 toHex32Local`，同样是跨包访问同一 `toHex32` 受阻后的
     * 本地镜像）在本文件内复刻一份，供下面两处未知构造子诊断日志把裸 `UInt32` 格式化成
     * 真正的十六进制文本。
     *
     * 这条修复本身也是本 feature 新增的 D-192 规则（"遇到未知构造子要打日志供日后审计"）
     * 的一次自我修正：原实现把裸 `UInt32` 直接塞进 `"0x${...}"` 插值，而 `UInt32.toString()`
     * 默认十进制，打印出的不是十六进制而是形似十六进制的十进制数字（如 `0x2661200029`），
     * D-192 要求的审计日志因此不可用——规则被自己的实现架空了。改用本函数后日志才是可比对的
     * 真实十六进制值。
     */
    private func toHex32(v: UInt32): String {
        let hexChars = "0123456789abcdef"
        let hexRunes = hexChars.toRuneArray()
        var result = ""
        var remaining = v
        for (_i in 0..8) {
            let nibble = Int64((remaining >> 28) & 0xF)
            result = result + hexRunes[nibble].toString()
            remaining = remaining << 4
        }
        return result
    }

    /**
     * H-1 修法 §3（parseAppConfigJsonValue）：help.appConfig 的 config:JSONValue 顶层入口。
     *
     * 顶层构造子协议上恒为 jsonObject#99c1d49d；非 jsonObject 或解析过程中任何异常
     * 一律返回空串——AppConfigData.configJson 的下游 3 处消费方
     * （services/SettingsService.cj:3094、pages/ChatFoldersPage.cj:354、pages/DebugSettingsPage.cj:245）
     * 都经 JsonParser.parseObject(configJson) 走"空串即默认值"路径，本函数签名不抛异常。
     */
    private func parseAppConfigJsonValue(d: TLDeserializer): String {
        try {
            let topCtor = d.peekUInt32()
            if (topCtor != 0x99c1d49d) {
                Hilog.info(0, "CjTelegram", "[DataService] getAppConfig: top-level config constructor is not jsonObject (0x${toHex32(topCtor)}), returning empty")
                return ""
            }
            return parseJsonValue(d)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DataService] getAppConfig: config JSONValue parse failed: ${e}")
            return ""
        }
    }

    /**
     * 解析 boxed TL JSONValue 联合体，还原成一段 JSON 文本。
     *
     * 六个构造子逐个核自源侧 Api0.swift:567-573（十进制有符号 → 无符号 hex 已转换核对）：
     *   jsonNull#3f6d7b68 = JSONValue
     *   jsonBool#c7345e6a value:Bool = JSONValue        （value 是 boxed TL Bool，走 readBool()）
     *   jsonNumber#2be0dfa4 value:double = JSONValue
     *   jsonString#b71e767a value:string = JSONValue
     *   jsonArray#f7444763 value:Vector<JSONValue> = JSONValue
     *   jsonObject#99c1d49d value:Vector<JSONObjectValue> = JSONValue
     * 未识别构造子按 D-186 修法第 3 条：只抛异常（由调用方 catch 记日志），不猜测形状读取字节。
     */
    private func parseJsonValue(d: TLDeserializer): String {
        let ctor = d.readUInt32()
        if (ctor == 0x3f6d7b68) {
            return "null"
        } else if (ctor == 0xc7345e6a) {
            if (d.readBool()) {
                return "true"
            } else {
                return "false"
            }
        } else if (ctor == 0x2be0dfa4) {
            let n = d.readDouble()
            return n.toString()
        } else if (ctor == 0xb71e767a) {
            return "\"" + escapeJsonString(d.readString()) + "\""
        } else if (ctor == 0xf7444763) {
            return parseJsonArrayBody(d)
        } else if (ctor == 0x99c1d49d) {
            return parseJsonObjectBody(d)
        } else {
            throw Exception("[DataService] unknown JSONValue constructor 0x${toHex32(ctor)}")
        }
    }

    /**
     * jsonArray#f7444763 的载荷：Vector<JSONValue>（boxed vector marker 0x1cb5c415 + count，
     * 每个元素自带自己的 boxed 构造子，递归走 parseJsonValue）。
     */
    private func parseJsonArrayBody(d: TLDeserializer): String {
        let _vecCtor = d.readUInt32()
        let count = d.readInt32()
        var result = "["
        var i: Int32 = 0
        while (i < count) {
            if (i > 0) {
                result += ","
            }
            result += parseJsonValue(d)
            i++
        }
        result += "]"
        return result
    }

    /**
     * jsonObject#99c1d49d 的载荷：Vector<JSONObjectValue>。
     * jsonObjectValue#c0de1bd9 key:string value:JSONValue（源侧 Api14.swift:1466-1514）：
     * key 是裸 TL string（不 boxed，readString() 直读），value 递归走 parseJsonValue。
     */
    private func parseJsonObjectBody(d: TLDeserializer): String {
        let _vecCtor = d.readUInt32()
        let count = d.readInt32()
        var result = "{"
        var i: Int32 = 0
        while (i < count) {
            let _ovCtor = d.readUInt32()
            let key = d.readString()
            let value = parseJsonValue(d)
            if (i > 0) {
                result += ","
            }
            result += "\"" + escapeJsonString(key) + "\":" + value
            i++
        }
        result += "}"
        return result
    }

    /**
     * 解析 Config 的核心 Limits 字段
     *
     * TL schema Config#cc1a241e 字段顺序（源侧 Api5.swift:1067 Cons_config，唯一登记的 boxed 构造子）：
     *   flags:#
     *   date:int
     *   expires:int
     *   test_mode:Bool   (TL Bool — 读 UInt32 构造函数 ID)
     *   this_dc:int
     *   dc_options:Vector<DcOption>   (变长，需遍历跳过)
     *   dc_txt_domain_name:string
     *   chat_size_max:int             → limits.maxGroupMemberCount
     *   megagroup_size_max:int        → limits.maxSupergroupMemberCount
     *
     * DcOption#18b7a10d 字段顺序：
     *   flags:#   id:int   ip_address:string   port:int
     *   secret:flags.10?bytes   (bit 10 置位时才有)
     */
    private func parseConfigLimits(d: TLDeserializer): ConfigLimitsData {
        let limits = ConfigLimitsData()
        try {
            // 1. flags (bare #)
            let _flags = d.readUInt32()
            // 2. date:int
            let _date = d.readInt32()
            // 3. expires:int
            let _expires = d.readInt32()
            // 4. test_mode:Bool — TL Bool is a 4-byte constructor ID
            let _testMode = d.readUInt32()
            // 5. this_dc:int
            let _thisDc = d.readInt32()
            // 6. dc_options:Vector<DcOption> — skip all entries
            let vecCtor = d.readUInt32()
            if (vecCtor == TLConstructors.VECTOR) {
                let dcCount = d.readInt32()
                var dcIdx: Int32 = 0
                while (dcIdx < dcCount) {
                    skipDcOption(d)
                    dcIdx++
                }
            }
            // 7. dc_txt_domain_name:string
            let _dcTxtDomain = d.readString()
            // 8. chat_size_max:int → maxGroupMemberCount
            limits.maxGroupMemberCount = d.readInt32()
            // 9. megagroup_size_max:int → maxSupergroupMemberCount
            limits.maxSupergroupMemberCount = d.readInt32()
            // 10-24（源侧 parse_config _10.._24）：forwarded_count_max, online_update_period_ms,
            //   offline_blur_timeout_ms, offline_idle_timeout_ms, online_cloud_timeout_ms,
            //   notify_cloud_delay_ms, notify_default_delay_ms, push_chat_period_ms, push_chat_limit,
            //   edit_time_limit, revoke_time_limit, revoke_pm_time_limit, rating_e_decay,
            //   stickers_recent_limit, channels_read_media_period —— 15 个 int，此处跳过
            var skipIdx = 0
            while (skipIdx < 15) {
                let _ = d.readInt32()
                skipIdx++
            }
            // 25. tmp_sessions:flags.0?int
            if ((_flags & 1) != 0) {
                let _tmpSessions = d.readInt32()
            }
            // 26. call_receive_timeout_ms:int  27. call_ring_timeout_ms:int
            limits.callReceiveTimeoutMs = d.readInt32()
            limits.callRingTimeoutMs = d.readInt32()
            Hilog.info(0, "CjTelegram", "[DataService] parseConfigLimits: chat_size_max=${limits.maxGroupMemberCount} megagroup_size_max=${limits.maxSupergroupMemberCount} call_receive_timeout_ms=${limits.callReceiveTimeoutMs} call_ring_timeout_ms=${limits.callRingTimeoutMs}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DataService] parseConfigLimits exception, using defaults: ${e}")
        }
        return limits
    }

    /**
     * 跳过单个 DcOption#18b7a10d
     * dcOption#18b7a10d flags:# ipv6:flags.0?true media_only:flags.1?true
     *   tcpo_only:flags.2?true cdn:flags.3?true static:flags.4?true
     *   this_port_only:flags.5?true id:int ip_address:string port:int
     *   secret:flags.10?bytes
     */
    private func skipDcOption(d: TLDeserializer) {
        let _ctor = d.readUInt32()      // constructor ID (0x18b7a10d)
        let dcFlags = d.readUInt32()    // flags:#
        let _id = d.readInt32()         // id:int
        let _ip = d.readString()        // ip_address:string
        let _port = d.readInt32()       // port:int
        // secret:flags.10?bytes — bit 10 = 0x400
        if ((dcFlags & 0x400) != 0) {
            let _secret = d.readBytes()
        }
    }

    /**
     * 解析国家向量
     * Vector<help.Country>
     * help.country#c3878e23 flags:# hidden:flags.0?true iso2:string default_name:string
     *   name:flags.1?string country_codes:Vector<help.CountryCode>
     */
    private func parseCountriesVector(d: TLDeserializer): ArrayList<CountryData> {
        let result = ArrayList<CountryData>()
        try {
            let vectorConstructor = d.readUInt32()
            if (vectorConstructor != TLConstructors.VECTOR) {
                return result
            }
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let countryConstructor = d.readUInt32()
                if (countryConstructor == 0xc3878e23) {
                    let country = parseCountry(d)
                    result.add(country)
                }
                i++
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DataService] parseCountriesVector exception: ${result.size} parsed so far")
        }
        return result
    }

    /**
     * 解析单个 help.Country
     * help.country#c3878e23 flags:# hidden:flags.0?true iso2:string default_name:string
     *   name:flags.1?string country_codes:Vector<help.CountryCode>
     */
    private func parseCountry(d: TLDeserializer): CountryData {
        let country = CountryData()
        let flags = d.readUInt32()
        country.hidden = (flags & 1) != 0
        country.iso2 = d.readString()
        country.defaultName = d.readString()
        if ((flags & 2) != 0) {
            country.localName = d.readString()
        }
        country.callingCodes = parseCountryCodesVector(d)
        return country
    }

    /**
     * 解析 help.CountryCode 向量
     * help.countryCode#4203c5ef country_code:string prefixes:flags.0?Vector<string>
     *   patterns:flags.1?Vector<string>
     */
    private func parseCountryCodesVector(d: TLDeserializer): ArrayList<CountryCallingCodeData> {
        let result = ArrayList<CountryCallingCodeData>()
        try {
            let vectorConstructor = d.readUInt32()
            if (vectorConstructor != TLConstructors.VECTOR) {
                return result
            }
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let codeConstructor = d.readUInt32()
                if (codeConstructor == 0x4203c5ef) {
                    let code = CountryCallingCodeData()
                    let codeFlags = d.readUInt32()
                    code.callingCode = d.readString()
                    if ((codeFlags & 1) != 0) {
                        code.prefixes = readStringVector(d)
                    }
                    if ((codeFlags & 2) != 0) {
                        code.patterns = readStringVector(d)
                    }
                    result.add(code)
                }
                i++
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DataService] parseCountryCodesVector exception")
        }
        return result
    }

    /**
     * 读取 Vector<string>
     */
    private func readStringVector(d: TLDeserializer): ArrayList<String> {
        let result = ArrayList<String>()
        let vectorConstructor = d.readUInt32()
        if (vectorConstructor != TLConstructors.VECTOR) {
            return result
        }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count) {
            result.add(d.readString())
            i++
        }
        return result
    }
}
