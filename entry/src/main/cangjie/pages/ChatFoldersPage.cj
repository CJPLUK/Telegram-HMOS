package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.random.Random
import ohos_app_cangjie_entry.models.ChatFolder
import ohos_app_cangjie_entry.models.ExportedChatFolderLink
import ohos_app_cangjie_entry.models.FolderShareablePeer
import ohos_app_cangjie_entry.services.getChatFolderLinksService
import ohos_app_cangjie_entry.services.getUndoToastService
import ohos_app_cangjie_entry.services.getChatListFilterSettingsHeaderService
import ohos_app_cangjie_entry.services.getRealChatListService
import ohos_app_cangjie_entry.services.showToast
import ohos_app_cangjie_entry.viewmodels.getChatListVM
import ohos_app_cangjie_entry.services.getTelegramEngineDataService
import ohos_app_cangjie_entry.services.JsonParser
import ohos_app_cangjie_entry.components.ChatListFilterSettingsHeaderComponent
import ohos_app_cangjie_entry.components.{itemListPageBackgroundColor, itemListCardColor}
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 聊天文件夹页面（Phase E4 + P2-174 folder invite links + TC-0015 文件夹重排）
 *
 * 新增 P2-174 gaps:
 *   ① chatlists.exportChatlistInvite — 创建 folder 邀请链接（含 peer 多选）
 *   ② chatlists.editExportedInvite  — 编辑/撤销已有链接
 *   ③ chatlists.getExportedInvites  — 列举 folder 全部邀请链接
 *   ④ chatlists.deleteExportedInvite — 删除链接
 *   ⑤ ExportedChatFolderLink 模型解析（title/url/peers/isRevoked）
 *   ⑥ peer 多选 + 全选（forEachFolder 内可分享的 peer）
 *   ⑦ 不可用 peer 灰显（isAvailable=false 时 fontColor 灰并 enabled(false)）
 *
 * TC-0014/TC-0015 (clist_filter_preset_editor 返修 round3，diag-suite_chat_list_folders-TC-0014.md
 *   与 diag-suite_chat_list_folders-TC-0015.md 归因的 3 个子缺陷):
 *   ① Premium 文件夹数量 gate 完全缺失 —— 创建/添加文件夹路径无数量校验，非会员可无限建
 *      文件夹（round3 修复：自定义文件夹数量（不含 All Chats，对齐 iOS 排除口径）达到
 *      FREE_FOLDER_LIMIT 时阻断并跳转 PremiumLimitUpsellPage）。
 *   ② 合法重排 commit 但列表视图不刷新 —— moveFolder() 对 this.folders 整体重赋值未触发
 *      ForEach 刷新（round3 修复：ForEach(this.folders,...) 显式提供 keyGeneratorFunc，使用
 *      folder.id 派生键值，避免默认键值生成规则在"相同对象引用仅调整顺序"场景下判定为
 *      无变化——参见 CangjieUI ForEach 文档"数组项是对象数据类型的情况下，不建议用内容
 *      相同的数组项替换旧的数组项"）。
 *   ③ 文件夹不持久化 —— ensureLoaded() 每次硬编码重建空白状态，从未调用已存在的
 *      messages.getDialogFilters 加载能力（round3 修复：改为优先同步读取
 *      RealChatListService 内存缓存（getDialogFilters()，非阻塞），缓存为空时先展示默认
 *      All Chats 状态，再异步走 ChatListFilterSettingsHeaderService.fetchFiltersFromServer()
 *      拉取服务端真实数据回填，S-001 合规，不阻塞 onAppear 主线程）。
 *
 * TC-0015 (clist_filter_preset_editor 返修 round2) — 文件夹拖拽重排:
 *   iOS ref: ChatListFilterTabContainerNode.swift（拖拽核心）+
 *            ChatListFilterPresetListController.swift:783-804（premium 门禁）+
 *            ChatListFiltering.swift:549/1599（updateDialogFiltersOrder 持久化）
 *   HarmonyOS ArkUI ListItem 无 onDragStart/onDrop 绑定（同 StickersSettingsPage.movePack /
 *   MediaPickerScreen 已验证结论），改用已在本仓库验证过的 tap-to-pick-and-place 两步点击方案：
 *     ① 点重排手柄选中该行（含 All Chats 行本身，round2 修正：手柄不再对 All Chats 隐藏）
 *        → ② 点目标行位置 → 执行 moveFolder(from, to)
 *   iOS 真实行为是"允许尝试移动、松手提交时才校验"，不是"从源头阻止尝试"：
 *     - 提交后计算新顺序，若 All Chats（filter id==0）被挤出首位（newOrder.first.id != 0）
 *       且当前用户非 Premium（getAuthStorage().getUserData().isPremium）→
 *       回滚到 previousOrderIds 快照 + 弹 SubscribeToMoveAll Undo 提示（Action 跳 PremiumPage）；
 *     - 会员，或者 All Chats 仍在首位 → 应用新顺序 + spawn 异步调用
 *       messages.updateDialogFiltersOrder 持久化。
 *   round2 修正点：round1 用 folder.id!=0 把 All Chats 整行排除在重排手柄之外，
 *   导致 toIdx==0 分支永远不可达（死代码）。现在手柄对所有行渲染，All Chats 本身
 *   也可被拿起/被作为目标槽，违规路径可真正触发。
 *
 * TC-0014 (clist_filter_preset_editor 返修：服务端一致性 fidelity 缺陷，
 *   diag-suite_chat_list_folders-TC-0014.md 白盒代码巡检发现):
 *   round3 引入的 blockIfFolderLimitReached() 用客户端硬编码常量 FREE_FOLDER_LIMIT=10
 *   做数量比较，服务端调整上限不会跟随生效。round1 修复：新增 resolveFolderLimit(isPremium)，
 *   从 help.getAppConfig 返回的 AppConfigData.configJson 里解析 dialog_filters_limit_default
 *   （非会员）/ dialog_filters_limit_premium（会员）两个字段，gate 按 isPremiumUser() 结果
 *   选取对应服务端值；appConfig 拿不到/字段缺失/非法值时兜底 FALLBACK_FREE_FOLDER_LIMIT=10 /
 *   FALLBACK_PREMIUM_FOLDER_LIMIT=20（与 iOS 默认值一致），保证离线/首次启动场景 gate 仍可用。
 *   会员分支不再无条件放行，同样按服务端 premium 上限阻断（对齐"上限恒由服务端驱动"语义）。
 *
 *   round2 修复（S-001/R-138 返修，上一轮复审驳回：round1 的 resolveFolderLimit() 在
 *   onClick 回调链路（commitCreateFolder/commitAddRecommendedFolder →
 *   blockIfFolderLimitReached → resolveFolderLimit）内**同步**调用
 *   getTelegramEngineDataService().getAppConfig()，该调用落到 MTProtoClient 的阻塞式
 *   RPC 等待（最坏 60 秒），用户点击"保存"/"添加"会冻结主线程）：
 *   拆成 prefetchFolderLimits()（页面进场时 ensureLoaded() 里 spawn{} 异步发起一次
 *   getAppConfig()，解析完成后 spawn(UIThread) 回写 folderLimitDefault/
 *   folderLimitPremium 两个 @State 字段）+ parseFolderLimitFromConfigJson()
 *   （纯本地字符串解析，无网络）。blockIfFolderLimitReached() 现在只读这两个
 *   @State 字段，onClick 链路全程无网络调用，立即返回。
 */

// TC-0014 round（服务端一致性 fidelity 返修）：文件夹数量上限本应由服务端
// help.getAppConfig 下发的 dialog_filters_limit_default（非会员）/
// dialog_filters_limit_premium（会员）驱动（对齐 iOS PremiumConfiguration /
// EngineConfiguration.UserLimits 消费 appConfig 的方式），不能是客户端硬编码常量。
// 以下两个 FALLBACK 常量只在 appConfig 尚未拉取成功 / 解析失败（离线、首次启动、
// 字段缺失）时使用，数值与 iOS 默认值一致，作为服务端不可用时的降级兜底，不是
// 正常路径的权威来源——正常路径必须走 prefetchFolderLimits()（进场异步预取）+
// parseFolderLimitFromConfigJson()（纯本地解析）读服务端配置，gate 本身只读
// 预取结果对应的 @State 字段（folderLimitDefault/folderLimitPremium）。
let FALLBACK_FREE_FOLDER_LIMIT: Int64 = 10
let FALLBACK_PREMIUM_FOLDER_LIMIT: Int64 = 20

@HybridComponentEntry
@Component
public class ChatFoldersPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false

    // 文件夹列表
    @State var folders: ArrayList<ChatFolder> = ArrayList<ChatFolder>()

    // 推荐文件夹
    @State var recommendedFolders: ArrayList<ChatFolder> = ArrayList<ChatFolder>()

    // 是否正在编辑
    @State var isEditing: Bool = false
    @State var revealedDeleteFolderId: Int32 = -1

    // 创建新文件夹面板状态
    @State var showCreatePanel: Bool = false
    @State var newFolderName: String = ""
    @State var showFolderTags: Bool = false

    // ==================== P2-174 邀请链接状态 ====================

    // 当前展开邀请链接管理面板的文件夹索引（-1 = 无）
    @State var expandedLinksFolderId: Int32 = -1

    // 当前展开文件夹的已导出邀请链接列表
    @State var folderLinks: ArrayList<ExportedChatFolderLink> = ArrayList<ExportedChatFolderLink>()

    // 正在加载链接
    @State var isLoadingLinks: Bool = false

    // 创建链接面板状态
    @State var showCreateLinkPanel: Bool = false
    @State var newLinkTitle: String = ""

    // peer 多选面板状态
    @State var showPeerSelection: Bool = false
    @State var shareablePeers: ArrayList<FolderShareablePeer> = ArrayList<FolderShareablePeer>()

    // ==================== TC-0015 文件夹重排状态 ====================

    // tap-to-pick-and-place 重排：待移动行的下标，-1 表示未选中
    // HarmonyOS ListItem 无 onDragStart/onDrop，使用两步点击替代（同 StickersSettingsPage 已验证方案）
    @State var dragFromIdx: Int64 = -1

    // S7-126 / S1-32：手柄真实拖动重排（对位 iOS ItemListController 的 reorder 手势）。
    // 与 ChatListPage.handlePinnedReorderTouch 同一套 onTouch 复刻：Down 记起点，Move 越过半行
    // 即与相邻行互换并把基准 Y 平移一行，Up 时若发生过互换则持久化并同步会话列表 tab 栏。
    // SDK 无 PanGesture，见 NotificationSoundSelectionPage.onHeaderTouch 头部注释。
    @State var dragFolderId: Int32 = -1
    @State var dragFolderOffsetY: Float64 = 0.0
    private var dragFolderLastY: Float64 = 0.0
    private var dragFolderMoved: Bool = false
    private var folderRowHeight: Float64 = 51.0

    // 重排前的顺序快照（供非会员违规回滚使用）；ArrayList<Int32> 存 folder.id 序列
    private var previousOrderIds: ArrayList<Int32> = ArrayList<Int32>()

    // ==================== TC-0014 round2 修复：文件夹数量上限预取状态 ====================
    // gate（blockIfFolderLimitReached/resolveFolderLimit）不得在 onClick 回调链路内
    // 同步发起网络 RPC（S-001/R-138）。改为进场时异步预取一次 appConfig 的
    // dialog_filters_limit_default/dialog_filters_limit_premium，写入以下两个 @State
    // 字段；gate 只读这两个本地字段，全程无网络调用。初值为 FALLBACK 常量，预取
    // 完成后（成功或字段缺失/非法都会覆盖为最终生效值）更新。
    @State var folderLimitDefault: Int64 = FALLBACK_FREE_FOLDER_LIMIT
    @State var folderLimitPremium: Int64 = FALLBACK_PREMIUM_FOLDER_LIMIT

    // TC-0541 C5：订已发布 snapshot，页 chrome 跟系统 Dark All day；禁止第二份快照 / 平行色表。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()

    // TC-0015 round5 修复：allocFolderId 不再用单调计数器（会命中服务端保留/非法区间，
    // 见下方 allocFolderId 文档），nextFolderId 字段整体移除，改为按需碰撞检测分配。

    /**
     * TC-0015 round5 修复（更深层根因）：filter id 必须落在服务端接受的合法区间，
     * 否则被拒 FILTER_ID_INVALID（真机 hilog 实证：round4 单调计数器从 1 分配，
     * 首个自建 filter 恒为 id=1，被服务端拒绝）。
     *
     * 对齐 iOS _internal_generateNewChatListFilterId
     * （ChatListFiltering.swift:1035-1042）：
     *   - id=0 保留给隐式 All Chats；
     *   - id=1 同样落在服务端保留/非法区间之外的合法起点是 2（iOS `2 + arc4random_uniform(255-2)`）；
     *   - 在 [2, 256) 区间内随机生成候选 id，对已存在的 folder id（this.folders，
     *     含服务端已加载的 filter）做碰撞检测，碰撞则重新生成。
     * 碰撞检测循环设置上限（254 次穷举 [2,256) 区间大小，超出仍未找到则说明该区间
     * 已被占满，属极端边界场景，退化为线性扫描兜底，避免死循环）。
     */
    private func allocFolderId(): Int32 {
        let rng = Random()
        var attempt: Int64 = 0
        while (attempt < 254) {
            // nextInt32(upper) 返回 [0, upper)，+2 平移到 [2, 256)
            let candidate = 2 + rng.nextInt32(254)
            if (!this.folderIdInUse(candidate)) {
                return candidate
            }
            attempt = attempt + 1
        }
        // 兜底：[2,256) 全部占满（254 个自定义文件夹，远超 FREE_FOLDER_LIMIT/Premium
        // 实际上限，理论不可达），线性扫描找第一个未占用 id，避免死循环。
        var fallback: Int32 = 2
        while (fallback < 256) {
            if (!this.folderIdInUse(fallback)) {
                return fallback
            }
            fallback = fallback + 1
        }
        return 255
    }

    /**
     * this.folders always carries the synthesized All Chats entry (id 0), so "no folders" in the
     * iOS sense means no entry besides it (ChatListFilterPresetListController.swift:270-275
     * actualFilters drops .allChats).
     */
    private func hasCustomFolders(): Bool {
        for (f in this.folders) {
            if (f.id != 0) {
                return true
            }
        }
        return false
    }

    /**
     * iOS ChatListFilterPresetListController.swift:287 — the All Chats / folder rows and the
     * "Tap 'Edit'" footer are listed only when folders exist or there are no recommendations.
     */
    private func showsFolderPresetList(): Bool {
        return this.hasCustomFolders() || this.recommendedFolders.isEmpty()
    }

    private func folderIdInUse(candidate: Int32): Bool {
        for (f in this.folders) {
            if (f.id == candidate) {
                return true
            }
        }
        return false
    }

    /**
     * 由一批加载到的 filters（不含/含 All Chats 均可）重建 this.folders。
     * All Chats（id==0）恒定存在且位于首位。
     * TC-0015 round5：不再维护 nextFolderId 单调计数基线（allocFolderId 改为
     * [2,256) 随机分配 + 碰撞检测，直接对 this.folders 做实时碰撞检测即可，
     * 无需额外维护 max+1 游标）。
     */
    private func applyLoadedFilters(loadedFilters: ArrayList<ChatFolder>): Unit {
        var hasAllChats = false
        for (folder in loadedFilters) {
            if (folder.id == 0) { hasAllChats = true }
        }
        let rebuilt = ArrayList<ChatFolder>()
        if (!hasAllChats) {
            let allChats = ChatFolder()
            allChats.id = 0
            allChats.name = "全部聊天"
            allChats.icon = "💬"
            allChats.filterType = "all"
            rebuilt.add(allChats)
        }
        for (f in loadedFilters) {
            rebuilt.add(f)
        }
        this.folders = rebuilt
    }

    /**
     * TC-0015 子缺陷3修复：持久化加载。
     * 复用已存在的能力：优先同步读取 RealChatListService 的内存缓存
     * （getRealChatListService().getDialogFilters()，非阻塞，无网络调用），而不是每次硬编码
     * 重建空白状态。缓存为空时（真正首次使用/冷启动）先展示默认 All Chats 单条状态，
     * 再异步调用 messages.getDialogFilters（ChatListFilterSettingsHeaderService
     * .fetchFiltersFromServer，走既有 spawn{}+spawn(UIThread) 模式，S-001 合规，不阻塞主线程）
     * 拉取服务端真实数据回填，避免同步网络调用卡住 onAppear。
     */
    private func loadPersistedFolders(): Unit {
        let cached = getRealChatListService().getDialogFilters()
        if (!cached.isEmpty()) {
            this.applyLoadedFilters(cached)
            Hilog.info(0, "CjTelegram", "[ChatFoldersPage] loadPersistedFolders: loaded ${cached.size} filters from cache")
            return
        }

        // 缓存为空：先展示默认状态，避免空白页
        let allChats = ChatFolder()
        allChats.id = 0
        allChats.name = "全部聊天"
        allChats.icon = "💬"
        allChats.filterType = "all"
        let initialFolders = ArrayList<ChatFolder>()
        initialFolders.add(allChats)
        this.folders = initialFolders

        // 异步向服务端拉取真实持久化数据（S-001: spawn 内网络调用 + spawn(UIThread) 回写 @State）
        spawn {
            =>
            let svc = getChatListFilterSettingsHeaderService()
            let fetched = svc.fetchFiltersFromServer()
            spawn(UIThread) {
                =>
                if (!fetched.isEmpty()) {
                    this.applyLoadedFilters(fetched)
                }
                Hilog.info(0, "CjTelegram", "[ChatFoldersPage] loadPersistedFolders: fetched ${fetched.size} filters from server")
            }
        }
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) {
            this.loadPersistedFolders()
            this.showFolderTags = getChatListFilterSettingsHeaderService().tagsEnabled()
            return
        }
        this.loaded = true

        // TC-0015 子缺陷3: 从已存在的 getDialogFilters 能力加载真实文件夹，而非硬编码重建
        this.loadPersistedFolders()
        this.showFolderTags = getChatListFilterSettingsHeaderService().tagsEnabled()

        // TC-0014 round2 修复：进场异步预取文件夹数量上限（S-001/R-138 合规，
        // 不阻塞 onAppear/onClick）。gate（blockIfFolderLimitReached）只读预取结果。
        this.prefetchFolderLimits()

        this.fetchRecommendedFolders()
    }

    private func sameFolderRules(lhs: ChatFolder, rhs: ChatFolder): Bool {
        if (lhs.includeContacts != rhs.includeContacts || lhs.includeNonContacts != rhs.includeNonContacts ||
            lhs.includeGroups != rhs.includeGroups || lhs.includeChannels != rhs.includeChannels ||
            lhs.includeBots != rhs.includeBots || lhs.excludeMuted != rhs.excludeMuted ||
            lhs.excludeRead != rhs.excludeRead || lhs.excludeArchived != rhs.excludeArchived ||
            lhs.includePeers.size != rhs.includePeers.size || lhs.excludePeers.size != rhs.excludePeers.size) {
            return false
        }
        for (id in lhs.includePeers) { if (!rhs.includePeers.contains(id)) { return false } }
        for (id in lhs.excludePeers) { if (!rhs.excludePeers.contains(id)) { return false } }
        return true
    }

    private func fetchRecommendedFolders(): Unit {
        spawn {
            =>
            let suggested = getChatListFilterSettingsHeaderService().fetchSuggestedFiltersFromServer()
            spawn(UIThread) {
                =>
                let visible = ArrayList<ChatFolder>()
                for (candidate in suggested) {
                    var duplicate = false
                    for (existing in this.folders) {
                        if (existing.id != 0 && this.sameFolderRules(candidate, existing)) { duplicate = true }
                    }
                    if (!duplicate) { visible.add(candidate) }
                }
                this.recommendedFolders = visible
                Hilog.info(0, "CjTelegram", "[ChatFoldersPage] recommended=${visible.size} customFolders=${this.hasCustomFolders()} addCustomFolderRow=${!visible.isEmpty() && !this.hasCustomFolders()}")
            }
        }
    }

    // ==================== TC-0015 文件夹重排核心逻辑 ====================

    /**
     * 当前用户是否为 Premium 会员（AuthStorage 持久化，同步读取）
     */
    private func isPremiumUser(): Bool {
        match (getAuthStorage().getUserData()) {
            case Some(user) => user.isPremium
            case None => false
        }
    }

    /**
     * TC-0014 round2 修复（S-001/R-138 返修，上一轮复审驳回理由：round1 把
     * resolveFolderLimit 实现成在 onClick 链路内同步调用 getAppConfig()，该调用
     * 落到 MTProtoClient.sendRequest()→sendRPCRequestConcurrent() 的
     * rpcMonitor.wait(timeout: REQUEST_TIMEOUT=60000ms) 阻塞等待，构成 UI 线程被
     * 网络 RPC 阻塞的真实缺陷）。
     *
     * 本函数现在是**纯本地字符串解析**，不发起任何网络调用：给定已经取到手的
     * configJson（由 prefetchFolderLimits() 在进场 spawn{} 里异步拿到后传入），
     * 用仓内既有 JsonParser 解析出 dialog_filters_limit_default /
     * dialog_filters_limit_premium 对应字段。字段缺失/值非法时返回 fallback。
     *
     * @param configJson  已经异步取到的 AppConfigData.configJson（可能是空串，
     *                    代表 appConfig 尚未拉到/拉取失败）
     * @param isPremium   要解析哪个字段（true=premium 字段，false=default 字段）
     * @param fallback    解析失败时的兜底值
     */
    private func parseFolderLimitFromConfigJson(configJson: String, isPremium: Bool, fallback: Int64): Int64 {
        if (configJson.size == 0) {
            Hilog.info(0, "CjTelegram",
                "[ChatFoldersPage] parseFolderLimitFromConfigJson: appConfig unavailable, fallback=${fallback} premium=${isPremium}")
            return fallback
        }
        let obj = JsonParser.parseObject(configJson)
        let fieldName = if (isPremium) { "dialog_filters_limit_premium" } else { "dialog_filters_limit_default" }
        if (!obj.has(fieldName)) {
            Hilog.info(0, "CjTelegram",
                "[ChatFoldersPage] parseFolderLimitFromConfigJson: field ${fieldName} missing in appConfig, fallback=${fallback} premium=${isPremium}")
            return fallback
        }
        let serverLimit = obj.getInt(fieldName)
        if (serverLimit <= 0) {
            Hilog.info(0, "CjTelegram",
                "[ChatFoldersPage] parseFolderLimitFromConfigJson: field ${fieldName} invalid value=${serverLimit}, fallback=${fallback} premium=${isPremium}")
            return fallback
        }
        return serverLimit
    }

    /**
     * TC-0014 round2 修复：页面进场异步预取一次 appConfig，解析出两档文件夹数量
     * 上限，写入 @State（folderLimitDefault/folderLimitPremium）。网络调用
     * （getTelegramEngineDataService().getAppConfig()，真实 help.getAppConfig RPC）
     * 全程在 spawn{} 里执行，不阻塞任何 UI 线程/onClick 回调；解析完成后回写
     * @State 切回 spawn(UIThread)（同文件 loadPersistedFolders/persistCreatedFolder
     * 等既有模式，S-001 合规）。
     *
     * gate（blockIfFolderLimitReached）本身不再调用本函数或 getAppConfig()，只读
     * 预取写好的 @State 字段——onClick 链路彻底无网络调用。
     */
    private func prefetchFolderLimits(): Unit {
        spawn {
            =>
            let appConfig = getTelegramEngineDataService().getAppConfig()
            let configJson = match (appConfig) {
                case Some(cfg) => cfg.configJson
                case None => ""
            }
            let resolvedDefault = this.parseFolderLimitFromConfigJson(configJson, false, FALLBACK_FREE_FOLDER_LIMIT)
            let resolvedPremium = this.parseFolderLimitFromConfigJson(configJson, true, FALLBACK_PREMIUM_FOLDER_LIMIT)
            spawn(UIThread) {
                =>
                this.folderLimitDefault = resolvedDefault
                this.folderLimitPremium = resolvedPremium
                Hilog.info(0, "CjTelegram",
                    "[ChatFoldersPage] prefetched folder limits default=${resolvedDefault} premium=${resolvedPremium}")
            }
        }
    }

    /**
     * TC-0014 子缺陷修复：创建/添加文件夹前的数量 gate。
     * 对齐 iOS ChatListFilterPresetListController.swift（addSuggestedPressed /
     * setupCreateFilterImpl 两处 gate，源码 :370-397,419-440）的 limit 校验语义：
     * `filters.filter { if case .allChats = filter.0 { return false }; return true }` ——
     * All Chats **不计入** limit 计数，只统计自定义文件夹数量。
     *
     * TC-0014 round2 修复（S-001/R-138）：gate 本身**只读**进场预取好的
     * @State 字段（folderLimitDefault/folderLimitPremium），全程不发起任何网络
     * 调用，onClick 回调链路（commitCreateFolder/commitAddRecommendedFolder →
     * blockIfFolderLimitReached）立即返回，不再有阻塞 UI 线程的风险。预取未完成
     * 时 @State 初值即 FALLBACK 常量，与 round1 的兜底语义一致。
     *
     * @return true 表示已阻断（调用方不应继续 add），false 表示放行
     */
    private func blockIfFolderLimitReached(): Bool {
        let isPremium = this.isPremiumUser()
        let limit = if (isPremium) { this.folderLimitPremium } else { this.folderLimitDefault }
        // 对齐 iOS：All Chats（id==0）不计入 limit 计数，只统计自定义文件夹
        var customFolderCount: Int64 = 0
        for (f in this.folders) {
            if (f.id != 0) {
                customFolderCount = customFolderCount + 1
            }
        }
        if (customFolderCount >= limit) {
            routerPush("PremiumLimitUpsellPage", "folders")
            Hilog.info(0, "CjTelegram",
                "[ChatFoldersPage] blockIfFolderLimitReached: premium=${isPremium} local dialog_filters_limit=${limit} (customFolderCount=${customFolderCount})")
            return true
        }
        return false
    }

    /**
     * TC-0015 round4 修复：新建/推荐添加文件夹提交后，比照 persistFolderOrder() 的
     * spawn{} 模式，异步调用 messages.updateDialogFilter 持久化该 filter 到服务端，
     * 使其能在 messages.getDialogFilters 中被拉回（跨重启保留）。
     * 本地状态已同步生效，此处仅做后台异步上报，不阻塞 UI（S-001 合规）。
     *
     * TC-0015 round5 修复（更深层根因）：round4 只记录 ok=false 到日志，UI 假装
     * "已创建"，用户被误导（真机 hilog 实证：服务端拒 FILTER_ID_INVALID，客户端
     * 自认 ok=false，但本地 this.folders 从不回滚）。现在：
     *   - ok=false 时，从 this.folders 移除该临时 folder（回滚乐观本地创建），
     *     恢复到持久化前的状态，避免"看起来已创建、实则服务端拒绝"的不一致假象；
     *   - 通过 showToast() 给用户可见的失败提示；
     *   - spawn{} 内网络调用完成后，回写 @State（this.folders）必须切回
     *     spawn(UIThread)（同文件 loadFolderLinks/doCreateLink 等既有模式，S-001 合规）。
     */
    private func persistCreatedFolder(folder: ChatFolder): Unit {
        spawn {
            =>
            let svc = getChatFolderLinksService()
            let ok = svc.updateDialogFilter(folder)
            Hilog.info(0, "CjTelegram", "[ChatFoldersPage] persistCreatedFolder id=${folder.id} ok=${ok}")
            spawn(UIThread) {
                =>
                if (ok) {
                    this.syncChatListFolders("created")
                    this.refetchChatListFolders()
                } else {
                    let remaining = ArrayList<ChatFolder>()
                    for (f in this.folders) {
                        if (f.id != folder.id) {
                            remaining.add(f)
                        }
                    }
                    this.folders = remaining
                    this.syncChatListFolders("createRollback")
                    this.fetchRecommendedFolders()
                    showToast("创建文件夹「${folder.name}」失败，请重试")
                    Hilog.info(0, "CjTelegram",
                        "[ChatFoldersPage] persistCreatedFolder rolled back local folder id=${folder.id} after server rejection")
                }
            }
        }
    }

    /**
     * TC-0014 修复：新建文件夹面板"保存"按钮提交逻辑，抽为独立方法（避免在 onClick 闭包内
     * 嵌套 if+for 触发 ArkUI 宏 "ForInExpr is not allowed in If" 限制）。
     * TC-0015 round4：提交后异步持久化到服务端（persistCreatedFolder），修复"创建从不
     * 持久化"缺陷。
     */
    private func commitCreateFolder(): Unit {
        if (this.blockIfFolderLimitReached()) {
            return
        }
        let name = this.newFolderName
        let newFolder = ChatFolder()
        newFolder.id = this.allocFolderId()
        newFolder.name = name
        newFolder.icon = "📁"
        newFolder.filterType = "custom"
        this.folders.add(newFolder)
        let updated = ArrayList<ChatFolder>()
        for (f in this.folders) {
            updated.add(f)
        }
        this.folders = updated
        this.showCreatePanel = false
        this.newFolderName = ""
        this.syncChatListFolders("createOptimistic")
        this.persistCreatedFolder(newFolder)
    }

    private func openCreateFolder(): Unit {
        if (this.blockIfFolderLimitReached()) { return }
        routerPush("ChatFolderEditorPage", "new")
    }

    private func deleteFolderAt(index: Int64, folder: ChatFolder): Unit {
        let cancel = AlertDialogButtonOptions(value: "Cancel", action: { => () })
        let remove = AlertDialogButtonOptions(value: "Remove", fontColor: 0xFFFF3B30, action: { =>
            // AlertDialog 的 action 回调不在 UI 更新链路里：直接改 @State 时列表不会重绘
            // （真机：删掉的行仍在，后续 minus/Delete 落到错位的行上）。与本文件其它异步回写一样
            // 切回 UIThread 再改 folders / revealedDeleteFolderId。按 id 而非下标摘除，避免错位。
            let removedId = folder.id
            spawn(UIThread) {
                =>
                let remaining = ArrayList<ChatFolder>()
                for (value in this.folders) {
                    if (value.id != removedId) { remaining.add(value) }
                }
                this.folders = remaining
                this.revealedDeleteFolderId = -1
                this.dragFromIdx = -1
                this.syncChatListFolders("delete")
                this.fetchRecommendedFolders()
                Hilog.info(0, "CjTelegram", "[ChatFoldersPage] folder removed locally id=${removedId} remaining=${remaining.size}")
            }
            spawn {
                =>
                let ok = getChatFolderLinksService().deleteDialogFilter(folder.id)
                Hilog.info(0, "CjTelegram", "[ChatFoldersPage] deleteDialogFilter id=${folder.id} ok=${ok}")
                spawn(UIThread) {
                    =>
                    if (ok) {
                        this.refetchChatListFolders()
                    } else {
                        let restored = ArrayList<ChatFolder>()
                        for (value in this.folders) { restored.add(value) }
                        if (index <= restored.size) { restored.add(folder, at: index) } else { restored.add(folder) }
                        this.folders = restored
                        this.syncChatListFolders("deleteRollback")
                        this.fetchRecommendedFolders()
                        showToast("Could not remove folder. Please try again.")
                    }
                }
            }
        })
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: "Remove Folder \"${folder.name}\"?",
            message: "This folder will be removed from all of your devices.",
            primaryButton: cancel,
            secondaryButton: remove,
            autoCancel: true
        ))
    }

    private func updateFolderTags(value: Bool): Unit {
        let previous = this.showFolderTags
        this.showFolderTags = value
        spawn {
            =>
            let ok = getChatFolderLinksService().toggleDialogFilterTags(value)
            if (!ok) { spawn(UIThread) { => this.showFolderTags = previous; showToast("Could not update folder tags.") } }
        }
    }

    /**
     * TC-0014 修复：推荐文件夹"添加"按钮提交逻辑，抽为独立方法（同上，避免在 onClick
     * 闭包内嵌套 if+for 触发 ArkUI 宏限制）。
     * TC-0015 round4：提交后异步持久化到服务端（persistCreatedFolder），修复"推荐添加
     * 从不持久化"缺陷。
     */
    private func commitAddRecommendedFolder(folder: ChatFolder, index: Int64): Unit {
        if (this.blockIfFolderLimitReached()) {
            return
        }
        let addedFolder = folder.copy()
        addedFolder.id = this.allocFolderId()
        this.folders.add(addedFolder)
        let newList = ArrayList<ChatFolder>()
        for (f in this.folders) {
            newList.add(f)
        }
        this.folders = newList

        let newRecommended = ArrayList<ChatFolder>()
        for (f in this.recommendedFolders) {
            if (!this.sameFolderRules(f, addedFolder)) { newRecommended.add(f) }
        }
        this.recommendedFolders = newRecommended

        Hilog.info(0, "CjTelegram", "[ChatFoldersPage] Added recommended folder: ${addedFolder.name}")
        // S7-127：会话列表 tab 立即出现（服务端确认后 refetch 校准；被拒则回滚并再同步）
        this.syncChatListFolders("addRecommendedOptimistic")
        this.persistCreatedFolder(addedFolder)
    }

    /**
     * 拍摄当前 folders 顺序快照（id 序列），供违规回滚使用
     */
    private func snapshotOrder(): ArrayList<Int32> {
        let snap = ArrayList<Int32>()
        for (f in this.folders) {
            snap.add(f.id)
        }
        return snap
    }

    /**
     * 上报重排后的顺序（messages.updateDialogFiltersOrder），本地已生效、后台异步上报
     */
    private func persistFolderOrder(): Unit {
        let orderIds = ArrayList<Int32>()
        for (f in this.folders) {
            orderIds.add(f.id)
        }
        spawn {
            =>
            let svc = getChatFolderLinksService()
            let ok = svc.updateDialogFiltersOrder(orderIds)
            Hilog.info(0, "CjTelegram", "[ChatFoldersPage] updateDialogFiltersOrder ok=${ok}")
            spawn(UIThread) {
                =>
                if (ok) {
                    this.refetchChatListFolders()
                } else {
                    showToast("Could not reorder folders. Please try again.")
                }
            }
        }
    }

    /**
     * 由 folder id 序列（previousOrderIds 快照）重建 this.folders，用于违规回滚。
     * 按快照里的 id 顺序，从当前 this.folders 中找回对应 ChatFolder 实例。
     */
    private func restoreFromOrderIds(orderIds: ArrayList<Int32>): Unit {
        let current = this.folders
        let restored = ArrayList<ChatFolder>()
        for (targetId in orderIds) {
            var i: Int64 = 0
            while (i < current.size) {
                if (current[i].id == targetId) {
                    restored.add(current[i])
                    break
                }
                i = i + 1
            }
        }
        this.folders = restored
    }

    /**
     * S1-32 / S7-126 / S7-127：文件夹本地改动后立即同步会话列表 tab 栏与
     * RealChatListService 缓存（对位 iOS updateChatListFiltersInteractively：本地先生效）。
     * 服务端确认后再回拉一次 messages.getDialogFilters 校准（refetchChatListFolders）。
     */
    private func syncChatListFolders(reason: String): Unit {
        match (getChatListVM()) {
            case Some(vm) => vm.applyLocalDialogFilters(this.folders, reason)
            case None => getRealChatListService().replaceDialogFiltersCache(this.folders)
        }
    }

    private func refetchChatListFolders(): Unit {
        match (getChatListVM()) {
            case Some(vm) => vm.loadFilters()
            case None => ()
        }
    }

    private func folderIndexOf(folderId: Int32): Int64 {
        var i: Int64 = 0
        while (i < this.folders.size) {
            if (this.folders[i].id == folderId) { return i }
            i = i + 1
        }
        return -1
    }

    private func swapFolderRows(a: Int64, b: Int64): Unit {
        let updated = ArrayList<ChatFolder>()
        var i: Int64 = 0
        while (i < this.folders.size) {
            if (i == a) { updated.add(this.folders[b]) }
            else if (i == b) { updated.add(this.folders[a]) }
            else { updated.add(this.folders[i]) }
            i = i + 1
        }
        this.folders = updated
    }

    /** 非会员不能把 All Chats 挤出首位（同 moveFolder 的提交校验，拖动时直接不允许越过）。 */
    private func canDragIntoIndex(targetIdx: Int64): Bool {
        if (targetIdx == 0 && !this.isPremiumUser()) { return false }
        return true
    }

    private func handleFolderDragTouch(evt: TouchEvent, folderId: Int32): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (folderId == 0 && !this.isPremiumUser()) { return }
                if (evt.touches.size > 0) { this.dragFolderLastY = evt.touches[0].screenY }
                this.dragFolderId = folderId
                this.dragFolderOffsetY = 0.0
                this.dragFolderMoved = false
            case TouchType.Move =>
                if (this.dragFolderId != folderId || evt.touches.size == 0) { return }
                let h = if (this.folderRowHeight > 20.0) { this.folderRowHeight } else { 51.0 }
                var dy = evt.touches[0].screenY - this.dragFolderLastY
                let idx = this.folderIndexOf(folderId)
                if (idx >= 0) {
                    if (dy > h * 0.5 && idx + 1 < this.folders.size) {
                        this.swapFolderRows(idx, idx + 1)
                        this.dragFolderLastY += h
                        dy -= h
                        this.dragFolderMoved = true
                    } else if (dy < -h * 0.5 && idx > 0 && this.canDragIntoIndex(idx - 1)) {
                        this.swapFolderRows(idx, idx - 1)
                        this.dragFolderLastY -= h
                        dy += h
                        this.dragFolderMoved = true
                    }
                }
                this.dragFolderOffsetY = dy
            case _ =>
                if (this.dragFolderId != folderId) { return }
                this.dragFolderId = -1
                this.dragFolderOffsetY = 0.0
                if (this.dragFolderMoved) {
                    this.dragFolderMoved = false
                    this.dragFromIdx = -1
                    this.persistFolderOrder()
                    this.syncChatListFolders("dragReorder")
                    Hilog.info(0, "CjTelegram", "[ChatFoldersPage] drag reorder committed folder=${folderId}")
                }
        }
    }

    /**
     * TC-0015 核心：文件夹拖拽重排（tap-to-pick-and-place 提交点，round2 重写）
     *
     * 设计对齐 iOS：拖动过程中允许把任意 folder（含 All Chats 本身）移到任意位置，
     * **松手提交时才校验**，不是从源头阻止尝试：
     *   1. 无条件计算候选新顺序 candidate（含把 All Chats 本身移走、或把别的 folder
     *      插到 All Chats 之前这两种"挤走 All Chats"的情况）
     *   2. 若 candidate.first.id != 0（All Chats 不再占据首位）且当前用户非 Premium
     *      （getAuthStorage().getUserData().isPremium）→ 核心违规：
     *        回滚（从 previousOrderIds 快照重建 folders，folders 保持挤走前的顺序）+
     *        弹 SubscribeToMoveAll Undo 提示（Action 跳 PremiumPage）
     *   3. 否则（会员 / All Chats 仍在首位）→ 应用 candidate + 异步上报
     *      updateDialogFiltersOrder 持久化
     */
    private func moveFolder(fromIdx: Int64, toIdx: Int64): Unit {
        let currentFolders = this.folders
        let sz = currentFolders.size
        if (fromIdx < 0 || toIdx < 0 || fromIdx >= sz || toIdx >= sz || fromIdx == toIdx) {
            return
        }

        // 提交前快照（供违规回滚使用）
        let snapshot = this.snapshotOrder()
        this.previousOrderIds = snapshot

        // 无条件构建候选新顺序（允许拿起 All Chats 本身，或把别的 folder 插到它之前）
        let buf = ArrayList<ChatFolder>()
        var i: Int64 = 0
        while (i < sz) {
            buf.add(currentFolders[i])
            i = i + 1
        }
        let moved = buf[fromIdx]
        if (fromIdx < toIdx) {
            var j: Int64 = fromIdx
            while (j < toIdx) {
                buf[j] = buf[j + 1]
                j = j + 1
            }
        } else {
            var j: Int64 = fromIdx
            while (j > toIdx) {
                buf[j] = buf[j - 1]
                j = j - 1
            }
        }
        buf[toIdx] = moved

        let candidate = ArrayList<ChatFolder>()
        var k: Int64 = 0
        while (k < buf.size) {
            candidate.add(buf[k])
            k = k + 1
        }

        // 提交时校验：All Chats 是否仍在首位
        let allChatsStillFirst = candidate.size > 0 && candidate[0].id == 0
        if (!allChatsStillFirst && !this.isPremiumUser()) {
            // 核心违规：非会员把 All Chats 挤出首位 —— 回滚 + Undo 提示
            this.restoreFromOrderIds(this.previousOrderIds)
            getUndoToastService().showUndo(
                "订阅 Telegram Premium 即可将「全部聊天」移出置顶位置",
                actionText: "订阅",
                onUndo: { =>
                    routerPush("PremiumPage", "")
                },
                onCommit: { =>
                    // 不撤销即维持回滚后的原顺序
                    ()
                }
            )
            Hilog.info(0, "CjTelegram",
                "[ChatFoldersPage] moveFolder rolled back: non-premium user attempted to move All Chats out of position 0 (from=${fromIdx} to=${toIdx})")
            return
        }

        // 合法重排（会员，或 All Chats 仍在首位）：整体重赋值触发刷新 + 异步持久化
        this.folders = candidate
        this.persistFolderOrder()
        this.syncChatListFolders("reorder")
        Hilog.info(0, "CjTelegram", "[ChatFoldersPage] moveFolder committed from=${fromIdx} to=${toIdx}")
    }

    // ==================== P2-174 邀请链接私有方法 ====================

    private func loadFolderLinks(folderId: Int32): Unit {
        this.isLoadingLinks = true
        this.folderLinks = ArrayList<ExportedChatFolderLink>()
        spawn {
            =>
            let svc = getChatFolderLinksService()
            let links = svc.getExportedInvites(folderId)
            spawn(UIThread) {
                =>
                this.folderLinks = links
                this.isLoadingLinks = false
                Hilog.info(0, "CjTelegram", "[ChatFoldersPage] loadFolderLinks: got ${links.size} links for folder ${folderId}")
            }
        }
    }

    private func doCreateLink(folderId: Int32, title: String): Unit {
        let selectedPeers = this.shareablePeers
        spawn {
            =>
            let svc = getChatFolderLinksService()
            let newLink = svc.exportChatlistInvite(folderId, title, selectedPeers)
            spawn(UIThread) {
                =>
                if (newLink.url.size > 0) {
                    let updated = ArrayList<ExportedChatFolderLink>()
                    for (l in this.folderLinks) {
                        updated.add(l)
                    }
                    updated.add(newLink)
                    this.folderLinks = updated
                    Hilog.info(0, "CjTelegram", "[ChatFoldersPage] doCreateLink: created link ${newLink.url}")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatFoldersPage] doCreateLink: failed for folder ${folderId}")
                }
                this.showCreateLinkPanel = false
                this.newLinkTitle = ""
                this.showPeerSelection = false
            }
        }
    }

    private func doDeleteLink(folderId: Int32, slug: String, linkIndex: Int64): Unit {
        spawn {
            =>
            let svc = getChatFolderLinksService()
            let ok = svc.deleteExportedInvite(folderId, slug)
            spawn(UIThread) {
                =>
                if (ok) {
                    let updated = ArrayList<ExportedChatFolderLink>()
                    var i: Int64 = 0
                    for (l in this.folderLinks) {
                        if (i != linkIndex) {
                            updated.add(l)
                        }
                        i = i + 1
                    }
                    this.folderLinks = updated
                    Hilog.info(0, "CjTelegram", "[ChatFoldersPage] doDeleteLink: deleted slug ${slug}")
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatFoldersPage] doDeleteLink: failed for slug ${slug}")
                }
            }
        }
    }

    private func doRevokeLink(folderId: Int32, slug: String, linkIndex: Int64): Unit {
        spawn {
            =>
            let svc = getChatFolderLinksService()
            let updated = svc.editExportedInvite(folderId, slug, revoke: true)
            spawn(UIThread) {
                =>
                if (updated.url.size > 0) {
                    let newList = ArrayList<ExportedChatFolderLink>()
                    var i: Int64 = 0
                    for (l in this.folderLinks) {
                        if (i == linkIndex) {
                            newList.add(updated)
                        } else {
                            newList.add(l)
                        }
                        i = i + 1
                    }
                    this.folderLinks = newList
                    Hilog.info(0, "CjTelegram", "[ChatFoldersPage] doRevokeLink: revoked slug ${slug}")
                }
            }
        }
    }

    private func buildShareablePeers(folder: ChatFolder): Unit {
        let result = ArrayList<FolderShareablePeer>()
        for (peerId in folder.includePeers) {
            let peer = FolderShareablePeer()
            peer.peerId = peerId
            peer.peerType = "channel"
            peer.accessHash = 0
            peer.title = "频道 #${peerId}"
            peer.isAvailable = true
            peer.isSelected = true
            result.add(peer)
        }
        this.shareablePeers = result
    }

    private func toggleAllPeersSelection(selectAll: Bool): Unit {
        let updated = ArrayList<FolderShareablePeer>()
        for (p in this.shareablePeers) {
            let newP = FolderShareablePeer()
            newP.peerId = p.peerId
            newP.peerType = p.peerType
            newP.accessHash = p.accessHash
            newP.title = p.title
            newP.isAvailable = p.isAvailable
            newP.isSelected = if (p.isAvailable) { selectAll } else { false }
            updated.add(newP)
        }
        this.shareablePeers = updated
    }

    private func togglePeerSelection(idx: Int64): Unit {
        let updated = ArrayList<FolderShareablePeer>()
        var i: Int64 = 0
        for (p in this.shareablePeers) {
            let newP = FolderShareablePeer()
            newP.peerId = p.peerId
            newP.peerType = p.peerType
            newP.accessHash = p.accessHash
            newP.title = p.title
            newP.isAvailable = p.isAvailable
            newP.isSelected = if (i == idx && p.isAvailable) { !p.isSelected } else { p.isSelected }
            updated.add(newP)
            i = i + 1
        }
        this.shareablePeers = updated
    }

    private func selectedPeerCount(): Int64 {
        var cnt: Int64 = 0
        for (p in this.shareablePeers) {
            if (p.isSelected) { cnt = cnt + 1 }
        }
        return cnt
    }

    // ==================== 构建方法 ====================

    @Builder
    func buildFolderLinkRow(link: ExportedChatFolderLink, linkIdx: Int64, folderId: Int32) {
        Row {
            Column {
                Text(if (link.title.isEmpty()) { "邀请链接" } else { link.title })
                    .fontSize(14)
                    .fontColor(if (link.isRevoked) { this.presentation.secondaryTextColor } else { this.presentation.textColor })
                    .layoutWeight(1)
                Text(link.url)
                    .fontSize(12)
                    .fontColor(if (link.isRevoked) { 0xCCCCCC } else { this.presentation.accentColor })
                    .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (!link.isRevoked) {
                Text("撤销")
                    .fontSize(12)
                    .fontColor(0xFF9500)
                    .padding(left: 8, right: 8, top: 4, bottom: 4)
                    .borderRadius(6)
                    .backgroundColor(0xFFF4E5)
                    .margin(right: 8)
                    .onClick({ _ =>
                        this.doRevokeLink(folderId, link.slug(), linkIdx)
                    })
            }

            Text("删除")
                .fontSize(12)
                .fontColor(0xFF3B30)
                .padding(left: 8, right: 8, top: 4, bottom: 4)
                .borderRadius(6)
                .backgroundColor(0xFFF0EF)
                .onClick({ _ =>
                    this.doDeleteLink(folderId, link.slug(), linkIdx)
                })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 10, bottom: 10)
        .backgroundColor(itemListCardColor())
    }

    @Builder
    func buildPeerRow(peer: FolderShareablePeer, peerIdx: Int64) {
        Row {
            Text(if (peer.isSelected) { "☑" } else { "☐" })
                .fontSize(20)
                .fontColor(if (peer.isAvailable) {
                    if (peer.isSelected) { this.presentation.accentColor } else { this.presentation.secondaryTextColor }
                } else {
                    0xCCCCCC
                })
                .margin(right: 12)

            Text(peer.title)
                .fontSize(15)
                .fontColor(if (peer.isAvailable) { this.presentation.textColor } else { 0xCCCCCC })
                .layoutWeight(1)

            if (!peer.isAvailable) {
                Text("无权限")
                    .fontSize(12)
                    .fontColor(0xCCCCCC)
                    .padding(left: 6, right: 6, top: 3, bottom: 3)
                    .borderRadius(4)
                    .backgroundColor(this.presentation.backgroundColor)
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .backgroundColor(itemListCardColor())
        .enabled(peer.isAvailable)
        .opacity(if (peer.isAvailable) { 1.0 } else { 0.4 })
        .onClick({ _ =>
            if (peer.isAvailable) {
                this.togglePeerSelection(peerIdx)
            }
        })
    }

    @Builder
    func buildFolderLinksPanel(folder: ChatFolder, folderIdx: Int64) {
        Column {
            // 标题栏
            Row {
                Text("${folder.icon} ${folder.name} 的邀请链接")
                    .fontSize(14)
                    .fontColor(this.presentation.textColor)
                    .fontWeight(FontWeight.Medium)
                    .layoutWeight(1)

                Text("关闭")
                    .fontSize(14)
                    .fontColor(this.presentation.accentColor)
                    .onClick({ _ =>
                        this.expandedLinksFolderId = -1
                        this.folderLinks = ArrayList<ExportedChatFolderLink>()
                        this.showCreateLinkPanel = false
                        this.showPeerSelection = false
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 12, bottom: 8)
            .backgroundColor(this.presentation.backgroundColor)

            if (this.isLoadingLinks) {
                Text("加载中...")
                    .fontSize(14)
                    .fontColor(this.presentation.secondaryTextColor)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)
            }

            // 链接列表
            ForEach(this.folderLinks, itemGenerator: { link: ExportedChatFolderLink, li: Int64 =>
                this.buildFolderLinkRow(link, li, folder.id)
            })

            // 创建新链接按钮
            if (!this.showCreateLinkPanel) {
                Row {
                    Text("＋ 创建邀请链接")
                        .fontSize(14)
                        .fontColor(this.presentation.accentColor)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 10, bottom: 10)
                .backgroundColor(itemListCardColor())
                .onClick({ _ =>
                    this.showCreateLinkPanel = true
                    this.newLinkTitle = ""
                    this.buildShareablePeers(folder)
                    this.showPeerSelection = true
                })
            }

            // 创建链接输入面板
            if (this.showCreateLinkPanel) {
                Column {
                    TextInput(text: this.newLinkTitle, placeholder: "链接名称（可选）")
                        .onChange({ val: String =>
                            this.newLinkTitle = val
                        })
                        .width(100.percent)
                        .height(44)
                        .backgroundColor(this.presentation.backgroundColor)
                        .fontColor(this.presentation.textColor)
                        .borderRadius(8)
                        .padding(left: 12, right: 12)
                        .margin(bottom: 12)

                    // peer 多选面板
                    if (this.showPeerSelection) {
                        Column {
                            // 全选/取消全选 控制行
                            Row {
                                Text("选择要分享的群组/频道")
                                    .fontSize(13)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .layoutWeight(1)

                                Text("全选")
                                    .fontSize(13)
                                    .fontColor(this.presentation.accentColor)
                                    .margin(right: 12)
                                    .onClick({ _ =>
                                        this.toggleAllPeersSelection(true)
                                    })

                                Text("取消")
                                    .fontSize(13)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .onClick({ _ =>
                                        this.toggleAllPeersSelection(false)
                                    })
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 8, bottom: 8)
                            .backgroundColor(this.presentation.backgroundColor)

                            // peer 列表（不可用 peer 灰显在下方）
                            ForEach(this.shareablePeers, itemGenerator: { peer: FolderShareablePeer, pi: Int64 =>
                                this.buildPeerRow(peer, pi)
                            })

                            if (this.shareablePeers.isEmpty()) {
                                Text("该文件夹暂无可分享的群组或频道")
                                    .fontSize(13)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .padding(left: 16, right: 16, top: 12, bottom: 12)
                            }
                        }
                        .width(100.percent)
                        .backgroundColor(itemListCardColor())
                        .margin(bottom: 12)
                    }

                    Row {
                        Button("取消")
                            .fontSize(14)
                            .fontColor(this.presentation.secondaryTextColor)
                            .backgroundColor(this.presentation.backgroundColor)
                            .borderRadius(8)
                            .height(36)
                            .layoutWeight(1)
                            .onClick({ _ =>
                                this.showCreateLinkPanel = false
                                this.newLinkTitle = ""
                                this.showPeerSelection = false
                            })

                        Button("创建")
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(
                                if (this.selectedPeerCount() == 0) { 0xCCCCCC } else { 0x317AFF }
                            )
                            .borderRadius(8)
                            .height(36)
                            .layoutWeight(1)
                            .margin(left: 12)
                            .enabled(this.selectedPeerCount() > 0)
                            .onClick({ _ =>
                                this.doCreateLink(folder.id, this.newLinkTitle)
                            })
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 12)
                .backgroundColor(itemListCardColor())
            }
        }
        .width(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
    }

    public func build() {
        Column {
            // 导航栏
            Row {
                Stack(alignContent: Alignment.Center) {
                    Image(@r(app.media.callui_v2_back))
                        .width(13)
                        .height(22)
                        .fillColor(this.presentation.textColor)
                }
                .width(44)
                .height(44)
                .borderRadius(22)
                .backgroundColor(this.presentation.cardColor)
                .shadow(radius: 12.0, color: 0x14000000, offsetX: 0.0, offsetY: 3.0)
                .onClick({ _ => routerPop() })

                Blank().layoutWeight(1)

                Text(trSource("Folders"))
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)

                Blank().layoutWeight(1)

                Text(if (this.isEditing) { "Done" } else { "Edit" })
                    .fontSize(16)
                    .fontColor(this.presentation.accentColor)
                    .padding(left: 14, right: 14, top: 10, bottom: 10)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(22)
                    .shadow(radius: 12.0, color: 0x14000000, offsetX: 0.0, offsetY: 3.0)
                    .onClick({ evt =>
                        this.isEditing = !this.isEditing
                        this.revealedDeleteFolderId = -1
                    })
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            // 内容
            List {
                // Source Folders screen always begins with its illustration and explanatory copy.
                ListItem {
                    Column {
                        Image(@r(app.media.chat_folders_intro))
                            .width(96)
                            .height(96)
                            .objectFit(ImageFit.Contain)
                            .margin(top: 24, bottom: 14)
                        Text("Create folders for different groups of chats and quickly switch between them.")
                            .fontSize(15)
                            .fontColor(this.presentation.secondaryTextColor)
                            .textAlign(TextAlign.Center)
                            .padding(left: 32, right: 32)
                            .margin(bottom: 24)
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                }

                ListItem {
                    Text(trSource("FOLDERS"))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .width(100.percent)
                        .padding(left: 16, top: 12, bottom: 7)
                }

                // The source presents Create, All Chats and custom folders as one rounded card.
                ListItem {
                    Row {
                    Column {
                        Row {
                            Text(trSource("Create a Folder"))
                                .fontSize(17)
                                .fontColor(this.presentation.accentColor)
                                .layoutWeight(1)
                                .textAlign(if (this.isEditing) { TextAlign.Center } else { TextAlign.Start })
                        }
                        .width(100.percent)
                        .height(50)
                        .padding(left: 16, right: 16)
                        .onClick({ _ => this.openCreateFolder() })

                        if (this.showsFolderPresetList()) {
                            ForEach(this.folders, itemGeneratorFunc: { folder: ChatFolder, index: Int64 =>
                                Column {
                                    Divider()
                                        .strokeWidth(1)
                                        .color(this.presentation.dividerColor)
                                        .margin(left: 16)
                                    Row {
                                        if (this.isEditing && folder.id != 0) {
                                            Stack(alignContent: Alignment.Center) {
                                                Circle().width(22).height(22).fill(0xFFFF3B30)
                                                Row {}.width(11).height(2).backgroundColor(0xFFFFFFFF).borderRadius(1)
                                            }.width(32).height(32).margin(right: 6)
                                                .onClick({ _ => this.revealedDeleteFolderId = folder.id })
                                        }
                                        Text(if (folder.id == 0) { "All Chats" } else { folder.name })
                                            .fontSize(17)
                                            .fontColor(this.presentation.textColor)
                                            .layoutWeight(1)

                                        if (!this.isEditing && folder.id != 0) {
                                            Image(@r(app.media.item_list_disclosure_arrow))
                                                .width(8)
                                                .height(14)
                                                .fillColor(this.presentation.secondaryTextColor)
                                        }

                                        if (this.isEditing && this.revealedDeleteFolderId != folder.id) {
                                            Stack(alignContent: Alignment.Center) {
                                                Column(space: 4) {
                                                    Row {}.width(18).height(2).backgroundColor(0xFFC7C7CC).borderRadius(1)
                                                    Row {}.width(18).height(2).backgroundColor(0xFFC7C7CC).borderRadius(1)
                                                    Row {}.width(18).height(2).backgroundColor(0xFFC7C7CC).borderRadius(1)
                                                }.width(20).height(20).justifyContent(FlexAlign.Center)
                                            }
                                            .width(32)
                                            .height(32)
                                            .margin(right: 4)
                                            .onTouch({ evt => this.handleFolderDragTouch(evt, folder.id) })
                                            .onClick({ _ =>
                                                if (this.dragFromIdx < 0) {
                                                    this.dragFromIdx = index
                                                } else if (this.dragFromIdx == index) {
                                                    this.dragFromIdx = -1
                                                } else {
                                                    let fromIdx = this.dragFromIdx
                                                    this.dragFromIdx = -1
                                                    this.moveFolder(fromIdx, index)
                                                }
                                            })
                                        }

                                        if (this.isEditing && this.revealedDeleteFolderId == folder.id) {
                                            Button(trSource("Delete")).fontSize(15).fontColor(0xFFFFFFFF)
                                                .backgroundColor(0xFFFF3B30).borderRadius(0)
                                                .height(50).width(78).margin(right: -16)
                                                .onClick({ _ => this.revealedDeleteFolderId = -1; this.deleteFolderAt(index, folder) })
                                        }
                                    }
                                    .width(100.percent)
                                    .height(50)
                                    .padding(left: 16, right: 16)
                                    .backgroundColor(if (this.dragFromIdx == index || this.dragFolderId == folder.id) { this.presentation.itemHighlightedBackgroundColor } else { itemListCardColor() })
                                    .onClick({ _ =>
                                        if (!this.isEditing && folder.id != 0) {
                                            routerPush("ChatFolderEditorPage", folder.id.toString())
                                        }
                                    })
                                }
                                .translate(y: if (this.dragFolderId == folder.id) { this.dragFolderOffsetY } else { 0.0 })
                                .zIndex(if (this.dragFolderId == folder.id) { 1 } else { 0 })
                                .onAreaChange({ _: Area, newArea: Area =>
                                    this.folderRowHeight = newArea.height.value
                                })
                            }, keyGeneratorFunc: { folder: ChatFolder, _: Int64 => folder.id.toString() })
                        }
                    }
                    .width(100.percent)
                    .backgroundColor(itemListCardColor())
                    .borderRadius(14)
                    .clip(true)
                    }.width(100.percent).padding(left: 16, right: 16)
                }

                // 新建文件夹输入面板（展开时显示）
                if (this.showCreatePanel) {
                    ListItem {
                        Column {
                            TextInput(text: this.newFolderName, placeholder: trSource("Folder Name"))
                                .onChange({ val: String =>
                                    this.newFolderName = val
                                })
                                .width(100.percent)
                                .height(44)
                                .backgroundColor(this.presentation.backgroundColor)
                                .fontColor(this.presentation.textColor)
                                .borderRadius(8)
                                .padding(left: 12, right: 12)
                                .margin(bottom: 12)

                            Row {
                                Button(trSource("Cancel"))
                                    .fontSize(15)
                                    .fontColor(this.presentation.secondaryTextColor)
                                    .backgroundColor(this.presentation.backgroundColor)
                                    .borderRadius(8)
                                    .height(36)
                                    .layoutWeight(1)
                                    .onClick({ evt =>
                                        this.showCreatePanel = false
                                        this.newFolderName = ""
                                    })

                                Button(trSource("Save"))
                                    .fontSize(15)
                                    .fontColor(0xFFFFFF)
                                    .backgroundColor(
                                        if (this.newFolderName.isEmpty()) { 0xCCCCCC } else { 0x317AFF }
                                    )
                                    .borderRadius(8)
                                    .height(36)
                                    .layoutWeight(1)
                                    .margin(left: 12)
                                    .enabled(!this.newFolderName.isEmpty())
                                    .onClick({ evt =>
                                        this.commitCreateFolder()
                                    })
                            }
                            .width(100.percent)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 12)
                        .backgroundColor(itemListCardColor())
                    }
                }

                if (this.showsFolderPresetList()) {
                ListItem {
                    Text("Tap 'Edit' to change the order or delete folders.")
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .padding(left: 16, right: 16, top: 8, bottom: 20)
                }
                }

                if (!this.recommendedFolders.isEmpty()) {
                    ListItem {
                        Text(trSource("RECOMMENDED FOLDERS"))
                            .fontSize(13)
                            .fontColor(this.presentation.secondaryTextColor)
                            .padding(left: 16, top: 12, bottom: 7)
                    }
                    ListItem {
                        Row {
                        Column {
                        ForEach(this.recommendedFolders, itemGenerator: { folder: ChatFolder, index: Int64 =>
                            Column {
                            if (index > 0) {
                                Divider().strokeWidth(1).color(this.presentation.dividerColor).margin(left: 16, right: 16)
                            }
                            Row {
                                Column {
                                    Text(folder.name).fontSize(17).fontColor(this.presentation.textColor)
                                    if (!folder.description.isEmpty()) {
                                        Text(folder.description).fontSize(13).fontColor(this.presentation.secondaryTextColor).margin(top: 2)
                                    }
                                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                                Text(trSource("ADD"))
                                    .fontSize(14)
                                    .fontWeight(FontWeight.Medium)
                                    .fontColor(0xFFFFFFFF)
                                    .backgroundColor(this.presentation.accentColor)
                                    .borderRadius(18)
                                    .padding(left: 16, right: 16, top: 7, bottom: 7)
                                    .onClick({ _ => this.commitAddRecommendedFolder(folder, index) })
                            }
                            .width(100.percent)
                            .height(if (folder.description.isEmpty()) { 50 } else { 62 })
                            .padding(left: 16, right: 16)
                            .backgroundColor(itemListCardColor())
                            }
                        })
                        // S7-128: iOS ChatListFilterPresetListController.swift:306-308 — with no
                        // folders yet, the RECOMMENDED card ends with "Add Custom Folder", which runs
                        // the same addNew flow as Create a Folder (:185-187, :409-450). The synthesized
                        // All Chats entry does not count as a folder (iOS filters is empty then).
                        if (!this.hasCustomFolders()) {
                            Divider().strokeWidth(1).color(this.presentation.dividerColor).margin(left: 16, right: 16)
                            Row {
                                Text(this.sourceLocalizationPresentation.getOr("ChatListFolderSettings_RecommendedNewFolder", "Add Custom Folder"))
                                    .fontSize(17)
                                    .fontColor(this.presentation.accentColor)
                                    .layoutWeight(1)
                            }
                            .width(100.percent)
                            .height(50)
                            .padding(left: 16, right: 16)
                            .backgroundColor(itemListCardColor())
                            .onClick({ _ => this.openCreateFolder() })
                        }
                        }.width(100.percent).backgroundColor(itemListCardColor()).borderRadius(14).clip(true)
                        }.width(100.percent).padding(left: 16, right: 16)
                    }
                }

                ListItem {
                    Row {
                        Row {
                        Text(trSource("Show Folder Tags"))
                            .fontSize(17)
                            .fontColor(this.presentation.textColor)
                            .layoutWeight(1)
                        if (!this.isPremiumUser()) {
                            Image(@r(app.media.misc_ic_premiumlock))
                                .width(18)
                                .height(18)
                                .fillColor(this.presentation.secondaryTextColor)
                                .margin(right: 8)
                        }
                        Toggle(ToggleType.Switch, isOn: this.showFolderTags)
                            .selectedColor(0x34C759)
                            .enabled(this.isPremiumUser())
                            .onChange({ value: Bool => this.updateFolderTags(value) })
                    }
                    .width(100.percent)
                    .height(52)
                    .padding(left: 16, right: 12)
                    .backgroundColor(itemListCardColor())
                    .borderRadius(14)
                    .onClick({ _ =>
                        if (!this.isPremiumUser()) { routerPush("PremiumPage", "folders") }
                    })
                        }.width(100.percent)
                    }.width(100.percent).padding(left: 16, right: 16)
                ListItem {
                    Text(trSource("Display folder names for each chat in the chat list."))
                        .fontSize(13)
                        .fontColor(this.presentation.secondaryTextColor)
                        .padding(left: 16, right: 16, top: 8, bottom: 24)
                }
            }
            .width(100.percent)
            .layoutWeight(1)
            .backgroundColor(itemListPageBackgroundColor())
            .enableScrollInteraction(this.dragFolderId < 0)
            .divider(ListDividerOptions(strokeWidth: 1, color: this.presentation.dividerColor, startMargin: 48, endMargin: 0))
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .padding(bottom: getSafeAreaBottom())
        .onVisibleAreaChange([0.0, 1.0], { visible: Bool, ratio: Float64 =>
            if (visible && ratio > 0.9) { this.ensureLoaded() }
        })
        .onAppear({ => this.ensureLoaded() })
    }
}
