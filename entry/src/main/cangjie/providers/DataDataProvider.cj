package ohos_app_cangjie_entry.providers

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{
    getTelegramEngineDataService,
    AppConfigData,
    ConfigLimitsData,
    CountryData,
    ChatListItemData,
    TopPeerData,
    TotalReadCountersData,
    ItemCacheQueryResult,
    OrderedListQueryResult,
    NoticeQueryResult,
    ContactDisplayData
}
import std.collection.ArrayList

/**
 * DataDataProvider — 数据引擎 UI 适配层
 *
 * 对应 iOS TelegramEngine.EngineData 的 ViewModel 接入层
 * 职责：
 *   - 将 TelegramEngine_DataService 的 API 数据转为 UI 可用的 ViewModel
 *   - 提供 getAppConfig / getConfigLimits / getCountriesList 的安全访问封装
 *   - 本地缓存最近一次成功返回的结果，避免重复网络请求
 *   - P2-158 新增：提供 EngineDataFacade 聚合门面（chatList / contacts / readCounters /
 *     itemCache / orderedLists / notices）
 *
 * 调用链：
 *   DataDataProvider → TelegramEngine_DataService → getMTProtoClient() → sendRequest()
 *
 * P2-158 响应式→命令式取舍（Gap 1）：
 *   iOS EngineData 是响应式订阅体系（Signal<T, NoError> Postbox 驱动，数据变更自动推送给所有订阅者）。
 *   Cangjie 无 Postbox / Signal 机制，无法直接 1:1 复刻"自动推送"语义。
 *   拍板方案：命令式等价（Command-equivalent pattern）——
 *     1. get*(...)：一次性获取当前快照（当前时刻的值）。
 *     2. EngineDataFacade：提供 addChangeListener / removeChangeListener / notifyListeners() 接口：
 *        - addChangeListener 注册一个 () -> Unit 回调（对应 iOS .start(next:)）
 *        - refreshAll() 重新聚合所有数据并调用所有已注册 listener
 *        - 上层（UI / 其他 Provider）在需要"数据可能已变化"时显式调用 refreshAll()
 *     3. 所有聚合路径均真实实现，无占位逻辑。
 *   诚实限制：不支持 Postbox 级别的细粒度变更检测（只有显式 refresh 才触发 listener）。
 */
public class DataDataProvider {
    private let service = getTelegramEngineDataService()

    // 本地缓存
    private var cachedAppConfig: Option<AppConfigData> = None
    private var cachedLimits: Option<ConfigLimitsData> = None
    private var cachedCountries: Option<ArrayList<CountryData>> = None

    // ==================== AppConfig ====================

    /**
     * 获取 AppConfig（优先返回缓存，若 None 则网络拉取）
     * 对应 iOS TelegramEngine.EngineData.Item.Configuration.App
     */
    public func getAppConfig(): AppConfigData {
        match (this.cachedAppConfig) {
            case Some(cfg) => return cfg
            case None =>
                match (this.service.getAppConfig()) {
                    case Some(cfg) =>
                        this.cachedAppConfig = Some(cfg)
                        return cfg
                    case None => return AppConfigData()
                }
        }
    }

    /**
     * 强制刷新 AppConfig（忽略缓存）
     * @return Some(data) 或 None（网络失败）
     */
    public func refreshAppConfig(): Option<AppConfigData> {
        let hashVal: Int32 = match (this.cachedAppConfig) {
            case Some(cfg) => cfg.hash
            case None => 0
        }
        let fresh = this.service.getAppConfig(hash: hashVal)
        match (fresh) {
            case Some(cfg) =>
                this.cachedAppConfig = Some(cfg)
            case None => ()
        }
        return fresh
    }

    /**
     * 获取 maxPinnedChatCount（从 AppConfig 中提取）
     * 对应 iOS EngineConfiguration.UserLimits.maxPinnedChatCount
     */
    public func getMaxPinnedChatCount(): Int32 {
        return this.getAppConfig().maxPinnedChatCount
    }

    /**
     * 获取 maxGroupMemberCount
     * 对应 iOS EngineConfiguration.Limits.maxGroupMemberCount
     */
    public func getMaxGroupMemberCount(): Int32 {
        return this.getConfigLimits().maxGroupMemberCount
    }

    // ==================== ConfigLimits ====================

    /**
     * 获取服务器 Limits 配置（优先缓存）
     * 对应 iOS TelegramEngine.EngineData.Item.Configuration.Limits
     */
    public func getConfigLimits(): ConfigLimitsData {
        match (this.cachedLimits) {
            case Some(limits) => return limits
            case None =>
                match (this.service.getConfigLimits()) {
                    case Some(limits) =>
                        this.cachedLimits = Some(limits)
                        return limits
                    case None => return ConfigLimitsData()
                }
        }
    }

    /**
     * 强制刷新 ConfigLimits
     */
    public func refreshConfigLimits(): Option<ConfigLimitsData> {
        let fresh = this.service.getConfigLimits()
        match (fresh) {
            case Some(limits) =>
                this.cachedLimits = Some(limits)
            case None => ()
        }
        return fresh
    }

    /**
     * 判断消息撤回时间是否在限制内
     * @param intervalSeconds 撤回操作距离发送时间的秒数
     */
    public func canRevokeMessage(intervalSeconds: Int32): Bool {
        let limits = this.getConfigLimits()
        return intervalSeconds <= limits.maxMessageRevokeInterval
    }

    /**
     * 判断是否可以在私聊中删除对方消息
     */
    public func canRemoveIncomingMessagesInPrivateChats(): Bool {
        return this.getConfigLimits().canRemoveIncomingMessagesInPrivateChats
    }

    /**
     * 获取最大消息编辑时间间隔（秒）
     */
    public func getMaxMessageEditingInterval(): Int32 {
        return this.getConfigLimits().maxMessageEditingInterval
    }

    // ==================== 国家列表 ====================

    /**
     * 获取国家列表（优先缓存）
     * 对应 iOS TelegramEngine.EngineData.Item.Configuration (ContactsData)
     */
    public func getCountriesList(langCode!: String = "en"): ArrayList<CountryData> {
        match (this.cachedCountries) {
            case Some(list) => return list
            case None =>
                match (this.service.getCountriesList(langCode: langCode)) {
                    case Some(list) =>
                        this.cachedCountries = Some(list)
                        return list
                    case None => return ArrayList<CountryData>()
                }
        }
    }

    /**
     * 强制刷新国家列表
     */
    public func refreshCountriesList(langCode!: String = "en"): Option<ArrayList<CountryData>> {
        let fresh = this.service.getCountriesList(langCode: langCode)
        match (fresh) {
            case Some(list) =>
                this.cachedCountries = Some(list)
            case None => ()
        }
        return fresh
    }

    /**
     * 根据 ISO2 代码查找国家
     * @param iso2 两字母国家代码，如 "CN", "US"
     */
    public func findCountry(iso2: String): Option<CountryData> {
        let iso2Upper = iso2.toAsciiUpper()
        let list = this.getCountriesList()
        for (country in list) {
            if (country.iso2 == iso2Upper) {
                return Some(country)
            }
        }
        return None
    }

    /**
     * 根据电话区号查找国家（返回首个匹配）
     * @param callingCode 如 "86", "1"
     */
    public func findCountryByCallingCode(callingCode: String): Option<CountryData> {
        let list = this.getCountriesList()
        for (country in list) {
            for (code in country.callingCodes) {
                if (code.callingCode == callingCode) {
                    return Some(country)
                }
            }
        }
        return None
    }

    // ==================== 缓存管理 ====================

    /**
     * 清除所有本地缓存（用于登出或刷新）
     */
    public func clearCache(): Unit {
        this.cachedAppConfig = None
        this.cachedLimits = None
        this.cachedCountries = None
    }
}

// ============================================================
// P2-158 EngineDataFacade — 聚合门面（响应式→命令式等价）
// ============================================================

/**
 * EngineDataFacade — TelegramEngine.EngineData 聚合门面（命令式等价）
 *
 * 对应 iOS TelegramEngine.EngineData 订阅/获取体系的 Cangjie 命令式等价实现。
 *
 * 取舍说明（Gap 1）：
 *   iOS EngineData 通过 Postbox Signal 实现响应式订阅（subscribe 返回 Signal<T, NoError>，
 *   数据变更时自动 push 给所有订阅者）。
 *   Cangjie 无 Postbox/Signal：
 *     - get*(...)：命令式一次性快照（等价于 iOS .get(...)）
 *     - addChangeListener / removeChangeListener：注册/注销变更回调（等价于 iOS .start(next:)）
 *     - notifyListeners()：触发所有 listener（等价于 Signal emit next）
 *     - refreshAll()：重新聚合所有数据并 notifyListeners()
 *                    （等价于 iOS 订阅触发的自动 next 推送，但需显式调用）
 *
 * 聚合路径：
 *   getChatListSnapshot()   → TelegramEngine_DataService.getChatListItems()
 *   getContactsSnapshot()   → TelegramEngine_DataService.getContactsList()
 *   getTopPeersSnapshot()   → TelegramEngine_DataService.getTopPeers()
 *   getReadCounters()       → TelegramEngine_DataService.getTotalReadCounters()
 *   getItemCacheEntry()     → TelegramEngine_DataService.getItemCacheEntry()
 *   getOrderedListItems()   → TelegramEngine_DataService.getOrderedListItems()
 *   getNoticeEntry()        → TelegramEngine_DataService.getNoticeEntry()
 */
public class EngineDataFacade {
    private let service = getTelegramEngineDataService()

    // 变更 listener 列表（key = listener ID, value = callback）
    private var listeners: ArrayList<EngineDataListener> = ArrayList<EngineDataListener>()
    private var nextListenerId: Int64 = 0

    // 聚合缓存（refreshAll 刷新后持有，供 listener 读取）
    private var lastChatList: ArrayList<ChatListItemData> = ArrayList<ChatListItemData>()
    private var lastContacts: ArrayList<ContactListItemData> = ArrayList<ContactListItemData>()
    private var lastTopPeers: ArrayList<TopPeerData> = ArrayList<TopPeerData>()
    private var lastReadCounters: TotalReadCountersData = TotalReadCountersData()

    // ==================== 变更 listener 注册（Gap 1）====================

    /**
     * 注册数据变更回调（对应 iOS .subscribe(...).start(next:)）
     * 数据变化时（通过 refreshAll() 触发）将调用 callback。
     *
     * @param callback 无参回调；调用后通过 get*Snapshot() 读取最新数据
     * @return listener ID，用于 removeChangeListener 注销
     */
    public func addChangeListener(callback: () -> Unit): Int64 {
        let id = this.nextListenerId
        this.nextListenerId = this.nextListenerId + 1
        let listener = EngineDataListener()
        listener.id = id
        listener.callback = callback
        this.listeners.add(listener)
        Hilog.info(0, "CjTelegram", "[EngineDataFacade] addChangeListener id=${id}, total=${this.listeners.size}")
        return id
    }

    /**
     * 注销数据变更回调（对应 iOS Disposable.dispose()）
     * @param listenerId addChangeListener 返回的 ID
     */
    public func removeChangeListener(listenerId: Int64): Unit {
        let prev = this.listeners.size
        let newList = ArrayList<EngineDataListener>()
        for (l in this.listeners) {
            if (l.id != listenerId) {
                newList.add(l)
            }
        }
        this.listeners = newList
        Hilog.info(0, "CjTelegram", "[EngineDataFacade] removeChangeListener id=${listenerId}, prev=${prev} now=${this.listeners.size}")
    }

    /**
     * 触发所有已注册 listener（对应 iOS Signal emit next event）
     * 由 refreshAll() 内部调用；也可外部直接调用（当已知数据可能已变化时）。
     */
    public func notifyListeners(): Unit {
        Hilog.info(0, "CjTelegram", "[EngineDataFacade] notifyListeners: ${this.listeners.size} listeners")
        for (l in this.listeners) {
            try {
                l.callback()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[EngineDataFacade] listener ${l.id} threw: ${e}")
            }
        }
    }

    /**
     * 重新聚合所有数据并通知 listener（对应 iOS Signal next push 的命令式触发版本）
     *
     * 调用时序：
     *   1. 拉取 chatList / contacts / topPeers / readCounters 快照
     *   2. 更新 last* 缓存字段
     *   3. notifyListeners()
     *
     * 上层应在以下场景调用 refreshAll()：
     *   - 登录完成后
     *   - 消息列表刷新后
     *   - 联系人变更后
     *   - 手动触发"刷新"操作后
     */
    public func refreshAll(): Unit {
        Hilog.info(0, "CjTelegram", "[EngineDataFacade] refreshAll begin")
        this.lastChatList = this.service.getChatListItems()
        this.lastReadCounters = this.service.getTotalReadCounters()
        this.lastTopPeers = this.service.getTopPeers()
        let contactsRaw = this.service.getContactsList()
        this.lastContacts = this.buildContactViewModels(contactsRaw)
        this.notifyListeners()
        Hilog.info(0, "CjTelegram", "[EngineDataFacade] refreshAll done: chats=${this.lastChatList.size} contacts=${this.lastContacts.size} topPeers=${this.lastTopPeers.size}")
    }

    // ==================== Gap 2: ChatList items ====================

    /**
     * 获取会话列表快照（EngineData.Item.Messages.ChatList 命令式 get）
     *
     * @param limit 最多返回会话数，默认 20
     * @return ChatListItemData 列表
     */
    public func getChatListSnapshot(limit!: Int32 = 20): ArrayList<ChatListItemData> {
        let items = this.service.getChatListItems(limit: limit)
        Hilog.info(0, "CjTelegram", "[EngineDataFacade] getChatListSnapshot: ${items.size} items")
        return items
    }

    /**
     * 获取上次 refreshAll() 缓存的会话列表（无网络请求）
     */
    public func getLastChatList(): ArrayList<ChatListItemData> {
        return this.lastChatList
    }

    // ==================== Gap 3: Contacts.List / Top ====================

    /**
     * 获取联系人列表快照（EngineData.Item.Contacts.List 命令式 get）
     *
     * @return ContactListItemData 列表
     */
    public func getContactsSnapshot(): ArrayList<ContactListItemData> {
        let raw = this.service.getContactsList()
        return this.buildContactViewModels(raw)
    }

    /**
     * 获取 Top Peers 快照（EngineData.Item.Contacts.TopPeers 命令式近似）
     *
     * 取舍：iOS 为交互频率排序的 TopPeers；Cangjie 取前 N 联系人近似替代。
     * @param topN 最多返回条目数，默认 8
     */
    public func getTopPeersSnapshot(topN!: Int32 = 8): ArrayList<TopPeerData> {
        return this.service.getTopPeers(topN: topN)
    }

    /**
     * 获取上次 refreshAll() 缓存的联系人列表（无网络请求）
     */
    public func getLastContacts(): ArrayList<ContactListItemData> {
        return this.lastContacts
    }

    /**
     * 获取上次 refreshAll() 缓存的 top peers（无网络请求）
     */
    public func getLastTopPeers(): ArrayList<TopPeerData> {
        return this.lastTopPeers
    }

    // ==================== Gap 4: Messages.TotalReadCounters ====================

    /**
     * 获取全局未读计数（EngineData.Item.Messages.TotalReadCounters 命令式 get）
     *
     * @param limit 用于拉取会话列表的 limit，影响覆盖面，默认 100
     * @return TotalReadCountersData
     */
    public func getReadCounters(limit!: Int32 = 100): TotalReadCountersData {
        return this.service.getTotalReadCounters(limit: limit)
    }

    /**
     * 获取上次 refreshAll() 缓存的未读计数（无网络请求）
     */
    public func getLastReadCounters(): TotalReadCountersData {
        return this.lastReadCounters
    }

    // ==================== Gap 5: ItemCache / OrderedLists / Notices ====================

    /**
     * 查询 ItemCache 单条（EngineData.Item.ItemCache.Item 命令式 get）
     * @param key 完整缓存 key
     */
    public func getItemCacheEntry(key: String): ItemCacheQueryResult {
        return this.service.getItemCacheEntry(key)
    }

    /**
     * 查询有序列表条目（EngineData.Item.OrderedLists.ListItems 命令式 get）
     * @param collectionId 集合 ID（0=recentGifs, 1=recentStickers, 2=inlineBots）
     */
    public func getOrderedListItems(collectionId: Int32): OrderedListQueryResult {
        return this.service.getOrderedListItems(collectionId)
    }

    /**
     * 查询 Notice 条目（EngineData.Item.Notices.Notice 命令式 get）
     * @param key notice key（按 iOS NoticeEntryKey 规范构造）
     */
    public func getNoticeEntry(key: String): NoticeQueryResult {
        return this.service.getNoticeEntry(key)
    }

    // ==================== Internal helpers ====================

    private func buildContactViewModels(raw: ArrayList<ContactDisplayData>): ArrayList<ContactListItemData> {
        let result = ArrayList<ContactListItemData>()
        for (c in raw) {
            let vm = ContactListItemData()
            vm.peerId = c.userId
            vm.accessHash = c.accessHash
            vm.firstName = c.firstName
            vm.lastName = c.lastName
            vm.username = c.username
            vm.phone = c.phone
            vm.isOnline = c.isOnline
            result.add(vm)
        }
        return result
    }
}

// ============================================================
// EngineDataFacade 全局单例访问器
// ============================================================

private var _engineDataFacadeInstance: Option<EngineDataFacade> = None

/**
 * 获取 EngineDataFacade 单例（对应 iOS TelegramEngine 内部单例化的 EngineData）
 */
public func getEngineDataFacade(): EngineDataFacade {
    match (_engineDataFacadeInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = EngineDataFacade()
            _engineDataFacadeInstance = Some(inst)
            return inst
    }
}

// ============================================================
// 辅助 ViewModel 类型
// ============================================================

/**
 * EngineDataListener — 内部 listener 封装
 */
public class EngineDataListener {
    public var id: Int64 = 0
    public var callback: () -> Unit = { => }
}

/**
 * ContactListItemData — 联系人列表条目 ViewModel
 *
 * 对应 iOS EngineData.Item.Contacts.List 中每条 EnginePeer 的展示数据。
 */
public class ContactListItemData {
    public var peerId: Int64 = 0
    public var accessHash: Int64 = 0
    public var firstName: String = ""
    public var lastName: String = ""
    public var username: String = ""
    public var phone: String = ""
    public var isOnline: Bool = false

    public func getDisplayName(): String {
        var name = this.firstName
        if (this.lastName.size > 0) {
            name = name + " " + this.lastName
        }
        if (name.size > 0) {
            return name
        }
        if (this.username.size > 0) {
            return "@" + this.username
        }
        return "User ${this.peerId}"
    }
}

