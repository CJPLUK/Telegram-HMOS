package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.*
import std.sync.*
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.models.ChatFolder
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.providers.getSettingsDataProvider
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.interop.{subscribe, callArk}
// 全局引用，用于跨页面更新聊天列表（ChatRoomPage 返回时更新 lastMessage 和 unreadCount）
private var _chatListVMRef: Option<ChatListViewModel> = None

public func registerChatListVM(vm: ChatListViewModel) {
    _chatListVMRef = Some(vm)
    ensureMainTabBackSubscription()
}

// 系统返回键：MainTabPage.ets onBackPressed 同步派发 mainTabPage.backPressed。Chats 处于归档视图时
// 返回主列表（iOS 归档是压栈的 ChatListController，返回即 pop 回根列表），并同步回调
// mainTab.backHandled 告知 ArkTS 已消费；否则不回调，ArkTS 照旧整应用退后台。
let MAIN_TAB_BACK_EVENT: String = "mainTabPage.backPressed"
let MAIN_TAB_BACK_HANDLED: String = "mainTab.backHandled"
var _mainTabBackSubscribed: Bool = false

func ensureMainTabBackSubscription(): Unit {
    if (_mainTabBackSubscribed) { return }
    _mainTabBackSubscribed = true
    subscribe(MAIN_TAB_BACK_EVENT, { _p: String =>
        match (_chatListVMRef) {
            case Some(vm) =>
                if (vm.currentFolderId != 0) {
                    Hilog.info(0, "CjTelegram", "[ArchiveTrace] system back leaves archive")
                    callArk(MAIN_TAB_BACK_HANDLED, "{}")
                    launch { vm.setCurrentFolder(0) }
                }
            case None => ()
        }
    })
}

public func getChatListVM(): Option<ChatListViewModel> {
    return _chatListVMRef
}

/**
 * S1-28：只有这些发布理由携带权威的文件夹列表（对应 ChatListViewModel.dialogFilters 的三个写入口：
 * loadFilters → "dialogFilters"、applyLocalDialogFilters → "dialogFilters:<reason>"、
 * ChatListPage.removeFolder → "folderRemoved"）。其余理由的发布不得改动投影里的 dialogFilters。
 */
func publishReasonCarriesDialogFilters(reason: String): Bool {
    return reason == "dialogFilters" || reason.startsWith("dialogFilters:") || reason == "folderRemoved"
}

/**
 * 聊天列表 ViewModel
 * 
 * Phase 7: 连接 RealChatListService，从 MTProto 获取真实对话列表
 * 
 * 功能:
 * - 管理聊天列表数据（增删改查）
 * - 搜索过滤
 * - 未读角标更新
 * - 通过 RealChatListService 获取真实数据
 */
@Observed
public class ChatListViewModel {
    // 聊天列表（使用 ArrayList 支持动态增删）
    @Publish public var chatList: ArrayList<Chat> = ArrayList<Chat>()
    
    // 归档聊天列表（folder 1）
    @Publish public var archiveChatList: ArrayList<Chat> = ArrayList<Chat>()
    
    // 当前文件夹：0=主列表，1=归档
    @Publish public var currentFolderId: Int32 = 0

    // iOS ChatListController 过滤类型：all / unread / groups / channels
    @Publish public var currentFilterType: String = "all"

    // 搜索关键词
    @Publish public var searchKeyword: String = ""
    
    // 正在输入的用户 ID 集合（用于显示 typing 指示）
    @Publish public var typingUserIds: ArrayList<Int64> = ArrayList<Int64>()
    
    // P5-8: 全局消息搜索结果（messages.searchGlobal — 消息维度）
    @Publish public var globalSearchResults: ArrayList<Chat> = ArrayList<Chat>()
    @Publish public var isSearching: Bool = false
    private var _lastSearchQuery: String = ""
    // S9-23：Messages 段范围（all / users / groups / channels），对位 iOS ChatListSearchMessagesScope
    public var globalSearchScope: String = "all"
    private var _lastSearchScope: String = "all"
    // S9-11：全局搜索 Channels 分类（CHANNELS YOU JOINED + RECOMMENDED CHANNELS）
    @Publish public var channelsPaneJoined: ArrayList<Chat> = ArrayList<Chat>()
    @Publish public var channelsPaneRecommended: ArrayList<Chat> = ArrayList<Chat>()
    @Publish public var isLoadingChannelsPane: Bool = false
    private var _recommendedChannelsCache: ArrayList<Chat> = ArrayList<Chat>()
    private var _recommendedChannelsLoaded: Bool = false

    // P2-102: 全局 peer 搜索结果（contacts.search — peer 维度）
    @Publish public var globalPeerSearchResults: ArrayList<Chat> = ArrayList<Chat>()
    @Publish public var isSearchingPeers: Bool = false
    private var _lastPeerSearchQuery: String = ""

    // iOS ChatListSearchListPaneNode：查询以 # 开头时 Chats 结果额外带一段 PUBLIC POSTS
    // （searchHashtagPosts → channels.searchPosts，SLP:2764-2804）。
    @Publish public var publicPostResults: ArrayList<Chat> = ArrayList<Chat>()
    @Publish public var isSearchingPublicPosts: Bool = false
    private var _lastPublicPostsQuery: String = ""

    // 全局搜索的 Media / Links / Files / Music / Voice 标签（iOS ChatListSearchListPaneNode
    // tagMask → messages.searchGlobal filter，SLP:1807-1818；Holes.swift messageFilterForTagMask）
    @Publish public var filterSearchResults: ArrayList<Chat> = ArrayList<Chat>()
    @Publish public var isSearchingFilter: Bool = false
    private var _lastFilterSearchKey: String = ""
    
    // 是否正在加载
    @Publish public var isLoading: Bool = false
    
    // 当前用户 ID
    @Publish public var currentUserId: Int64 = 1

    // P2-101: 服务端文件夹 tab 列表（messages.getDialogFilters 真拉）
    // 空列表 → 不显示 tab 栏；单个 "All" → 也不显示（iOS 语义：单文件夹无需 tab）
    @Publish public var dialogFilters: ArrayList<ChatFolder> = ArrayList<ChatFolder>()

    // P2-101: 当前激活的文件夹过滤 ID（-1 = All dialogs, 其他 = dialogFilter.id）
    @Publish public var activeFilterId: Int32 = -1

    // P2-108: MTProto 连接状态字符串 "online" / "connecting" / "updating" / "waiting"
    // 从 MTProtoClient.isTransportConnected() + 轮询状态衍生
    @Publish public var connectionStatus: String = "online"

    // P2-108: 是否通过代理连接（用于显示代理 header）
    @Publish public var hasActiveProxy: Bool = false

    // P2-108: 下拉刷新进行中标志
    @Publish public var isRefreshing: Bool = false

    // TC-0028 M3（round 2 已按 diag-clist_archive-retry-termination-design.md 收窄语义）：
    // 待同步 folder 操作的"单次尝试进行中"标记，源侧 op-log（AccountTaskManager 的
    // managedSynchronizeGroupedPeersOperations，每 peer 一条、后写覆盖先写）的内存态复刻。
    // key = chatId，value = 目标 folderId（1=归档 / 0=主列表）。生命周期从乐观写入那一刻到
    // 该次 RPC 返回（成功/失败/异常）那一刻——单次尝试即终态，不再有跨 tick 重试；
    // refreshForConsistencyRecovery 用它在整表覆盖前保护尚未被服务端确认的本地变更（这段过滤逻辑与本次
    // 收窄无关，见 D-157 修法说明，不改动其行为）。
    // 仅内存态：本地 ChatListTable 目前没有 folder/archived 维度（RealChatListService.cj:128、
    // ChatListEntry.cj 文件头均已声明该维度延后接入），故本轮不做持久化——有据的降级，非遗漏。
    // D-157：该字段被 UI 线程（archiveChatWithUndo/onUndo 的乐观写入）与至少三个独立 spawn{}
    // 协程（archiveChatWithUndo 的内联 spawn、onUndo 的内联 spawn、unarchiveChat 的 spawn）
    // 以及 refreshForConsistencyRecovery 轮询协程自身跨线程读写；Cangjie 的 HashMap 非线程安全容器，且这些
    // 写入点无法像 chatList/archiveChatList 那样统一收敛进 launch{}（部分需要在 spawn 内同步
    // 判断 contains 后再 remove），故对所有跨协程访问点改用显式 Mutex 序列化（对齐本文件
    // RadialStatusService.cj/FailedMessageStore.cj 已确立的 ReentrantMutex + synchronized 范式）。
    private var _pendingFolderOps: HashMap<Int64, Int32> = HashMap<Int64, Int32>()
    private let _pendingFolderOpsMutex: ReentrantMutex = ReentrantMutex()
    // 取消归档待定期间的会话快照（同受 _pendingFolderOpsMutex 保护）：主列表被任何回源结果
    // 整体覆盖时，据此把仍处于 pending=0 的会话补回，不依赖覆盖前的 chatList 里还有它。
    private var _pendingUnarchivedChats: HashMap<Int64, Chat> = HashMap<Int64, Chat>()

    private var _refreshSubscriptionToken: Int64 = -1
    private var _typingSubscriptionToken: Int64 = -1
    private let _recoveryRefreshInFlight = AtomicBool(false)
    private let _recoveryRerunRequested = AtomicBool(false)

    // 主列表翻页游标（对齐 iOS ChatListHole：首屏 getDialogs 之后，列表滚到末尾时以
    // 当前已加载区间最底部的非置顶会话 (date, id, peer) 为 offset 继续拉更早会话，
    // 直到服务端返回 messages.dialogs 或空页）。只在 UI 线程读写。
    private var _dialogsHasMore: Bool = false
    private var _dialogsNextOffsetDate: Int32 = 0
    private var _dialogsNextOffsetId: Int32 = 0
    private var _dialogsNextOffsetPeerType: String = ""
    private var _dialogsNextOffsetPeerId: Int64 = 0
    // 首屏重载 / 切账号时递增，丢弃在途的旧翻页结果。
    private var _dialogsPagingGeneration: Int64 = 0
    private let _loadMoreDialogsInFlight = AtomicBool(false)
    // 本 VM 当前绑定的账号 slot（loadRealDialogs 时按活跃账号绑定；-1 = 尚未加载过）。
    // 账号切换后旧页面的 VM 仍然存活并持有上一账号的列表 / 文件夹 / 归档，其订阅回调
    // 与在途加载的回灌若不按 slot 拒绝，会把上一账号的数据发布进账号级投影。
    private var _boundSlot: Int32 = -1

    /** 在途加载启动时的 slot 是否仍是活跃账号；不是则该批结果属于上一账号，整批丢弃。 */
    private func loadStillActive(loadSlot: Int32, stage: String): Bool {
        let activeSlot = getAuthStorage().getActiveSlot()
        if (loadSlot == activeSlot) { return true }
        Hilog.info(0, "CjTelegram",
            "[ChatListVM] ${stage} discarded: loaded for slot=${loadSlot}, active slot=${activeSlot}")
        return false
    }

    /**
     * 页面收到投影快照时调用（UI 线程）。快照可能由后台线程基于稍旧的列表发布（实时消息 /
     * 已读 / 连接状态），整体采纳前补回仍处于取消归档待定期的会话。
     */
    public func adoptProjectedChats(chats: ArrayList<Chat>): Unit {
        this.chatList = this.withPendingUnarchived(chats)
    }

    /** Phase 3：把已提交的 Chats 状态发布到账号级 Projection。调用方必须在 UI 线程更新列表后调用。 */
    public func publishCurrentChatList(reason: String): Unit {
        // 绑定到上一账号的 VM（账号切换后仍存活的旧页面实例）不得再向账号级投影发布：
        // 它的 chatList / dialogFilters / archiveChatList 全是上一账号的数据。
        let activeSlot = getAuthStorage().getActiveSlot()
        if (this._boundSlot >= 0 && this._boundSlot != activeSlot) {
            Hilog.info(0, "CjTelegram",
                "[ChatListVM] publish skipped reason=${reason}: VM bound to slot=${this._boundSlot}, active slot=${activeSlot}")
            return
        }
        // 只有主实例（registerChatListVM 注册者）的 chatList 是权威主列表；搜索实例的 VM
        // 发布时沿用投影当前列表，只借这次发布刷新自己的派生状态，不回写旧列表。
        let isMain = match (_chatListVMRef) {
            case Some(vm) => refEq(vm, this)
            case None => true
        }
        let projection = getChatListProjection()
        let current = projection.currentSnapshot()
        let chatsToPublish = if (isMain) { this.chatList } else { current.chats }
        // S1-28：文件夹列表只随文件夹来源的发布变化（loadFilters / applyLocalDialogFilters /
        // removeFolder），其余发布（initialArchive / typing / 已读 / 置顶……）一律沿用投影里
        // 已加载的 dialogFilters。否则冷启动时 ChatListPage 按 generation 顺序回放早于
        // loadFilters 的快照（updatingBegan/updatingEnded 等，dialogFilters 为空）会把本 VM 已
        // 装好的 dialogFilters 倒回空表，紧随其后的 initialArchive 再把空表发布出去，tab 栏
        // 刚出现就被覆盖掉（hilog：generation=10 dialogFilters filters=3 → generation=11
        // initialArchive filters=0）。对位 iOS ChatListControllerNode：filters 是独立信号
        // （chatListFilters），对话列表 / 归档的任何更新都不会改动它，有文件夹时 tab 栏始终显示。
        let filtersToPublish = if (publishReasonCarriesDialogFilters(reason)) {
            this.dialogFilters
        } else {
            current.dialogFilters
        }
        projection.publish(
            chatsToPublish,
            this.isLoading,
            filtersToPublish,
            this.connectionStatus,
            this.hasActiveProxy,
            reason
        )
    }
    
    /**
     * 获取过滤后的聊天列表
     * 根据搜索关键词、当前文件夹、过滤类型（All/Unread/Groups/Channels）过滤
     * P2-101 r1: 额外按 activeFilterId 对应的 ChatFolder includePeers/excludePeers 过滤
     * iOS ChatListController 关键功能覆盖
     */
    public func getFilteredChats(): ArrayList<Chat> {
        var srcList = if (this.currentFolderId == 1) { this.archiveChatList } else { this.chatList }
        // 过滤类型：all / unread / groups / channels
        if (this.currentFilterType == "unread") {
            let filtered = ArrayList<Chat>()
            for (c in srcList) {
                // M-2g：对位 CombinedPeerReadState.isUnread，计数与 markedUnread 位任一为真
                if (c.unreadCount > 0 || c.isMarkedUnread) { filtered.add(c) }
            }
            srcList = filtered
        } else if (this.currentFilterType == "groups") {
            let filtered = ArrayList<Chat>()
            for (c in srcList) {
                if (c.isGroup || c.isMegagroup) { filtered.add(c) }
            }
            srcList = filtered
        } else if (this.currentFilterType == "channels") {
            let filtered = ArrayList<Chat>()
            for (c in srcList) {
                if (c.isChannel) { filtered.add(c) }
            }
            srcList = filtered
        }
        // P2-101 r1: folder tab filter by activeFilterId
        // -1 = All dialogs (no folder filter); >= 0 = apply include/exclude peer set
        if (this.activeFilterId >= 0) {
            srcList = applyFolderFilter(srcList, this.activeFilterId)
        }
        if (this.searchKeyword.isEmpty()) {
            return srcList
        }
        var result: ArrayList<Chat> = ArrayList<Chat>()
        // 对齐 iOS ChatListSearchListPaneNode 本地段：名称 / 用户名按大小写不敏感匹配
        // （原实现大小写敏感，输入 "durov" 匹配不到 "Pavel Durov"）。
        let needle = this.searchKeyword.toAsciiLower()
        for (chat in srcList) {
            if (chat.name.toAsciiLower().contains(needle) ||
                chat.username.toAsciiLower().contains(needle) ||
                chat.lastMessage.toAsciiLower().contains(needle)) {
                result.add(chat)
            }
        }
        return result
    }

    /**
     * P2-101 r1: 按 filterId 对应的 ChatFolder 做 include/exclude peer 过滤
     * includePeers 非空 → 白名单（只保留 chat.id 在 includePeers 中的）
     * excludePeers 非空 → 黑名单（过滤掉 chat.id 在 excludePeers 中的）
     * 两者均为空（服务端未下发） → 不过滤，返回原列表
     */
    private func applyFolderFilter(src: ArrayList<Chat>, filterId: Int32): ArrayList<Chat> {
        var targetFolder: Option<ChatFolder> = None
        for (f in this.dialogFilters) {
            if (f.id == filterId) {
                targetFolder = Some(f)
                break
            }
        }
        let folder = match (targetFolder) {
            case Some(f) => f
            case None => return src
        }
        let hasInclude = folder.includePeers.size > 0
        let hasExclude = folder.excludePeers.size > 0
        if (!hasInclude && !hasExclude) { return src }
        let result = ArrayList<Chat>()
        for (chat in src) {
            if (hasInclude) {
                var inInclude = false
                for (pid in folder.includePeers) {
                    if (pid == chat.id) { inInclude = true; break }
                }
                if (!inInclude) { continue }
            }
            if (hasExclude) {
                var inExclude = false
                for (pid in folder.excludePeers) {
                    if (pid == chat.id) { inExclude = true; break }
                }
                if (inExclude) { continue }
            }
            result.add(chat)
        }
        return result
    }

    /**
     * 设置过滤类型（iOS ChatListController 过滤标签）
     * DEFERRED: 拖拽排序需平台 LazyVStack 等能力
     */
    public func setFilterType(filterType: String): Unit {
        this.currentFilterType = filterType
        this.publishCurrentChatList("filterType")
    }

    /**
     * 设置当前文件夹并加载对应列表
     */
    public func setCurrentFolder(folderId: Int32) {
        this.currentFolderId = folderId
        // iOS 打开归档是 groupId=.group(1) 的独立 ChatListController，直接读 Postbox 的
        // folder 1 视图并随 hole 回源补齐。这里先用本地已知的归档列表出首帧，同时每次进入
        // 都回源刷新一次（messages.getDialogs folder_id=1），不再只在本地为空时才拉。
        this.publishCurrentChatList("folderChanged")
        if (folderId == 1) {
            this.loadArchivedDialogs()
        }
    }

    // 归档列表回源进行中（仅 UI 线程读写）。与主列表的 isLoading 分开：归档加载不能把
    // 主列表 / 投影快照的 isLoading 置真，否则一次并发发布就会让骨架屏状态回写卡住。
    public var archiveLoadInFlight: Bool = false

    /**
     * P2-101: 从服务器加载文件夹 tab 列表（messages.getDialogFilters）
     * RPC 在 spawn{} 内执行，状态回写走 launch{}（S-001 合规）
     * 加载完成后若有多个文件夹则更新 dialogFilters，否则保持空（隐藏 tab 栏）
     */
    public func loadFilters(): Unit {
        let loadSlot = getAuthStorage().getActiveSlot()
        spawn {
            try {
                let svc = getChatListFilterSettingsHeaderService()
                let filters = svc.fetchFiltersFromServer()
                Hilog.info(0, "CjTelegram", "[ChatListVM] loadFilters: ${filters.size} server folders")
                launch {
                    if (!this.loadStillActive(loadSlot, "dialogFilters")) { return }
                    // iOS 语义：仅当有多个文件夹（不止 All）时才显示 tab 栏
                    if (filters.size > 1) {
                        this.dialogFilters = filters
                    } else {
                        this.dialogFilters = ArrayList<ChatFolder>()
                    }
                    this.publishCurrentChatList("dialogFilters")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] loadFilters failed: ${e}")
            }
        }
    }

    /**
     * S7-64：Reset All Notifications 成功后，本地所有会话（主列表 + 归档）的静音状态一并清掉
     * （服务端 account.resetNotifySettings 已把 per-peer 设置清空；iOS Postbox 随 updates 回写，
     * 这里直接同步内存与本地会话表，不等下一次 getDialogs）。
     */
    public func clearAllChatMutes(): Unit {
        var cleared: Int64 = 0
        let mainList = ArrayList<Chat>()
        for (c in this.chatList) {
            if (c.isMuted) { c.isMuted = false; cleared += 1 }
            mainList.add(c)
        }
        let archiveList = ArrayList<Chat>()
        for (c in this.archiveChatList) {
            if (c.isMuted) { c.isMuted = false; cleared += 1 }
            archiveList.add(c)
        }
        this.chatList = mainList
        this.archiveChatList = archiveList
        getChatListStore().storeChats(mainList)
        Hilog.info(0, "CjTelegram", "[ChatListVM] clearAllChatMutes cleared=${cleared}")
        this.publishCurrentChatList("resetNotifySettings")
    }

    /**
     * S1-32 / S1-37 / S7-126 / S7-127：文件夹被本地改动（排序 / 删除 / 新增 / 移出会话）后
     * 立即把新列表灌进 tab 栏与 RealChatListService 缓存，不等服务端回拉（对位 iOS
     * updateChatListFiltersInteractively 本地先生效）。列表含 All Chats（id 0）时按服务端
     * 形态原样保留；只剩 All Chats 时清空（隐藏 tab 栏）。当前激活的文件夹若已不存在则回到 All。
     */
    public func applyLocalDialogFilters(filters: ArrayList<ChatFolder>, reason: String): Unit {
        let cacheList = ArrayList<ChatFolder>()
        var customCount: Int64 = 0
        for (f in filters) {
            cacheList.add(f)
            if (f.id != 0) { customCount += 1 }
        }
        getRealChatListService().replaceDialogFiltersCache(cacheList)
        if (customCount > 0) {
            this.dialogFilters = cacheList
        } else {
            this.dialogFilters = ArrayList<ChatFolder>()
        }
        if (this.activeFilterId >= 0) {
            var stillExists = false
            for (f in this.dialogFilters) {
                if (f.id == this.activeFilterId) { stillExists = true }
            }
            if (!stillExists) { this.activeFilterId = -1 }
        }
        Hilog.info(0, "CjTelegram", "[ChatListVM] applyLocalDialogFilters reason=${reason} folders=${cacheList.size} custom=${customCount}")
        this.publishCurrentChatList("dialogFilters:" + reason)
    }

    /**
     * P2-101: 切换到指定文件夹 tab
     * filterId = -1 → All dialogs（无过滤）
     * filterId >= 0 → 对应 dialogFilter.id 的过滤器
     */
    public func setActiveFilter(filterId: Int32): Unit {
        this.activeFilterId = filterId
        this.publishCurrentChatList("activeFilter")
    }

    /** 指定文件夹当前命中的会话（与 tab 过滤同一规则），供文件夹长按菜单的 Read All / Mute All 使用。 */
    public func chatsInFilter(filterId: Int32): ArrayList<Chat> {
        return applyFolderFilter(this.chatList, filterId)
    }

    /**
     * P2-101 r1: 计算指定 filterId 对应的未读计数（badge）
     * filterId = -1 → 全部对话未静音未读数之和
     * filterId >= 0 → 按 ChatFolder includePeers/excludePeers 过滤后的未读数之和
     */
    public func getUnreadCountForFilter(filterId: Int32): Int64 {
        if (filterId == -1) {
            var count: Int64 = 0
            for (c in this.chatList) {
                if (c.unreadCount > 0 && !c.isMuted) {
                    count += c.unreadCount
                }
            }
            return count
        }
        let filtered = applyFolderFilter(this.chatList, filterId)
        var count: Int64 = 0
        for (c in filtered) {
            if (c.unreadCount > 0 && !c.isMuted) {
                count += c.unreadCount
            }
        }
        return count
    }

    /** 本实例是否仍是 registerChatListVM 注册的主列表 VM（未注册时视为主实例，单实例回归安全）。 */
    private func isRegisteredMainVM(): Bool {
        return match (_chatListVMRef) {
            case Some(vm) => refEq(vm, this)
            case None => true
        }
    }

    /**
     * 订阅账号级 UpdatesManager 的 typed 事件（一致性刷新 / typing）。幂等。
     *
     * 账号切换会 routerReplace 重建 MainTabPage → 新 ChatListPage 新建 VM 并 registerChatListVM；
     * 旧 VM 没有销毁钩子（onDisAppear 只表示不可见），其订阅闭包会一直留在 UpdatesManager 单例里，
     * 每来一条事件就把旧实例的 isLoading / dialogFilters（上一账号的文件夹）经
     * publishCurrentChatList 回灌进账号级投影。闭包因此在触发时自检：不再是主 VM 就自行退订，
     * 对位 iOS 切账号后旧 AccountContext 连同其订阅整体释放。
     */
    public func ensureAccountSubscriptions(): Unit {
        let updMgr = getUpdatesManager()
        if (this._refreshSubscriptionToken < 0) {
            this._refreshSubscriptionToken = updMgr.addChatListRefreshSubscriber({ =>
                if (!this.isRegisteredMainVM()) {
                    this.releaseAccountSubscriptions()
                    return
                }
                this.refreshForConsistencyRecovery()
            })
        }

        if (this._typingSubscriptionToken < 0) {
            this._typingSubscriptionToken = updMgr.addTypingSubscriber({ userId: Int64 =>
                if (!this.isRegisteredMainVM()) {
                    this.releaseAccountSubscriptions()
                    return
                }
                launch {
                    this.addTypingUserId(userId)
                    this.publishCurrentChatList("typing")
                }
                this.clearTypingAfterDelay(userId)
            })
        }
    }

    /** 退订 ensureAccountSubscriptions 建立的账号级订阅；UpdatesManager 按快照分发，回调内自退安全。 */
    public func releaseAccountSubscriptions(): Unit {
        let updMgr = getUpdatesManager()
        if (this._refreshSubscriptionToken >= 0) {
            updMgr.removeChatListRefreshSubscriber(this._refreshSubscriptionToken)
            this._refreshSubscriptionToken = -1
        }
        if (this._typingSubscriptionToken >= 0) {
            updMgr.removeTypingSubscriber(this._typingSubscriptionToken)
            this._typingSubscriptionToken = -1
        }
        Hilog.info(0, "CjTelegram", "[ChatListVM] released stale account subscriptions (no longer main VM)")
    }

    /**
     * P2-108: 更新连接状态，从 MTProtoClient.isTransportConnected() 读取真实状态
     * 连接态：online = 已连接；connecting = 正在连接；waiting = 等待网络
     * 由连接事件与显式生命周期入口调用，不依赖列表轮询。
     *
     * 这里只探测 transport 连通性。"updating" 不是 transport 状态：它由 ChatListProjection
     * 按 getDifference / getState 在途计数派生（对位 iOS Account.networkState =
     * network.connectionStatus × stateManager.isUpdating）。旧实现把首屏 isLoading 折算成
     * "updating" 写进 connectionStatus，而 isLoading 变回 false 时没有任何路径重算——
     * 账号切换后新 client 在页面重建前就已连上、不会再来一次 Connected 事件，
     * 标题因此永远停在 "Updating..."。
     */
    public func updateConnectionStatus(): Unit {
        try {
            let client = getMTProtoClient()
            let connected = client.isTransportConnected()
            let proxyStore = getProxyStateStore()
            let proxyOpt = proxyStore.getCurrentProxy()
            let hasProxy = match (proxyOpt) {
                case Some(_) => true
                case None => false
            }
            let newStatus = if (connected) { "online" } else { "connecting" }
            launch {
                this.connectionStatus = newStatus
                this.hasActiveProxy = hasProxy
                this.publishCurrentChatList("connectionStatus")
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ChatListVM] updateConnectionStatus failed: ${e}")
        }
    }

    /**
     * P2-108: 下拉刷新触发（Refresh 组件 onRefreshing 回调）
     * 真实 reload dialogs + 更新连接状态，完成后清除刷新状态
     * RPC 在 spawn{} 内执行，launch{} 回写 @Publish 字段（S-001 合规）
     *
     * onDone: 刷新链路真正完成（成功或失败）时的一次性同步通知回调，供调用方
     * （ChatListPage）在同一时刻把 Refresh 组件的 refreshing 状态置回
     * false，而不是依赖后台轮询同步循环（修复 TC-0011：轮询周期与快速 RPC
     * 完成时刻竞态，导致 spinner 长期悬挂不收起）。
     *
     * TC-0011 rework round 3（干净解法，前两轮均被打回）：
     * - round 1：重入 guard 命中时直接 return、不调用 onDone → 若上一次 RPC
     *   尚未完成、用户二次下拉再次触发 onRefreshing，Page 层 isRefreshing
     *   永久卡 true（卡死）。
     * - round 2：guard 命中改为立即同步调用 onDone → 相反缺陷：第一次 RPC
     *   仍在途时，第二次调用命中 guard 会把 Page.isRefreshing 提前置
     *   false，产生"尚未真正刷新完成却已收起 spinner"的过早消失假象。
     * - round 3（本次）：重入的第二次调用被彻底忽略——不触发 onDone、不做
     *   任何状态改动，单纯 return。唯一真相来源是第一次（也是唯一真正发起
     *   RPC 的那次）调用完成时执行的 onDone()。这样重入的调用既不会导致卡
     *   死（第一次调用仍会正常收尾），也不会导致过早消失（第二次调用不产
     *   生任何提前完成的信号）。真正的兜底交给 ChatListPage.cj 的
     *   .onStateChange（处理 onDone 万一没有触发的极端场景，作为安全网）。
     */
    public func refreshWithPullDown(onDone!: () -> Unit = { => }): Unit {
        if (this.isRefreshing) {
            // 重入：已有一次刷新在途，忽略本次调用，不触发 onDone、不改变
            // 任何状态。让在途的那次调用的 onDone() 作为唯一真相来源。
            return
        }
        launch { this.isRefreshing = true }
        spawn {
            try {
                let chatListService = getRealChatListService()
                let dialogsResult = chatListService.getDialogsResult()
                let dialogs = dialogsResult.chats
                Hilog.info(0, "CjTelegram", "[ChatListVM] pull-down refresh: ${dialogs.size} dialogs")
                if (!dialogs.isEmpty()) {
                    launch {
                        this.chatList = this.withPendingUnarchived(this.mergeFirstPageKeepingLoadedTail(dialogsResult))
                        this.publishCurrentChatList("pullDownRefresh")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] refreshWithPullDown failed: ${e}")
            }
            launch {
                this.isRefreshing = false
                onDone()
            }
        }
    }

    /**
     * 主列表滚到末尾时加载更早的会话（对齐 iOS ChatListNode 可见区接近末尾 → 填补
     * ChatListHole → FetchChatList(upperBound = hole.index)）。
     * offset 取自上一页非置顶会话的最小 top message 索引；服务端返回 messages.dialogs
     * 或本页没有非置顶会话时停止。只处理主列表（folderId 0），归档/搜索态不翻页。
     */
    public func loadMoreDialogs(): Unit {
        if (this.currentFolderId != 0 || !this._dialogsHasMore) { return }
        if (!this._loadMoreDialogsInFlight.compareAndSwap(false, true)) { return }
        let generation = this._dialogsPagingGeneration
        let offsetDate = this._dialogsNextOffsetDate
        let offsetId = this._dialogsNextOffsetId
        let offsetPeerType = this._dialogsNextOffsetPeerType
        let offsetPeerId = this._dialogsNextOffsetPeerId
        let loadSlot = getAuthStorage().getActiveSlot()
        Hilog.info(0, "CjTelegram",
            "[ChatListVM] loadMoreDialogs offsetDate=${offsetDate} offsetId=${offsetId} offsetPeer=${offsetPeerType}/${offsetPeerId} loaded=${this.chatList.size}")
        spawn {
            try {
                let page = getRealChatListService().getDialogsResult(limit: 20, offsetDate: offsetDate, folderId: 0,
                    offsetId: offsetId, offsetPeerType: offsetPeerType, offsetPeerId: offsetPeerId)
                launch {
                    var continueLoading = false
                    if (generation == this._dialogsPagingGeneration && page.success &&
                        this.loadStillActive(loadSlot, "loadMoreDialogs")) {
                        let merged = ArrayList<Chat>()
                        for (c in this.chatList) { merged.add(c) }
                        var appended = 0
                        for (c in page.chats) {
                            if (!containsDialogPeer(merged, c)) {
                                merged.add(c)
                                appended += 1
                            }
                        }
                        this.applyDialogsCursor(page)
                        // 游标没有前进（服务端重复返回同一段）视为到底，防止空转。
                        if (page.nextOffsetDate == offsetDate && page.nextOffsetId == offsetId &&
                            page.nextOffsetPeerId == offsetPeerId) {
                            this._dialogsHasMore = false
                        }
                        Hilog.info(0, "CjTelegram",
                            "[ChatListVM] loadMoreDialogs got ${page.chats.size}, appended ${appended}, hasMore=${this._dialogsHasMore}")
                        if (appended > 0) {
                            this.chatList = merged
                            this.publishCurrentChatList("loadMoreDialogs")
                            triggerFullPhotoDownloads(page.chats)
                        } else {
                            // 整页都被过滤（已退出/本地删除）或重复：列表不变，onReachEnd 不会再触发，
                            // 直接续拉下一页。
                            continueLoading = this._dialogsHasMore
                        }
                    }
                    this._loadMoreDialogsInFlight.store(false)
                    if (continueLoading) { this.loadMoreDialogs() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] loadMoreDialogs failed: ${e}")
                launch { this._loadMoreDialogsInFlight.store(false) }
            }
        }
    }

    private func applyDialogsCursor(result: DialogsFetchResult): Unit {
        this._dialogsHasMore = result.hasMore
        this._dialogsNextOffsetDate = result.nextOffsetDate
        this._dialogsNextOffsetId = result.nextOffsetId
        this._dialogsNextOffsetPeerType = result.nextOffsetPeerType
        this._dialogsNextOffsetPeerId = result.nextOffsetPeerId
    }

    /** 切账号 / 清空列表时丢弃翻页状态。 */
    public func resetDialogsPaging(): Unit {
        this._dialogsPagingGeneration += 1
        this._dialogsHasMore = false
        this._dialogsNextOffsetDate = 0
        this._dialogsNextOffsetId = 0
        this._dialogsNextOffsetPeerType = ""
        this._dialogsNextOffsetPeerId = 0
    }

    /**
     * 首页快照 + 已翻页加载的更早会话。首页刷新（下拉 / 一致性恢复）只覆盖首页区间，
     * 对齐 iOS：Postbox 里已填补的 hole 之外的会话不会因重新拉首页而消失。
     * 保留条件：不在新首页、非置顶、且 top message 不晚于新首页的下一页游标（即确实位于
     * 首页之后的区间）；新首页已是全量（messages.dialogs）时不保留。
     */
    private func firstPageWithLoadedTail(firstPage: DialogsFetchResult, previous: ArrayList<Chat>): ArrayList<Chat> {
        let result = ArrayList<Chat>()
        for (c in firstPage.chats) { result.add(c) }
        if (!firstPage.hasMore) { return result }
        let boundary = Int64(firstPage.nextOffsetDate)
        for (c in previous) {
            if (c.isPinned || c.lastMessageTimestamp > boundary) { continue }
            if (!containsDialogPeer(result, c)) { result.add(c) }
        }
        return result
    }

    /** UI 线程：首页刷新后合并尾部并更新游标。 */
    private func mergeFirstPageKeepingLoadedTail(firstPage: DialogsFetchResult): ArrayList<Chat> {
        let merged = this.firstPageWithLoadedTail(firstPage, this.chatList)
        this.refreshDialogsCursorAfterFirstPage(firstPage, merged)
        return merged
    }

    /**
     * 首页刷新后：若尾部保留了已翻页的会话，游标维持在已加载区间末尾（旧游标）；
     * 否则以新首页游标为准。
     */
    private func refreshDialogsCursorAfterFirstPage(firstPage: DialogsFetchResult, merged: ArrayList<Chat>): Unit {
        if (!firstPage.success) { return }
        if (!firstPage.hasMore || merged.size <= firstPage.chats.size) {
            this._dialogsPagingGeneration += 1
            this.applyDialogsCursor(firstPage)
        }
    }

    /**
     * 加载归档对话列表
     *
     * 调用方既有 UI 事件线程（setCurrentFolder(1) 的入口行 onClick）也有 T-2 修复后
     * 新增的 loadRealDialogs() 冷启动 spawn{} 协程——后者属非 UI 线程，`isLoading` 写入
     * 必须走 launch{}（S-001），因此这里统一用 launch{} 包裹，不再假设调用方总在主线程。
     */
    public func loadArchivedDialogs() {
        let loadSlot = getAuthStorage().getActiveSlot()
        launch {
            this.archiveLoadInFlight = true
            this.publishCurrentChatList("archiveLoading")
        }
        spawn {
            try {
                let svc = getRealChatListService()
                Hilog.info(0, "CjTelegram", "[ArchiveTrace] vm load start")
                let result = svc.getDialogsResult(limit: 100, offsetDate: 0, folderId: 1)
                Hilog.info(0, "CjTelegram",
                    "[ArchiveTrace] vm load result success=${result.success} count=${result.chats.size}")
                launch {
                    if (!this.loadStillActive(loadSlot, "archiveLoaded")) {
                        this.archiveLoadInFlight = false
                        return
                    }
                    // 先落加载态，合并出错也不能把归档页卡在骨架屏上。
                    this.archiveLoadInFlight = false
                    if (result.success) {
                        try {
                            this.archiveChatList = this.mergeArchiveWithPendingOps(result.chats)
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[ArchiveTrace] vm merge failed: ${e}")
                            this.archiveChatList = result.chats
                        }
                    }
                    Hilog.info(0, "CjTelegram",
                        "[ArchiveTrace] vm applied archive=${this.archiveChatList.size} folder=${this.currentFolderId}")
                    this.publishCurrentChatList("archiveLoaded")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] loadArchivedDialogs failed: ${e}")
                launch {
                    this.archiveLoadInFlight = false
                    this.publishCurrentChatList("archiveLoadFailed")
                }
            }
        }
    }

    /**
     * 服务端 folder 1 快照与本地未确认的 folder 操作合并（对位 refreshForConsistencyRecovery
     * 对主列表做的同一过滤）：本地已归档、editPeerFolders 尚未被服务端反映的会话保留；
     * 本地已取消归档、服务端仍在 folder 1 的会话剔除。避免"刚归档 → 立刻回源拿到空归档"
     * 把乐观移入的会话冲掉。
     */
    private func mergeArchiveWithPendingOps(server: ArrayList<Chat>): ArrayList<Chat> {
        let merged = ArrayList<Chat>()
        synchronized (this._pendingFolderOpsMutex) {
            for (c in server) {
                match (this._pendingFolderOps.get(c.id)) {
                    case Some(v) => if (v != Int32(0)) { merged.add(c) }
                    case None => merged.add(c)
                }
            }
            for (c in this.archiveChatList) {
                match (this._pendingFolderOps.get(c.id)) {
                    case Some(v) =>
                        if (v == Int32(1) && !containsDialogPeer(merged, c)) { merged.add(c) }
                    case None => ()
                }
            }
        }
        return sortChatList(merged)
    }

    /**
     * 主列表整体覆盖前调用（UI 线程）：本地已取消归档、服务端快照尚未反映的会话补回主列表。
     * 对位 iOS：本地 Postbox groupId 已改回 root，任何网络快照都不会把它从根列表拿掉。
     */
    private func withPendingUnarchived(list: ArrayList<Chat>): ArrayList<Chat> {
        var added = false
        let result = ArrayList<Chat>()
        for (c in list) { result.add(c) }
        synchronized (this._pendingFolderOpsMutex) {
            let stale = ArrayList<Int64>()
            for ((cid, chat) in this._pendingUnarchivedChats) {
                match (this._pendingFolderOps.get(cid)) {
                    case Some(v) =>
                        if (v == Int32(0)) {
                            if (!containsDialogPeer(result, chat)) {
                                result.add(chat)
                                added = true
                                Hilog.info(0, "CjTelegram", "[ArchiveTrace] re-added pending unarchived chatId=${cid}")
                            }
                        } else {
                            stale.add(cid)
                        }
                    case None => stale.add(cid)
                }
            }
            for (cid in stale) {
                if (this._pendingUnarchivedChats.contains(cid)) {
                    let _ = this._pendingUnarchivedChats.remove(cid)
                }
            }
        }
        if (added) { return sortChatList(result) }
        return result
    }

    /**
     * 是否正在输入（用于聊天列表显示 typing 指示）
     */
    public func isTyping(peerId: Int64): Bool {
        for (uid in this.typingUserIds) {
            if (uid == peerId) { return true }
        }
        return false
    }

    private func addTypingUserId(userId: Int64): Unit {
        for (uid in this.typingUserIds) {
            if (uid == userId) { return }
        }
        this.typingUserIds.add(userId)
    }

    private func clearTypingAfterDelay(userId: Int64): Unit {
        let uid = userId
        spawn {
            sleep(Duration.second * 6)
            launch {
                let newList = ArrayList<Int64>()
                for (id in this.typingUserIds) {
                    if (id != uid) { newList.add(id) }
                }
                this.typingUserIds = newList
                this.publishCurrentChatList("typingExpired")
            }
        }
    }

    /**
     * 归档对话
     */
    public func archiveChat(chatId: Int64) {
        var peerType = "user"
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                peerType = chat.peerType
                break
            }
        }
        let pt = peerType
        let cid = chatId
        spawn {
            try {
                let svc = getRealChatListService()
                if (svc.archiveChat(pt, cid)) {
                    let newMain = ArrayList<Chat>()
                    var archivedChat: Option<Chat> = None
                    for (c in this.chatList) {
                        if (c.id != cid) {
                            newMain.add(c)
                        } else {
                            archivedChat = Some(c)
                        }
                    }
                    let acOpt = archivedChat
                    // 3c 返修：同形态原地 add() 一并改为整体重新赋值（修法 A 波及处）。
                    let newArchive = ArrayList<Chat>()
                    for (c in this.archiveChatList) {
                        newArchive.add(c)
                    }
                    match (acOpt) {
                        case Some(ac) => newArchive.add(ac)
                        case None => ()
                    }
                    launch {
                        this.chatList = newMain
                        this.archiveChatList = newArchive
                        this.publishCurrentChatList("archive")
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] archiveChat failed: ${e}")
            }
        }
    }

    /**
     * 取消归档对话
     */
    public func unarchiveChat(chatId: Int64) {
        // 对位 archiveChatWithUndo（TC-0028 M1/M2）：本地移出归档 / 移入主列表是同一个乐观
        // 事务（源侧 updatePeersGroupIdInteractively 先改本地 Postbox，再异步同步
        // folders.editPeerFolders），UI 不等网络；RPC 失败不回滚、不重试。
        var peerType = "user"
        var moved: Option<Chat> = None
        let newArchive = ArrayList<Chat>()
        for (c in this.archiveChatList) {
            if (c.id == chatId) {
                peerType = c.peerType
                moved = Some(c)
            } else {
                newArchive.add(c)
            }
        }
        let pt = peerType
        let cid = chatId
        synchronized (this._pendingFolderOpsMutex) {
            this._pendingFolderOps[cid] = Int32(0)
            match (moved) {
                case Some(uc) => this._pendingUnarchivedChats[cid] = uc
                case None => ()
            }
        }
        this.archiveChatList = newArchive
        match (moved) {
            case Some(uc) =>
                if (!containsDialogPeer(this.chatList, uc)) {
                    let newMain = ArrayList<Chat>()
                    for (c in this.chatList) { newMain.add(c) }
                    newMain.add(uc)
                    this.chatList = sortChatList(newMain)
                }
            case None => ()
        }
        this.publishCurrentChatList("unarchive")
        Hilog.info(0, "CjTelegram",
            "[ArchiveTrace] unarchive optimistic chatId=${cid} found=${moved.isSome()} main=${this.chatList.size} archive=${this.archiveChatList.size}")
        spawn {
            var ok = false
            try {
                ok = getRealChatListService().unarchiveChat(pt, cid)
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] unarchiveChat failed: ${e}")
            }
            Hilog.info(0, "CjTelegram", "[ChatListVM] unarchiveChat chatId=${cid} ok=${ok}")
            if (ok) {
                // 本地 folder 状态是权威（iOS 本地 Postbox groupId 已改，不被服务端快照覆盖）：
                // 待定项保留到一致性刷新看到服务端 folder 0 已含该会话才出队（refreshForConsistencyRecovery
                // 的 settledKeys），期间任何旧快照都不能把它从主列表冲掉。随即回源确认一次。
                this.refreshForConsistencyRecovery()
            } else {
                synchronized (this._pendingFolderOpsMutex) {
                    if (this._pendingFolderOps.contains(cid)) {
                        let _ = this._pendingFolderOps.remove(cid)
                    }
                }
            }
        }
    }
    
    private var _photoCallbackRegistered: Bool = false

    private func registerPhotoCallback(): Unit {
        if (this._photoCallbackRegistered) { return }
        this._photoCallbackRegistered = true
        getUserPhotoService().addPhotoReadyCallback({ userId: Int64, dataUrl: String =>
            var found = false
            let newList = ArrayList<Chat>()
            for (c in this.chatList) {
                if (c.id == userId) {
                    c.avatarLocalPath = dataUrl
                    found = true
                }
                newList.add(c)
            }
            if (found) {
                launch {
                    this.chatList = newList
                    this.publishCurrentChatList("avatarReady")
                }
                Hilog.info(0, "CjTelegram", "[ChatListVM] Avatar updated for userId=${userId}")
            }
        })
    }

    /**
     * 从 MTProto 加载真实对话列表
     */
    public func loadRealDialogs() {
        // 本次加载归属的账号：整条链路（本地缓存 / 首页 / 归档 / 文件夹 / 失败兜底）的每次
        // 回灌都先核对活跃账号仍是它，账号切换后迟到的结果整批丢弃。
        let loadSlot = getAuthStorage().getActiveSlot()
        this._boundSlot = loadSlot
        // AppStartup already bootstraps ChatListProjection from Postbox.  Retain that
        // snapshot as the first frame instead of publishing an empty loading snapshot
        // and replacing six cached rows with skeletons for one frame.
        let projected = getChatListProjection().currentSnapshot()
        if (!projected.chats.isEmpty()) {
            this.chatList = projected.chats
            this.isLoading = false
            Hilog.info(0, "CjTelegram",
                "[ChatListVM] Retaining ${projected.chats.size} projected chats for cold-start first frame")
        } else {
            this.isLoading = true
            this.publishCurrentChatList("initialLoading")
        }
        this.registerPhotoCallback()
        
        spawn {
            try {
                Hilog.info(0, "CjTelegram", "[ChatListVM] Loading real dialogs...")
                let chatListService = getRealChatListService()

                // ── 先用本地缓存点亮首屏，绝不等网络 ──
                // 对齐 iOS：ChatListView 直接观察 Postbox，DB 里有什么立刻渲染什么；
                // getDifference 由 AccountStateManager 独立跑、结果写回 Postbox 再反向
                // 通知视图。UI 从不阻塞在网络同步上（单一数据源模型）。
                //
                // 此前本函数是「先同步、再查询、最后渲染」的串行链路：下面的
                // fetchDifference / fetchAndStoreSyncState 都是阻塞式 RPC，断网时各自
                // 要等满 REQUEST_TIMEOUT(60s)，首屏因此空白 60s 以上，本地缓存形同虚设。
                //
                // isLoading 只表示首屏是否仍在等待可展示的数据。命中缓存后首屏已经完成，
                // getDifference 属于后台增量同步，不能继续占用页面加载态；否则顶部状态会把
                // 整段阻塞式同步（最坏可达 REQUEST_TIMEOUT）都显示成 "Updating..."。
                // 断网状态仍由 isTransportConnected() 独立映射为 "connecting"，不会误报 online。
                //
                // 配套前提：ChatListPage.buildListContent 的分支链必须保持三段
                //   isPageLoading && displayList 为空 → 骨架屏
                //   displayList 为空                  → 空状态
                //   else                              → 列表（有数据就渲染，与加载态无关）
                // 该文件原先在 1、2 之间还有一个「加载中 → 居中转圈」分支，会整个替换内容区，
                // 使本函数写入的缓存数据无法显示；已在同分支的 UI 修复中删除，切勿复原。
                let cachedChats = getChatListStore().loadLocalChats(20)
                if (!cachedChats.isEmpty()) {
                    Hilog.info(0, "CjTelegram",
                        "[ChatListVM] Rendering ${cachedChats.size} cached chats before network sync")
                    launch {
                        if (!this.loadStillActive(loadSlot, "localCache")) { return }
                        this.chatList = cachedChats
                        this.isLoading = false
                        this.publishCurrentChatList("localCache")
                    }
                }

                // ── 各类处理器注册：全部前置于网络调用 ──
                // 对齐 iOS：Account.swift:1273 在 init 中同步构造 AccountStateManager、
                // :1277 构造 AccountViewTracker —— 这些订阅/管理器的建立不依赖任何网络往返。
                //
                // 原实现把整段注册排在下面的 fetchDifference / getDialogs 之后，断网冷启动时
                // 每个阻塞 RPC 各等满 REQUEST_TIMEOUT(60s)，导致轮询、更新分发、历史监听等
                // 约 3 分钟后才生效 —— 期间即使网络恢复也无人驱动刷新。
                //
                // 以下调用均不触网，可安全前置：
                //   updMgr.initialize()        仅从 AuthStorage 读取 pts/qts/date/seq
                //   updateConnectionStatus()   仅读 client.isTransportConnected() 与本地代理配置
                //   其余为纯回调注册
                let updMgr = getUpdatesManager()
                updMgr.initialize()
                this.ensureAccountSubscriptions()

                // P2-108: 初始化连接状态和代理状态
                this.updateConnectionStatus()

                // ic_messages_update_chat_list: register history listener so message mutations refresh chat list
                getRealMessageService().setHistoryListener({ _peerId: Int64 =>
                    launch {
                        this.publishCurrentChatList("historyMutation")
                    }
                })

                // ic_settings_presentation_to_chat_list: register presentation listener so theme/locale changes re-render
                getSettingsDataProvider().setPresentationListener({ =>
                    launch {
                        this.publishCurrentChatList("presentation")
                    }
                })

                // ── 首屏网络段 ──
                // 主列表是无缓存时唯一会阻塞可见内容的请求，必须先发。旧实现先等
                // getDifference，再依次等主列表、归档、filters；即使 Postbox 已有 6 条，
                // getDialogsLocalFirst 因少于 limit=20 仍回源，整条链路约 1.26s。
                // 这里直接刷新主列表；缓存已在上方即时呈现，不再参与网络回源判定。
                let dialogsResult = chatListService.getDialogsResult(limit: 20, offsetDate: 0, folderId: 0)
                let dialogs = dialogsResult.chats

                launch {
                    if (!this.loadStillActive(loadSlot, "initialDialogs")) { return }
                    // 成功的空响应也是权威快照，必须清掉本地最后一条旧会话；
                    // 请求失败时才保留已经展示的离线缓存。
                    if (dialogsResult.success || this.chatList.isEmpty()) {
                        this.chatList = this.withPendingUnarchived(dialogs)
                    }
                    if (dialogsResult.success) {
                        this._dialogsPagingGeneration += 1
                        this.applyDialogsCursor(dialogsResult)
                    }
                    this.isLoading = false
                    this.publishCurrentChatList("initialDialogs")
                }

                // 主列表完成后，difference / 归档 / filters 都是非首屏数据，分别后台
                // 执行，互不串行阻塞。MTProto pendingRPCs 支持并发 in-flight。
                let backgroundService = chatListService
                spawn {
                    try {
                        let storage = getAuthStorage()
                        if (storage.hasSyncState()) {
                            let newMsgs = backgroundService.fetchDifference()
                            if (newMsgs.size > 0) {
                                Hilog.info(0, "CjTelegram",
                                    "[ChatListVM] Got ${newMsgs.size} offline messages via getDifference")
                            }
                        } else {
                            let _ = backgroundService.fetchAndStoreSyncState()
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatListVM] background difference failed: ${e}")
                    }
                }
                spawn {
                    try {
                        let archived = backgroundService.getDialogsResult(limit: 100, offsetDate: 0, folderId: 1)
                        launch {
                            if (!this.loadStillActive(loadSlot, "initialArchive")) { return }
                            if (archived.success) {
                                this.archiveChatList = this.mergeArchiveWithPendingOps(archived.chats)
                            }
                            this.publishCurrentChatList("initialArchive")
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatListVM] background archive failed: ${e}")
                    }
                }

                // 主列表可见后再预取列表小头像，避免与首屏 RPC 争用主 DC 连接。
                triggerFullPhotoDownloads(dialogs)

                // loadFilters 内部自带 spawn，不阻塞当前路径。
                if (this.loadStillActive(loadSlot, "loadFilters")) {
                    this.loadFilters()
                }

                Hilog.info(0, "CjTelegram", "[ChatListVM] Loaded ${dialogs.size} dialogs")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] Failed to load dialogs: ${e}")
                launch {
                    if (!this.loadStillActive(loadSlot, "initialLoadFailed")) { return }
                    this.isLoading = false
                    this.publishCurrentChatList("initialLoadFailed")
                }
            }
        }
    }

    /** 仅用于未知 update、编辑/删除 top message 或 difference 后的一致性恢复。 */
    private func refreshForConsistencyRecovery(): Unit {
        if (!this._recoveryRefreshInFlight.compareAndSwap(false, true)) {
            // 在途那次的 getDialogs 可能早于刚发生的变更（如取消归档）发出；丢掉这次触发会让
            // 那份旧快照成为最后的权威结果。记下来，在途那次结束后再跑一轮。
            this._recoveryRerunRequested.store(true)
            return
        }
        let loadSlot = getAuthStorage().getActiveSlot()
        spawn {
            try {
                let dialogsResult = getRealChatListService().getDialogsResult()
                var dialogs = dialogsResult.chats
                // 回源期间切换了账号：整份快照属于上一账号，不得覆盖当前账号的列表。
                let stillActive = this.loadStillActive(loadSlot, "consistencyRecovery")
                if (dialogsResult.success && stillActive) {
                    // 已翻页加载的更早会话不在首页快照里，整表覆盖前保留下来（见 mergeFirstPageKeepingLoadedTail）。
                    dialogs = this.firstPageWithLoadedTail(dialogsResult, this.chatList)
                    // TC-0028 M3 步骤 1：整表覆盖 chatList 之前先按 _pendingFolderOps 过滤/补回：
                    // value==1（本地已归档，服务端还没跟上）从结果中剔除；value==0（本地已取消
                    // 归档，服务端还没跟上）若不在结果中，按原顺序补回。顺带做"服务端已生效"判定，
                    // 满足即出队。F4（返修 round2）：本段过滤/补回逻辑本身不改动，仅补齐 D-157
                    // 要求的 Mutex 序列化——它守的是一个真实且源侧同构的竞态窗口（整表覆盖前
                    // 保护尚未被服务端确认的本地变更），与本轮重试终止化修复无关。此逻辑原挂在
                    // startPolling 上，随轮询整体退场迁移到本函数（§4.1 结转，宿主变更、逻辑不变）。
                    let presentInDialogs = HashMap<Int64, Bool>()
                    for (d in dialogs) {
                        presentInDialogs[d.id] = true
                    }
                    let filtered = ArrayList<Chat>()
                    // D-157：本段读取+移除 _pendingFolderOps 的完整序列在同一临界区内原子执行，
                    // 与 UI 线程的乐观写入、archiveChatWithUndo/onUndo/unarchiveChat 的 spawn{}
                    // 结果回调互斥，避免本协程读到正在被并发修改的 HashMap。
                    synchronized (this._pendingFolderOpsMutex) {
                        let settledKeys = ArrayList<Int64>()
                        for ((pid, pval) in this._pendingFolderOps) {
                            let stillPresent = presentInDialogs.contains(pid)
                            if (pval == Int32(1) && !stillPresent) {
                                settledKeys.add(pid)
                            } else if (pval == Int32(0) && stillPresent) {
                                settledKeys.add(pid)
                            }
                        }
                        for (sk in settledKeys) {
                            if (this._pendingFolderOps.contains(sk)) {
                                let _ = this._pendingFolderOps.remove(sk)
                            }
                        }
                        for (d in dialogs) {
                            let pendingVal = this._pendingFolderOps.get(d.id)
                            match (pendingVal) {
                                case Some(v) =>
                                    if (v != Int32(1)) { filtered.add(d) }
                                case None => filtered.add(d)
                            }
                        }
                        for (c in this.chatList) {
                            let pendingVal = this._pendingFolderOps.get(c.id)
                            match (pendingVal) {
                                case Some(v) =>
                                    if (v == Int32(0) && !presentInDialogs.contains(c.id)) {
                                        var alreadyInFiltered = false
                                        for (fc in filtered) {
                                            if (fc.id == c.id) { alreadyInFiltered = true; break }
                                        }
                                        if (!alreadyInFiltered) { filtered.add(c) }
                                    }
                                case None => ()
                            }
                        }
                    }
                    // TC-0028 M3 步骤 2
                    let recoveredList = filtered
                    launch {
                        if (!this.loadStillActive(loadSlot, "consistencyRecovery")) { return }
                        this.chatList = this.withPendingUnarchived(recoveredList)
                        this.refreshDialogsCursorAfterFirstPage(dialogsResult, recoveredList)
                        this.publishCurrentChatList("consistencyRecovery")
                    }
                    // TC-0028 M4：归档计数与主列表来自同一轮服务端快照，避免 Archived (N) 在
                    // 会话内失步（§4.3 结转：原挂在轮询 tick 上，随轮询退场改挂到一致性恢复之后，
                    // 仍在同一个 if (!dialogs.isEmpty()) 块、同一 spawn 协程里，保证同拍）。
                    this.loadArchivedDialogs()
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] consistency recovery failed: ${e}")
            } finally {
                this._recoveryRefreshInFlight.store(false)
                if (this._recoveryRerunRequested.compareAndSwap(true, false)) {
                    this.refreshForConsistencyRecovery()
                }
            }
        }
    }

    /**
     * 加载 Mock 数据（回退模式）
     */
    public func loadMockData() {
        this.isLoading = true
        
        this.chatList = ArrayList<Chat>()
        let c1 = Chat(); c1.id = 1; c1.name = "Alice"; c1.lastMessage = "你好！最近怎么样？"
        c1.time = "下午 3:42"; c1.unreadCount = 2; c1.avatarText = "A"; c1.avatarColor = 0xFF5722; c1.isPinned = true
        this.chatList.add(c1)
        let c2 = Chat(); c2.id = 2; c2.name = "Bob"; c2.lastMessage = "明天见！"
        c2.time = "下午 2:30"; c2.avatarText = "B"; c2.avatarColor = 0x2196F3
        this.chatList.add(c2)
        let c3 = Chat(); c3.id = 3; c3.name = "工作群"; c3.lastMessage = "[图片]"
        c3.time = "上午 11:20"; c3.unreadCount = 5; c3.avatarText = "工"; c3.avatarColor = 0x4CAF50; c3.isGroup = true
        this.chatList.add(c3)
        let c4 = Chat(); c4.id = 4; c4.name = "Charlie"; c4.lastMessage = "收到，谢谢！"
        c4.time = "昨天"; c4.avatarText = "C"; c4.avatarColor = 0x9C27B0
        this.chatList.add(c4)
        let c5 = Chat(); c5.id = 5; c5.name = "家庭群"; c5.lastMessage = "周末一起吃饭吧"
        c5.time = "昨天"; c5.unreadCount = 10; c5.avatarText = "家"; c5.avatarColor = 0xE91E63; c5.isGroup = true
        this.chatList.add(c5)
        
        this.isLoading = false
        this.publishCurrentChatList("mockData")
    }
    
    /**
     * 添加新聊天
     */
    public func addChat(chat: Chat) {
        this.chatList.add(chat, at: 0)
        this.publishCurrentChatList("addChat")
    }

    /** 服务端确认离开群聊后，从主列表和归档列表同步移除该会话。 */
    public func removeChatFromLocal(chatId: Int64): Unit {
        let newList = ArrayList<Chat>()
        for (chat in this.chatList) {
            if (chat.id != chatId) { newList.add(chat) }
        }
        let newArchiveList = ArrayList<Chat>()
        for (chat in this.archiveChatList) {
            if (chat.id != chatId) { newArchiveList.add(chat) }
        }
        this.chatList = newList
        this.archiveChatList = newArchiveList
        this.publishCurrentChatList("peerLeft")
        getChatListStore().storeChats(newList)
    }
    
    /**
     * Phase P1-1: 删除聊天 — 先调用服务端 API，成功后移除本地对话
     *
     * 数据流: UI → deleteChat → spawn → RealChatListService.deleteDialog
     *   → messages.deleteHistory / channels.leaveChannel → 本地移除
     */
    public func deleteChat(chatId: Int64) {
        var targetPeerType = "user"
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                targetPeerType = chat.peerType
                break
            }
        }
        let peerTypeCopy = targetPeerType
        let chatIdCopy = chatId

        spawn {
            try {
                let svc = getRealChatListService()
                let success = svc.deleteDialog(peerTypeCopy, chatIdCopy)
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] deleteChat success, removing from local list")
                    let newList = ArrayList<Chat>()
                    for (c in this.chatList) {
                        if (c.id != chatIdCopy) {
                            newList.add(c)
                        }
                    }
                    launch {
                        this.chatList = newList
                        this.publishCurrentChatList("deleteChat")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] deleteChat API failed, keeping in list")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] deleteChat exception: ${e}")
            }
        }
    }
    
    /**
     * 更新聊天的最后一条消息（整体赋值触发 @Publish UI 刷新）
     */
    public func updateLastMessage(chatId: Int64, message: String, time: String) {
        let newList = ArrayList<Chat>()
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                chat.lastMessage = message
                chat.time = time
                chat.unreadCount = 0  // 从聊天详情返回时清除未读
                chat.isMarkedUnread = false  // M-2e：已读清除时一并清标志
            }
            newList.add(chat)
        }
        this.chatList = newList  // 整体赋值强制触发 @Publish UI 刷新
        this.publishCurrentChatList("lastMessage")
    }

    /**
     * 清除聊天的未读数
     */
    public func clearUnreadCount(chatId: Int64) {
        let newList = ArrayList<Chat>()
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                chat.unreadCount = 0
                chat.isMarkedUnread = false  // M-2e：已读清除时一并清标志
                // iOS history consumption also commits the mention and unseen-reaction
                // tag summaries locally before their synchronization operations run.
                // Keeping these counters here made an already-opened chat retain an @ or
                // reaction badge until a later dialogs refresh (and reactions never
                // cleared at all while the RPC was missing).
                chat.mentionCount = 0
                chat.unreadReactionsCount = 0
            }
            newList.add(chat)
        }
        this.chatList = newList  // 整体赋值强制触发 @Publish UI 刷新
        this.publishCurrentChatList("clearUnread")
        // Keep the Postbox-style cold-start snapshot in the same committed
        // state. Otherwise a process restart can briefly restore the stale
        // unread badge before the next dialogs RPC completes.
        // 落盘走后台线程（快照已拷贝），UI 线程不再等 RDB 清旧写新。
        getChatListStore().storeChatsAsync(newList)
    }

    /** 把服务端已清空的历史投影到主列表和归档列表，并持久化冷启动快照。 */
    public func applyHistoryCleared(chatId: Int64): Unit {
        let newList = ArrayList<Chat>()
        for (chat in this.chatList) {
            if (chat.id == chatId) { this.resetHistorySummary(chat) }
            newList.add(chat)
        }
        let newArchiveList = ArrayList<Chat>()
        for (chat in this.archiveChatList) {
            if (chat.id == chatId) { this.resetHistorySummary(chat) }
            newArchiveList.add(chat)
        }
        this.chatList = newList
        this.archiveChatList = newArchiveList
        this.publishCurrentChatList("clearHistory")
        getChatListStore().storeChatsAsync(newList)
    }

    private func resetHistorySummary(chat: Chat): Unit {
        chat.lastMessage = ""
        chat.lastMessageType = "text"
        chat.lastMessageTimestamp = 0
        chat.lastMessageSenderName = ""
        chat.lastMessageViews = 0
        chat.lastMessageOutgoing = false
        chat.lastMessageRead = true
        chat.time = ""
        chat.unreadCount = 0
        chat.mentionCount = 0
        chat.unreadReactionsCount = 0
        chat.isMarkedUnread = false
    }
    
    /**
     * Phase E: 标记对话已读（调用服务端 API）
     */
    public func markAsRead(chatId: Int64, peerType: String) {
        // 本地立即清零
        this.clearUnreadCount(chatId)
        // 异步通知服务端
        spawn {
            try {
                let chatListService = getRealChatListService()
                chatListService.markDialogAsRead(peerType, chatId)
                Hilog.info(0, "CjTelegram", "[ChatListVM] markAsRead: ${chatId}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] markAsRead failed: ${e}")
            }
        }
    }

    /**
     * P2-104: 标记/取消标记对话未读（messages.markDialogUnread）
     *
     * - unread=true  → 强制标记为未读（本地 unreadCount 保持不变或置 1）
     * - unread=false → 清除未读标记（本地 clearUnreadCount）
     * RPC 走 spawn{}（网络操作不阻塞 UI），@State 回写走 launch{}（S-001 合规）。
     */
    public func toggleMarkUnread(chatId: Int64): Unit {
        var peerTypeStr = "user"
        var currentUnread = false
        var hasMessageUnread = false
        for (c in this.chatList) {
            if (c.id == chatId) {
                peerTypeStr = c.peerType
                // M-2c：判据对位 PeerReadState.isUnread（PeerReadState.swift:24-30），
                // 计数与 markedUnread 位任一为真即为未读。
                currentUnread = c.unreadCount > 0 || c.isMarkedUnread
                hasMessageUnread = c.unreadCount > 0
                break
            }
        }
        let pt = peerTypeStr
        let cid = chatId
        let markAsUnread = !currentUnread
        let readMessages = hasMessageUnread

        if (markAsUnread) {
            // M-2c：乐观本地更新改为置 isMarkedUnread 布尔位（不再伪造 unreadCount），
            // 对位源侧 applyInteractiveMarkUnread 只改 markedUnread、不动 count
            // （MessageHistoryReadStateTable.swift:438-455）。
            let newList = ArrayList<Chat>()
            for (c in this.chatList) {
                if (c.id == cid) {
                    c.isMarkedUnread = true
                }
                newList.add(c)
            }
            launch {
                this.chatList = newList
                this.publishCurrentChatList("toggleMarkUnread")
            }
        } else {
            this.clearUnreadCount(cid)
        }

        spawn {
            try {
                let svc = getRealChatListService()
                // iOS togglePeersUnreadMarkInteractively reads through the
                // peer's top message when unread messages exist.  Only the
                // count==0 manual-dot case uses markDialogUnread(false).
                let ok = if (!markAsUnread && readMessages) {
                    svc.markDialogAsRead(pt, cid)
                } else {
                    svc.markDialogUnread(pt, cid, markAsUnread)
                }
                Hilog.info(0, "CjTelegram", "[ChatListVM] toggleMarkUnread chatId=${cid} markAsUnread=${markAsUnread} ok=${ok}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] toggleMarkUnread failed: ${e}")
            }
        }
    }

    /**
     * P2-104: 清除对话历史（messages.deleteHistory，带二次确认）
     *
     * - 调用 RealMessageService.clearHistory（已有实现，走 MessagesDeleteHistory TL）
     * - 成功后本地清除该对话的 lastMessage / unreadCount
     * - 调用方负责弹二次确认 Dialog（showAlert(destructive: true)），确认后调本方法
     */
    public func clearChatHistory(chatId: Int64): Unit {
        var peerTypeStr = "user"
        for (c in this.chatList) {
            if (c.id == chatId) {
                peerTypeStr = c.peerType
                break
            }
        }
        let pt = peerTypeStr
        let cid = chatId

        spawn {
            try {
                let msgSvc = getRealMessageService()
                let ok = msgSvc.clearHistory(pt, cid, maxId: 2147483646, justClear: true, revoke: false)
                Hilog.info(0, "CjTelegram", "[ChatListVM] clearChatHistory chatId=${cid} ok=${ok}")
                if (ok) {
                    getMessageHistoryStore().clearPeer(cid, peerType: pt)
                    launch {
                        this.applyHistoryCleared(cid)
                        msgSvc.notifyHistoryChanged(cid)
                    }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] clearChatHistory failed: ${e}")
            }
        }
    }
    
    /**
     * 增加未读数
     */
    public func incrementUnreadCount(chatId: Int64) {
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                chat.unreadCount += 1
                break
            }
        }
        this.publishCurrentChatList("incrementUnread")
    }
    
    /**
     * Phase P1-2: 置顶/取消置顶聊天 — 先调 API，成功后翻转本地状态并重排序
     *
     * 数据流: UI → togglePinChat → spawn → RealChatListService.togglePinDialog
     *   → messages.toggleDialogPin → 本地翻转 isPinned + 重排序
     */
    public func togglePinChat(chatId: Int64) {
        var targetPeerType = "user"
        var currentPinned = false
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                targetPeerType = chat.peerType
                currentPinned = chat.isPinned
                break
            }
        }
        let peerTypeCopy = targetPeerType
        let chatIdCopy = chatId
        let newPinned = !currentPinned

        spawn {
            try {
                let svc = getRealChatListService()
                let success = svc.togglePinDialog(peerTypeCopy, chatIdCopy, newPinned)
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] togglePin success, updating local state")
                    // B4：对齐 iOS TogglePeerChatPinned.swift:66（新置顶插到置顶序首位 itemIds.insert(at: 0)）；
                    // 取消置顶的会话回到非置顶区并按最后消息时间重排（sortChatList，与网络回源同一排序），
                    // 不再原地停在列表顶部直到重启。
                    let pinned = ArrayList<Chat>()
                    let others = ArrayList<Chat>()
                    var target: Option<Chat> = None
                    for (c in this.chatList) {
                        if (c.id == chatIdCopy) {
                            c.isPinned = newPinned
                            target = Some(c)
                        } else if (c.isPinned) {
                            pinned.add(c)
                        } else {
                            others.add(c)
                        }
                    }
                    let newList = ArrayList<Chat>()
                    match (target) {
                        case Some(t) =>
                            if (newPinned) { newList.add(t) } else { others.add(t) }
                        case None => ()
                    }
                    for (p in pinned) { newList.add(p) }
                    for (u in sortChatList(others)) { newList.add(u) }
                    getChatListStore().storeChats(newList)
                    launch {
                        this.chatList = newList
                        this.publishCurrentChatList("togglePin")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] togglePin API failed")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] togglePin exception: ${e}")
            }
        }
    }
    
    /**
     * Phase P1-3: 静音/取消静音聊天 — 先调 API，成功后翻转本地状态
     *
     * 数据流: UI → toggleMuteChat → spawn → RealChatListService.toggleMuteDialog
     *   → account.updateNotifySettings → 本地翻转 isMuted
     */
    public func toggleMuteChat(chatId: Int64) {
        var targetPeerType = "user"
        var currentMuted = false
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                targetPeerType = chat.peerType
                currentMuted = chat.isMuted
                break
            }
        }
        let peerTypeCopy = targetPeerType
        let chatIdCopy = chatId
        let newMuted = !currentMuted

        spawn {
            try {
                let svc = getRealChatListService()
                let success = svc.toggleMuteDialog(peerTypeCopy, chatIdCopy, newMuted)
                if (success) {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] toggleMute success")
                    let newList = ArrayList<Chat>()
                    for (c in this.chatList) {
                        if (c.id == chatIdCopy) {
                            c.isMuted = newMuted
                        }
                        newList.add(c)
                    }
                    getChatListStore().storeChats(newList)
                    launch {
                        this.chatList = newList
                        this.publishCurrentChatList("toggleMute")
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] toggleMute API failed")
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] toggleMute exception: ${e}")
            }
        }
    }
    
    // ==================== P2-406: undo-aware destructive operations ====================

    /**
     * T-3 修复：把 chat 插回 list 的 index 位置（而非头插），返回新列表，不修改入参。
     * getFilteredChats() 不做任何排序，头插会直接破坏会话的服务端时间序。
     * index 按 list 当前长度夹取（< 0 → 0；> size → size），因为恢复发生时列表长度可能
     * 已因并发操作变化，与归档前记录 index 时的长度不再一致。
     */
    private func insertChatAtIndex(list: ArrayList<Chat>, chat: Chat, index: Int64): ArrayList<Chat> {
        let size = Int64(list.size)
        var clamped = index
        if (clamped < 0) { clamped = 0 }
        if (clamped > size) { clamped = size }
        let result = ArrayList<Chat>()
        var pos: Int64 = 0
        var inserted = false
        for (c in list) {
            if (pos == clamped) {
                result.add(chat)
                inserted = true
            }
            result.add(c)
            pos += 1
        }
        if (!inserted) { result.add(chat) }
        return result
    }

    /**
     * 归档对话 + undo toast（iOS archivedChat 语义）
     *
     * 执行归档，同时弹 5s 可撤销 toast。
     * onUndo → 调 unarchiveChat 反向恢复（archive/unarchive 本身可逆，无需延迟提交）。
     * onCommit → 无需额外动作（归档已在 archiveChat() 内提交）。
     *
     * iOS 对应：UndoOverlayContent.archivedChat，originalRemainingSeconds=5
     */
    public func archiveChatWithUndo(chatId: Int64): Unit {
        let cid = chatId

        // 归档前从 chatList 捞到 Chat 引用及 peerType（在 spawn 之前，避免 in-flight 竞态）
        // T-3: 同一次遍历顺带记录会话在 chatList 中的下标，供两条恢复路径插回原位（而非头插）。
        var foundChat: Option<Chat> = None
        var peerTypeStr = "user"
        var chatName = ""
        var foundIndex: Int64 = -1
        var scanIdx: Int64 = 0
        for (c in this.chatList) {
            if (c.id == chatId) {
                foundChat = Some(c)
                peerTypeStr = c.peerType
                chatName = c.name
                foundIndex = scanIdx
                break
            }
            scanIdx += 1
        }
        let savedChat = foundChat
        let pt = peerTypeStr
        let nameForToast = chatName

        // 原始下标：单元素 ArrayList<Int64> 作可捕获 let 容器，与下面 cancelledRef 同范式
        // （仓颉闭包不可捕获本地 var，但可改变 let 容器内容）。
        let originalIndexRef = ArrayList<Int64>()
        originalIndexRef.add(foundIndex)

        // 取消标志：单元素 ArrayList<Bool> 作可捕获 let 容器（仓颉闭包不可捕获本地 var，
        // 但可改变 let 容器内容；参见 ReadStateTable.totalUnreadCount / PeerTable.getAllPeers 范式）
        let cancelledRef = ArrayList<Bool>()
        cancelledRef.add(false)

        // TC-0028 M2：乐观提交是"移出主列表 + 移入归档列表"的同一个本地事务的两半，
        // 同步一起写，不再像此前那样把 archiveChatList 那一半推迟到 RPC 成功分支才补——
        // 源侧 updatePeersGroupIdInteractively 走本地 Postbox 事务、与网络提交解耦
        // （SynchronizeGroupedPeersOperation.swift:5-27），归档状态不依赖网络成功。
        let newMain = ArrayList<Chat>()
        for (c in this.chatList) {
            if (c.id != cid) { newMain.add(c) }
        }
        this.chatList = newMain
        match (savedChat) {
            case Some(ac) =>
                let newArchive = ArrayList<Chat>()
                for (c in this.archiveChatList) {
                    newArchive.add(c)
                }
                newArchive.add(ac)
                this.archiveChatList = newArchive
            case None => ()
        }
        // TC-0028 M3：登记待同步 folder 操作（1=已本地归档，等待服务端确认）。
        // D-157：与 spawn{} 结果回调、refreshForConsistencyRecovery 一致性恢复协程共享
        // _pendingFolderOps，经 _pendingFolderOpsMutex 序列化（此处在 UI 线程同步执行，
        // 仍需持锁以与其它协程的并发访问互斥）。
        synchronized (this._pendingFolderOpsMutex) {
            this._pendingFolderOps[cid] = Int32(1)
        }
        this.publishCurrentChatList("archiveOptimistic")

        // 发起归档 API（内联 spawn，不委托 archiveChat，以便取消标志可拦截迟到回写）
        spawn {
            try {
                let chatSvc = getRealChatListService()
                if (chatSvc.archiveChat(pt, cid)) {
                    // 待定项保留到一致性刷新看到服务端主列表已不含该会话才出队（settledKeys），
                    // 防止早于本次 RPC 发出的旧快照把会话放回主列表；随即回源确认一次。
                    this.refreshForConsistencyRecovery()
                    Hilog.info(0, "CjTelegram", "[ChatListVM] archiveChat API success chatId=${cid} cancelled=${cancelledRef[0]}")
                } else {
                    // TC-0028 M1：不再回滚本地状态——源侧 ManagedSynchronizeGroupedPeersOperations.swift:145-152
                    // 把 folders.editPeerFolders 的网络失败 catch 吞掉，本地 inclusion 原样保留。
                    // 单次尝试即终态：失败不重试、不回滚，无条件出队，对位源侧
                    // ManagedSynchronizeGroupedPeersOperations.swift:107-111 的无条件 removeEntry。
                    synchronized (this._pendingFolderOpsMutex) {
                        if (this._pendingFolderOps.contains(cid)) {
                            let _ = this._pendingFolderOps.remove(cid)
                        }
                    }
                    Hilog.info(0, "CjTelegram", "[ChatListVM] archiveChat API failed, kept optimistic local state chatId=${cid}, not retried")
                }
            } catch (e: Exception) {
                // 异常路径与失败路径在"是否出队"上必须一视同仁，避免异常成为新的无限期残留来源。
                synchronized (this._pendingFolderOpsMutex) {
                    if (this._pendingFolderOps.contains(cid)) {
                        let _ = this._pendingFolderOps.remove(cid)
                    }
                }
                Hilog.info(0, "CjTelegram", "[ChatListVM] archiveChat exception: ${e}")
            }
        }

        let svc = getUndoToastService()
        svc.showUndo(
            "Chat archived",
            actionText: "Undo",
            durationMs: 5000,
            onUndo: { =>
                // RACE-1/2 修复：先置位取消标志，阻止迟到 spawn 写 archiveChatList 或重复恢复 chatList
                cancelledRef[0] = true
                Hilog.info(0, "CjTelegram", "[ChatListVM] undo archive chatId=${cid}")
                // TC-0028 M3：撤销把该 chat 的目标 folder 改回主列表（0=待取消归档，等待服务端确认），
                // 防止 refreshForConsistencyRecovery 在服务端反映这次撤销之前的一次整表覆盖把它当
                // "仍归档"丢弃。
                // D-157：与 spawn{} 结果回调、refreshForConsistencyRecovery 一致性恢复协程共享
                // _pendingFolderOps，经 _pendingFolderOpsMutex 序列化。
                synchronized (this._pendingFolderOpsMutex) {
                    this._pendingFolderOps[cid] = Int32(0)
                    match (savedChat) {
                        case Some(sc) => this._pendingUnarchivedChats[cid] = sc
                        case None => ()
                    }
                }
                match (savedChat) {
                    case Some(chat) =>
                        // 幂等恢复 chatList：若 spawn 失败恢复路径已插入，则不重复插
                        var alreadyRestored = false
                        for (c in this.chatList) {
                            if (c.id == cid) { alreadyRestored = true; break }
                        }
                        let newArchive = ArrayList<Chat>()
                        for (c in this.archiveChatList) {
                            if (c.id != cid) { newArchive.add(c) }
                        }
                        if (!alreadyRestored) {
                            // T-3: 插回原下标而非头插，避免破坏会话时间序
                            let restored = insertChatAtIndex(this.chatList, chat, originalIndexRef[0])
                            launch {
                                this.chatList = restored
                                this.archiveChatList = newArchive
                                this.publishCurrentChatList("archiveUndo")
                            }
                        } else {
                            launch {
                                this.archiveChatList = newArchive
                                this.publishCurrentChatList("archiveUndo")
                            }
                        }
                    case None => ()
                }
                spawn {
                    try {
                        let chatSvc = getRealChatListService()
                        let ok = chatSvc.unarchiveChat(pt, cid)
                        // 成功：待定项留到一致性刷新确认服务端主列表已含该会话再出队（同 unarchiveChat）；
                        // 失败：单次尝试即终态，出队（ManagedSynchronizeGroupedPeersOperations.swift:107-111）。
                        if (ok) {
                            this.refreshForConsistencyRecovery()
                        } else {
                            synchronized (this._pendingFolderOpsMutex) {
                                if (this._pendingFolderOps.contains(cid)) {
                                    let _ = this._pendingFolderOps.remove(cid)
                                }
                            }
                        }
                        Hilog.info(0, "CjTelegram", "[ChatListVM] unarchive API result=${ok} chatId=${cid}")
                    } catch (e: Exception) {
                        // 异常路径与失败路径在"是否出队"上必须一视同仁，避免异常成为新的无限期残留来源。
                        synchronized (this._pendingFolderOpsMutex) {
                            if (this._pendingFolderOps.contains(cid)) {
                                let _ = this._pendingFolderOps.remove(cid)
                            }
                        }
                        Hilog.info(0, "CjTelegram", "[ChatListVM] unarchive exception: ${e}")
                    }
                }
            },
            onCommit: { =>
                Hilog.info(0, "CjTelegram", "[ChatListVM] archive committed chatId=${cid} name=${nameForToast}")
            }
        )
    }

    /**
     * 静音/取消静音 + undo toast（iOS notificationMuted 语义）
     *
     * 执行 toggle mute，同时弹 5s 可撤销 toast。
     * onUndo → 方向明确地把静音设回 previouslyMuted，不再二次 toggle，
     *          消除"第一次 spawn 未完成时二次 toggle 方向错误"的竞态。
     * onCommit → 无需额外动作。
     *
     * iOS 对应：UndoOverlayContent.universal，originalRemainingSeconds=5
     */
    public func toggleMuteChatWithUndo(chatId: Int64): Unit {
        let cid = chatId

        // toggle 前快照 peerType 和原始 muted 状态（避免读 in-flight spawn 更新后的本地态）
        var peerTypeStr = "user"
        var wasMuted = false
        for (c in this.chatList) {
            if (c.id == chatId) {
                peerTypeStr = c.peerType
                wasMuted = c.isMuted
                break
            }
        }
        let pt = peerTypeStr
        let previouslyMuted = wasMuted
        let newMuted = !previouslyMuted

        // 取消标志（同 archiveChatWithUndo；单元素 ArrayList<Bool> 作 let 容器，闭包可改内容）
        let cancelledRef = ArrayList<Bool>()
        cancelledRef.add(false)

        // RACE-3 修复：不再委托 toggleMuteChat（其 spawn 成功后无条件覆写 isMuted）
        // 内联乐观写本地状态
        launch {
            let optimisticList = ArrayList<Chat>()
            for (c in this.chatList) {
                if (c.id == cid) { c.isMuted = newMuted }
                optimisticList.add(c)
            }
            this.chatList = optimisticList
            this.publishCurrentChatList("muteOptimistic")
        }

        // 内联 spawn：API 成功后回写本地状态时先检查取消标志
        spawn {
            try {
                let chatSvc = getRealChatListService()
                let ok = chatSvc.toggleMuteDialog(pt, cid, newMuted)
                if (ok && !cancelledRef[0]) {
                    // 仅在未撤销时确认本地状态（幂等于乐观写，防止 onUndo 已写 previouslyMuted 被覆盖）
                    let confirmedList = ArrayList<Chat>()
                    for (c in this.chatList) {
                        if (c.id == cid) { c.isMuted = newMuted }
                        confirmedList.add(c)
                    }
                    // B5：服务端确认后同步写回本地会话表（对齐 iOS ManagedPendingPeerNotificationSettings：
                    // 请求成功后 transaction.updateCurrentPeerNotificationSettings 落 Postbox），
                    // 冷启动首帧读本地表时不再回到旧的未静音状态。
                    getChatListStore().storeChats(confirmedList)
                    launch {
                        this.chatList = confirmedList
                        this.publishCurrentChatList("muteConfirmed")
                    }
                    // 回读服务端权威值，便于回归时直接从 hilog 判定是否真正落库。
                    let serverMuted = chatSvc.getPeerMuteState(pt, cid)
                    Hilog.info(0, "CjTelegram", "[ChatListVM] mute verify chatId=${cid} expected=${newMuted} server=${serverMuted}")
                }
                Hilog.info(0, "CjTelegram", "[ChatListVM] toggleMute API result=${ok} chatId=${cid} newMuted=${newMuted} cancelled=${cancelledRef[0]}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] toggleMute exception: ${e}")
            }
        }

        let svc = getUndoToastService()
        let toastText = if (previouslyMuted) { "Chat unmuted" } else { "Chat muted" }
        svc.showUndo(
            toastText,
            actionText: "Undo",
            durationMs: 5000,
            onUndo: { =>
                // RACE-3 修复：先置位取消标志，阻止迟到 spawn 用 newMuted 覆盖已撤销的本地状态
                cancelledRef[0] = true
                Hilog.info(0, "CjTelegram", "[ChatListVM] undo mute toggle chatId=${cid} restoreMuted=${previouslyMuted}")
                // 乐观回写本地状态为 previouslyMuted
                let restoredList = ArrayList<Chat>()
                for (c in this.chatList) {
                    if (c.id == cid) { c.isMuted = previouslyMuted }
                    restoredList.add(c)
                }
                launch {
                    this.chatList = restoredList
                    this.publishCurrentChatList("muteUndo")
                }
                // 方向明确的反向 API 请求
                spawn {
                    try {
                        let chatSvc = getRealChatListService()
                        let ok = chatSvc.toggleMuteDialog(pt, cid, previouslyMuted)
                        if (ok) { getChatListStore().storeChats(restoredList) }
                        Hilog.info(0, "CjTelegram", "[ChatListVM] undo mute API result=${ok} chatId=${cid} muted=${previouslyMuted}")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatListVM] undo mute exception: ${e}")
                    }
                }
            },
            onCommit: { =>
                Hilog.info(0, "CjTelegram", "[ChatListVM] mute committed chatId=${cid} newMuted=${newMuted}")
            }
        )
    }

    /**
     * TC-0035 返修（diag-suite_chat_list-TC-0035.md「M2」）：删除/离开会话的统一漏斗。
     * 对应源侧 ChatListController.swift:6146
     * schedulePeerChatRemoval(peer:type:deleteGloballyIfPossible:completion:)——全文件 11
     * 个删除入口无一例外汇入该函数。原 deleteChatWithUndo() 只服务 1:1/频道且已被证实是
     * "正确但覆盖不全"的实现（该 case 4.2 节独立核实）；本轮升级为对所有 peerType 统一
     * 生效的单一漏斗，替换掉此前群聊走 DeleteChatPeerActionSheetComponent 自行发起
     * 不可逆 RPC、完全绕过撤销体系的平行路径（见 pages/ChatListPage.cj
     * buildDeleteChatPeerSheet() 的返修说明）。
     *
     *   1. 乐观：立即从本地列表移除（UI 即刻反馈），同时记录原始下标
     *   2. 5s 内点 Undo → 按原始下标插回（不头插——getFilteredChats() 不做排序，显示顺序
     *      即 chatList 顺序，头插会导致撤销后位置错乱，对应该 case §5.4 边界条件）
     *   3. 5s 到 onCommit → 真正调 svc.deleteDialog() 提交删除（源 :6208-6225）
     *
     * @param deleteGloballyIfPossible 对应源侧 removePeerChat(deleteGloballyIfPossible:)：
     *        true 时群主/频道主走 deleteChat / deleteChannel（为所有成员删除），
     *        false 时走 deleteChatUser(self) / leaveChannel；同时决定提示文案。
     */
    public func schedulePeerChatRemoval(chatId: Int64, deleteGloballyIfPossible!: Bool = false): Unit {
        let cid = chatId
        var removedChat: Option<Chat> = None
        var peerType = "user"
        var originalIndex: Int64 = -1
        var scanIndex: Int64 = 0
        for (c in this.chatList) {
            if (c.id == chatId) {
                removedChat = Some(c)
                peerType = c.peerType
                originalIndex = scanIndex
                break
            }
            scanIndex = scanIndex + 1
        }
        let removedOpt = removedChat
        let pt = peerType
        let restoreIndex = originalIndex

        // 乐观：立即从本地列表移除。同时登记 removed（iOS removePeerChat 先把会话置为
        // chat list notIncluded 再发 RPC）：撤销窗口内的一致性刷新、以及退群 RPC 返回的
        // "left the group" 服务消息都不得把它放回列表。
        let removedKeyType = normalizeDialogPeerType(pt)
        getRealChatListService().markDialogRemoved(removedKeyType, cid)
        let newList = ArrayList<Chat>()
        for (c in this.chatList) {
            if (c.id != cid) { newList.add(c) }
        }
        this.chatList = newList
        this.publishCurrentChatList("deleteOptimistic")

        // 文案（对应源 statusText，:6164-6195）
        var statusText = "Chat deleted"
        if (pt == "chat") {
            statusText = if (deleteGloballyIfPossible) { "Group deleted" } else { "Left group" }
        } else if (pt == "channel") {
            statusText = if (deleteGloballyIfPossible) { "Channel deleted" } else { "Left channel" }
        } else {
            statusText = if (deleteGloballyIfPossible) { "Chat deleted for both sides" } else { "Chat deleted" }
        }

        let svc = getUndoToastService()
        svc.showUndo(
            statusText,
            actionText: "Undo",
            durationMs: 5000,
            onUndo: { =>
                // 恢复：按原始下标把 chat 插回（不头插，避免撤销后位置错乱）
                Hilog.info(0, "CjTelegram", "[ChatListVM] undo delete chatId=${cid}")
                getRealChatListService().clearDialogRemoved(removedKeyType, cid)
                match (removedOpt) {
                    case Some(chat) =>
                        let restored = ArrayList<Chat>()
                        var writeIndex: Int64 = 0
                        var didInsert = false
                        for (c in this.chatList) {
                            if (restoreIndex >= 0 && writeIndex == restoreIndex) {
                                restored.add(chat)
                                didInsert = true
                            }
                            restored.add(c)
                            writeIndex = writeIndex + 1
                        }
                        if (!didInsert) { restored.add(chat) }
                        launch {
                            this.chatList = restored
                            this.publishCurrentChatList("deleteUndo")
                        }
                    case None => ()
                }
            },
            onCommit: { =>
                // 5s 后真正提交删除
                Hilog.info(0, "CjTelegram", "[ChatListVM] delete committed, calling deleteDialog chatId=${cid}")
                spawn {
                    try {
                        let chatListSvc = getRealChatListService()
                        let success = chatListSvc.deleteDialog(pt, cid, deleteGlobally: deleteGloballyIfPossible,
                            revokeUserHistory: deleteGloballyIfPossible)
                        Hilog.info(0, "CjTelegram", "[ChatListVM] deleteDialog result=${success} chatId=${cid}")
                        // 私聊删除历史后，对方的新消息应让会话重新出现（iOS 新消息重新 include）；
                        // 群/频道已离开，保持 removed。失败时撤销登记并回源刷新，会话回到列表。
                        if (!success || removedKeyType == "user") {
                            chatListSvc.clearDialogRemoved(removedKeyType, cid)
                        }
                        if (!success) { this.refreshWithPullDown() }
                    } catch (e: Exception) {
                        getRealChatListService().clearDialogRemoved(removedKeyType, cid)
                        Hilog.info(0, "CjTelegram", "[ChatListVM] deleteDialog exception: ${e}")
                    }
                }
            }
        )
    }

    /**
     * 公开帖子 hashtag 搜索 —— 对位 iOS _internal_searchHashtagPosts
     * （SearchMessages.swift:652：channels.searchPosts(flags: 1<<0, hashtag:, offsetRate: 0,
     * offsetPeer: inputPeerEmpty, offsetId: 0, limit:)）。Chats 结果页取 limit 10，
     * 结果按消息成行（与 messages.searchGlobal 同一 messages.Messages 结构）。
     * 若 channels.searchPosts 被服务端拒绝，退回 messages.searchGlobal(broadcasts_only)
     * —— 与 HashtagSearchPageNode 的 Public Posts 作用域同一条已验证的请求。
     */
    public func searchPublicPosts(query: String): Unit {
        if (!query.startsWith("#") || query.size < 2) {
            this.publicPostResults = ArrayList<Chat>()
            this.isSearchingPublicPosts = false
            this._lastPublicPostsQuery = ""
            return
        }
        if (query == this._lastPublicPostsQuery) { return }
        this._lastPublicPostsQuery = query
        this.isSearchingPublicPosts = true
        let queryCopy = query
        let hashtag = String(query.toRuneArray()[1..])
        spawn {
            var rows = ArrayList<Chat>()
            try {
                let client = getMTProtoClient()
                let req = ChannelsSearchPosts()
                req.hashtag = hashtag
                req.limit = 10
                var responseData = client.sendRequest(req.toBytes())
                var failed = responseData.size < 8
                if (!failed) {
                    let d = TLDeserializer(responseData)
                    let ctor = d.readUInt32()
                    if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                        let errCode = d.readInt32()
                        let errMsg = d.readString()
                        Hilog.info(0, "CjTelegram", "[ChatListVM] searchPosts error ${errCode} ${errMsg}, fallback searchGlobal")
                        failed = true
                    }
                }
                if (failed) {
                    let fallback = MessagesSearchGlobal()
                    fallback.q = queryCopy
                    fallback.broadcastsOnly = true
                    fallback.limit = 10
                    responseData = client.sendRequest(fallback.toBytes())
                    if (responseData.size >= 8) {
                        let d2 = TLDeserializer(responseData)
                        let ctor2 = d2.readUInt32()
                        failed = ctor2 == TLConstructors.RPC_ERROR || ctor2 == 0x2144ca19
                    }
                }
                if (!failed && responseData.size >= 8) {
                    rows = buildMessageSearchRows(MessagesHistoryResponse.deserialize(responseData))
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchPublicPosts exception: ${e}")
            }
            let finalRows = rows
            launch {
                if (queryCopy == this._lastPublicPostsQuery) {
                    this.publicPostResults = finalRows
                }
                this.isSearchingPublicPosts = false
            }
            Hilog.info(0, "CjTelegram", "[ChatListVM] searchPublicPosts '${queryCopy}': ${finalRows.size} posts")
        }
    }

    /**
     * 分类标签搜索：pane ∈ media / links / files / music / voice，查询可为空（空查询列出最近的该类消息）。
     * 过滤器对位 iOS messageFilterForTagMask：photoOrVideo → PhotoVideo、webPage → Url、
     * file → Document、music → Music、voiceOrInstantVideo → RoundVoice。
     */
    public func searchFilteredMessages(query: String, pane: String): Unit {
        let key = "${pane}|${query}"
        if (key == this._lastFilterSearchKey) { return }
        this._lastFilterSearchKey = key
        this.isSearchingFilter = true
        this.filterSearchResults = ArrayList<Chat>()
        let queryCopy = query
        let paneCopy = pane
        spawn {
            var rows = ArrayList<Chat>()
            try {
                let req = MessagesSearchGlobal()
                req.q = queryCopy
                req.limit = 50
                let filter: TLObject = match (paneCopy) {
                    case "media" => InputMessagesFilterPhotoVideo()
                    case "links" => InputMessagesFilterUrl()
                    case "files" => InputMessagesFilterDocument()
                    case "music" => InputMessagesFilterMusic()
                    case _ => InputMessagesFilterRoundVoice()
                }
                req.filter = filter
                let responseData = getMTProtoClient().sendRequest(req.toBytes())
                var ok = responseData.size >= 8
                if (ok) {
                    let d = TLDeserializer(responseData)
                    let ctor = d.readUInt32()
                    ok = !(ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19)
                }
                if (ok) {
                    rows = buildMessageSearchRows(MessagesHistoryResponse.deserialize(responseData), summary: paneCopy)
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchFilteredMessages ${paneCopy} failed: ${e}")
            }
            let finalRows = rows
            launch {
                if (key == this._lastFilterSearchKey) {
                    this.filterSearchResults = finalRows
                    this.isSearchingFilter = false
                }
            }
            Hilog.info(0, "CjTelegram", "[ChatListVM] searchFilteredMessages ${paneCopy} '${queryCopy}': ${finalRows.size}")
        }
    }

    /**
     * 一组会话一次性标为已读 —— 对位 iOS markAllChatsAsReadInteractively
     * （文件夹 Read All：CLC:4169-4183；归档行 Mark All as Read：CCM:31-37）。
     * 主列表与归档列表同时乐观清零（含 markedUnread 位与 @/reaction 计数），
     * 再逐个把服务端已读边界推到最新；手动标记未读的会话额外清掉 unread 标记。
     */
    public func markChatsAsReadInteractively(chatIds: ArrayList<Int64>): Unit {
        let targets = ArrayList<(String, Int64, Bool)>()
        let apply = { list: ArrayList<Chat> =>
            let updated = ArrayList<Chat>()
            for (c in list) {
                if (chatIds.contains(c.id) && (c.unreadCount > 0 || c.isMarkedUnread)) {
                    targets.add((c.peerType, c.id, c.isMarkedUnread && c.unreadCount == 0))
                    let copy = c.copy()
                    copy.unreadCount = 0
                    copy.isMarkedUnread = false
                    copy.mentionCount = 0
                    copy.unreadReactionsCount = 0
                    updated.add(copy)
                } else {
                    updated.add(c)
                }
            }
            updated
        }
        let mainList = apply(this.chatList)
        let archive = apply(this.archiveChatList)
        this.chatList = mainList
        this.archiveChatList = archive
        this.publishCurrentChatList("markAllRead")
        getChatListStore().storeChats(mainList)
        spawn {
            let svc = getRealChatListService()
            for ((pt, cid, onlyMarked) in targets) {
                try {
                    if (onlyMarked) {
                        let _ = svc.markDialogUnread(pt, cid, false)
                    } else {
                        let _ = svc.markDialogAsRead(pt, cid)
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] markChatsAsRead failed ${cid}: ${e}")
                }
            }
            Hilog.info(0, "CjTelegram", "[ChatListVM] markChatsAsReadInteractively: ${targets.size} chats")
        }
    }

    /**
     * 文件夹 Mute All / Unmute All —— 对位 iOS updateMultiplePeerMuteSettings（CLC:1178-1182）。
     * 乐观更新两份列表后逐个提交 account.updateNotifySettings。
     */
    public func setChatsMuted(chatIds: ArrayList<Int64>, muted: Bool): Unit {
        let targets = ArrayList<(String, Int64)>()
        let apply = { list: ArrayList<Chat> =>
            let updated = ArrayList<Chat>()
            for (c in list) {
                if (chatIds.contains(c.id) && c.isMuted != muted) {
                    targets.add((c.peerType, c.id))
                    let copy = c.copy()
                    copy.isMuted = muted
                    updated.add(copy)
                } else {
                    updated.add(c)
                }
            }
            updated
        }
        let mainList = apply(this.chatList)
        let archive = apply(this.archiveChatList)
        this.chatList = mainList
        this.archiveChatList = archive
        this.publishCurrentChatList("folderMute")
        spawn {
            let svc = getRealChatListService()
            for ((pt, cid) in targets) {
                try {
                    let _ = svc.toggleMuteDialog(pt, cid, muted)
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ChatListVM] setChatsMuted failed ${cid}: ${e}")
                }
            }
        }
    }

    /**
     * 编辑态拖动置顶会话后提交新顺序 —— iOS ChatListNode reorderItems → setChatListPinnedItems
     * → ManagedSynchronizePinnedChatsOperations 发 messages.reorderPinnedDialogs(force, folder_id, order)。
     * 本地先按新顺序重排置顶段（非置顶段保持原序），再后台提交。
     */
    public func applyPinnedOrder(pinnedIds: ArrayList<Int64>, archive!: Bool = false): Unit {
        let source = if (archive) { this.archiveChatList } else { this.chatList }
        let pinned = ArrayList<Chat>()
        for (pid in pinnedIds) {
            for (c in source) {
                if (c.id == pid && c.isPinned) { pinned.add(c); break }
            }
        }
        let reordered = ArrayList<Chat>()
        for (c in pinned) { reordered.add(c) }
        for (c in source) {
            if (!(c.isPinned && pinnedIds.contains(c.id))) { reordered.add(c) }
        }
        if (archive) { this.archiveChatList = reordered } else { this.chatList = reordered }
        this.publishCurrentChatList("pinnedReorder")
        if (!archive) { getChatListStore().storeChats(reordered) }
        let peers = ArrayList<(String, Int64)>()
        for (c in pinned) { peers.add((c.peerType, c.id)) }
        let folderId: Int32 = if (archive) { 1 } else { 0 }
        spawn {
            try {
                let msgSvc = getRealMessageService()
                let req = MessagesReorderPinnedDialogs()
                req.folderId = folderId
                for ((pt, pid) in peers) {
                    let dialogPeer = InputDialogPeer()
                    dialogPeer.peer = msgSvc.buildInputPeer(pt, pid)
                    req.order.add(dialogPeer)
                }
                let responseData = getMTProtoClient().sendRequest(req.toBytes())
                var ok = responseData.size >= 4
                if (ok) {
                    let d = TLDeserializer(responseData)
                    ok = d.readUInt32() == TLConstructors.BOOL_TRUE
                }
                Hilog.info(0, "CjTelegram", "[ChatListVM] reorderPinnedDialogs count=${peers.size} ok=${ok}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] reorderPinnedDialogs failed: ${e}")
            }
        }
    }

    /** 会话是否已在本账号的会话列表（主列表或归档）里 —— iOS ChatListGroup(id:) != nil。 */
    public func isChatInList(chatId: Int64): Bool {
        for (c in this.chatList) { if (c.id == chatId) { return true } }
        for (c in this.archiveChatList) { if (c.id == chatId) { return true } }
        return false
    }

    /**
     * 获取总未读数
     */
    public func getTotalUnreadCount(): Int64 {
        var total: Int64 = 0
        for (chat in this.chatList) {
            if (!chat.isMuted) {
                total += chat.unreadCount
            }
        }
        return total
    }
    
    /**
     * Phase P5-8: 全局搜索 messages.searchGlobal
     * 搜索关键词 → API 调用 → 解析消息结果 → 组装 Chat 列表
     */
    public func searchGlobal(query: String): Unit {
        if (query.isEmpty()) {
            this.globalSearchResults = ArrayList<Chat>()
            this.isSearching = false
            this._lastSearchQuery = ""
            return
        }
        if (query == this._lastSearchQuery && this.globalSearchScope == this._lastSearchScope) { return }
        this._lastSearchQuery = query
        this._lastSearchScope = this.globalSearchScope
        this.isSearching = true
        let queryCopy = query
        let scopeCopy = this.globalSearchScope
        spawn {
            try {
                let client = getMTProtoClient()
                let req = MessagesSearchGlobalScoped()
                req.q = queryCopy
                req.limit = 30
                req.usersOnly = scopeCopy == "users"
                req.groupsOnly = scopeCopy == "groups"
                req.broadcastsOnly = scopeCopy == "channels"

                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobal: q='${queryCopy}' scope=${scopeCopy}")
                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size < 8) {
                    launch { this.isSearching = false }
                    return
                }

                let d = TLDeserializer(responseData)
                let ctor = d.readUInt32()
                if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
                    let errCode = d.readInt32()
                    let errMsg = d.readString()
                    Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobal error: ${errCode} ${errMsg}")
                    launch { this.isSearching = false }
                    return
                }

                let response = MessagesHistoryResponse.deserialize(responseData)
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobal: ${response.messages.size} messages, ${response.users.size} users, ${response.chats.size} chats")

                let results = buildMessageSearchRows(response)
                launch {
                    if (queryCopy == this._lastSearchQuery && scopeCopy == this._lastSearchScope) {
                        this.globalSearchResults = results
                    }
                    this.isSearching = false
                }
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobal: ${results.size} message rows scope=${scopeCopy}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobal error: ${e}")
                launch { this.isSearching = false }
            }
        }
    }

    /**
     * S9-23：切换 Messages 段范围并用当前查询重新搜索（iOS ChatListSearchListPaneNode
     * searchScope 变化 → 重新发起 messages.searchGlobal，带 users_only / groups_only / broadcasts_only）。
     */
    public func setGlobalSearchScope(scope: String, query: String): Unit {
        if (scope == this.globalSearchScope) { return }
        this.globalSearchScope = scope
        this._lastSearchQuery = ""
        this.globalSearchResults = ArrayList<Chat>()
        this.searchGlobal(query)
    }

    /**
     * S9-11：全局搜索 Channels 分类。
     * CHANNELS YOU JOINED = 本地会话（主列表 + 归档）里的广播频道（iOS getAllLocalChannels）；
     * RECOMMENDED CHANNELS = channels.getChannelRecommendations（无 channel 参数，全局推荐），
     * 剔除已加入的；两段都按查询串（若非空）做名称/用户名过滤。
     */
    public func loadChannelsPane(query: String): Unit {
        let needle = query.toAsciiLower()
        let joined = ArrayList<Chat>()
        let joinedIds = HashSet<Int64>()
        for (list in [this.chatList, this.archiveChatList]) {
            for (c in list) {
                if (!c.isChannel || c.isMegagroup) { continue }
                if (joinedIds.contains(c.id)) { continue }
                if (needle.size > 0 && !c.name.toAsciiLower().contains(needle) && !c.username.toAsciiLower().contains(needle)) { continue }
                joinedIds.add(c.id)
                joined.add(c)
            }
        }
        this.channelsPaneJoined = joined
        if (this._recommendedChannelsLoaded) {
            this.channelsPaneRecommended = this.filterRecommendedChannels(needle, joinedIds)
            return
        }
        this.isLoadingChannelsPane = true
        spawn {
            let photoSvc = getUserPhotoService()
            let fetched = fetchRecommendedChannels()
            let rows = ArrayList<Chat>()
            for (ch in fetched) {
                if (ch.isMigrated) { continue }
                let chat = Chat()
                chat.id = ch.id
                chat.name = ch.title
                chat.peerType = "channel"
                chat.username = ch.username
                chat.avatarText = if (ch.title.size > 0) { ch.title.toRuneArray()[0].toString() } else { "?" }
                chat.isChannel = true
                chat.isMegagroup = ch.isMegagroup
                chat.isGroup = ch.isMegagroup
                chat.isVerified = ch.isVerified
                chat.participantsCount = Int64(ch.participantsCount)
                chat.avatarLocalPath = photoSvc.getChatPhotoPath(ch.id)
                if (ch.participantsCount > 0) {
                    chat.lastMessage = "${groupSearchCountDigits(Int64(ch.participantsCount))} subscribers"
                } else if (ch.username.size > 0) {
                    chat.lastMessage = "@${ch.username}"
                }
                rows.add(chat)
            }
            launch {
                this._recommendedChannelsCache = rows
                this._recommendedChannelsLoaded = true
                this.channelsPaneRecommended = this.filterRecommendedChannels(needle, joinedIds)
                this.isLoadingChannelsPane = false
                Hilog.info(0, "CjTelegram", "[ChatListVM] channels pane joined=${joined.size} recommended=${this.channelsPaneRecommended.size}")
            }
        }
    }

    private func filterRecommendedChannels(needle: String, joinedIds: HashSet<Int64>): ArrayList<Chat> {
        let out = ArrayList<Chat>()
        for (c in this._recommendedChannelsCache) {
            if (joinedIds.contains(c.id)) { continue }
            if (needle.size > 0 && !c.name.toAsciiLower().contains(needle) && !c.username.toAsciiLower().contains(needle)) { continue }
            out.add(c)
        }
        return out
    }

    /**
     * P2-102: 全局 peer 搜索（contacts.search#05f58d0f → contacts.found#b3134d9d）
     *
     * 对应 iOS ChatListSearchContainerNode 的 globalSearch 标签页——
     * 通过 contacts.search TL 在服务端搜索匹配的用户/群组/频道。
     * 与 searchGlobal()（messages.searchGlobal，消息维度）互为补充：
     *   - searchGlobalPeers: peer 名称/username 搜索 → globalPeerSearchResults
     *   - searchGlobal:     消息文本内容搜索     → globalSearchResults
     *
     * RPC 在 spawn{} 内执行（网络操作不阻塞 UI 线程），
     * 状态回写走 launch{} 确保在主线程更新 @Publish 字段（S-001 合规）。
     *
     * TL 调用链:
     *   searchGlobalPeers(query)
     *     → spawn → getMTProtoClient().sendRequest(ContactsSearch.toBytes())
     *     → ContactsFoundResponse.deserialize()
     *     → launch { globalPeerSearchResults = ... }
     *
     * contacts.search#05f58d0f  (iOS Api42.swift:4927 appendInt32(99978511) == 0x05f58d0f)
     * contacts.found#b3134d9d  (iOS Api9.swift, TLResponses.cj:840 verified)
     */
    public func searchGlobalPeers(query: String): Unit {
        if (query.isEmpty()) {
            this.globalPeerSearchResults = ArrayList<Chat>()
            this.isSearchingPeers = false
            this._lastPeerSearchQuery = ""
            return
        }
        if (query == this._lastPeerSearchQuery) { return }
        this._lastPeerSearchQuery = query
        this.isSearchingPeers = true
        let queryCopy = query
        spawn {
            try {
                let client = getMTProtoClient()
                let req = ContactsSearch()
                req.q = queryCopy
                // iOS _internal_searchPeers: contacts.search(flags: 0, q:, limit: 20)
                req.limit = 20

                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobalPeers: q='${queryCopy}'")
                let responseData = client.sendRequest(req.toBytes())
                if (responseData.size < 8) {
                    launch { this.isSearchingPeers = false }
                    return
                }

                // RPC error check
                let checkD = TLDeserializer(responseData)
                let checkCtor = checkD.readUInt32()
                if (checkCtor == TLConstructors.RPC_ERROR || checkCtor == 0x2144ca19) {
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobalPeers RPC error: ${errCode} ${errMsg}")
                    launch { this.isSearchingPeers = false }
                    return
                }

                let response = ContactsFoundResponse.deserialize(responseData)
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobalPeers: my=${response.myResults.size} results=${response.results.size} ${response.users.size} users, ${response.chats.size} chats")

                let chatListSvc = getRealChatListService()
                let photoSvc = getUserPhotoService()
                // 先把 chats/users 建成 id → Chat，再按 my_results、results 的服务端顺序取出
                // （iOS SearchPeers.swift _internal_searchPeers：renderedMyPeers / renderedPeers 均按
                // Peer 列表顺序从 AccumulatedPeers 取；ChatListSearchListPaneNode 先列 my_results 再列 results）。
                // 此前按 users 在前、chats 在后拼接，服务端排在前面的频道（@telegram 等）被一串 bot 挤到后面。
                let userMap = HashMap<Int64, Chat>()
                for (u in response.users) {
                    if (u.isEmpty || u.isSelf) { continue }
                    // 点结果要能直接打开会话 / 资料：access hash 与头像元数据必须入缓存
                    // （对位 iOS 搜索结果 peer 先写入 Postbox 再 openPeer）。
                    chatListSvc.cacheUserResponse(u)
                    let chat = Chat()
                    chat.id = u.id
                    var name = u.firstName
                    if (u.lastName.size > 0) { name = "${name} ${u.lastName}" }
                    chat.name = name
                    // 与 getDialogs 同一 peerType 约定（Peer.type_：user/chat/channel），bot 以 isBot 标记，
                    // 否则 ChatRoomPage 用 "bot"/"group" 构不出 InputPeer。
                    chat.peerType = "user"
                    chat.isBot = u.isBot
                    chat.isVerified = u.isVerified
                    chat.username = u.username
                    chat.avatarText = if (name.size > 0) { name.toRuneArray()[0].toString() } else { "?" }
                    chat.avatarLocalPath = photoSvc.getUserPhotoPath(u.id)
                    chat.lastMessage = if (u.username.size > 0) { "@${u.username}" } else { "" }
                    userMap[u.id] = chat
                }
                let chatMap = HashMap<Int64, Chat>()
                for (ch in response.chats) {
                    // iOS：group.migrationReference != nil 的旧群不列出
                    if (ch.isMigrated) { continue }
                    chatListSvc.cacheChatResponse(ch)
                    let chat = Chat()
                    chat.id = ch.id
                    chat.name = ch.title
                    chat.peerType = if (ch.isChannel) { "channel" } else { "chat" }
                    chat.username = ch.username
                    chat.avatarText = if (ch.title.size > 0) { ch.title.toRuneArray()[0].toString() } else { "?" }
                    chat.isChannel = ch.isChannel
                    chat.isMegagroup = ch.isMegagroup
                    chat.isGroup = !ch.isChannel || ch.isMegagroup
                    chat.isVerified = ch.isVerified
                    chat.participantsCount = Int64(ch.participantsCount)
                    chat.avatarLocalPath = photoSvc.getChatPhotoPath(ch.id)
                    // iOS ChatListSearchListPaneNode globalPeer：「@username, N subscribers / members」
                    var subtitle = if (ch.username.size > 0) { "@${ch.username}" } else { "" }
                    if (ch.participantsCount > 0) {
                        let noun = if (ch.isChannel && !ch.isMegagroup) { "subscribers" } else { "members" }
                        let countText = "${groupSearchCountDigits(Int64(ch.participantsCount))} ${noun}"
                        subtitle = if (subtitle.size > 0) { "${subtitle}, ${countText}" } else { countText }
                    }
                    chat.lastMessage = subtitle
                    chatMap[ch.id] = chat
                }
                let results = ArrayList<Chat>()
                let seenKeys = HashSet<String>()
                for (peers in [response.myResults, response.results]) {
                    for (p in peers) {
                        let key = "${p.type_}_${p.id}"
                        if (seenKeys.contains(key)) { continue }
                        let found: Option<Chat> = if (p.type_ == "user") { userMap.get(p.id) } else { chatMap.get(p.id) }
                        match (found) {
                            case Some(c) =>
                                seenKeys.add(key)
                                results.add(c)
                            case None => ()
                        }
                    }
                }

                launch {
                    if (queryCopy == this._lastPeerSearchQuery) {
                        // iOS ChatListSearchListPaneNode：已出现在本地会话段的 peer 不在全局段重复列出。
                        let localIds = HashSet<Int64>()
                        for (c in this.getFilteredChats()) { localIds.add(c.id) }
                        let deduped = ArrayList<Chat>()
                        for (r in results) {
                            if (!localIds.contains(r.id)) { deduped.add(r) }
                        }
                        this.globalPeerSearchResults = deduped
                    }
                    this.isSearchingPeers = false
                }
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobalPeers: ${results.size} results")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChatListVM] searchGlobalPeers error: ${e}")
                launch { this.isSearchingPeers = false }
            }
        }
    }

    /**
     * 重置所有搜索状态（搜索框清空时调用）
     */
    public func clearSearch(): Unit {
        this.searchKeyword = ""
        this.globalSearchResults = ArrayList<Chat>()
        this.globalPeerSearchResults = ArrayList<Chat>()
        this.isSearching = false
        this.isSearchingPeers = false
        this._lastSearchQuery = ""
        this._lastPeerSearchQuery = ""
        this.publicPostResults = ArrayList<Chat>()
        this.isSearchingPublicPosts = false
        this._lastPublicPostsQuery = ""
        this.filterSearchResults = ArrayList<Chat>()
        this.isSearchingFilter = false
        this._lastFilterSearchKey = ""
        this.publishCurrentChatList("clearSearch")
    }

    /**
     * 根据 ID 获取聊天
     */
    public func getChatById(chatId: Int64): Option<Chat> {
        for (chat in this.chatList) {
            if (chat.id == chatId) {
                return Some(chat)
            }
        }
        return None<Chat>
    }

    // ==================== P2-107: 批量操作（多选编辑模式） ====================

    /**
     * P2-107: 批量标记已读（遍历选中集，复用单项 toggleMarkUnread，对有未读的对话标记已读）
     * RPC 在 spawn{} 内循环执行，@Publish 回写走 launch{}（S-001 合规）。
     */
    public func batchMarkAsRead(chatIds: ArrayList<Int64>): Unit {
        let idsCopy = ArrayList<Int64>()
        for (cid in chatIds) { idsCopy.add(cid) }
        spawn {
            for (cid in idsCopy) {
                var peerTypeStr = "user"
                var hasUnread = false
                for (c in this.chatList) {
                    if (c.id == cid) {
                        peerTypeStr = c.peerType
                        hasUnread = c.unreadCount > 0
                        break
                    }
                }
                if (hasUnread) {
                    let pt = peerTypeStr
                    let ci = cid
                    try {
                        let svc = getRealChatListService()
                        let ok = svc.markDialogAsRead(pt, ci)
                        Hilog.info(0, "CjTelegram", "[ChatListVM] batchMarkAsRead chatId=${ci} ok=${ok}")
                        if (ok) {
                            let newList = ArrayList<Chat>()
                            for (c in this.chatList) {
                                if (c.id == ci) { c.unreadCount = 0; c.isMarkedUnread = false }  // M-2e
                                newList.add(c)
                            }
                            launch {
                                this.chatList = newList
                                this.publishCurrentChatList("batchRead")
                            }
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatListVM] batchMarkAsRead failed chatId=${ci}: ${e}")
                    }
                }
            }
        }
    }

    /**
     * P2-107: 批量静音（遍历选中集，对未静音的对话执行静音 RPC）
     * RPC 在 spawn{} 内循环执行，@Publish 回写走 launch{}（S-001 合规）。
     */
    public func batchMute(chatIds: ArrayList<Int64>): Unit {
        let idsCopy = ArrayList<Int64>()
        for (cid in chatIds) { idsCopy.add(cid) }
        spawn {
            for (cid in idsCopy) {
                var peerTypeStr = "user"
                var alreadyMuted = false
                for (c in this.chatList) {
                    if (c.id == cid) {
                        peerTypeStr = c.peerType
                        alreadyMuted = c.isMuted
                        break
                    }
                }
                if (!alreadyMuted) {
                    let pt = peerTypeStr
                    let ci = cid
                    try {
                        let svc = getRealChatListService()
                        let ok = svc.toggleMuteDialog(pt, ci, true)
                        Hilog.info(0, "CjTelegram", "[ChatListVM] batchMute chatId=${ci} ok=${ok}")
                        if (ok) {
                            let newList = ArrayList<Chat>()
                            for (c in this.chatList) {
                                if (c.id == ci) { c.isMuted = true }
                                newList.add(c)
                            }
                            launch {
                                this.chatList = newList
                                this.publishCurrentChatList("batchMute")
                            }
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatListVM] batchMute failed chatId=${ci}: ${e}")
                    }
                }
            }
        }
    }

    /**
     * P2-107: 批量归档（遍历选中集，对主列表对话执行归档 RPC）
     * RPC 在 spawn{} 内循环执行，@Publish 回写走 launch{}（S-001 合规）。
     */
    public func batchArchive(chatIds: ArrayList<Int64>): Unit {
        let idsCopy = ArrayList<Int64>()
        for (cid in chatIds) { idsCopy.add(cid) }
        spawn {
            for (cid in idsCopy) {
                var peerTypeStr = "user"
                var foundInMain = false
                var foundChatOpt: Option<Chat> = None
                for (c in this.chatList) {
                    if (c.id == cid) {
                        peerTypeStr = c.peerType
                        foundInMain = true
                        foundChatOpt = Some(c)
                        break
                    }
                }
                if (foundInMain) {
                    let pt = peerTypeStr
                    let ci = cid
                    let fc = foundChatOpt
                    try {
                        let svc = getRealChatListService()
                        let ok = svc.archiveChat(pt, ci)
                        Hilog.info(0, "CjTelegram", "[ChatListVM] batchArchive chatId=${ci} ok=${ok}")
                        if (ok) {
                            let newMain = ArrayList<Chat>()
                            for (c in this.chatList) {
                                if (c.id != ci) { newMain.add(c) }
                            }
                            // 3c 返修：同形态原地 add() 一并改为整体重新赋值（修法 A 波及处）。
                            let newArchive = ArrayList<Chat>()
                            for (c in this.archiveChatList) {
                                newArchive.add(c)
                            }
                            match (fc) {
                                case Some(ac) => newArchive.add(ac)
                                case None => ()
                            }
                            launch {
                                this.chatList = newMain
                                this.archiveChatList = newArchive
                                this.publishCurrentChatList("batchArchive")
                            }
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[ChatListVM] batchArchive failed chatId=${ci}: ${e}")
                    }
                }
            }
        }
    }

    /**
     * R-128 修复（原 batchDelete 无 undo 状态机，TC-0012 归因为 product_issue）：
     * 批量删除 + undo toast（iOS ChatListController.swift:5008-5060 DeleteForAll 分支语义）。
     *
     * 与单聊 schedulePeerChatRemoval() 同一"乐观移除 + 延迟提交"模型，批量场景下整批恢复/整批提交：
     *   1. 乐观：立即从本地列表移除所有选中对话（UI 即刻反馈，与 iOS pendingRemovalItemIds 语义对应）
     *   2. 5s 内点 Undo → 整批恢复（按原顺序重新插回，与 iOS state.pendingRemovalItemIds.remove 对应）
     *   3. 5s 到 onCommit → 才真正对每个 peerId 提交 deleteDialog RPC（与 iOS removePeerChats 对应）
     *
     * 注：iOS 源批量删除分支本身没有二次" This cannot be undone"确认弹窗——直接进 undo overlay；
     * UI 层 ChatListPage.doBatchDeleteConfirmed() 保留的二次确认仅作误触防护，文案已改为可撤销语义。
     */
    public func batchDeleteWithUndo(chatIds: ArrayList<Int64>, revokeUsers!: Bool = false): Unit {
        let idsCopy = ArrayList<Int64>()
        for (cid in chatIds) { idsCopy.add(cid) }
        if (idsCopy.isEmpty()) { return }

        // 在乐观移除前，先从主列表构建 peerType 快照（channel/group 在主列表，归档列表查不到）
        let peerTypeSnapshot = HashMap<Int64, String>()
        for (c in this.chatList) {
            for (cid in idsCopy) {
                if (c.id == cid) { peerTypeSnapshot[cid] = c.peerType; break }
            }
        }
        // 归档内多选删除：peerType 同样要能取到，并从归档列表乐观移除
        let removedArchived = ArrayList<Chat>()
        let keptArchived = ArrayList<Chat>()
        for (c in this.archiveChatList) {
            if (idsCopy.contains(c.id)) {
                peerTypeSnapshot[c.id] = c.peerType
                removedArchived.add(c)
            } else {
                keptArchived.add(c)
            }
        }
        if (!removedArchived.isEmpty()) { this.archiveChatList = keptArchived }

        // 保存被移除的 Chat 对象快照（按原列表相对顺序），供 undo 时整批恢复
        let removedChats = ArrayList<Chat>()
        for (c in this.chatList) {
            for (cid in idsCopy) {
                if (c.id == cid) { removedChats.add(c); break }
            }
        }

        // 乐观：立即从本地列表移除所有选中对话
        let newList = ArrayList<Chat>()
        for (c in this.chatList) {
            var shouldRemove = false
            for (cid in idsCopy) {
                if (c.id == cid) { shouldRemove = true; break }
            }
            if (!shouldRemove) { newList.add(c) }
        }
        this.chatList = newList
        // 同 schedulePeerChatRemoval：撤销窗口与退群服务消息都不得把这些会话放回列表。
        for (cid in idsCopy) {
            let t = match (peerTypeSnapshot.get(cid)) { case Some(v) => v; case None => "user" }
            getRealChatListService().markDialogRemoved(normalizeDialogPeerType(t), cid)
        }
        this.publishCurrentChatList("batchDeleteOptimistic")

        let removedSnapshot = removedChats
        let count = idsCopy.size
        // iOS ChatList_DeletedChats（"Deleted 1 chat" / "Deleted %@ chats"）
        let toastText = if (count > 1) { "Deleted ${count} chats" } else { "Deleted 1 chat" }

        let svc = getUndoToastService()
        svc.showUndo(
            toastText,
            actionText: "Undo",
            durationMs: 5000,
            onUndo: { =>
                // 整批恢复：按原相对顺序把被移除的 chat 重新插回列表头部
                Hilog.info(0, "CjTelegram", "[ChatListVM] undo batchDelete count=${removedSnapshot.size}")
                for (cid in idsCopy) {
                    let t = match (peerTypeSnapshot.get(cid)) { case Some(v) => v; case None => "user" }
                    getRealChatListService().clearDialogRemoved(normalizeDialogPeerType(t), cid)
                }
                let restored = ArrayList<Chat>()
                for (c in removedSnapshot) { restored.add(c) }
                for (c in this.chatList) { restored.add(c) }
                let restoredArchive = ArrayList<Chat>()
                for (c in removedArchived) { restoredArchive.add(c) }
                for (c in this.archiveChatList) { restoredArchive.add(c) }
                launch {
                    this.chatList = restored
                    if (!removedArchived.isEmpty()) { this.archiveChatList = restoredArchive }
                    this.publishCurrentChatList("batchDeleteUndo")
                }
            },
            onCommit: { =>
                // 5s 后才真正逐个提交删除 RPC
                Hilog.info(0, "CjTelegram", "[ChatListVM] batchDelete committed count=${idsCopy.size}")
                spawn {
                    for (cid in idsCopy) {
                        var peerTypeStr = match (peerTypeSnapshot.get(cid)) {
                            case Some(pt) => pt
                            case None => "user"
                        }
                        let pt = peerTypeStr
                        let ci = cid
                        try {
                            let chatSvc = getRealChatListService()
                            let ok = chatSvc.deleteDialog(pt, ci, revokeUserHistory: revokeUsers)
                            Hilog.info(0, "CjTelegram", "[ChatListVM] batchDelete chatId=${ci} ok=${ok}")
                            if (!ok || normalizeDialogPeerType(pt) == "user") {
                                chatSvc.clearDialogRemoved(normalizeDialogPeerType(pt), ci)
                            }
                        } catch (e: Exception) {
                            getRealChatListService().clearDialogRemoved(normalizeDialogPeerType(pt), ci)
                            Hilog.info(0, "CjTelegram", "[ChatListVM] batchDelete failed chatId=${ci}: ${e}")
                        }
                    }
                }
            }
        )
    }
}

/**
 * messages.Messages → 搜索结果行（每条消息一行，对位 iOS ChatListSearchEntry.message）。
 * 行携带 searchMessageId，供点按 / View in Chat 定位；peer 的 access hash 同时入缓存，
 * 未加入的公开频道也能直接打开。
 */
func buildMessageSearchRows(response: MessagesHistoryResponse, summary!: String = ""): ArrayList<Chat> {
    let userMap = HashMap<Int64, String>()
    for (u in response.users) {
        var name = u.firstName
        if (u.lastName.size > 0) { name = "${name} ${u.lastName}" }
        userMap[u.id] = name
        if (u.accessHash != 0) { getRealMessageService().cacheUserAccessHash(u.id, u.accessHash) }
    }
    let chatMap = HashMap<Int64, String>()
    let chatTypeMap = HashMap<Int64, String>()
    let chatUsernameMap = HashMap<Int64, String>()
    let chatMegagroupMap = HashMap<Int64, Bool>()
    for (ch in response.chats) {
        chatMap[ch.id] = ch.title
        chatTypeMap[ch.id] = if (ch.isChannel) { "channel" } else { "chat" }
        chatUsernameMap[ch.id] = ch.username
        chatMegagroupMap[ch.id] = ch.isMegagroup
        getRealChatListService().cacheChatResponse(ch)
    }
    let rows = ArrayList<Chat>()
    for (msg in response.messages) {
        if (msg.isEmpty) { continue }
        let peerId = msg.peerId.id
        let chat = Chat()
        chat.id = peerId
        if (chatMap.contains(peerId)) {
            chat.name = chatMap[peerId]
            chat.peerType = chatTypeMap[peerId]
            chat.isChannel = chat.peerType == "channel"
            chat.isMegagroup = chatMegagroupMap[peerId]
            chat.isGroup = !chat.isChannel || chat.isMegagroup
            chat.username = chatUsernameMap[peerId]
            chat.avatarLocalPath = getUserPhotoService().getChatPhotoPath(peerId)
        } else if (userMap.contains(peerId)) {
            chat.name = userMap[peerId]
            chat.peerType = "user"
            chat.avatarLocalPath = getUserPhotoService().getUserPhotoPath(peerId)
        } else {
            chat.name = "Chat ${peerId}"
            chat.peerType = "user"
        }
        chat.lastMessage = searchRowSummary(msg, summary)
        chat.lastMessageTimestamp = Int64(msg.date)
        chat.searchMessageId = Int64(msg.id)
        chat.avatarText = if (chat.name.size > 0) { chat.name.toRuneArray()[0].toString() } else { "?" }
        rows.add(chat)
    }
    return rows
}

/** 分类标签结果行的第二行文字：链接给标题/网址，音乐给「标题 — 演唱者」，文件给文件名，语音给时长。 */
func searchRowSummary(msg: TLMessage, summary: String): String {
    let fallback = if (msg.message.size > 0) { msg.message } else { msg.mediaDescription }
    match (summary) {
        case "links" =>
            if (msg.webPageTitle.size > 0 && msg.webPageUrl.size > 0) { return "${msg.webPageTitle}\n${msg.webPageUrl}" }
            if (msg.webPageUrl.size > 0) { return msg.webPageUrl }
            return fallback
        case "music" =>
            if (msg.audioTitle.size > 0 && msg.audioPerformer.size > 0) { return "${msg.audioTitle} — ${msg.audioPerformer}" }
            if (msg.audioTitle.size > 0) { return msg.audioTitle }
            if (msg.documentFileName.size > 0) { return msg.documentFileName }
            return fallback
        case "files" =>
            if (msg.documentFileName.size > 0) { return msg.documentFileName }
            return fallback
        case "voice" =>
            let d = if (msg.audioDuration > 0) { msg.audioDuration } else { msg.videoDuration }
            let label = if (msg.mediaType == "video" || msg.mediaType == "round") { "Video Message" } else { "Voice Message" }
            if (d > 0) {
                let secs = d % 60
                let pad = if (secs < 10) { "0" } else { "" }
                return "${label}, ${d / 60}:${pad}${secs}"
            }
            return label
        case "media" =>
            if (msg.mediaDescription.size > 0) { return msg.mediaDescription }
            return fallback
        case _ => return fallback
    }
}

func triggerFullPhotoDownloads(dialogs: ArrayList<Chat>): Unit {
    let userIds = ArrayList<Int64>()
    let chatIds = ArrayList<Int64>()
    for (chat in dialogs) {
        if (chat.peerType == "user" && chat.id > 0) {
            userIds.add(chat.id)
        } else if ((chat.peerType == "chat" || chat.peerType == "channel") && chat.id > 0) {
            chatIds.add(chat.id)
        }
    }
    if (!userIds.isEmpty()) {
        getUserPhotoService().requestFullPhotosForUsers(userIds)
    }
    if (!chatIds.isEmpty()) {
        getUserPhotoService().requestFullPhotosForChats(chatIds)
    }
}

/** 千分位分组（iOS 搜索结果副标题 "9,476,239 subscribers"） */
func groupSearchCountDigits(value: Int64): String {
    let raw = value.toString().toRuneArray()
    var out = ""
    let n = raw.size
    for (i in 0..n) {
        if (i > 0 && (n - i) % 3 == 0) { out = out + "," }
        out = out + raw[i].toString()
    }
    return out
}

private func containsDialogPeer(list: ArrayList<Chat>, chat: Chat): Bool {
    for (c in list) {
        if (isSameDialogPeer(c.peerType, c.id, chat.peerType, chat.id)) { return true }
    }
    return false
}
