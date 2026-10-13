package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.sync.*
import ohos_app_cangjie_entry.models.Chat
import ohos_app_cangjie_entry.models.ChatEntry
import ohos_app_cangjie_entry.models.ChatFolder
import ohos_app_cangjie_entry.models.{ChatFolderPeer, FolderShareablePeer, ExportedChatFolderLink}
import ohos_app_cangjie_entry.interop.{callArkAsync, SHARE_LINK}
import ohos_app_cangjie_entry.utils.copyText
import ohos_app_cangjie_entry.utils.{chatOpenPerfBegin, chatOpenPerfMark}
import ohos_app_cangjie_entry.viewmodels.*
import ohos_app_cangjie_entry.components.ChatListItem
import ohos_app_cangjie_entry.components.SkeletonRow
import ohos_app_cangjie_entry.components.ChatListSearchRecentPeersComponent
import ohos_app_cangjie_entry.components.ChatListSearchItemHeaderComponent
import ohos_app_cangjie_entry.components.ItemListPeerActionComponent
import ohos_app_cangjie_entry.components.ComposeButtonTooltip
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.components.ProgressNavButton
import ohos_app_cangjie_entry.components.DeleteChatPeerActionSheetComponent
import ohos_app_cangjie_entry.components.MessageBubble
import ohos_app_cangjie_entry.components.Avatar
import ohos_app_cangjie_entry.models.Message
import ohos_app_cangjie_entry.core.storage.getChatBgDisplayPath
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation, PresentationStringsSnapshot, currentPresentationStrings}
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.services.{addAccountSwitchListenerWithId, removeAccountSwitchListener}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.utils.safeAnimateTo
import ohos_app_cangjie_entry.utils.HistoryAnchorKeeper
import ohos_app_cangjie_entry.core.mtproto.UserResponse

// The Projection is bootstrapped during appStartup, before Home creates this
// component.  Seed the page's plain @State mirrors synchronously so the very
// first build renders Postbox rows.  Waiting for onAppear -> addSubscriber ->
// launch used to build 10 SkeletonRows (30 ShimmerViews) for ~20 ms even when
// cached chats were already available.
private func coldStartChatEntries(): ArrayList<ChatEntry> {
    let entries = ArrayList<ChatEntry>()
    for (chat in getChatListProjection().currentSnapshot().chats) {
        entries.add(ChatEntry(chat))
    }
    return entries
}

private func coldStartPageLoading(): Bool {
    let snapshot = getChatListProjection().currentSnapshot()
    return snapshot.isLoading && snapshot.chats.isEmpty()
}

private func coldStartFolderTabs(): ArrayList<ChatFolder> {
    return getChatListProjection().currentSnapshot().dialogFilters
}

/** 文件夹列表里是否含自定义文件夹（id != 0 的 All Chats 以外条目）——tab 栏显隐的唯一判据。 */
private func folderTabsHaveCustom(filters: ArrayList<ChatFolder>): Bool {
    for (folder in filters) {
        if (folder.id != 0) { return true }
    }
    return false
}

private func coldStartFolderTabsVisible(): Bool {
    return folderTabsHaveCustom(coldStartFolderTabs())
}

/**
 * 聊天列表页面（Phase E 增强版）— 混合工程迁移版（TAB CONTENT）
 *
 * 由 MainTabPage 的 Tabs 直接渲染为 ChatListPage() 子组件（非独立路由页）。
 *
 * 参照 TelegramHarmony ChatListPage.ets：
 * - 下拉刷新（Refresh 组件）
 * - 滑动操作（ListItem.swipeAction: 静音/置顶/删除）
 * - 长按菜单（ActionSheet: 置顶/静音/标记已读/删除）
 * - 改进的空状态
 * - ViewModel 负责服务器通信，Page 通过 sync 循环拉取数据
 *
 * 混合迁移改动（tab-content 处理，非完整 page-shell recipe）：
 *  - 不加 @HybridComponentEntry（由 MainTabPage 承载嵌入）
 *  - 删 @Consume var pageStack（混合嵌入无 @Provide 栈）
 *  - pageStack.pushPathByName(name, param) → routerPush(name, param)
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫），根挂 .onAppear
 *  - aboutToDisappear 有实清理 → cleanup()，根挂 .onDisAppear
 */
// 长按上下文菜单的动作面板行几何。
// 面板窗口 Y 由 onAreaChange 提供，行的相对位置由这组常量推出：
//   面板顶即第一行顶（iOS 的动作面板没有标题头），每行 44、行间分隔线 1。
// 用常量而非逐行测量：ArkUI 没有为子项暴露逐项几何，而这份面板的行高在本文件内固定，
// 改布局时同步改这里即可。（自定义组件内不允许声明 static 成员，故放在文件级。）
private let CHAT_ACTION_ROW_HEIGHT: Float64 = 44.0
private let CHAT_ACTION_ROW_STRIDE: Float64 = 45.0
// 通用上下文菜单（文件夹 tab / 归档行 / 搜索消息结果）的几何：iOS ContextActionsContainerNode
// 行高 44、分组分隔 8、宽 250。
private let LIST_MENU_WIDTH: Float64 = 250.0
private let LIST_MENU_ROW_HEIGHT: Float64 = 44.0
private let LIST_MENU_SEPARATOR_HEIGHT: Float64 = 8.0
// iOS 动作面板宽 220~240（ContextControllerActionsStackNode.swift:2246-2247）
private let CHAT_ACTION_PANEL_WIDTH: Float64 = 240.0
// 底部安全区（Home 指示条 / 手势区）——浮层整体不得越过它，否则最后一项会被盖住
private let CHAT_CONTEXT_BOTTOM_INSET: Float64 = 34.0

/** 第 index 个动作行相对面板顶部的偏移 */
private func chatActionRowTop(index: Int64): Float64 {
    return Float64(index) * CHAT_ACTION_ROW_STRIDE
}

/** 面板总高（count 行，行间 1vp 分隔线） */
private func chatActionPanelHeight(count: Int64): Float64 {
    if (count <= 0) { return 0.0 }
    return chatActionRowTop(count - 1) + CHAT_ACTION_ROW_HEIGHT
}

/** 搜索消息结果的选择键：会话 + 消息 id（同一会话多条结果各自成行）。 */
// RECENT → Clear 菜单的说明行（iOS ChatList_ClearSearchHistory，无动作）。
private let RECENT_CLEAR_INFO_KEY: String = "clearSearchHistoryInfo"

private func searchMessageKey(c: Chat): String {
    return "${c.peerType}_${c.id}_${c.searchMessageId}"
}

private func containsSearchRow(list: ArrayList<Chat>, c: Chat): Bool {
    for (x in list) {
        if (searchMessageKey(x) == searchMessageKey(c)) { return true }
    }
    return false
}

/**
 * 上下文菜单的一项（iOS ContextMenuActionItem 的最小投影）。
 * key 供执行分派；icon 是本地矢量资源的语义名，渲染处按名选图；
 * separatorBefore 对应 iOS 的 .separator（8vp 分组间隔）。
 */
public class ChatListMenuItem {
    public var key: String
    public var title: String
    public var icon: String
    public var destructive: Bool
    public var separatorBefore: Bool

    public init(key: String, title: String, icon: String, destructive!: Bool = false, separatorBefore!: Bool = false) {
        this.key = key
        this.title = title
        this.icon = icon
        this.destructive = destructive
        this.separatorBefore = separatorBefore
    }
}

/**
 * 预览卡头部的副标题 —— 对齐 iOS 聊天页导航栏标题下那一行。
 * 私聊显示在线状态，群/频道显示成员数。
 */
/**
 * 预览列表项的 ForEach key。
 *
 * 与 ChatRoomPage 的 keyGenerator 同构：
 *   身份段 identityKey()（= stableId）—— 本地消息发出后 id 会换成服务端号，用 id 会误判换条；
 *   内容段 —— MessageBubble.message 是常规成员变量，key 不含内容就不会原地刷新，
 *            媒体下载完、状态变化都不上屏。
 */
private func previewItemKey(msg: Message): String {
    return "${msg.identityKey()}_${msg.content}_${msg.status}_${msg.photoLocalPath}_${msg.documentLocalPath}_${msg.documentThumbnailPath}"
}

private func previewSubtitleFor(chat: Chat): String {
    if (chat.isChannel) {
        if (chat.participantsCount > 0) { return "${chat.participantsCount} subscribers" }
        return "channel"
    }
    if (chat.isGroup || chat.isMegagroup) {
        if (chat.participantsCount > 0) { return "${chat.participantsCount} members" }
        return "group"
    }
    if (chat.isOnline) { return "online" }
    return "last seen recently"
}

@Component
public class ChatListPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    public var onSearchVisibilityChange: (Bool) -> Unit = { _visible: Bool => }
    /**
     * 长按上下文菜单显隐 —— 通知 MainTabPage 把悬浮 tab bar 滑出/滑回。
     * tab bar 是 TabContent 的兄弟节点、画在页面之上，本页的浮层盖不到它；
     * iOS 的 presentInGlobalOverlay 会连 tab bar 一起盖住，故用回调达成同样效果。
     */
    public var onContextOverlayChange: (Bool) -> Unit = { _visible: Bool => }
    // 回合合流修复：编辑态通知容器。origin/main 的批量操作栏是页内自绘的
    // （buildBatchActionBar），而本仓容器 MainTabPage 有一条常驻的悬浮 tab bar 盖在屏底带上
    // ⇒ 实测批量栏被 tab bar 与 FAB 完全压住、只露出 Delete 的一角，节点在但不可用。
    // 与既有 onSearchVisibilityChange / onContextOverlayChange 同型：页面只发布状态，
    // 由容器决定摘除什么（容器侧 mount 级互斥，不用 opacity——D-149）。
    public var onEditModeChange: (Bool) -> Unit = { _editing: Bool => }
    // 返修（diag-suite_settings_appearance-TC-0401-round9.md F-2）：本订阅曾在 c129b3fd5（RC-3）
    // 交付并通过评审，被 a8998a341（整文件取 origin/main 覆盖）连带删除，导致聊天列表整屏不随
    // 主题切换（tab 栏胶囊在同一帧已变深，独此屏停留浅色）。写法与仓内先例一致：
    // pages/MainTabPage.cj:100、pages/AppearanceSettingsPage.cj:44。
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @StorageLink["presentationStrings"] var presentationStrings: PresentationStringsSnapshot = currentPresentationStrings()

    private func localized(key: String, fallback: String): String {
        return this.presentationStrings.getOr(key, fallback)
    }
    @Prop @Watch[onExternalSearchVisibleChanged] var externalSearchVisible: Bool
    // G1/G3/E5：Chats 搜索态下获焦的是 MainTabPage tab 栏里的搜索胶囊（tabbar_search_input），
    // 其文本经此 @Prop 下发。此前本页只监听自己（被覆盖层挡住、从不获焦）的 SearchBar，
    // 用户输入的查询从未触发本地过滤 / contacts.search / messages.searchGlobal。
    // 对位 iOS ChatListSearchContainerNode.searchTextUpdated（边输边搜）。
    @Prop @Watch[onExternalSearchQueryChanged] var externalSearchQuery: String
    // 搜索态下软键盘高度（vp，MainTabPage KeyboardHeightChange 下发）：tab 栏搜索胶囊随键盘
    // 抬起，搜索覆盖层底部占位要跟着抬，筛选条才能始终贴在胶囊上方。
    @Prop var externalKeyboardInset: Float64
    // ViewModel（负责服务器通信和数据管理）
    @State var viewModel: ChatListViewModel = ChatListViewModel()

    // 本地显示列表：ChatEntry 实现 ToString
    @State var displayList: ArrayList<ChatEntry> = coldStartChatEntries()

    // 本地加载状态
    @State var isPageLoading: Bool = coldStartPageLoading()

    // 搜索关键词
    @State var searchKeyword: String = ""

    // 是否显示搜索框
    @State var showSearch: Bool = false

    // TC-0013 返修：镜像 this.viewModel 的搜索相关嵌套字段到页面自身 @State。
    // 根因（diag-suite_chat_list_folders-TC-0013.md）：page 的 build() 内联读取
    // this.viewModel.globalSearchResults / isSearching 等（@State 持有的 @Observed
    // 实例的嵌套 @Publish 字段）不可靠触发本页 build() 重新求值 —— hilog 证实
    // ViewModel 层状态已正确变为空结果，但 dumpLayout 证实页面渲染树未跟随更新。
    // 搜索结果仍使用独立的短生命周期镜像；Chats 主列表已迁到 ChatListProjection 推送。
    @State var searchGlobalResultsMirror: ArrayList<Chat> = ArrayList<Chat>()
    @State var searchGlobalPeerResultsMirror: ArrayList<Chat> = ArrayList<Chat>()
    @State var isSearchingMirror: Bool = false
    @State var isSearchingPeersMirror: Bool = false

    // 返修：镜像 this.viewModel.dialogFilters（文件夹 tab 栏）到页面自身 @State。
    // 根因：ChatListViewModel.loadFilters()（viewmodels/ChatListViewModel.cj:215-233）在
    // spawn{}→launch{} 内整体重赋值 this.dialogFilters = filters（@State 持有的 @Observed
    // ChatListViewModel 实例的 @Publish 嵌套字段整体重赋值），build() 内联直接读取
    // this.viewModel.dialogFilters 不可靠触发本页重新渲染（hilog 证实 VM 层数据已到，
    // dumpLayout 证实渲染树未跟随）。同一坑已在 TC-0013（搜索镜像）验证过修复范式。
    // 现由 ChatListProjection 快照回写页面裸 @State，build() 不直接读取嵌套字段。
    @State var folderTabsMirror: ArrayList<ChatFolder> = coldStartFolderTabs()
    // 冷启动文件夹 tab 栏间歇不出现（约 1/4 冷启动；hilog 里 loadFilters: 2 server folders →
    // publish reason=dialogFilters → page 已 "projection applied generation=N, reason=dialogFilters"，
    // 镜像已到位但 tab 栏不渲染，Settings → Chat Folders 里文件夹仍在）。失败那次的时序特征：
    // 主线程先被 LangPack 应用 + "gc is triggered for OOM" 占住 ~250ms，随后 updatingBegan /
    // updatingEnded / avatarReady / initialDialogs / dialogFilters / initialArchive 六个快照在同一
    // 个 UI 回合里连续应用，folderTabsMirror 在这一回合内被整体重赋值五次（[] → [] → [] →
    // [coreV…] → [coreV…]），displayList 也在同回合整体替换；正常冷启动时 dialogFilters 快照
    // 落在独立的一帧。build() 内 `if (this.hasCustomFolderTab() && …)` 通过方法调用间接读
    // ArrayList @State 作为分支判据，在这种"同回合多次整体重赋值 + 大量兄弟节点同帧重建"
    // 下不可靠地漏掉分支切换。修复：
    //   1. tab 栏显隐改由裸 Bool @State folderTabsVisible 驱动，在投影回调里由快照当场派生、
    //      只在值变化时写一次（不再让 if 判据依赖 ArrayList 整体重赋值的通知）；
    //   2. tab 栏 Scroll 挂 onAppear/onDisAppear 记录是否真的挂载；显隐翻到 true 后起一个
    //      一次性看门狗，700ms 后若仍未挂载则在安静回合里重新驱动该 Bool（false → 下一回合
    //      true）并重发镜像，最多重试两次，每步打 hilog 供上机对照。
    // 对位 iOS ChatListControllerNode：filters 非空即显示 tab 栏，不依赖到达时序。
    @State var folderTabsVisible: Bool = coldStartFolderTabsVisible()
    private var _folderBarMounted: Bool = false
    private var _folderBarWatchdogGeneration: Int64 = 0

    // TC-0086 返修（diag-suite_settings_root-TC-0086.md「M-1」，D-129 形态）：镜像
    // this.viewModel.currentFolderId 到本页裸 @State。根因：归档态导航栏三处分支（返回
    // 按钮/标题/「⋯」按钮）跨对象嵌套读 this.viewModel.currentFolderId 不可靠触发本组件
    // 重新 build()。修复：对齐本文件 folderTabsMirror 同款模式，在 ChatListProjection
    // 投影回调块内随快照回写裸 @State 镜像，build() 只读镜像字段。
    @State var currentFolderIdMirror: Int32 = 0
    // 归档会话数镜像（同上 D-129 形态）：主列表顶部 Archived Chats 行的显隐只读它，
    // 不在 build() 里跨对象读 this.viewModel.archiveChatList（该读取不触发重绘，
    // 归档列表被回源清空后入口行仍残留）。
    @State var archiveCountMirror: Int64 = 0
    // S1-66：Archived Chats 行右侧未读徽标 —— iOS ChatList.swift:649 groupReference.unreadCount =
    // unreadState.count(countingCategory: .chats, mutedCategory: .all)，即"有未读的归档会话数"
    // （含静音、含手动标未读）。同 D-129 形态镜像到裸 @State。
    @State var archiveUnreadChatsMirror: Int64 = 0

    // Compose 菜单状态 (iOS-style: New Message/Group/Channel/Secret Chat/Contact)
    @State var showComposeMenu: Bool = false

    // TC-0086 返修（「M-4」，与「M-5」配套）：归档态导航栏右上「⋯」菜单开关。对位源侧
    // ChatListController.swift:3932 openArchiveMoreMenu(sourceView:gesture:)。
    @State var showArchiveMoreMenu: Bool = false

    // 长按菜单状态
    @State var showActionSheet: Bool = false
    @State var selectedChatId: Int64 = 0
    @State var selectedChatName: String = ""
    @State var selectedChatPeerType: String = ""
    @State var selectedChatPinned: Bool = false
    @State var selectedChatMuted: Bool = false
    // P2-104: 当前选中对话是否有未读消息（用于「标记未读/已读」菜单项）
    @State var selectedChatUnread: Bool = false
    // 长按连续手势：当前高亮的动作行索引（-1 = 未命中）
    @State var actionHighlightIndex: Int64 = -1
    // 动作面板左上角的窗口坐标（vp），由 onAreaChange 提供，用于把触点映射到行
    private var actionPanelTop: Float64 = 0.0
    private var actionPanelLeft: Float64 = 0.0
    // 被长按那一行的窗口几何（vp），面板据此定位、弹簧动画据此起跳
    @State var contextSourceY: Float64 = 0.0
    @State var contextSourceHeight: Float64 = 0.0
    // 面板入场：scale 0.01→1（iOS ContextControllerExtractedPresentationNode 的
    // animateSpring transform.scale from 0.01），配合 opacity 淡入
    @State var actionPanelScale: Float32 = 0.01
    @State var actionPanelPresented: Bool = false
    // 屏幕尺寸（vp），用于把面板夹在可视区内
    @State var screenHeightVp: Float64 = 800.0
    @State var screenWidthVp: Float64 = 390.0
    // 浮层自身的几何（vp）。浮层 expandSafeArea 之后铺满整块屏幕，原点在窗口顶（状态栏之上），
    // 与页面内容区不是同一套坐标；菜单定位要换算回来，否则整组会上移一个状态栏的高度。
    @State var overlayHeightVp: Float64 = 0.0
    @State var contentTopVp: Float64 = 0.0
    // 连续手势的门控，逐条对齐 ContextControllerImpl.swift:221-295：
    //   armed   = didCompleteAnimationIn，入场动画没结束前手指移动不生效
    //   anchor  = initialContinueGesturePoint，菜单弹出后收到的第一个点
    //   engaged = didMoveFromInitialGesturePoint，纵向离开锚点 4vp 才开始高亮
    // 少了这三道门，手指停在原地不动也会高亮它下面那一行，抬手即执行 —— 会话行
    // 靠近屏幕下缘时面板正好弹在手指底下，于是几乎必然误触。
    private var contextGestureArmed: Bool = false
    private var contextGestureHasAnchor: Bool = false
    private var contextGestureAnchorY: Float64 = 0.0
    private var contextGestureEngaged: Bool = false
    /**
     * 上下文菜单里的会话预览。
     *
     * iOS 长按会话行弹的是一个真实的 ChatController（.previewing 模式），
     * 并且显式 canReadHistory.set(false)，预览不会把消息标记已读
     * （ChatListController.swift:1932-1934）。
     * 我们无法把路由页塞进浮层，改为只读本地库最近若干条自绘 —— 纯本地读取，
     * 同样不会产生已读回执。
     */
    @State var contextPreviewMessages: ArrayList<Message> = ArrayList<Message>()
    @State var contextPreviewAvatar: String = ""
    @State var contextPreviewSubtitle: String = ""
    // 预览列表的滚动控制器：加载完成后定位到底部（最新消息）
    let contextPreviewScroller = Scroller()
    /**
     * 预览复用聊天页的 ViewModel —— 复刻 iOS 的结构。
     *
     * iOS 的预览不是另写一个消息列表，而是**同一个 ChatController** 换成 .previewing 模式；
     * 历史仍由 Postbox 的窗口视图提供，媒体仍由节点订阅 MediaBox 拉取。
     * 我们对应地复用 ChatRoomViewModel：initPreview 只做减法（不轮询、不注册推送、
     * 不上报已读），本地秒开 / 媒体回填 / 向上翻页全部沿用聊天室那套已验证的实现。
     *
     * 此前预览自带一份朴素分页，缺去重、缺锚点恢复、也没触发媒体回填，
     * 于是「往上划不动 / 往下无限循环 / 资源加载不出来」三个症状一起出现。
     */
    private let contextPreviewVM = ChatRoomViewModel()
    // 头插历史时保持可视锚点（与聊天室共用同一实现）
    private let contextPreviewAnchor = HistoryAnchorKeeper()
    // 首帧 scrollEdge 落地前 onReachStart 会被初始索引 0 自动触发，必须拦截
    private var contextPreviewSettled: Bool = false
    private var contextPreviewFirstVisible: Int64 = -1
    // 上一次上屏的渲染键，用于跳过「产物没变」的重复发布
    private var _previewRenderKey: String = ""
    // 不在最新端时显示「回到最新」圆形下箭头（对齐 iOS ChatHistoryNavigationButtons）
    @State var contextPreviewShowScrollDown: Bool = false
    // 预览卡的起跳位移：从被按行中心弹到预览中心
    // （iOS animationInContentYDistance = contentRect.midY - sourcePoint.y）
    @State var previewOffsetY: Float64 = 0.0

    // TC-0016 第四轮返修：真正挂载 components/DeleteChatPeerActionSheetComponent.cj（此前
    // Diagnoser 归因报告点名的"已实现但零调用点"死代码组件），而非用通用 showAlert 替代。
    // @Prop 调用点必须是裸 @State 字段（D-125），故把该组件需要的头像三项也镜像进裸字段。
    @State var showDeleteChatPeerSheet: Bool = false
    @State var selectedChatAvatarText: String = ""
    @State var selectedChatAvatarColor: Int64 = 0x317AFF
    @State var selectedChatAvatarLocalPath: String = ""

    // S1-47：搜索结果长按 → Add to Contacts → iOS NewContactScreen（与 ChatRoomPage 同款底部表单）。
    @State var showNewContactSheet: Bool = false
    @State var newContactUserId: Int64 = 0
    @State var newContactFirstName: String = ""
    @State var newContactLastName: String = ""
    @State var newContactPhone: String = ""
    @State var newContactBusy: Bool = false

    // TC-0012 第三轮返修：swipeAction end 侧多按钮面板——镜像"当前正在滑出面板的那一行"
    // 数据到裸 @State 字段（D-125 合规：@Builder func 内只能读裸 this.字段，不能读参数
    // /闭包捕获的 entry），供 buildSwipeEndPanel()（@Builder 无参函数）读取渲染 3 个按钮。
    @State var swipeRowChatId: Int64 = 0
    @State var swipeRowChatName: String = ""
    @State var swipeRowPeerType: String = ""
    @State var swipeRowMuted: Bool = false
    @State var swipeRowArchived: Bool = false
    @State var swipeRowUnread: Bool = false
    // 行滑出面板点动作后收回：ArkUI-CJ 无 closeAllSwipeActions，改为把该行的 ForEach 键
    // 换代，重建出一个未展开的新 ListItem（iOS revealOptionSelected close=true 语义）。
    @State var swipeResetChatId: Int64 = 0
    @State var swipeResetGen: Int64 = 0
    // 编辑态拖动置顶会话（S1-02）
    @State var reorderChatId: Int64 = 0
    @State var reorderOffsetY: Float64 = 0.0
    private var reorderLastY: Float64 = 0.0
    private var reorderMoved: Bool = false
    private var editRowHeight: Float64 = 76.0
    @State var swipeRowPinned: Bool = false

    // 混合迁移：一次性初始化守卫（原 aboutToAppear 实逻辑挪至此）
    @State var loaded: Bool = false

    // iOS parity（TC-TAB-002）：重按 Chats tab 回顶用的 List scroller
    private var chatListScroller: Scroller = Scroller()

    var _chatListProjectionToken: Int64 = -1
    // 已应用到本页的最新投影 generation。快照回调从发布线程 launch{} 到 UI 线程，不同线程
    // 的 launch 不保证先后（真机：generation=329 chats=0 在 330 chats=19 之后才应用），
    // 旧快照迟到会把 VM 列表倒回空表，再由主 VM 的 dialogFilters/initialArchive 发布出去。
    // 只应用严格更新的 generation。
    var _lastAppliedProjectionGeneration: Int64 = 0

    // P2-318g: per-listener ID for account-switch listener (-1 = not registered)
    var _accountSwitchListenerId: Int64 = -1

    // P2-107: 多选编辑模式状态
    @State var isEditMode: Bool = false
    // CTL-CHATS-001: 编辑态选择控件滑入位移(0→44)
    @State var chatEditShift: Float64 = 0.0
    // CTL-SHARED-001: Edit 按钮按压(alpha 0.6)
    @State var editBtnPressed: Bool = false
    // P2-107: 当前已选中的对话 ID 集合（使用 ArrayList<Int64>，S-007 合规显式类型）
    @State var selectedChatIds: ArrayList<Int64> = ArrayList<Int64>()

    // 会话长按菜单的动作项（iOS chatContextMenuItems 的结果）。行数随来源变化：
    // 会话列表内是 标记已读/置顶/静音/删除；搜索到的未加入频道只有 Join Channel（CCM:471-476）。
    @State var chatActionItems: ArrayList<ChatListMenuItem> = ArrayList<ChatListMenuItem>()

    // ---- 通用上下文菜单（文件夹 tab / 归档行 / 搜索消息结果）----
    @State var showListMenu: Bool = false
    @State var listMenuItems: ArrayList<ChatListMenuItem> = ArrayList<ChatListMenuItem>()
    @State var listMenuX: Float64 = 0.0
    @State var listMenuY: Float64 = 0.0
    private var listMenuFolderId: Int32 = -1
    private var listMenuTarget: Chat = Chat()

    // 文件夹 tab 长按识别（ArkUI-CJ 无 LongPressGesture，与 ChatListItem 同一套 onTouch + 定时器）
    private var folderPressActive: Bool = false
    private var folderPressGeneration: Int64 = 0
    private var folderTouchStartX: Float64 = 0.0
    private var folderTouchStartY: Float64 = 0.0
    private var suppressNextFolderTap: Bool = false
    private var folderBarBottomY: Float64 = 0.0

    // 归档行：长按菜单 + 「隐藏在列表上方」（iOS ChatArchiveSettings.isHiddenByDefault）。
    // archiveRevealed = 隐藏态下被下拉临时露出（ChatListNode.revealScrollHiddenItem）。
    @State var archiveHidden: Bool = false
    // iOS ChatListController：代理列表非空（ProxySettings.servers 非空，不论是否启用）时
    // 导航栏多一个代理按钮，点按进 Proxy 设置（CLC:6822-6831、7314-7337）。
    @State var proxyConfigured: Bool = false
    private var _proxyWatchGeneration: Int64 = 0
    @State var archiveRevealed: Bool = false
    private var archiveRowTopY: Float64 = 0.0
    private var archiveRowHeight: Float64 = 0.0
    private var archivePressActive: Bool = false
    private var archivePressGeneration: Int64 = 0
    private var archiveTouchStartX: Float64 = 0.0
    private var archiveTouchStartY: Float64 = 0.0
    private var suppressNextArchiveTap: Bool = false
    private var listFirstVisibleIndex: Int64 = 0
    private var listPullStartY: Float64 = -1.0

    // 全局搜索：消息结果多选（iOS ChatListSearchContainerNode selectedMessageIds + 选择面板）
    @State var searchSelectionActive: Bool = false
    @State var searchSelectedKeys: ArrayList<String> = ArrayList<String>()
    // hashtag 查询的 PUBLIC POSTS 段与 Public Posts 标签（SLP:1128-1133、SCN:339-341）
    @State var publicPostsMirror: ArrayList<Chat> = ArrayList<Chat>()
    @State var isSearchingPublicPostsMirror: Bool = false
    @State var showPublicPostsTab: Bool = false
    @State var publicPostsPaneActive: Bool = false
    // Global search "Downloads" pane (ChatListSearchPaneKey.downloads).
    @State var downloadsPaneActive: Bool = false
    // 全局搜索分类标签：chats（默认）/ media / links / files / music / voice
    // （iOS defaultAvailableSearchPanes，SPC:102-123；tagMask 见 SLP:1807-1818）
    @State var searchPane: String = "chats"
    @State var filterResultsMirror: ArrayList<Chat> = ArrayList<Chat>()
    @State var isSearchingFilterMirror: Bool = false
    // 空查询时的 RECENT（最近搜索过的 peer）段 + Clear（SLP:306-308、SCN:268-290）
    @State var recentSearchPeers: ArrayList<Chat> = ArrayList<Chat>()
    // RECENT 段 Clear 的窗口坐标（vp），确认菜单锚在它下方（iOS ChatListSearchClearRecentReferenceContentSource）
    var recentClearAnchorX: Float64 = 0.0
    var recentClearAnchorTop: Float64 = 0.0
    var recentClearAnchorBottom: Float64 = 0.0
    // S9-23：MESSAGES 段右侧 "From All Chats" 范围按钮（iOS ChatListSearchMessagesScope 菜单）
    @State var messagesSearchScope: String = "all"
    var messagesScopeAnchorX: Float64 = 0.0
    var messagesScopeAnchorTop: Float64 = 0.0
    var messagesScopeAnchorBottom: Float64 = 0.0
    // S9-11：Channels 分类镜像（CHANNELS YOU JOINED / RECOMMENDED CHANNELS）
    @State var channelsJoinedMirror: ArrayList<Chat> = ArrayList<Chat>()
    @State var channelsRecommendedMirror: ArrayList<Chat> = ArrayList<Chat>()
    @State var isLoadingChannelsMirror: Bool = false

    /**
     * 页面初始化（混合迁移：根容器 .onAppear 触发，loaded 守卫只跑一次）
     */
    private func ensureLoaded(): Unit {
        if (this.loaded) {
            this.resumeAfterDisappear()
            return
        }
        this.loaded = true
        this.archiveHidden = isChatArchiveHiddenByDefault()
        this.registerChatListProjectionIfNeeded()
        if (!this.externalSearchVisible) { this.startProxyWatch() }

        // ── 搜索实例（MainTabPage index 4，externalSearchVisible = true）──
        //
        // MainTabPage 用「第二个完整的 ChatListPage」承载搜索界面（MainTabPage.cj:663），
        // 故本组件每次都被实例化两次；而 viewModel 是每实例各建一个
        // （@State var viewModel = ChatListViewModel()），并非共享单例。
        // 若两个实例都走完整初始化，则 getDifference / getDialogs / 轮询 / 监听器全部翻倍
        // —— 真机日志实证：每次冷启动都出现两条 "Loading real dialogs..." 与两次 getDifference。
        //
        // 对齐 iOS：ChatListController 全程只有一个实例，搜索是同一 display node 上挂的
        // searchDisplayController 覆盖层（ChatListController.swift:4676 activateSearch，
        // 仅当 `self.chatListDisplayNode.searchDisplayController == nil` 时才创建，
        // deactivateSearch 时移除），从不存在第二个会话列表。
        //
        // 在不重构 Tab 结构的前提下，让搜索实例只做渲染所需的最小初始化：
        //   - 不发起任何会话列表网络请求（搜索自身走 contacts.search / messages.searchGlobal，
        //     与会话列表拉取无关）
        //   - 不调 registerChatListVM —— 否则会覆盖主实例的注册，使 ChatRoomPage /
        //     ChatRoomViewModel 的 getChatListVM() 拿到搜索实例的 VM（错误刷新目标）
        //   - 不注册账号切换监听器与 tab 回顶（主实例已注册，重复注册会各触发一次）
        //   - 仍读本地缓存：搜索结果的 DIALOGS 段要用本地会话做匹配；纯本地读，不触网
        if (this.externalSearchVisible) {
            // 本地缓存只灌进本实例（投影为空时的兜底），不再发布到账号级投影：
            // Postbox 缓存不含本会话内的归档/取消归档等变更，发布出去会覆盖主实例的主列表。
            let cached = getChatListStore().loadLocalChats(20)
            if (!cached.isEmpty() && getChatListProjection().currentSnapshot().chats.isEmpty()) {
                launch {
                    this.viewModel.chatList = cached
                    let entries = ArrayList<ChatEntry>()
                    for (chat in this.viewModel.getFilteredChats()) { entries.add(ChatEntry(chat)) }
                    this.displayList = entries
                }
            }
            Hilog.info(0, "CjTelegram",
                "[ChatListPage] search instance: local-only init (${cached.size} cached chats), no network")
            return
        }

        // ── 主 Chats 实例（index 2）：完整初始化 ──
        // iOS parity（TC-TAB-002）：重按 Chats tab（index 2）→ 列表回顶
        registerTabRetapHandler(2, { =>
            this.chatListScroller.scrollTo(xOffset: 0.0, yOffset: 0.0)
        })
        registerChatListVM(this.viewModel)
        if (this.viewModel.chatList.isEmpty()) {
            this.viewModel.loadRealDialogs()
        }
        // 投影在页面建立前就已持有文件夹（热重建 / 账号切换后再进 Chats）：首帧即可见，
        // 没有 false → true 的翻转，也要核对一次真实挂载。
        if (this.folderTabsVisible) { this.armFolderTabsWatchdog(1) }

        // 初始化 CallService 并注册 updateCallback
        // 这样才能在主页面就接收到来电推送
        let _ = getCallService()

        // P2-318g: 注册账号切换监听器，账号切换后刷新聊天列表数据源。
        // 使用 per-ID API 确保 SettingsPage 的清理不会误清此监听器。
        // 监听器从 spawn{} 内被调用（非 UI 线程），刷新前需 launch{} 切回主线程（S-001 合规）。
        // 回归安全：单账号(不切换)不触发 switchAccount，此监听器不被调用，行为完全不变。
        this.registerAccountSwitchListenerIfNeeded()
    }

    /**
     * onDisAppear 只表示当前不可见，不代表组件销毁。返回同一个 Chats 实例时恢复
     * 展示镜像与账号监听，保留已有列表、筛选和滚动位置。
     */
    private func resumeAfterDisappear(): Unit {
        this.registerChatListProjectionIfNeeded()
        if (!this.externalSearchVisible) { this.startProxyWatch() }
        if (this.isSearchActive()) {
            this.startSearchMirrorSync()
        }
        if (!this.externalSearchVisible) {
            registerChatListVM(this.viewModel)
            this.registerAccountSwitchListenerIfNeeded()
        }
        Hilog.info(0, "CjTelegram", "[ChatListPage] resumed subscriptions after disappear")
    }

    private func registerAccountSwitchListenerIfNeeded(): Unit {
        if (this._accountSwitchListenerId >= 0) { return }
        this._accountSwitchListenerId = addAccountSwitchListenerWithId({ newSlot: Int32 =>
            Hilog.info(0, "CjTelegram", "[ChatListPage] Account switched to slot=${newSlot}, reloading chat list")
            // 重置 ViewModel 并重新加载活跃账号的对话列表（真实刷新，非假刷新）
            launch {
                this.viewModel.chatList = ArrayList<Chat>()
                this.viewModel.archiveChatList = ArrayList<Chat>()
                this.viewModel.resetDialogsPaging()
                this.viewModel.isLoading = true
                this.viewModel.publishCurrentChatList("accountSwitchReset")
            }
            launch {
                this.viewModel.loadRealDialogs()
                Hilog.info(0, "CjTelegram", "[ChatListPage] Chat list reload triggered for slot=${newSlot}")
            }
        })
        Hilog.info(0, "CjTelegram", "[ChatListPage] Registered account switch listener id=${this._accountSwitchListenerId}")
    }

    /**
     * 清理 — 注销账号切换监听器 + 停止同步循环（根容器 .onDisAppear 触发）
     */
    private func cleanup(): Unit {
        if (this._chatListProjectionToken >= 0) {
            getChatListProjection().removeSubscriber(this._chatListProjectionToken)
            this._chatListProjectionToken = -1
        }
        // P2-318g: 精准移除本页注册的监听器，不影响 SettingsPage 等其他消费者
        if (this._accountSwitchListenerId >= 0) {
            removeAccountSwitchListener(this._accountSwitchListenerId)
            Hilog.info(0, "CjTelegram", "[ChatListPage] cleanup: removed listener id=${this._accountSwitchListenerId}")
            this._accountSwitchListenerId = -1
        }
        this._searchSyncActive = false
        this._searchSyncGeneration += 1
        this._proxyWatchGeneration += 1
    }

    /**
     * 代理列表没有变更通知，主实例存活期间每秒读一次内存里的代理列表（纯内存读，不触网），
     * 只在有无变化时写 @State —— 对位 iOS 订阅 SharedDataKeys.proxySettings。
     */
    private func startProxyWatch(): Unit {
        this._proxyWatchGeneration += 1
        let generation = this._proxyWatchGeneration
        let _ = spawn {
            while (generation == this._proxyWatchGeneration) {
                let has = getProxyService().getProxies().size > 0
                launch {
                    if (this.proxyConfigured != has) { this.proxyConfigured = has }
                }
                sleep(Duration.millisecond * 1000)
            }
        }
    }

    /**
     * Phase 3：直接订阅账号级 ChatListProjection。
     *
     * 快照到达后在 UI 线程同步更新本实例 ViewModel 与页面自身 @State displayList，
     * 因此实时消息与本地列表操作均不再等待固定轮询节拍。
     */
    private func registerChatListProjectionIfNeeded(): Unit {
        if (this._chatListProjectionToken >= 0) { return }
        this._chatListProjectionToken = getChatListProjection().addSubscriber({ snapshot: ChatListProjectionSnapshot =>
            if (snapshot.generation == 0) { return }
            launch {
                if (this._chatListProjectionToken < 0) { return }
                if (snapshot.generation <= this._lastAppliedProjectionGeneration) {
                    Hilog.info(0, "CjTelegram",
                        "[ChatListPage] stale projection skipped generation=${snapshot.generation}, reason=${snapshot.reason}, applied=${this._lastAppliedProjectionGeneration}")
                    return
                }
                this._lastAppliedProjectionGeneration = snapshot.generation
                this.viewModel.adoptProjectedChats(snapshot.chats)
                this.viewModel.isLoading = snapshot.isLoading
                this.viewModel.dialogFilters = snapshot.dialogFilters
                this.viewModel.connectionStatus = snapshot.connectionStatus
                this.viewModel.hasActiveProxy = snapshot.hasActiveProxy
                let source = this.viewModel.getFilteredChats()
                let entries = ArrayList<ChatEntry>()
                for (chat in source) { entries.add(ChatEntry(chat)) }
                this.displayList = entries
                // 归档视图的加载态只看归档回源本身，不继承主列表快照的 isLoading。
                this.isPageLoading = if (this.viewModel.currentFolderId == 1) {
                    this.viewModel.archiveLoadInFlight
                } else {
                    snapshot.isLoading
                }
                this.folderTabsMirror = snapshot.dialogFilters
                this.currentFolderIdMirror = this.viewModel.currentFolderId
                this.syncFolderTabsVisibility(snapshot.generation, snapshot.reason)
                this.archiveCountMirror = this.viewModel.archiveChatList.size
                this.archiveUnreadChatsMirror = this.countArchiveUnreadChats()
                if (this.viewModel.currentFolderId == 1) {
                    Hilog.info(0, "CjTelegram",
                        "[ArchiveTrace] page applied reason=${snapshot.reason} archive=${this.viewModel.archiveChatList.size} display=${entries.size} loading=${this.isPageLoading} filter=${this.viewModel.currentFilterType}/${this.viewModel.activeFilterId}")
                }
                chatOpenPerfMark("listProjectionApplied reason=${snapshot.reason}")
                Hilog.info(0, "CjTelegram",
                    "[ChatListPage] projection applied generation=${snapshot.generation}, reason=${snapshot.reason}, chats=${entries.size}")
            }
        })
    }

    /**
     * 由已回写的镜像派生 tab 栏显隐（有自定义文件夹且不在归档视图），只在值变化时写
     * folderTabsVisible；翻到可见时布置一次看门狗核对真实挂载。仅在 UI 线程调用。
     */
    private func syncFolderTabsVisibility(generation: Int64, reason: String): Unit {
        let visible = folderTabsHaveCustom(this.folderTabsMirror) && this.currentFolderIdMirror != 1
        if (visible == this.folderTabsVisible) { return }
        this.folderTabsVisible = visible
        Hilog.info(0, "CjTelegram",
            "[ChatListPage] folder tabs visible=${visible} filters=${this.folderTabsMirror.size} folder=${this.currentFolderIdMirror} generation=${generation}, reason=${reason}")
        if (visible) { this.armFolderTabsWatchdog(1) }
    }

    /**
     * 看门狗：显隐已置 true 后 700ms 仍没有收到 tab 栏 Scroll 的 onAppear/onAreaChange，
     * 说明分支切换被框架漏掉；在这个安静回合里把 Bool 翻回 false，下一回合再置 true 并重发
     * 一份镜像副本，让 if 分支与 ForEach 都拿到全新通知。最多重试两次，每步 hilog 可对照。
     */
    private func armFolderTabsWatchdog(attempt: Int64): Unit {
        this._folderBarWatchdogGeneration += 1
        let generation = this._folderBarWatchdogGeneration
        let _ = spawn {
            sleep(Duration.millisecond * 700)
            launch {
                if (generation != this._folderBarWatchdogGeneration) { return }
                if (this._chatListProjectionToken < 0) { return }
                if (!this.folderTabsVisible || this._folderBarMounted) {
                    Hilog.info(0, "CjTelegram",
                        "[ChatListPage] folder tab bar check attempt=${attempt}: mounted=${this._folderBarMounted} visible=${this.folderTabsVisible}")
                    return
                }
                if (attempt > 2) {
                    Hilog.info(0, "CjTelegram",
                        "[ChatListPage] folder tab bar watchdog gave up after attempt=${attempt - 1}: visible but never mounted")
                    return
                }
                Hilog.info(0, "CjTelegram",
                    "[ChatListPage] folder tab bar watchdog attempt=${attempt}: visible but not mounted, re-driving state (filters=${this.folderTabsMirror.size})")
                this.folderTabsVisible = false
                launch {
                    if (generation != this._folderBarWatchdogGeneration) { return }
                    let refreshed = ArrayList<ChatFolder>()
                    for (folder in this.folderTabsMirror) { refreshed.add(folder) }
                    this.folderTabsMirror = refreshed
                    this.folderTabsVisible = folderTabsHaveCustom(refreshed) && this.currentFolderIdMirror != 1
                    if (this.folderTabsVisible) { this.armFolderTabsWatchdog(attempt + 1) }
                }
            }
        }
    }

    // P2-107: 判断对话是否已选中
    func isChatSelected(chatId: Int64): Bool {
        for (cid in this.selectedChatIds) {
            if (cid == chatId) { return true }
        }
        return false
    }

    // P2-107: 切换单个对话的选中状态
    func toggleChatSelection(chatId: Int64): Unit {
        let newList = ArrayList<Int64>()
        var removed = false
        for (cid in this.selectedChatIds) {
            if (cid == chatId) {
                removed = true
            } else {
                newList.add(cid)
            }
        }
        if (!removed) {
            newList.add(chatId)
        }
        this.selectedChatIds = newList
        this.refreshEditRows()
    }

    /** 收回指定行的滑动面板：键换代后重新发布 displayList，该行重建为未展开状态。 */
    func closeSwipeRow(chatId: Int64): Unit {
        this.swipeResetChatId = chatId
        this.swipeResetGen += 1
        let rows = ArrayList<ChatEntry>()
        for (entry in this.displayList) { rows.add(ChatEntry(entry.chat)) }
        this.displayList = rows
    }

    /** 普通模式行键：内容指纹；刚点过滑动动作的行追加代号，保证重建收回面板。 */
    func swipeRowKey(entry: ChatEntry): String {
        if (entry.chat.id == this.swipeResetChatId) {
            return "${entry}_sw${this.swipeResetGen}"
        }
        return "${entry}"
    }

    /** 选中集合变化后重新发布编辑态行（键里含选中态），勾选圈即时刷新。 */
    func refreshEditRows(): Unit {
        if (!this.isEditMode) { return }
        let rows = ArrayList<ChatEntry>()
        for (entry in this.displayList) { rows.add(entry) }
        this.displayList = rows
    }

    /**
     * 长按会话行 → 弹出上下文动作菜单。
     *
     * 对齐 iOS：会话列表长按打开的是 peer 的上下文菜单（chatContextMenuItems：
     * 标记未读/已读、置顶、静音、删除），多选编辑另有导航栏 Edit 入口
     * （ChatListController.swift:1926 起的 activateChatPreview 分支）。
     * 我们此前普通列表长按直接进多选编辑模式，菜单只挂在搜索结果行上。
     *
     * 三个开关必须从 chat 实体读真值：搜索行此前一律写死 false，
     * 于是已置顶的会话在菜单里仍显示「置顶」、已静音的仍显示「静音」。
     */
    func presentChatActionSheet(chat: Chat, sourceY!: Float64 = 0.0, sourceHeight!: Float64 = 0.0, fromSearch!: Bool = false): Unit {
        this.chatActionItems = this.buildChatActionItems(chat, fromSearch)
        if (this.chatActionItems.isEmpty()) { return }
        this.selectedChatId = chat.id
        this.selectedChatName = chat.name
        this.selectedChatPeerType = chat.peerType
        this.selectedChatPinned = chat.isPinned
        this.selectedChatMuted = chat.isMuted
        this.selectedChatUnread = chat.unreadCount > 0
        this.contextSourceY = sourceY
        this.contextSourceHeight = sourceHeight
        this.actionHighlightIndex = -1
        this.resetContextGesture()
        this.contextPreviewAvatar = chat.avatarLocalPath
        this.contextPreviewSubtitle = previewSubtitleFor(chat)
        this.contextPreviewMessages = ArrayList<Message>()
        this.contextPreviewSettled = false
        this.contextPreviewFirstVisible = -1
        this.contextPreviewAnchor.reset()
        this._previewRenderKey = ""
        this.contextPreviewShowScrollDown = false
        // 复用聊天页的 ViewModel：本地秒开 + 媒体回填 + 后台刷新全部沿用，
        // 但不轮询、不注册推送、不上报已读（见 ChatRoomViewModel.initPreview）。
        let previewChatId = chat.id
        this.contextPreviewVM.setMessagesChangedHandler({ => this.publishPreviewMessages() })
        this.contextPreviewVM.initPreview(chat.id, chat.name, chat.peerType)
        spawn {
            // 等列表挂载并落到底部之后才允许翻页，避开首帧自动触发的 onReachStart
            sleep(Duration.millisecond * 120)
            launch {
                if (this.selectedChatId == previewChatId) {
                    try {
                        this.contextPreviewScroller.scrollEdge(Edge.Bottom)
                    } catch (_e: Exception) {}
                    this.contextPreviewSettled = true
                }
            }
        }
        // 从被按行处弹出：先归零，再在同一帧后做弹簧展开
        this.actionPanelScale = 0.01
        this.actionPanelPresented = false
        // 起跳位移：被按行中心 → 预览卡中心
        this.previewOffsetY = (sourceY + sourceHeight / 2.0) - (this.previewY() + this.previewHeight() / 2.0)
        this.showActionSheet = true
        this.setContextSystemBars(true)
        safeAnimateTo(
            { => this.getUIContext() },
            AnimateParam(duration: 420, curve: Curve.Friction),
            { =>
                this.actionPanelScale = 1.0
                this.actionPanelPresented = true
                this.previewOffsetY = 0.0
            }
        )
        // iOS 的 didCompleteAnimationIn：入场动画跑完之前，手指移动一律不高亮
        spawn {
            sleep(Duration.millisecond * 420)
            launch {
                if (this.showActionSheet && this.selectedChatId == previewChatId) {
                    this.contextGestureArmed = true
                }
            }
        }
    }

    /**
     * 会话长按菜单的动作项 —— 对位 iOS chatContextMenuItems（ChatContextMenus.swift）。
     *   会话已在列表（peerGroup != nil）：标记已读/未读、置顶、静音、删除；
     *   搜索来源且会话不在列表（peerGroup == nil）：频道给 Join Channel、超级群给 Join Chat
     *   （:471-476），加入后直接进入会话（:527-537）。
     */
    private func buildChatActionItems(chat: Chat, fromSearch: Bool): ArrayList<ChatListMenuItem> {
        let items = ArrayList<ChatListMenuItem>()
        if (fromSearch && !this.viewModel.isChatInList(chat.id)) {
            if (chat.peerType == "channel") {
                if (chat.isMegagroup) {
                    items.add(ChatListMenuItem("join", this.localized("ChatList_Context_JoinChat", "Join Chat"), "add"))
                } else {
                    items.add(ChatListMenuItem("join", this.localized("ChatList_Context_JoinChannel", "Join Channel"), "add"))
                }
                return items
            }
        }
        // S1-47：非联系人的普通用户（非 bot / 非自己 / 非 support / 未注销）首项 Add to Contacts
        // （ChatContextMenus.swift:181-198，加入后该项不再出现）。
        if (this.chatOffersAddToContacts(chat)) {
            items.add(ChatListMenuItem("addContact", this.localized("ChatList_Context_AddToContacts", "Add to Contacts"), "add"))
        }
        // S1-37：当前停在自定义文件夹 tab 时首项 Remove from Folder（ChatContextMenus.swift:218-243，
        // 语义为 addExcludePeer：从 include/pinned 摘掉并加入 exclude）。
        if (!fromSearch && this.viewModel.activeFilterId >= 0 && this.currentFolderIdMirror != 1) {
            items.add(ChatListMenuItem("removeFromFolder", this.localized("ChatList_Context_RemoveFromFolder", "Remove from Folder"), "folder", separatorBefore: !items.isEmpty()))
        }
        if (chat.unreadCount > 0 || chat.isMarkedUnread) {
            items.add(ChatListMenuItem("markRead", this.localized("ChatList_Context_MarkAsRead", "Mark as Read"), "read"))
        } else {
            items.add(ChatListMenuItem("markUnread", this.localized("ChatList_Context_MarkAsUnread", "Mark as Unread"), "unread"))
        }
        if (chat.isPinned) {
            items.add(ChatListMenuItem("pin", this.localized("ChatList_Context_Unpin", "Unpin"), "unpin"))
        } else {
            items.add(ChatListMenuItem("pin", this.localized("ChatList_Context_Pin", "Pin"), "pin"))
        }
        if (chat.isMuted) {
            items.add(ChatListMenuItem("mute", this.localized("ChatList_Context_Unmute", "Unmute"), "unmute"))
        } else {
            items.add(ChatListMenuItem("mute", this.localized("ChatList_Context_Mute", "Mute"), "mute"))
        }
        items.add(ChatListMenuItem("delete", this.localized("ChatList_Context_Delete", "Delete"), "delete", destructive: true))
        return items
    }

    /**
     * 预览内向上翻历史 —— 交给 ViewModel 的 loadMoreHistory，与聊天室同一条实现。
     *
     * 触发前先记锚点：头插会把可见内容整体推下去，必须在新快照落地的同一轮
     * UI 更新里把锚点钉回原像素位置（见 HistoryAnchorKeeper）。
     */
    func loadOlderPreviewMessages(): Unit {
        // 首帧 scrollEdge 未落地前不翻页：此时 List 的可见索引还是 0，
        // onReachStart / onScrollIndex 都会自动触发一次，会立刻把窗口往前拉。
        if (!this.contextPreviewSettled) { return }
        if (!this.contextPreviewVM.hasMoreHistory || this.contextPreviewVM.isPagingLocal) { return }
        let current = this.contextPreviewMessages
        let idx = this.contextPreviewFirstVisible
        if (idx >= 0 && idx < current.size) {
            this.contextPreviewAnchor.capture(
                this.contextPreviewScroller, idx, current[idx].identityKey())
        }
        Hilog.info(0, "CjTelegram",
            "[PreviewPaging] loadOlder trigger firstVisible=${idx} size=${current.size} hasMore=${this.contextPreviewVM.hasMoreHistory}")
        this.contextPreviewVM.loadMoreHistory()
    }

    /**
     * 把 ViewModel 的快照推给渲染镜像。
     * 分组标记是 UI 派生字段，每次重算；随后在同一轮更新里恢复锚点。
     */
    private func publishPreviewMessages(): Unit {
        let items = this.contextPreviewVM.messageList
        computeMessageGroupPositions(items)
        // 渲染幂等：VM 每次媒体回填 / 网络刷新都会推快照，若最终渲染产物一样就别换列表，
        // 否则 ForEach 全量重挂、滚动位置丢失（同 ChatRoomPage._lastRenderKey 的作用）。
        var renderKey = ""
        for (m in items) {
            renderKey = renderKey + previewItemKey(m) + "|"
        }
        if (renderKey == this._previewRenderKey && !this.contextPreviewAnchor.hasPending) {
            return
        }
        this._previewRenderKey = renderKey
        this.contextPreviewMessages = items
        Hilog.info(0, "CjTelegram",
            "[PreviewPaging] publish size=${items.size} anchorPending=${this.contextPreviewAnchor.hasPending}")
        if (this.contextPreviewAnchor.hasPending) {
            let target = this.contextPreviewAnchor.stableId
            var anchorIndex: Int64 = -1
            var i: Int64 = 0
            while (i < items.size) {
                if (items[i].identityKey() == target) {
                    anchorIndex = i
                    break
                }
                i += 1
            }
            let _ = this.contextPreviewAnchor.restore(this.contextPreviewScroller, anchorIndex)
        }
    }

    /** 关闭上下文菜单：顺带停掉预览的媒体任务并清空容器 */
    func dismissChatContextMenu(restoreWindow!: Bool = true): Unit {
        this.showActionSheet = false
        this.actionHighlightIndex = -1
        this.resetContextGesture()
        if (restoreWindow) {
            this.setContextSystemBars(false)
        } else {
            // 紧接着要进聊天页，由它自己接管窗口布局与系统栏；这里再恢复一次会跟它抢，
            // 顺序还不确定（我们是 spawn，它是 ArkTS 的 promise 链）。
            this.onContextOverlayChange(false)
        }
        this.contextPreviewSettled = false
        this.contextPreviewAnchor.reset()
        this.contextPreviewVM.cleanupPreview()
        this.contextPreviewMessages = ArrayList<Message>()
    }

    /** 预览内回到最新消息 */
    func scrollPreviewToLatest(): Unit {
        try {
            this.contextPreviewScroller.scrollEdge(Edge.Bottom)
        } catch (_e: Exception) {}
        this.contextPreviewShowScrollDown = false
    }

    /** 打开预览对应的会话 —— iOS 点预览即把它升格为真正的聊天页 */
    func openPreviewedChat(): Unit {
        let cid = this.selectedChatId
        let cname = this.selectedChatName
        let ptype = this.selectedChatPeerType
        // 走统一出口，确保 tab bar 滑回、预览 VM 被清理
        this.dismissChatContextMenu(restoreWindow: false)
        // 已读提交同列表行点按：由 ChatRoomPage.ensureLoaded 在首屏之后完成。
        chatOpenPerfBegin(cid, ptype)
        setSelectedChat(cid, cname, ptype)
        setSelectedChatDraft("")
        routerPush("ChatRoomPage", cname)
        chatOpenPerfMark("navigateIssued")
    }

    // ---- 浮层几何 ----
    //
    // iOS：预览卡左右各内缩 12、最大高 460、圆角 30，整体在屏幕纵向居中
    // （ContextControllerExtractedPresentationNode.swift:988-1028）；
    // 动作面板贴在预览下方 10vp，并与预览右缘对齐（:1228-1276）。

    private func actionPanelHeight(): Float64 {
        return chatActionPanelHeight(this.chatActionItems.size)
    }

    func previewWidth(): Float64 {
        return this.screenWidthVp - 24.0
    }

    // 浮层坐标系里的可用纵向区间：卡片要待在窗口内容区里，上不压页面顶、
    // 下不越底部手势区。overlayHeightVp 未测到时退回按页面高度算，首帧也有合理值。
    private func contextUsableTop(): Float64 {
        if (this.overlayHeightVp <= 0.0) { return 0.0 }
        return this.contentTopVp
    }

    private func contextUsableBottom(): Float64 {
        if (this.overlayHeightVp <= 0.0) {
            return this.screenHeightVp - CHAT_CONTEXT_BOTTOM_INSET
        }
        return this.overlayHeightVp - CHAT_CONTEXT_BOTTOM_INSET
    }

    func previewHeight(): Float64 {
        // 上下各留 24
        let available = (this.contextUsableBottom() - this.contextUsableTop()) - 48.0
            - this.actionPanelHeight() - 10.0
        if (available < 160.0) { return 160.0 }
        if (available > 460.0) { return 460.0 }
        return available
    }

    /** 预览 + 间距 + 动作面板作为一个整体在安全区内纵向居中 */
    func previewY(): Float64 {
        let total = this.previewHeight() + 10.0 + this.actionPanelHeight()
        let usableTop = this.contextUsableTop()
        let usableBottom = this.contextUsableBottom()
        var top = usableTop + ((usableBottom - usableTop) - total) / 2.0
        let maxTop = usableBottom - 24.0 - total
        if (top > maxTop) { top = maxTop }
        if (top < usableTop + 24.0) { return usableTop + 24.0 }
        return top
    }

    /** 面板左缘：与预览卡右缘对齐 */
    func actionPanelX(): Float64 {
        let x = 12.0 + this.previewWidth() - CHAT_ACTION_PANEL_WIDTH
        if (x < 12.0) { return 12.0 }
        return x
    }

    /** 面板顶缘：预览卡下方 10vp */
    func actionPanelY(): Float64 {
        return this.previewY() + this.previewHeight() + 10.0
    }

    // ==================== 长按上下文菜单：连续手势 ====================
    //
    // 动作面板的行几何。面板从 onAreaChange 拿到窗口 Y，行的相对位置由这组常量推出：
    //   面板顶即第一行顶（iOS 的动作面板没有标题头），每行 44、行间分隔线 1。
    // 之所以用常量而不是逐行测量：ArkUI 没有给 ForEach 子项暴露逐项几何，
    // 而这份面板的行高在本文件内是固定值，改布局时同步改这里即可。
    /**
     * 菜单期间把浮层够不到的两条边染成同色。
     *
     * 遮罩只能铺满页面的安全区，上下各露一条白边，来源并不相同：
     *   顶部 —— 系统状态栏是独立窗口（hidumper 里的 SCBStatusBar，1080x108），
     *           压在应用窗口之上，只能用 setWindowSystemBarProperties 染；
     *   底部 —— 应用窗口本身是全屏的（telegram0 [0 0 1080 2406]），
     *           页面根节点被安全区内缩，指示条那一带露的是窗口背景色。
     * 页面内 expandSafeArea 对两者都无效：菜单在 Tabs/TabContent 里，会被裁掉。
     * 染色值取遮罩压在白底上的等效色：#000A26 @20% over #FFFFFF = #CCCED3。
     */
    private func setContextSystemBars(active: Bool): Unit {
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                let color = if (active) { "#FFCCCED3" } else { "#FFFFFFFF" }
                let _ = spawn {
                    try {
                        let win = getLastWindow(ctx)
                        // 窗口在 EntryAbility 里已是全屏布局，这里只染系统栏颜色；
                        // 切回非全屏会让各页在安全区之外再多出一条空白。
                        win.setWindowSystemBarProperties(
                            SystemBarProperties(
                                statusBarColor: color,
                                statusBarContentColor: "#FF000000",
                                navigationBarColor: color,
                                navigationBarContentColor: "#FF000000"
                            )
                        )
                    } catch (_: Exception) {
                        Hilog.warn(0, "CjTelegram", "[ChatListPage] context tint failed (non-fatal)")
                    }
                    // 布局模式落地之后再翻 MainTabPage 的补偿内边距：反过来的话，
                    // 内容会先被内缩一整个安全区、下一帧才撑开，肉眼是一次抖动。
                    launch { this.onContextOverlayChange(active) }
                }
            case None => this.onContextOverlayChange(active)
        }
    }

    /** 清掉连续手势的三道门，菜单每次弹出/收起都要归零 */
    private func resetContextGesture(): Unit {
        this.contextGestureArmed = false
        this.contextGestureHasAnchor = false
        this.contextGestureAnchorY = 0.0
        this.contextGestureEngaged = false
    }

    /**
     * 窗口坐标 → 动作行下标；不在任何一行上（含分隔线、面板之外）返回 -1。
     *
     * 横向也必须判：面板只有 240 宽、贴在预览卡右缘，此前只比 Y，手指落在面板左边
     * 那片空白上照样算命中同一行，抬手就把它执行了。iOS 是拿 actionNode(at:) 做真正的
     * 命中测试，落在面板之外一律返回 nil（ContextControllerImpl.swift:300-305）。
     */
    private func contextRowAt(x: Float64, y: Float64): Int64 {
        if (this.actionPanelTop <= 0.0) { return -1 }
        if (x < this.actionPanelLeft || x >= this.actionPanelLeft + CHAT_ACTION_PANEL_WIDTH) {
            return -1
        }
        let local = y - this.actionPanelTop
        var i: Int64 = 0
        while (i < this.chatActionItems.size) {
            let top = chatActionRowTop(i)
            // 落在行间分隔线上不算命中，高亮更跳
            if (local >= top && local < top + CHAT_ACTION_ROW_HEIGHT) {
                return i
            }
            i += 1
        }
        return -1
    }

    /** 换高亮行：跨行给一次轻触觉，离开面板则清空（iOS ContextControllerImpl.swift:306-313） */
    private func setActionHighlight(index: Int64): Unit {
        if (index == this.actionHighlightIndex) { return }
        if (index >= 0) {
            triggerHaptic("impact", "light")
        }
        this.actionHighlightIndex = index
    }

    /**
     * 长按激活后手指移动 —— 按窗口坐标高亮对应动作行。
     *
     * 对齐 iOS ContextControllerImpl.swift:288-315：入场动画跑完（armed）之后记下第一个
     * 落点当锚点，纵向离开锚点 4vp 才算「开始滑选」，此前手指怎么抖都不高亮。
     */
    func handleContextGestureMove(x: Float64, y: Float64): Unit {
        if (!this.showActionSheet || !this.contextGestureArmed) { return }
        if (!this.contextGestureHasAnchor) {
            this.contextGestureHasAnchor = true
            this.contextGestureAnchorY = y
            return
        }
        if (!this.contextGestureEngaged) {
            let dy = y - this.contextGestureAnchorY
            let dist = if (dy < 0.0) { -dy } else { dy }
            if (dist <= 4.0) { return }
            this.contextGestureEngaged = true
        }
        this.setActionHighlight(this.contextRowAt(x, y))
    }

    /**
     * 长按手指抬起 —— 只有滑动过（engaged）才执行选中的那一行。
     *
     * iOS 里 externalEnded 先看 didMoveFromInitialGesturePoint：没动过就什么都不做，
     * 菜单留在屏幕上等用户点或者重新按住滑（ContextControllerImpl.swift:323-337）。
     */
    func handleContextGestureEnd(): Unit {
        if (!this.showActionSheet) {
            this.resetContextGesture()
            return
        }
        let index = this.actionHighlightIndex
        let engaged = this.contextGestureEngaged
        this.actionHighlightIndex = -1
        // 手势一次性：这一轮结束后由动作行自己的触摸接管（handleRowPress 等）
        this.resetContextGesture()
        this.contextGestureArmed = true
        if (engaged && index >= 0 && index < this.chatActionItems.size) {
            this.performChatAction(index)
        }
    }

    // ---- 菜单已在屏幕上时，直接按住面板滑选 ----
    //
    // iOS 的动作行本身就是可按压的（ContextActionNode 的 touch down 即高亮、抬手执行），
    // 所以第一次长按松手之后再按住菜单滑动，手感与长按连贯滑选完全一致。
    // 触摸挂在每一行上而不是面板容器上：容器的 onTouch 收不到子节点冒泡上来的事件，
    // 点击会完全没反应。逐行挂顺带让点击不依赖任何坐标换算。

    /** 按在某一行上 —— 直接用行自己的下标，不做坐标换算 */
    func handleRowPress(index: Int64): Unit {
        this.setActionHighlight(index)
    }

    /** 抬手：执行当前高亮的那一行（滑到别的行上时 handlePanelTouchMove 已经改过它） */
    func handleRowRelease(): Unit {
        let index = this.actionHighlightIndex
        this.actionHighlightIndex = -1
        if (index >= 0 && index < this.chatActionItems.size) {
            this.performChatAction(index)
        }
    }

    /** 手指在面板上移动：按窗口坐标改高亮，跨行才有效（行外返回 -1） */
    func handlePanelTouchMove(x: Float64, y: Float64): Unit {
        this.setActionHighlight(this.contextRowAt(x, y))
    }

    func handlePanelTouchCancel(): Unit {
        this.actionHighlightIndex = -1
    }

    /**
     * 动作面板的统一执行入口 —— 点击与滑动选中共用同一份实现。
     * 索引与面板中行的先后一致：标记已读未读 / 置顶 / 静音 / 删除。
     */
    func performChatAction(index: Int64): Unit {
        if (index < 0 || index >= this.chatActionItems.size) { return }
        let key = this.chatActionItems[index].key
        match (key) {
            case "markRead" | "markUnread" =>
                this.viewModel.toggleMarkUnread(this.selectedChatId)
                // 乐观翻转本地状态（toggleMarkUnread 内部也已更新，此处同步 UI 选中状态）
                this.selectedChatUnread = !this.selectedChatUnread
                this.dismissChatContextMenu()
            case "pin" =>
                this.viewModel.togglePinChat(this.selectedChatId)
                this.dismissChatContextMenu()
            case "mute" =>
                this.viewModel.toggleMuteChatWithUndo(this.selectedChatId)
                this.dismissChatContextMenu()
            case "delete" =>
                let cid = this.selectedChatId
                let cname = this.selectedChatName
                let ptype = this.selectedChatPeerType
                this.dismissChatContextMenu()
                // main 已把所有 peer 类型收敛到同一确认卡片与可撤销删除漏斗。
                // 保留本地长按浮层，仅更新删除动作的下层 API 接线。
                this.openDeleteChatPeerSheet(cid, cname, ptype)
            case "join" =>
                let cid = this.selectedChatId
                let cname = this.selectedChatName
                this.dismissChatContextMenu()
                this.joinChannelFromSearch(cid, cname)
            case "addContact" =>
                let cid = this.selectedChatId
                let cname = this.selectedChatName
                this.dismissChatContextMenu()
                this.openNewContactSheet(cid, cname)
            case "removeFromFolder" =>
                let cid = this.selectedChatId
                let cname = this.selectedChatName
                let ptype = this.selectedChatPeerType
                this.dismissChatContextMenu()
                this.removeChatFromCurrentFolder(cid, cname, ptype)
            case _ => ()
        }
    }

    /** S1-47：iOS ChatContextMenus.swift:181-183 —— 普通用户且 !isContact 才给 Add to Contacts。 */
    private func chatOffersAddToContacts(chat: Chat): Bool {
        if (normalizeDialogPeerType(chat.peerType) != "user") { return false }
        if (chat.isBot || chat.isSavedMessages || chat.isDeletedAccount || chat.isSecretChat) { return false }
        if (chat.id == getCurrentUserId()) { return false }
        match (this.lookupCachedUser(chat.id)) {
            case Some(user) =>
                if (user.isContact || user.isSupport || user.isBot || user.isSelf) { return false }
                return true
            case None => return false
        }
    }

    private func lookupCachedUser(userId: Int64): Option<UserResponse> {
        match (getUserPhotoService().getCachedUser(userId)) {
            case Some(u) => return Some(u)
            case None => return getRealChatListService().getCachedUser(userId)
        }
    }

    /** S1-47：iOS openAddPersonContact → NewContactScreen（首/末名 + Done）。 */
    private func openNewContactSheet(userId: Int64, fallbackName: String): Unit {
        var first = fallbackName
        var last = ""
        var phone = ""
        match (this.lookupCachedUser(userId)) {
            case Some(u) =>
                if (u.firstName.size > 0 || u.lastName.size > 0) {
                    first = u.firstName
                    last = u.lastName
                }
                phone = u.phone
            case None => ()
        }
        this.newContactUserId = userId
        this.newContactFirstName = first
        this.newContactLastName = last
        this.newContactPhone = phone
        this.newContactBusy = false
        this.showNewContactSheet = true
    }

    private func saveNewContact(): Unit {
        if (this.newContactBusy) { return }
        let first = this.newContactFirstName.trimAscii()
        if (first.isEmpty()) { return }
        let last = this.newContactLastName.trimAscii()
        let phone = this.newContactPhone
        let uid = this.newContactUserId
        this.newContactBusy = true
        let _ = spawn {
            let ok = getChatComposeExtrasService().addPeerContact(uid, first, last, phone, false)
            Hilog.info(0, "CjTelegram", "[ChatListPage] addContact from search uid=${uid} ok=${ok}")
            launch {
                this.newContactBusy = false
                if (ok) {
                    this.showNewContactSheet = false
                    match (getUserPhotoService().getCachedUser(uid)) {
                        case Some(u) => u.isContact = true
                        case None => ()
                    }
                    match (getRealChatListService().getCachedUser(uid)) {
                        case Some(u) => u.isContact = true
                        case None => ()
                    }
                    // iOS AddContact.StatusSuccess
                    showToast("${first} is now in your contacts list.")
                } else {
                    showToast(trSource("An error occurred."))
                }
            }
        }
    }

    /**
     * S1-37：iOS ChatContextMenus.swift:218-243 —— 当前文件夹 data.addExcludePeer(peer)：
     * 从 includePeers / pinnedPeers 移除并加入 excludePeers，updateChatListFiltersInteractively
     * 落服务端后弹 ChatList_RemovedFromFolderTooltip。本地先生效（tab 列表立即少一行），
     * RPC 失败则回拉服务端文件夹并提示。
     */
    private func removeChatFromCurrentFolder(chatId: Int64, chatName: String, peerType: String): Unit {
        let folderId = this.viewModel.activeFilterId
        if (folderId < 0) { return }
        var target: Option<ChatFolder> = None
        for (f in this.viewModel.dialogFilters) {
            if (f.id == folderId) { target = Some(f) }
        }
        let folder = match (target) {
            case Some(f) => f
            case None => return
        }
        let updated = folder.copy()
        let keptInclude = ArrayList<Int64>()
        for (pid in updated.includePeers) { if (pid != chatId) { keptInclude.add(pid) } }
        updated.includePeers = keptInclude
        let keptIncludeRefs = ArrayList<ChatFolderPeer>()
        for (p in updated.includePeerRefs) { if (p.id != chatId) { keptIncludeRefs.add(p) } }
        updated.includePeerRefs = keptIncludeRefs
        let keptPinned = ArrayList<Int64>()
        for (pid in updated.pinnedPeers) { if (pid != chatId) { keptPinned.add(pid) } }
        updated.pinnedPeers = keptPinned
        if (!updated.excludePeers.contains(chatId)) {
            updated.excludePeers.add(chatId)
            let ref = ChatFolderPeer()
            ref.id = chatId
            ref.peerType = normalizeDialogPeerType(peerType)
            ref.name = chatName
            if (ref.peerType == "user") {
                ref.accessHash = getRealMessageService().getAccessHashForUser(chatId)
            } else if (ref.peerType == "channel") {
                ref.accessHash = getRealMessageService().getAccessHashForChannel(chatId)
            }
            updated.excludePeerRefs.add(ref)
        }
        let filters = ArrayList<ChatFolder>()
        for (f in this.viewModel.dialogFilters) {
            if (f.id == folderId) { filters.add(updated) } else { filters.add(f) }
        }
        this.viewModel.applyLocalDialogFilters(filters, "removeFromFolder")
        let folderTitle = folder.name
        let tooltip = this.localized("ChatList_RemovedFromFolderTooltip", "%1$@ has been removed from folder %2$@")
        spawn {
            let ok = getChatFolderLinksService().updateDialogFilter(updated)
            Hilog.info(0, "CjTelegram", "[ChatListPage] removeFromFolder chatId=${chatId} folder=${folderId} ok=${ok}")
            launch {
                if (ok) {
                    // iOS 这里 present 的是 UndoOverlayController(.chatRemovedFromFolder)（页内浮条，
                    // action 恒 false = 无 Undo 按钮），不是系统 toast；W3 实测 ToastHost 的
                    // TopMost 原生 toast 在本页看不到，改走同一载体 UndoToast（showAction/showProgress 关）。
                    getUndoToastService().showUndo(
                        tooltip.replace("%1$@", chatName).replace("%2$@", folderTitle),
                        showProgress: false, showAction: false)
                } else {
                    showToast(trSource("An error occurred."))
                    this.viewModel.loadFilters()
                }
            }
        }
    }

    /** S1-47：iOS NewContactScreen（与 ChatRoomPage.newContactSheet 同款）。 */
    @Builder
    func buildNewContactSheet() {
        if (this.showNewContactSheet) {
            Stack(alignContent: Alignment.Bottom) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x66000000)
                    .onClick({ _evt => this.showNewContactSheet = false })
                Column {
                    Row {
                        Text(trSource("Cancel"))
                            .fontSize(17)
                            .fontColor(0xFF007AFF)
                            .onClick({ _evt => this.showNewContactSheet = false })
                        Blank()
                        Text("New Contact")
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.textColor)
                        Blank()
                        Text(trSource("Done"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(if (this.newContactFirstName.trimAscii().isEmpty() || this.newContactBusy) { 0xFFAEAEB2 } else { 0xFF007AFF })
                            .onClick({ _evt => this.saveNewContact() })
                    }
                    .width(100.percent)
                    .height(52)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)

                    Column {
                        TextInput(text: this.newContactFirstName, placeholder: "First Name")
                            .height(44)
                            .backgroundColor(Color.Transparent)
                            .fontColor(this.presentation.textColor)
                            .onChange({ v: String => this.newContactFirstName = v })
                        Divider().color(0x1F000000).strokeWidth(0.5).margin(left: 16)
                        TextInput(text: this.newContactLastName, placeholder: "Last Name")
                            .height(44)
                            .backgroundColor(Color.Transparent)
                            .fontColor(this.presentation.textColor)
                            .onChange({ v: String => this.newContactLastName = v })
                    }
                    .width(100.percent)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)

                    Row {
                        Text("mobile")
                            .fontSize(15)
                            .fontColor(this.presentation.textColor)
                        Blank()
                        Text(if (this.newContactPhone.isEmpty()) { "Hidden" } else { "+" + this.newContactPhone })
                            .fontSize(15)
                            .fontColor(0xFF8E8E93)
                    }
                    .width(100.percent)
                    .height(44)
                    .padding(left: 16, right: 16)
                    .margin(top: 16)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(10)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 34)
                .backgroundColor(this.presentation.backgroundColor)
                .borderRadius(topLeft: 12, topRight: 12)
                .onClick({ _evt => })
            }
            .width(100.percent)
            .height(100.percent)
        }
    }

    /**
     * 搜索结果长按 → Join Channel / Join Chat。
     * 对位 iOS ChatContextMenus.swift:477-537：peerChannelMemberCategoriesContextsManager.join →
     * 成功后 navigateToChatController 进入该会话；失败弹 Login_UnknownError。
     */
    private func joinChannelFromSearch(channelId: Int64, name: String): Unit {
        let _ = spawn {
            let msgSvc = getRealMessageService()
            let ok = msgSvc.joinChannel(channelId, msgSvc.getAccessHashForChannel(channelId))
            Hilog.info(0, "CjTelegram", "[ChatListPage] join from search channelId=${channelId} ok=${ok}")
            if (ok) {
                match (getRealChatListService().getCachedChat(channelId)) {
                    case Some(cached) => cached.isLeft = false
                    case None => ()
                }
            }
            launch {
                if (!ok) {
                    showToast(trSource("An error occurred."))
                    return
                }
                this.viewModel.refreshWithPullDown()
                setSelectedChat(channelId, name, "channel")
                setSelectedChatDraft("")
                setSelectedChatUsername("")
                routerPush("ChatRoomPage", name)
            }
        }
    }


    // ==================== 通用上下文菜单（文件夹 tab / 归档行 / 搜索消息结果） ====================

    private func listMenuHeight(): Float64 {
        var h: Float64 = 0.0
        for (item in this.listMenuItems) {
            h += LIST_MENU_ROW_HEIGHT
            if (item.separatorBefore) { h += LIST_MENU_SEPARATOR_HEIGHT }
        }
        return h
    }

    /**
     * 弹出菜单：anchorTop/anchorBottom 为来源控件的窗口 Y（vp），anchorX 为横向锚点。
     * 下方放得下就贴在来源下方，否则翻到上方（iOS ContextControllerActionsStackNode 的上下翻转）。
     */
    private func presentListMenu(items: ArrayList<ChatListMenuItem>, anchorX: Float64, anchorTop: Float64, anchorBottom: Float64): Unit {
        if (items.isEmpty()) { return }
        this.listMenuItems = items
        let pageTop = this.contentTopVp
        let pageHeight = if (this.overlayHeightVp > 0.0) { this.overlayHeightVp } else { this.screenHeightVp }
        let h = this.listMenuHeight()
        var y = anchorBottom - pageTop + 6.0
        if (y + h > pageHeight - CHAT_CONTEXT_BOTTOM_INSET) {
            y = anchorTop - pageTop - 6.0 - h
        }
        if (y < 8.0) { y = 8.0 }
        var x = anchorX - LIST_MENU_WIDTH / 2.0
        if (x + LIST_MENU_WIDTH > this.screenWidthVp - 8.0) { x = this.screenWidthVp - 8.0 - LIST_MENU_WIDTH }
        if (x < 8.0) { x = 8.0 }
        this.listMenuX = x
        this.listMenuY = y
        triggerHaptic("impact", "light")
        this.showListMenu = true
        this.onContextOverlayChange(true)
    }

    private func dismissListMenu(): Unit {
        this.showListMenu = false
        this.onContextOverlayChange(false)
    }

    func performListMenuAction(key: String): Unit {
        let folderId = this.listMenuFolderId
        let target = this.listMenuTarget
        this.dismissListMenu()
        match (key) {
            // 文件夹 tab（CLC:1024-1270）
            case "editFolder" => routerPush("ChatFolderEditorPage", folderId.toString())
            case "addChats" => this.openAddChatsToFolder(folderId)
            case "readAll" => this.readAllInFolder(folderId)
            case "muteAll" => this.setFolderMuted(folderId, true)
            case "unmuteAll" => this.setFolderMuted(folderId, false)
            case "shareFolder" => this.shareFolder(folderId)
            case "removeFolder" => this.askForFolderRemoval(folderId)
            case "editFolders" => routerPush("ChatFoldersPage", "")
            case "reorderTabs" => routerPush("ChatFoldersPage", "")
            // S9-23：MESSAGES 段范围
            case "searchScopeAll" => this.applyMessagesScope("all")
            case "searchScopeUsers" => this.applyMessagesScope("users")
            case "searchScopeGroups" => this.applyMessagesScope("groups")
            case "searchScopeChannels" => this.applyMessagesScope("channels")
            // 归档行（CCM:19-49）
            case "archiveReadAll" => this.markArchiveAsRead()
            case "hideArchive" => this.toggleArchiveHidden()
            case "unhideArchive" => this.toggleArchiveHidden()
            // 搜索消息结果（SCN:1231-1290）
            case "forwardMessage" =>
                let ids = ArrayList<Int32>()
                ids.add(Int32(target.searchMessageId))
                setPendingForward(target.peerType, target.id, ids)
                routerPush("ShareControllerPage", "")
            case "viewInChat" => this.openSearchMessage(target)
            case "clearSearchHistory" => this.clearRecentSearch()
            case "selectMessage" =>
                let keys = ArrayList<String>()
                keys.add(searchMessageKey(target))
                this.searchSelectedKeys = keys
                this.searchSelectionActive = true
            case _ => ()
        }
    }

    // ---- 文件夹 tab 长按 ----

    private func handleFolderTabTouch(evt: TouchEvent, filterId: Int32): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                var x: Float64 = 0.0
                if (evt.touches.size > 0) {
                    this.folderTouchStartX = evt.touches[0].x
                    this.folderTouchStartY = evt.touches[0].y
                    x = evt.touches[0].screenX
                }
                this.folderPressActive = true
                this.folderPressGeneration += 1
                let generation = this.folderPressGeneration
                let anchorX = x
                spawn {
                    sleep(Duration.millisecond * 320)
                    launch {
                        if (this.folderPressActive && generation == this.folderPressGeneration) {
                            this.folderPressActive = false
                            this.suppressNextFolderTap = true
                            this.openFolderTabMenu(filterId, anchorX)
                        }
                    }
                }
            case TouchType.Move =>
                if (this.folderPressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].x - this.folderTouchStartX
                    let dy = evt.touches[0].y - this.folderTouchStartY
                    if (dx * dx + dy * dy > 64.0) {
                        this.folderPressActive = false
                        this.folderPressGeneration += 1
                    }
                }
            case _ =>
                this.folderPressActive = false
                this.folderPressGeneration += 1
        }
    }

    private func handleFolderTabTap(filterId: Int32): Unit {
        if (this.suppressNextFolderTap) {
            this.suppressNextFolderTap = false
            return
        }
        this.viewModel.setActiveFilter(filterId)
    }

    private func folderById(filterId: Int32): Option<ChatFolder> {
        for (folder in this.folderTabsMirror) {
            if (folder.id == filterId) { return Some(folder) }
        }
        return None
    }

    /**
     * 文件夹 tab 长按菜单 —— 项与顺序逐条对位 ChatListController.swift:1024-1300：
     *   自定义文件夹：Edit Folder / Add Chats / Read All（该 tab 未读 > 0）/ Mute All|Unmute All
     *   （会话数 ≤ 200）/ Share（仅手动添加的会话、无类型无排除）/ Remove（destructive）
     *   All Chats：Edit Folders
     *   两者末尾：分隔 + Reorder Tabs（文件夹数 > 1）
     */
    private func openFolderTabMenu(filterId: Int32, anchorX: Float64): Unit {
        let items = ArrayList<ChatListMenuItem>()
        if (filterId >= 0) {
            match (this.folderById(filterId)) {
                case Some(folder) =>
                    items.add(ChatListMenuItem("editFolder", this.localized("ChatList_EditFolder", "Edit Folder"), "edit"))
                    items.add(ChatListMenuItem("addChats", this.localized("ChatList_AddChatsToFolder", "Add Chats"), "add"))
                    if (this.folderTabUnreadCount(filterId) > 0) {
                        items.add(ChatListMenuItem("readAll", this.localized("ChatList_ReadAll", "Read All"), "readAll"))
                    }
                    let chats = this.viewModel.chatsInFilter(filterId)
                    if (chats.size <= 200) {
                        var areMuted = true
                        for (c in chats) {
                            if (!c.isMuted) { areMuted = false; break }
                        }
                        if (areMuted) {
                            items.add(ChatListMenuItem("unmuteAll", this.localized("ChatList_ContextUnmuteAll", "Unmute All"), "unmute"))
                        } else {
                            items.add(ChatListMenuItem("muteAll", this.localized("ChatList_ContextMuteAll", "Mute All"), "mute"))
                        }
                    }
                    if (!folder.includePeers.isEmpty() && !folder.includeContacts && !folder.includeNonContacts &&
                        !folder.includeGroups && !folder.includeChannels && !folder.includeBots &&
                        !folder.excludeRead && !folder.excludeMuted && !folder.excludeArchived &&
                        folder.excludePeers.isEmpty()) {
                        items.add(ChatListMenuItem("shareFolder", this.localized("ChatList_ContextMenuShare", "Share"), "link"))
                    }
                    items.add(ChatListMenuItem("removeFolder", this.localized("ChatList_RemoveFolder", "Remove"), "delete", destructive: true))
                case None => return
            }
        } else {
            items.add(ChatListMenuItem("editFolders", this.localized("ChatList_EditFolders", "Edit Folders"), "edit"))
        }
        if (this.folderTabsMirror.size > 1) {
            items.add(ChatListMenuItem("reorderTabs", this.localized("ChatList_ReorderTabs", "Reorder Tabs"), "reorder", separatorBefore: true))
        }
        this.listMenuFolderId = filterId
        this.presentListMenu(items, anchorX, this.folderBarBottomY - 44.0, this.folderBarBottomY)
    }

    /** Add Chats：iOS chatListFilterAddChatsController（Include Chats 选择器，确认即保存，applyAutomatically: true）。 */
    private func openAddChatsToFolder(folderId: Int32): Unit {
        match (getChatFolderDraftService().beginExisting(folderId)) {
            case Some(_) => routerPush("ChatFolderPeerSelectionPage", "addChats")
            case None => showToast(trSource("An error occurred."))
        }
    }

    /** Read All：iOS readAllInFilter → markAllChatsAsReadInteractively(filterPredicate)（CLC:4169-4183）。 */
    private func readAllInFolder(folderId: Int32): Unit {
        let ids = ArrayList<Int64>()
        for (c in this.viewModel.chatsInFilter(folderId)) { ids.add(c.id) }
        this.viewModel.markChatsAsReadInteractively(ids)
    }

    /** Mute All / Unmute All：updateMultiplePeerMuteSettings + 「All chats in {folder} are now muted」提示（CLC:1178-1231）。 */
    private func setFolderMuted(folderId: Int32, muted: Bool): Unit {
        let ids = ArrayList<Int64>()
        for (c in this.viewModel.chatsInFilter(folderId)) { ids.add(c.id) }
        this.viewModel.setChatsMuted(ids, muted)
        var title = ""
        match (this.folderById(folderId)) {
            case Some(folder) => title = folder.name
            case None => ()
        }
        let template = if (muted) {
            this.localized("ChatList_ToastFolderMutedV2", "All chats in {folder} are now muted")
        } else {
            this.localized("ChatList_ToastFolderUnmutedV2", "All chats in {folder} are now unmuted")
        }
        getUndoToastService().showUndo(template.replace("{folder}", title), showProgress: false, showAction: false)
    }

    /**
     * Share：iOS shareFolder（CLC:4185-4240）—— 取已有邀请链接；没有就按文件夹里可分享的会话
     * 新建一条 chatlists.exportChatlistInvite（openCreateChatListFolderLink），再进链接页复制/分享。
     */
    private func shareFolder(folderId: Int32): Unit {
        let draftService = getChatFolderDraftService()
        let folder = match (draftService.beginExisting(folderId)) {
            case Some(value) => value
            case None => return
        }
        let peers = ArrayList<FolderShareablePeer>()
        for (ref in folder.includePeerRefs) {
            let peer = FolderShareablePeer()
            peer.peerId = ref.id
            peer.peerType = ref.peerType
            peer.accessHash = ref.accessHash
            peer.title = if (ref.name.isEmpty()) { "Chat ${ref.id}" } else { ref.name }
            peer.isAvailable = ref.canShareLink && !ref.isMigrated
            peer.isSelected = peer.isAvailable
            peers.add(peer)
        }
        showToast(trSource("Loading..."))
        spawn {
            let linksService = getChatFolderLinksService()
            let existing = linksService.getExportedInvites(folderId)
            var link = ExportedChatFolderLink()
            var created = false
            var hasAvailablePeer = false
            for (peer in peers) {
                if (peer.isAvailable) { hasAvailablePeer = true }
            }
            var hasActiveLink = false
            for (value in existing) {
                if (!hasActiveLink && !value.isRevoked && !value.url.isEmpty()) {
                    link = value
                    hasActiveLink = true
                }
            }
            if (hasActiveLink) {
                ()
            } else if (hasAvailablePeer) {
                link = linksService.exportChatlistInvite(folderId, "", peers)
                created = !link.url.isEmpty()
            }
            let finalLink = link
            let finalCreated = created
            let finalHasPeer = hasAvailablePeer
            launch {
                if (!finalLink.url.isEmpty()) {
                    draftService.selectInvite(finalLink)
                    if (finalCreated) { draftService.setUpdatedInvite(finalLink) }
                    let sharedFolder = folder.copy()
                    sharedFolder.isShared = true
                    draftService.update(sharedFolder)
                    routerPush("ChatFolderInviteLinkPage", "")
                } else if (!finalHasPeer) {
                    draftService.clearSelectedInvite()
                    routerPush("ChatFolderInviteLinkPage", "")
                } else {
                    showToast(trSource("Could not create an invite link."))
                }
            }
        }
    }

    /** Remove：iOS askForFilterRemoval（CLC:4515-4647）「Remove %@?」→ Cancel / Remove。 */
    private func askForFolderRemoval(folderId: Int32): Unit {
        let folder = match (this.folderById(folderId)) {
            case Some(value) => value
            case None => return
        }
        let titleTemplate = this.localized("ChatList_RemoveFolderConfirmationTitle", "Remove %@?")
        let cancel = AlertDialogButtonOptions(value: this.localized("Common_Cancel", "Cancel"), action: { => () })
        let remove = AlertDialogButtonOptions(
            value: this.localized("ChatList_RemoveFolderAction", "Remove"),
            fontColor: 0xFFFF3B30,
            action: { => this.removeFolder(folder) }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: titleTemplate.replace("%@", folder.name),
            message: this.localized("ChatList_RemoveFolderConfirmation", "This will remove the folder, your chats will not be deleted."),
            primaryButton: cancel,
            secondaryButton: remove,
            autoCancel: true
        ))
    }

    private func removeFolder(folder: ChatFolder): Unit {
        let folderId = folder.id
        if (this.viewModel.activeFilterId == folderId) {
            this.viewModel.setActiveFilter(-1)
        }
        let remaining = ArrayList<ChatFolder>()
        for (value in this.viewModel.dialogFilters) {
            if (value.id != folderId) { remaining.add(value) }
        }
        let hasCustom = remaining.size > 1
        this.viewModel.dialogFilters = if (hasCustom) { remaining } else { ArrayList<ChatFolder>() }
        this.viewModel.publishCurrentChatList("folderRemoved")
        getRealChatListService().removeDialogFilter(folderId)
        spawn {
            let ok = getChatFolderLinksService().deleteDialogFilter(folderId)
            Hilog.info(0, "CjTelegram", "[ChatListPage] remove folder ${folderId} ok=${ok}")
            if (!ok) {
                launch {
                    showToast(trSource("Could not remove folder. Please try again."))
                    this.viewModel.loadFilters()
                }
            }
        }
    }

    // ---- 归档行 ----

    private func archiveHasUnread(): Bool {
        for (c in this.viewModel.archiveChatList) {
            if (c.unreadCount > 0 || c.isMarkedUnread) { return true }
        }
        return false
    }

    /** S1-66：归档里有未读的会话数（iOS countingCategory .chats / mutedCategory .all）。 */
    private func countArchiveUnreadChats(): Int64 {
        var n: Int64 = 0
        for (c in this.viewModel.archiveChatList) {
            if (c.unreadCount > 0 || c.isMarkedUnread) { n += 1 }
        }
        return n
    }

    private func handleArchiveRowTouch(evt: TouchEvent): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0) {
                    this.archiveTouchStartX = evt.touches[0].screenX
                    this.archiveTouchStartY = evt.touches[0].screenY
                }
                this.archivePressActive = true
                this.archivePressGeneration += 1
                let generation = this.archivePressGeneration
                spawn {
                    sleep(Duration.millisecond * 320)
                    launch {
                        if (this.archivePressActive && generation == this.archivePressGeneration) {
                            this.archivePressActive = false
                            this.suppressNextArchiveTap = true
                            this.openArchiveRowMenu()
                        }
                    }
                }
            case TouchType.Move =>
                // 横向位移同样取消：左滑出 Hide/Pin 时若不取消，320ms 后长按菜单会盖上来，
                // 随后点 Hide 只是关掉菜单；横滑还会穿过菜单遮罩把 Tabs 翻到 Settings。
                if (this.archivePressActive && evt.touches.size > 0) {
                    let dx = evt.touches[0].screenX - this.archiveTouchStartX
                    let dy = evt.touches[0].screenY - this.archiveTouchStartY
                    if (dx * dx + dy * dy > 64.0) {
                        this.archivePressActive = false
                        this.archivePressGeneration += 1
                    }
                }
            case _ =>
                this.archivePressActive = false
                this.archivePressGeneration += 1
        }
    }

    private func handleArchiveRowTap(): Unit {
        if (this.suppressNextArchiveTap) {
            this.suppressNextArchiveTap = false
            return
        }
        this.viewModel.setCurrentFolder(1)
    }

    /** Archived Chats 行长按 —— iOS archiveContextMenuItems（ChatContextMenus.swift:19-49）。 */
    private func openArchiveRowMenu(): Unit {
        let items = ArrayList<ChatListMenuItem>()
        if (this.archiveHasUnread()) {
            items.add(ChatListMenuItem("archiveReadAll", this.localized("ChatList_Context_MarkAllAsRead", "Mark All as Read"), "read"))
        }
        if (!this.archiveHidden) {
            items.add(ChatListMenuItem("hideArchive", this.localized("ChatList_Context_HideArchive", "Hide Above the List"), "unpin"))
        } else {
            items.add(ChatListMenuItem("unhideArchive", this.localized("ChatList_Context_UnhideArchive", "Pin in the list"), "pin"))
        }
        this.presentListMenu(items, this.screenWidthVp / 2.0, this.archiveRowTopY, this.archiveRowTopY + this.archiveRowHeight)
    }

    private func markArchiveAsRead(): Unit {
        let ids = ArrayList<Int64>()
        for (c in this.viewModel.archiveChatList) { ids.add(c.id) }
        this.viewModel.markChatsAsReadInteractively(ids)
    }

    /** iOS toggleArchivedFolderHiddenByDefault（CLC:5360-5405）+ hidArchive / revealedArchive 提示。 */
    private func toggleArchiveHidden(): Unit {
        let hidden = !this.archiveHidden
        setChatArchiveHiddenByDefault(hidden)
        this.archiveHidden = hidden
        this.archiveRevealed = false
        if (hidden) {
            getUndoToastService().showUndo(
                this.localized("ChatList_UndoArchiveHiddenText", "Swipe down to see archive."),
                title: this.localized("ChatList_UndoArchiveHiddenTitle", "Archive hidden"),
                showProgress: false, showAction: false)
        } else {
            getUndoToastService().showUndo(
                this.localized("ChatList_UndoArchiveRevealedText", "Swipe left on the archive to hide it."),
                title: this.localized("ChatList_UndoArchiveRevealedTitle", "Archive pinned"),
                showProgress: false, showAction: false)
        }
    }

    /** 归档行是否出现在主列表顶部：仅 All Chats 根列表、非搜索；隐藏态只在下拉露出后显示。 */
    func shouldShowArchiveRow(): Bool {
        if (this.isSearchActive() || this.currentFolderIdMirror != 0 || this.viewModel.activeFilterId >= 0) { return false }
        if (this.archiveCountMirror <= 0) { return false }
        return !this.archiveHidden || this.archiveRevealed
    }

    /**
     * 下拉露出隐藏的归档（iOS ChatListNode.revealScrollHiddenItem，CLN0:3232-3257）：
     * 列表已在顶部时继续下拉越过阈值即露出；滚离顶部后再收起。
     */
    private func onChatListScrolled(): Unit {
        if (!this.archiveHidden || this.isSearchActive()) { return }
        match (this.chatListScroller.currentOffset()) {
            case Some(o) =>
                if (o.yOffset < -40.0 && !this.archiveRevealed && this.shouldOfferArchiveReveal()) {
                    this.archiveRevealed = true
                    triggerHaptic("impact", "light")
                } else if (o.yOffset > 160.0 && this.archiveRevealed) {
                    this.archiveRevealed = false
                }
            case None => ()
        }
    }

    private func shouldOfferArchiveReveal(): Bool {
        return this.currentFolderIdMirror == 0 && this.viewModel.activeFilterId < 0 &&
            this.archiveCountMirror > 0
    }

    /** 同一判定的触摸兜底：弹性回弹期间部分机型不回调 onDidScroll，按手指下拉位移判定。 */
    private func handleChatListPull(evt: TouchEvent): Unit {
        if (!this.archiveHidden || this.archiveRevealed || this.isSearchActive()) { return }
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0 && this.listFirstVisibleIndex == 0) {
                    this.listPullStartY = evt.touches[0].screenY
                } else {
                    this.listPullStartY = -1.0
                }
            case TouchType.Move =>
                if (this.listPullStartY >= 0.0 && evt.touches.size > 0 && this.listFirstVisibleIndex == 0) {
                    var atTop = true
                    match (this.chatListScroller.currentOffset()) {
                        case Some(o) => atTop = o.yOffset <= 1.0
                        case None => ()
                    }
                    if (atTop && evt.touches[0].screenY - this.listPullStartY > 80.0 && this.shouldOfferArchiveReveal()) {
                        this.archiveRevealed = true
                        this.listPullStartY = -1.0
                        triggerHaptic("impact", "light")
                    }
                }
            case _ => this.listPullStartY = -1.0
        }
    }

    // ---- 搜索消息结果 ----

    /** 点消息结果 / View in Chat：打开会话并定位到该消息（SCN openMessage）。 */
    private func openSearchMessage(msgChat: Chat): Unit {
        setSelectedChat(msgChat.id, msgChat.name, msgChat.peerType)
        setSelectedChatDraft("")
        setSelectedChatUsername(msgChat.username)
        if (msgChat.searchMessageId > 0) {
            setSelectedChatFocusMessageId(msgChat.searchMessageId)
        }
        routerPush("ChatRoomPage", msgChat.name)
    }

    private func onSearchMessageTap(msgChat: Chat): Unit {
        if (this.searchSelectionActive) {
            this.toggleSearchSelection(msgChat)
            return
        }
        this.openSearchMessage(msgChat)
    }

    /**
     * 消息结果长按 —— iOS messageContextAction（SCN:1231-1290）：
     *   Forward（未开启禁止转发）/ View in Chat / 分隔 / Select
     */
    private func openSearchMessageMenu(msgChat: Chat, rowTop: Float64, rowHeight: Float64): Unit {
        if (this.searchSelectionActive) {
            this.toggleSearchSelection(msgChat)
            return
        }
        let items = ArrayList<ChatListMenuItem>()
        var protected = false
        match (getRealChatListService().getCachedChat(msgChat.peerType, msgChat.id)) {
            case Some(cached) => protected = cached.noForwardsEnabled
            case None => ()
        }
        if (!protected) {
            items.add(ChatListMenuItem("forwardMessage", this.localized("Conversation_ContextMenuForward", "Forward"), "forward"))
        }
        items.add(ChatListMenuItem("viewInChat", this.localized("SharedMedia_ViewInChat", "View in Chat"), "goto"))
        items.add(ChatListMenuItem("selectMessage", this.localized("Conversation_ContextMenuSelect", "Select"), "select", separatorBefore: true))
        this.listMenuTarget = msgChat
        this.presentListMenu(items, this.screenWidthVp / 2.0, rowTop, rowTop + rowHeight)
    }

    func isSearchMessageSelected(msgChat: Chat): Bool {
        return this.searchSelectedKeys.contains(searchMessageKey(msgChat))
    }

    private func toggleSearchSelection(msgChat: Chat): Unit {
        let key = searchMessageKey(msgChat)
        let updated = ArrayList<String>()
        var removed = false
        for (k in this.searchSelectedKeys) {
            if (k == key) { removed = true } else { updated.add(k) }
        }
        if (!removed) { updated.add(key) }
        this.searchSelectedKeys = updated
    }

    func exitSearchSelection(): Unit {
        this.searchSelectionActive = false
        this.searchSelectedKeys = ArrayList<String>()
    }

    private func selectedSearchMessages(): ArrayList<Chat> {
        let result = ArrayList<Chat>()
        for (c in this.searchGlobalResultsMirror) {
            if (this.searchSelectedKeys.contains(searchMessageKey(c))) { result.add(c) }
        }
        for (c in this.publicPostsMirror) {
            if (this.searchSelectedKeys.contains(searchMessageKey(c)) && !containsSearchRow(result, c)) { result.add(c) }
        }
        return result
    }

    /** 选中的消息是否都来自同一会话（转发面板一次只接受一个来源会话）。 */
    func canForwardSearchSelection(): Bool {
        let selected = this.selectedSearchMessages()
        if (selected.isEmpty()) { return false }
        for (c in selected) {
            if (c.id != selected[0].id || c.peerType != selected[0].peerType) { return false }
            match (getRealChatListService().getCachedChat(c.peerType, c.id)) {
                case Some(cached) => if (cached.noForwardsEnabled) { return false }
                case None => ()
            }
        }
        return true
    }

    func forwardSearchSelection(): Unit {
        if (!this.canForwardSearchSelection()) { return }
        let selected = this.selectedSearchMessages()
        let ids = ArrayList<Int32>()
        for (c in selected) { ids.add(Int32(c.searchMessageId)) }
        setPendingForward(selected[0].peerType, selected[0].id, ids)
        this.exitSearchSelection()
        routerPush("ShareControllerPage", "")
    }

    /** 选择面板的分享（iOS makeShareController externalShare）：公开频道帖子给 t.me 链接，其余给文本。 */
    func shareSearchSelection(): Unit {
        let selected = this.selectedSearchMessages()
        if (selected.isEmpty()) { return }
        var text = ""
        for (c in selected) {
            let line = if (c.peerType == "channel" && c.username.size > 0) {
                "https://t.me/${c.username}/${c.searchMessageId}"
            } else {
                c.lastMessage
            }
            text = if (text.isEmpty()) { line } else { "${text}\n${line}" }
        }
        let payload = text
        let escaped = payload.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
        callArkAsync(SHARE_LINK, "{\"url\":\"${escaped}\",\"title\":\"Share\"}", { res =>
            if (!res.contains("\"ok\":true")) {
                let _ = copyText(payload)
                launch { showToast(trSource("Copied to clipboard")) }
            }
        })
        this.exitSearchSelection()
    }

    func deleteSearchSelection(): Unit {
        let selected = this.selectedSearchMessages()
        if (selected.isEmpty()) { return }
        let count = selected.size
        let title = if (count == 1) { "Delete message" } else { "Delete ${count} messages" }
        let cancel = AlertDialogButtonOptions(value: this.localized("Common_Cancel", "Cancel"), action: { => () })
        let confirm = AlertDialogButtonOptions(
            value: this.localized("Conversation_DeleteMessagesForMe", "Delete for me"),
            fontColor: 0xFFFF3B30,
            action: { => this.commitDeleteSearchSelection(selected) }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: title,
            message: "",
            primaryButton: cancel,
            secondaryButton: confirm,
            autoCancel: true
        ))
    }

    private func commitDeleteSearchSelection(selected: ArrayList<Chat>): Unit {
        let keys = ArrayList<String>()
        for (c in selected) { keys.add(searchMessageKey(c)) }
        let remaining = ArrayList<Chat>()
        for (c in this.viewModel.globalSearchResults) {
            if (!keys.contains(searchMessageKey(c))) { remaining.add(c) }
        }
        this.viewModel.globalSearchResults = remaining
        this.searchGlobalResultsMirror = remaining
        this.exitSearchSelection()
        spawn {
            let msgSvc = getRealMessageService()
            for (c in selected) {
                let ids = ArrayList<Int32>()
                ids.add(Int32(c.searchMessageId))
                let ok = msgSvc.deleteMessages(c.peerType, c.id, ids, revoke: false)
                Hilog.info(0, "CjTelegram", "[ChatListPage] delete search message ${c.id}/${c.searchMessageId} ok=${ok}")
            }
        }
    }

    /** S9-11：切到 Channels 分类（空查询 = 已加入频道 + 推荐频道；有查询则按名称过滤）。 */
    func selectChannelsPane(): Unit {
        this.publicPostsPaneActive = false
        this.downloadsPaneActive = false
        this.searchPane = "channels"
        this.startSearchMirrorSync()
        this.viewModel.loadChannelsPane(this.searchKeyword)
    }

    /** S9-23：MESSAGES 段范围按钮文案（ChatList_Search_Messages_*）。 */
    func messagesScopeTitle(): String {
        match (this.messagesSearchScope) {
            case "users" => return this.localized("ChatList_Search_Messages_PrivateChats", "From Private Chats")
            case "groups" => return this.localized("ChatList_Search_Messages_GroupChats", "From Group Chats")
            case "channels" => return this.localized("ChatList_Search_Messages_Channels", "From Channels")
            case _ => return this.localized("ChatList_Search_Messages_AllChats", "From All Chats")
        }
    }

    /** S9-23：范围菜单 All Chats / Private Chats / Group Chats / Channels（ChatList_Search_Messages_Menu_*）。 */
    func presentMessagesScopeMenu(): Unit {
        let items = ArrayList<ChatListMenuItem>()
        items.add(ChatListMenuItem("searchScopeAll", this.localized("ChatList_Search_Messages_Menu_AllChats", "All Chats"), if (this.messagesSearchScope == "all") { "check" } else { "" }))
        items.add(ChatListMenuItem("searchScopeUsers", this.localized("ChatList_Search_Messages_Menu_PrivateChats", "Private Chats"), if (this.messagesSearchScope == "users") { "check" } else { "" }))
        items.add(ChatListMenuItem("searchScopeGroups", this.localized("ChatList_Search_Messages_Menu_GroupChats", "Group Chats"), if (this.messagesSearchScope == "groups") { "check" } else { "" }))
        items.add(ChatListMenuItem("searchScopeChannels", this.localized("ChatList_Search_Messages_Menu_Channels", "Channels"), if (this.messagesSearchScope == "channels") { "check" } else { "" }))
        this.presentListMenu(items, this.messagesScopeAnchorX, this.messagesScopeAnchorTop, this.messagesScopeAnchorBottom)
    }

    private func applyMessagesScope(scope: String): Unit {
        this.messagesSearchScope = scope
        this.startSearchMirrorSync()
        this.viewModel.setGlobalSearchScope(scope, this.searchKeyword)
        Hilog.info(0, "CjTelegram", "[ChatListPage] messages search scope=${scope} q='${this.searchKeyword}'")
    }

    /** 切到分类标签：查询可为空（空查询列出最近的该类消息）。 */
    func selectSearchPane(pane: String): Unit {
        this.publicPostsPaneActive = false
        this.downloadsPaneActive = false
        this.searchPane = pane
        this.startSearchMirrorSync()
        this.viewModel.searchFilteredMessages(this.searchKeyword, pane)
    }

    /**
     * RECENT → Clear：iOS 弹一个锚在 Clear 上的上下文菜单——第一行是小字说明
     * ChatList_ClearSearchHistory（无动作），第二行是红色 ChatList_ClearSearchHistory_Confirm「Clear」，
     * 点后 clearRecentlySearchedPeers（ChatListSearchContainerNode.swift:263-290）。
     */
    func confirmClearRecentSearch(): Unit {
        let items = ArrayList<ChatListMenuItem>()
        items.add(ChatListMenuItem(RECENT_CLEAR_INFO_KEY,
            this.localized("ChatList_ClearSearchHistory", "Are you sure you want to clear your search history?"), ""))
        items.add(ChatListMenuItem("clearSearchHistory",
            this.localized("ChatList_ClearSearchHistory_Confirm", "Clear"), "", destructive: true))
        this.presentListMenu(items, this.recentClearAnchorX, this.recentClearAnchorTop, this.recentClearAnchorBottom)
    }

    private func clearRecentSearch(): Unit {
        getChatListSearchRecentPeersService().clearRecentPeers()
        this.recentSearchPeers = ArrayList<Chat>()
    }

    private func openRecentSearchPeer(chat: Chat): Unit {
        getChatListSearchRecentPeersService().addRecentPeer(chat)
        setSelectedChat(chat.id, chat.name, chat.peerType)
        setSelectedChatDraft(chat.draftText)
        setSelectedChatUsername(chat.username)
        routerPush("ChatRoomPage", chat.name)
    }

    /** Show More > → Public Posts 标签（SCN:339-341 switchToFilter(.publicPosts)）。 */
    func openPublicPostsPane(): Unit {
        this.showPublicPostsTab = true
        this.publicPostsPaneActive = true
    }

    // ---- 私聊删除确认（S1-49）----

    /**
     * iOS maybeAskForPeerChatRemoval（CLC:5898-6000）：私聊（非 bot、非自己）弹
     * 「Delete Chat」确认，纵向三个动作：Delete just for me / Delete for me and <名> / Cancel；
     * 选第二项再弹 Warning!（Cancel / Delete All），确认后才双向撤回（revoke）。
     */
    private func presentPrivateChatDeleteAlert(chatId: Int64, chatName: String, isDeletedAccount: Bool): Unit {
        let uiCtx = getUIContext()
        let actions = ArrayList<AlertDialogButtonOptions>()
        if (isDeletedAccount) {
            actions.add(AlertDialogButtonOptions(
                value: this.localized("Common_Delete", "Delete"),
                fontColor: 0xFFFF3B30,
                action: { => this.viewModel.schedulePeerChatRemoval(chatId, deleteGloballyIfPossible: true) }
            ))
        } else {
            var compactTitle = chatName
            match (getRealChatListService().getCachedUser(chatId)) {
                case Some(user) =>
                    if (user.firstName.size > 0) { compactTitle = user.firstName }
                    else if (user.lastName.size > 0) { compactTitle = user.lastName }
                case None => ()
            }
            let forEveryoneTemplate = this.localized("ChatList_DeleteForEveryone", "Delete for me and %@")
            actions.add(AlertDialogButtonOptions(
                value: this.localized("ChatList_DeleteForCurrentUser", "Delete just for me"),
                fontColor: 0xFFFF3B30,
                action: { => this.viewModel.schedulePeerChatRemoval(chatId, deleteGloballyIfPossible: false) }
            ))
            actions.add(AlertDialogButtonOptions(
                value: forEveryoneTemplate.replace("%@", compactTitle),
                fontColor: 0xFFFF3B30,
                action: { => this.presentDeleteForEveryoneWarning(chatId) }
            ))
        }
        actions.add(AlertDialogButtonOptions(value: this.localized("Common_Cancel", "Cancel"), action: { => () }))
        let template = this.localized("ChatList_DeleteChatConfirmation", "Are you sure you want to delete chat\nwith %@?")
        uiCtx.showAlertDialog(AlertDialogParamWithOptions(
            title: this.localized("ChatList_DeleteChat", "Delete Chat"),
            message: template.replace("%@", chatName),
            autoCancel: true,
            buttons: actions.toArray(),
            buttonDirection: DialogButtonDirection.Vertical,
            textStyle: WordBreak.BreakWord
        ))
    }

    private func presentDeleteForEveryoneWarning(chatId: Int64): Unit {
        let cancel = AlertDialogButtonOptions(value: this.localized("Common_Cancel", "Cancel"), action: { => () })
        let confirm = AlertDialogButtonOptions(
            value: this.localized("ChatList_DeleteForEveryoneConfirmationAction", "Delete All"),
            fontColor: 0xFFFF3B30,
            action: { => this.viewModel.schedulePeerChatRemoval(chatId, deleteGloballyIfPossible: true) }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: this.localized("ChatList_DeleteForEveryoneConfirmationTitle", "Warning!"),
            message: this.localized("ChatList_DeleteForEveryoneConfirmationText", "This will delete all messages in this chat for both participants.").replace("**", ""),
            primaryButton: cancel,
            secondaryButton: confirm,
            autoCancel: true
        ))
    }

    /** 群主「Delete for all members」→ Warning!（ChannelInfo_DeleteGroup/ChannelConfirmation）→ Delete All（CLC:5530-5560）。 */
    func confirmDeleteSelectedForAll(): Unit {
        let chatId = this.selectedChatId
        let isGroup = this.selectedChatIsGroupLike()
        Hilog.info(0, "CjTelegram", "[ChatListPage] delete-for-all warning chatId=${chatId} group=${isGroup}")
        // 删除卡片在 Warning! 弹出之后、用户作答时才收起：此前在同一点击回调里先把发起弹窗的卡片
        // 摘掉再 showAlertDialog，弹窗能显示，但 Delete All 的 action 从未执行（真机 hilog 无任何
        // 删除/退出日志），频道原样保留。
        let cancel = AlertDialogButtonOptions(value: this.localized("Common_Cancel", "Cancel"), action: { =>
            this.showDeleteChatPeerSheet = false
        })
        let confirm = AlertDialogButtonOptions(
            value: this.localized("ChatList_DeleteForEveryoneConfirmationAction", "Delete All"),
            fontColor: 0xFFFF3B30,
            action: { =>
                Hilog.info(0, "CjTelegram", "[ChatListPage] delete-for-all confirmed chatId=${chatId}")
                this.showDeleteChatPeerSheet = false
                this.viewModel.schedulePeerChatRemoval(chatId, deleteGloballyIfPossible: true)
            }
        )
        let text = if (isGroup) {
            this.localized("ChannelInfo_DeleteGroupConfirmation", "Wait! Deleting this group will remove all members and all messages will be lost. Delete the group anyway?")
        } else {
            this.localized("ChannelInfo_DeleteChannelConfirmation", "Wait! Deleting this channel will remove all members and all messages will be lost. Delete the channel anyway?")
        }
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: this.localized("ChatList_DeleteForEveryoneConfirmationTitle", "Warning!"),
            message: text,
            primaryButton: cancel,
            secondaryButton: confirm,
            autoCancel: true,
            cancel: { => this.showDeleteChatPeerSheet = false }
        ))
    }

    // P2-107: 进入编辑（多选）模式
    // CTL-CHATS-001: 选择控件自左滑入(x=-w/2+alpha, 0.4 spring)——槽位宽度 0→44 动画
    func enterEditMode(): Unit {
        this.isEditMode = true
        this.onEditModeChange(true)
        this.selectedChatIds = ArrayList<Int64>()
        this.chatEditShift = 0.0
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 400, curve: Curve.EaseOut), { =>
            this.chatEditShift = 44.0
        })
    }

    private func displayIndexOf(chatId: Int64): Int64 {
        var i: Int64 = 0
        while (i < this.displayList.size) {
            if (this.displayList[i].chat.id == chatId) { return i }
            i += 1
        }
        return -1
    }

    /** 相邻两行互换（只在置顶段内换，拖出置顶段即停） */
    private func swapDisplayRows(a: Int64, b: Int64): Unit {
        let updated = ArrayList<ChatEntry>()
        var i: Int64 = 0
        while (i < this.displayList.size) {
            if (i == a) { updated.add(this.displayList[b]) }
            else if (i == b) { updated.add(this.displayList[a]) }
            else { updated.add(this.displayList[i]) }
            i += 1
        }
        this.displayList = updated
    }

    private func handlePinnedReorderTouch(evt: TouchEvent, chatId: Int64): Unit {
        match (evt.eventType) {
            case TouchType.Down =>
                if (evt.touches.size > 0) { this.reorderLastY = evt.touches[0].screenY }
                this.reorderChatId = chatId
                this.reorderOffsetY = 0.0
                this.reorderMoved = false
            case TouchType.Move =>
                if (this.reorderChatId != chatId || evt.touches.size == 0) { return }
                let h = if (this.editRowHeight > 20.0) { this.editRowHeight } else { 76.0 }
                var dy = evt.touches[0].screenY - this.reorderLastY
                let idx = this.displayIndexOf(chatId)
                if (idx >= 0) {
                    if (dy > h * 0.5 && idx + 1 < this.displayList.size && this.displayList[idx + 1].chat.isPinned) {
                        this.swapDisplayRows(idx, idx + 1)
                        this.reorderLastY += h
                        dy -= h
                        this.reorderMoved = true
                    } else if (dy < -h * 0.5 && idx > 0 && this.displayList[idx - 1].chat.isPinned) {
                        this.swapDisplayRows(idx, idx - 1)
                        this.reorderLastY -= h
                        dy += h
                        this.reorderMoved = true
                    }
                }
                this.reorderOffsetY = dy
            case _ =>
                if (this.reorderChatId != chatId) { return }
                this.reorderChatId = 0
                this.reorderOffsetY = 0.0
                if (this.reorderMoved) {
                    this.reorderMoved = false
                    let order = ArrayList<Int64>()
                    for (entry in this.displayList) {
                        if (entry.chat.isPinned) { order.add(entry.chat.id) }
                    }
                    this.viewModel.applyPinnedOrder(order, archive: this.currentFolderIdMirror == 1)
                }
        }
    }

    // P2-107: 退出编辑（多选）模式并清除选中
    // CTL-CHATS-001: 先滑出(250ms)再摘编辑分支
    func exitEditMode(): Unit {
        safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 250, curve: Curve.EaseInOut), { =>
            this.chatEditShift = 0.0
        })
        let _ = spawn {
            sleep(Duration.millisecond * 260)
            launch {
                this.isEditMode = false
                this.onEditModeChange(false)
                this.selectedChatIds = ArrayList<Int64>()
            }
        }
    }

    // P2-107: 全选当前显示列表
    func selectAllChats(): Unit {
        let newList = ArrayList<Int64>()
        for (entry in this.displayList) {
            newList.add(entry.chat.id)
        }
        this.selectedChatIds = newList
        this.refreshEditRows()
    }

    // P2-107: 是否全部已选（用于 Select All / Deselect All 按钮文字切换）
    func isAllSelected(): Bool {
        if (this.displayList.isEmpty()) { return false }
        for (entry in this.displayList) {
            var found = false
            for (cid in this.selectedChatIds) {
                if (cid == entry.chat.id) { found = true; break }
            }
            if (!found) { return false }
        }
        return true
    }

    // P2-107: 获取当前选中 ID 列表的快照副本（@Builder onClick 内不能用 for，通过此方法间接取）
    func snapshotSelectedIds(): ArrayList<Int64> {
        let ids = ArrayList<Int64>()
        for (cid in this.selectedChatIds) { ids.add(cid) }
        return ids
    }

    // P2-107: 批量已读并退出编辑模式
    func doBatchMarkAsRead(): Unit {
        if (this.selectedChatIds.isEmpty()) { return }
        this.viewModel.markChatsAsReadInteractively(this.snapshotSelectedIds())
        this.exitEditMode()
    }

    // ---- iOS 编辑态 toolbar 左动作：Read All / Read ----

    func batchReadTitle(): String {
        if (this.selectedChatIds.isEmpty() && this.currentFolderIdMirror != 1) {
            return this.localized("ChatList_ReadAll", "Read All")
        }
        return this.localized("ChatList_Read", "Read")
    }

    /** iOS options.read：未选时 .all(是否有未读)，已选时 .selective(选中里是否有未读)。 */
    func batchReadEnabled(): Bool {
        if (this.selectedChatIds.isEmpty()) {
            if (this.currentFolderIdMirror == 1) { return false }
            for (entry in this.displayList) {
                if (entry.chat.unreadCount > 0 || entry.chat.isMarkedUnread) { return true }
            }
            return false
        }
        for (entry in this.displayList) {
            if (this.isChatSelected(entry.chat.id) && (entry.chat.unreadCount > 0 || entry.chat.isMarkedUnread)) { return true }
        }
        return false
    }

    /** 已选 → 标记这些会话已读；未选 → 当前列表（含文件夹过滤）全部已读（markAllChatsAsReadInteractively）。 */
    func doBatchRead(): Unit {
        let ids = ArrayList<Int64>()
        if (this.selectedChatIds.isEmpty()) {
            for (entry in this.displayList) { ids.add(entry.chat.id) }
        } else {
            for (cid in this.selectedChatIds) { ids.add(cid) }
        }
        this.viewModel.markChatsAsReadInteractively(ids)
        this.exitEditMode()
    }

    /**
     * iOS toolbar Delete（CLC:5040-5215）：有私聊时给「Delete from both sides (where possible)」与
     * 「Delete for me」；否则一项「Delete N Chats」（单个为 Delete）；另起一组 Cancel。
     */
    func presentBatchDeleteSheet(): Unit {
        if (this.selectedChatIds.isEmpty()) { return }
        var havePrivate = false
        var haveNonPrivate = false
        for (entry in this.displayList) {
            if (this.isChatSelected(entry.chat.id)) {
                if (normalizeDialogPeerType(entry.chat.peerType) == "user") { havePrivate = true } else { haveNonPrivate = true }
            }
        }
        let count = this.selectedChatIds.size
        let sheets = ArrayList<SheetInfo>()
        if (havePrivate) {
            let bothTitle = if (haveNonPrivate) {
                this.localized("ChatList_DeleteForAllWhenPossible", "Delete from both sides where possible")
            } else {
                this.localized("ChatList_DeleteForAll", "Delete from both sides")
            }
            sheets.add(SheetInfo(title: bothTitle, action: { => this.doBatchDeleteConfirmed(revoke: true) }))
            sheets.add(SheetInfo(title: this.localized("ChatList_DeleteForMe", "Delete for me"), action: { => this.doBatchDeleteConfirmed(revoke: false) }))
        } else {
            let title = if (count == 1) { this.localized("Common_Delete", "Delete") } else { "Delete ${count} Chats" }
            sheets.add(SheetInfo(title: title, action: { => this.doBatchDeleteConfirmed(revoke: false) }))
        }
        getUIContext().showActionSheet(ActionSheetOptions(
            title: None,
            message: None,
            confirm: ActionSheetButtonOptions(value: this.localized("Common_Cancel", "Cancel"), action: { => () }),
            sheets: sheets.toArray(),
            autoCancel: true
        ))
    }

    // P2-107: 批量静音并退出编辑模式
    func doBatchMute(): Unit {
        if (this.selectedChatIds.isEmpty()) { return }
        this.viewModel.batchMute(this.snapshotSelectedIds())
        this.exitEditMode()
    }

    // P2-107: 批量归档并退出编辑模式
    func doBatchArchive(): Unit {
        if (this.selectedChatIds.isEmpty()) { return }
        if (this.currentFolderIdMirror == 1) {
            // 归档内多选：中间动作是 Unarchive（iOS ChatListController 归档 toolbar）
            for (cid in this.snapshotSelectedIds()) { this.viewModel.unarchiveChat(cid) }
        } else {
            this.viewModel.batchArchive(this.snapshotSelectedIds())
        }
        this.exitEditMode()
    }

    // R-128: 批量删除改为可撤销语义（二次确认在 @Builder 层调用 showAlert，
    // 确认后走 batchDeleteWithUndo：乐观移除 + Undo toast 5s 窗口，onCommit 才真正提交 RPC）
    func doBatchDeleteConfirmed(revoke!: Bool = false): Unit {
        if (this.selectedChatIds.isEmpty()) { return }
        this.viewModel.batchDeleteWithUndo(this.snapshotSelectedIds(), revokeUsers: revoke)
        this.exitEditMode()
    }

    // P2-107: 返回当前选中计数（避免 @Builder 内直接访问 selectedChatIds.size）
    func selectedCount(): Int64 {
        return this.selectedChatIds.size
    }

    // TC-0016 第四轮返修：填充 DeleteChatPeerActionSheetComponent 需要的头像三项镜像字段
    // （D-125 合规：组件 @Prop 调用点必须是裸 @State 字段，故在弹出前一次性写入）。
    func openDeleteChatPeerSheet(chatId: Int64, chatName: String, peerType: String): Unit {
        // iOS deletePeerChat（CLC:5417-5440）：非 bot 的私聊（且不是 Saved Messages）走
        // maybeAskForPeerChatRemoval 的居中确认；其余（群/频道/bot/自己）走动作面板。
        if (normalizeDialogPeerType(peerType) == "user") {
            var isBot = false
            var isSelf = false
            var isDeleted = false
            match (this.viewModel.getChatById(chatId)) {
                case Some(chat) =>
                    isBot = chat.isBot
                    isSelf = chat.isSavedMessages
                    isDeleted = chat.isDeletedAccount
                case None => ()
            }
            if (chatId == getCurrentUserId()) { isSelf = true }
            if (!isBot && !isSelf) {
                this.presentPrivateChatDeleteAlert(chatId, chatName, isDeleted)
                return
            }
        }
        this.selectedChatId = chatId
        this.selectedChatName = chatName
        this.selectedChatPeerType = peerType
        match (this.viewModel.getChatById(chatId)) {
            case Some(chat) =>
                this.selectedChatAvatarText = chat.avatarText
                this.selectedChatAvatarColor = chat.avatarColor
                this.selectedChatAvatarLocalPath = chat.avatarLocalPath
            case None =>
                this.selectedChatAvatarText = ""
                this.selectedChatAvatarColor = 0x317AFF
                this.selectedChatAvatarLocalPath = ""
        }
        this.showDeleteChatPeerSheet = true
    }

    // swipeAction 与长按菜单共用新版 main 的统一确认卡片，避免不同 peer 类型走两套
    // 删除 API，也避免旧 deleteChatWithUndo 被移除后退化成不可撤销的直接 RPC。
    func doSwipeRowDelete(): Unit {
        this.openDeleteChatPeerSheet(this.swipeRowChatId, this.swipeRowChatName, this.swipeRowPeerType)
    }

    // TC-0012 第三轮返修：swipeAction end 面板"归档/取消归档"按钮
    func doSwipeRowArchiveToggle(): Unit {
        let cid = this.swipeRowChatId
        // 方向取当前所在列表（按钮文案同一判据），不取 onOffsetChange 写入的 swipeRowArchived：
        // 后者只在偏移变化回调里刷新，一旦没刷到就会在归档页把 Unarchive 执行成 Archive。
        let inArchive = this.currentFolderIdMirror == 1
        Hilog.info(0, "CjTelegram",
            "[ArchiveTrace] swipe archive toggle chatId=${cid} inArchive=${inArchive} mirrored=${this.swipeRowArchived}")
        if (inArchive) {
            this.viewModel.unarchiveChat(cid)
        } else {
            this.viewModel.archiveChatWithUndo(cid)
        }
    }

    // P2-107: 返回批量删除提示文字（@Builder 内不能用 if 表达式的 let 赋值，通过函数规避）
    func batchDeleteTitle(): String {
        let count = this.selectedChatIds.size
        if (count > 1) {
            return "Delete ${count} Chats"
        }
        return "Delete Chat"
    }

    /**
     * TC-0013 返修：搜索状态的短生命周期镜像同步循环。
     * 根因：this.viewModel.globalSearchResults / globalPeerSearchResults / isSearching /
     * isSearchingPeers 是 @State 持有的 @Observed ViewModel 实例的嵌套 @Publish 字段，
     * build() 内联直接读取该嵌套字段不可靠触发本页重新渲染（真机 hilog + dumpLayout 双重
     * 证实：ViewModel 内部状态已正确变化，页面渲染树未跟随更新）。
     * 修复：轮询回写到页面自身裸 @State 镜像字段（对齐本文件 displayList/isPageLoading
     * 已验证有效的同款模式），build() 只读镜像字段，不再直接读 this.viewModel.* 嵌套字段。
     * 仅在 showSearch 为 true 时运行，退出搜索即停止，避免常驻空转。
     */
    var _searchSyncActive: Bool = false
    var _searchSyncGeneration: Int64 = 0

    func startSearchMirrorSync() {
        this.recentSearchPeers = getChatListSearchRecentPeersService().getRecentlySearchedPeers()
        if (this._searchSyncActive) { return }
        this._searchSyncActive = true
        this._searchSyncGeneration += 1
        let generation = this._searchSyncGeneration
        let _ = spawn {
            Hilog.info(0, "CjTelegram", "[ChatListPage] Search mirror sync loop started")
            while (this._searchSyncActive && this.isSearchActive() && generation == this._searchSyncGeneration) {
                let results = this.viewModel.globalSearchResults
                let peerResults = this.viewModel.globalPeerSearchResults
                let searching = this.viewModel.isSearching
                let searchingPeers = this.viewModel.isSearchingPeers
                let posts = this.viewModel.publicPostResults
                let searchingPosts = this.viewModel.isSearchingPublicPosts
                let filtered = this.viewModel.filterSearchResults
                let searchingFiltered = this.viewModel.isSearchingFilter
                let channelsJoined = this.viewModel.channelsPaneJoined
                let channelsRecommended = this.viewModel.channelsPaneRecommended
                let loadingChannels = this.viewModel.isLoadingChannelsPane
                Hilog.info(0, "CjTelegram", "[ChatListPage] searchMirrorSync tick: results=${results.size} peerResults=${peerResults.size} searching=${searching} searchingPeers=${searchingPeers}")
                launch {
                    this.searchGlobalResultsMirror = results
                    this.searchGlobalPeerResultsMirror = peerResults
                    this.isSearchingMirror = searching
                    this.isSearchingPeersMirror = searchingPeers
                    this.publicPostsMirror = posts
                    this.isSearchingPublicPostsMirror = searchingPosts
                    this.filterResultsMirror = filtered
                    this.isSearchingFilterMirror = searchingFiltered
                    this.channelsJoinedMirror = channelsJoined
                    this.channelsRecommendedMirror = channelsRecommended
                    this.isLoadingChannelsMirror = loadingChannels
                }
                sleep(Duration.millisecond * 120)
            }
            if (generation == this._searchSyncGeneration) {
                this._searchSyncActive = false
            }
            Hilog.info(0, "CjTelegram", "[ChatListPage] Search mirror sync loop stopped")
        }
    }

    /** Chats 结果里的 PUBLIC POSTS 段最多 3 条（SLP:1128-1133 之前按 index 截断）。 */
    func firstPublicPosts(): ArrayList<Chat> {
        let result = ArrayList<Chat>()
        for (c in this.publicPostsMirror) {
            if (result.size >= 3) { break }
            result.add(c)
        }
        return result
    }

    func stopSearchMirrorSync() {
        this._searchSyncActive = false
        this._searchSyncGeneration += 1
        // 停止后清空镜像字段，避免下次重新打开搜索前残留陈旧结果闪现
        this.searchGlobalResultsMirror = ArrayList<Chat>()
        this.searchGlobalPeerResultsMirror = ArrayList<Chat>()
        this.isSearchingMirror = false
        this.isSearchingPeersMirror = false
        this.publicPostsMirror = ArrayList<Chat>()
        this.isSearchingPublicPostsMirror = false
        this.showPublicPostsTab = false
        this.publicPostsPaneActive = false
        this.downloadsPaneActive = false
        this.searchPane = "chats"
        this.filterResultsMirror = ArrayList<Chat>()
        this.isSearchingFilterMirror = false
        this.searchSelectionActive = false
        this.searchSelectedKeys = ArrayList<String>()
    }

    /**
     * P2-108: 将 connectionStatus 字符串转换为 iOS 对应的状态文字
     * Connecting → "Connecting..." / Updating → "Updating..." / Waiting → "Waiting for network"
     */
    func connectionStatusText(): String {
        if (this.viewModel.connectionStatus == "connecting") {
            return "Connecting..."
        } else if (this.viewModel.connectionStatus == "updating") {
            return "Updating..."
        } else if (this.viewModel.connectionStatus == "waiting") {
            return "Waiting for network"
        }
        return ""
    }

    // P2-101: 辅助函数：判断当前 filterId 是否激活（@Builder 内不能用 let，改为函数调用）
    func isFolderTabActive(filterId: Int32): Bool {
        return this.viewModel.activeFilterId == filterId
    }

    func hasCustomFolderTab(): Bool {
        for (folder in this.folderTabsMirror) {
            if (folder.id != 0) { return true }
        }
        return false
    }

    // P2-110: 判断当前是否在特定文件夹 tab（非 All），用于空状态文案切换
    // activeFilterId >= 0 表示在具体文件夹 tab（iOS "This folder is empty" 语义）
    func isInSpecificFolder(): Bool {
        return this.viewModel.activeFilterId >= 0
    }

    // P2-110: 空状态标题文字（对应 iOS ChatListEmpty: folder / search / main 三态）
    // - 特定文件夹空 → "This folder is empty"
    // - 搜索无结果  → "No Results"
    // - 主列表空   → "No messages yet"
    func emptyStateTitleText(): String {
        if (this.isSearchActive()) {
            return "No Results"
        }
        if (this.isInSpecificFolder()) {
            return "This folder is empty"
        }
        return "No messages yet"
    }

    // P2-110: 空状态副标题文字（iOS subtitle 语义）
    func emptyStateSubtitleText(): String {
        if (this.isSearchActive()) {
            return "Try different keywords or check the spelling"
        }
        if (this.isInSpecificFolder()) {
            return "There are no chats in this folder"
        }
        return "Tap the compose button to start a new message"
    }

    // P2-110: 空状态图标（搜索 vs 聊天 vs 文件夹，@Builder 内不能用 let，改为函数）
    func emptyStateIcon(): String {
        if (this.isSearchActive()) { return "🔍" }
        if (this.isInSpecificFolder()) { return "📂" }
        return "✉️"
    }

    // P2-101: 辅助函数：获取文件夹未读计数
    func folderTabUnreadCount(filterId: Int32): Int64 {
        return this.viewModel.getUnreadCountForFilter(filterId)
    }

    /**
     * P2-101: 构建单个文件夹 tab（含未读 badge）
     * filterId = -1 → "All" (总对话列表)；filterId >= 0 → 具体文件夹
     * 激活状态用蓝色 + 粗体 + 底部蓝色指示线；未激活灰色
     *
     * 返修（D-115 命中修复）：本函数曾是带参数的 @Builder 成员函数，从
     * ForEach.itemGeneratorFunc 闭包内以 this.buildFolderTab(folder.name, folder.id)
     * 调用——命中 D-115（@Component 类内 @Builder func 不能带参数从 build()/闭包内调用），
     * 真机验证发现 10/11 个闭包内调用坍缩为 0 节点，唯一渲染成功的是本文件里唯一一处
     * 直接写在 build() 内的静态字面量调用（"All"）。已按 Diagnoser 建议改为普通函数，
     * 不再是 @Builder；build() / itemGeneratorFunc 闭包内改为内联展开 UI 结构（对齐
     * ChatFoldersPage.cj:1097-1194 已验证有效的"闭包内直接内联组件树"范式），不再
     * 通过任何 @Builder 函数间接调用。保留本函数体仅作为共享的纯计算辅助，
     * UI 结构在 build() 与 ForEach 闭包两处各自内联书写（对齐视觉与交互逻辑）。
     *
     * 返修（D-175 自查，diag-suite_settings_appearance-TC-0401-round9.md F-2，原始修复
     * c129b3fd5 被 a8998a341 覆盖删除后在此恢复）：返回类型由 UInt32 改为 Color——旧实现
     * `return 0x00000000` 表意"未激活 tab 无指示条"，但本 SDK ResourceColor.alphaAdapt()
     * 对首字节为 0 的数值字面量强制补 alpha=FF，渲染为不透明黑，不是透明。真机上每个未激活
     * 文件夹 tab 底下都会有一条常驻黑色 2px 横线，不会随选中态消失。唯一真透明写法是
     * Color.Transparent；Color(0x317AFF) 与 Color.Transparent 同为 Color 类型，if/else 分支
     * 类型统一，调用点 .backgroundColor(ResourceColor) 直接接受 Color 实例，无需改动调用点。
     */
    func folderTabIndicatorColor(filterId: Int32): Color {
        if (this.isFolderTabActive(filterId)) {
            return Color(0x317AFF)
        }
        return Color.Transparent
    }

    private func closeDedicatedSearch(): Unit {
        this.showSearch = false
        this.onSearchVisibilityChange(false)
        this.searchKeyword = ""
        this.messagesSearchScope = "all"
        this.viewModel.clearSearch()
        this.stopSearchMirrorSync()
    }

    /**
     * 搜索态：本页自身入口（导航栏下 Search 胶囊 → showSearch）或 tab 栏搜索圆钮
     * （MainTabPage → externalSearchVisible）任一激活即为搜索中。后者不会置 showSearch，
     * 所以结果分区 / 镜像同步不能只看 showSearch。
     */
    func isSearchActive(): Bool {
        return this.showSearch || this.externalSearchVisible
    }

    private func onExternalSearchVisibleChanged(): Unit {
        if (this.externalSearchVisible) {
            this.startSearchMirrorSync()
            return
        }
        // tab 栏 ✕ / 点 tab 区退出：宿主已清空胶囊文本，这里复位本页搜索态。
        if (this.showSearch || this.searchKeyword.size > 0) {
            this.showSearch = false
            this.searchKeyword = ""
            this.viewModel.clearSearch()
        }
        this.stopSearchMirrorSync()
    }

    private func onExternalSearchQueryChanged(): Unit {
        if (!this.isSearchActive()) { return }
        if (this.externalSearchQuery == this.searchKeyword) { return }
        this.updateDedicatedSearch(this.externalSearchQuery)
    }

    private func updateDedicatedSearch(value: String): Unit {
        this.searchKeyword = value
        this.viewModel.searchKeyword = value
        this.viewModel.publishCurrentChatList("searchKeyword")
        if (value.isEmpty()) {
            this.viewModel.clearSearch()
            this.searchGlobalResultsMirror = ArrayList<Chat>()
            this.searchGlobalPeerResultsMirror = ArrayList<Chat>()
            this.isSearchingMirror = false
            this.isSearchingPeersMirror = false
            this.publicPostsMirror = ArrayList<Chat>()
            this.isSearchingPublicPostsMirror = false
            this.showPublicPostsTab = false
            this.publicPostsPaneActive = false
            this.viewModel.searchPublicPosts("")
            if (this.searchPane == "channels") {
                this.startSearchMirrorSync()
                this.viewModel.loadChannelsPane("")
            } else if (this.searchPane != "chats") {
                this.startSearchMirrorSync()
                this.viewModel.searchFilteredMessages("", this.searchPane)
            }
        } else {
            // iOS：# 开头的查询仍留在会话搜索里，Chats 结果多一段 PUBLIC POSTS
            // （SLP:2764 key == .chats && query.hasPrefix("#")）；非 # 查询时离开 Public Posts 标签（SCN:715）。
            this.startSearchMirrorSync()
            this.viewModel.searchGlobalPeers(value)
            this.viewModel.searchGlobal(value)
            if (this.searchPane == "channels") {
                this.viewModel.loadChannelsPane(value)
            } else if (this.searchPane != "chats") {
                this.viewModel.searchFilteredMessages(value, this.searchPane)
            }
            if (value.startsWith("#")) {
                this.viewModel.searchPublicPosts(value)
            } else {
                this.viewModel.searchPublicPosts("")
                this.showPublicPostsTab = false
                this.publicPostsPaneActive = false
            }
        }
    }

    /** 空查询时的 RECENT 段：最近搜索过的会话 + 右侧 Clear（header 对位 ChatListSearchItemHeader .recentPeers）。 */
    @Builder
    func buildRecentSearchSection() {
        if (this.recentSearchPeers.isEmpty()) {
            Blank().layoutWeight(1)
        } else {
            Column {
                Row {
                    Text(this.localized("DialogList_SearchSectionRecent", "Recent").toAsciiUpper())
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .layoutWeight(1)
                    // ListSectionHeaderNode.updateActionTitle：generic 动作用 sectionHeaderTextColor（与标题同灰）
                    Text(this.localized("WebSearch_RecentSectionClear", "Clear"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .padding(top: 4, bottom: 4)
                        .onAreaChange({ _: Area, newArea: Area =>
                            match ((newArea.globalPosition.x, newArea.globalPosition.y)) {
                                case (Some(x), Some(y)) =>
                                    this.recentClearAnchorX = x.value + newArea.width.value / 2.0
                                    this.recentClearAnchorTop = y.value
                                    this.recentClearAnchorBottom = y.value + newArea.height.value
                                case _ => ()
                            }
                        })
                        .onClick({ _ => this.confirmClearRecentSearch() })
                }
                .width(100.percent)
                .height(28)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                List {
                    ForEach(this.recentSearchPeers, itemGeneratorFunc: { peer: Chat, _idx: Int64 =>
                        ListItem {
                            Row {
                                Avatar(
                                    avatarUrl: peer.avatarLocalPath,
                                    displayName: peer.name,
                                    avatarSize: 40,
                                    avatarColor: peer.avatarColor,
                                    peerId: peer.id
                                )
                                Text(peer.name)
                                    .fontSize(17)
                                    .fontColor(this.presentation.textColor)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .layoutWeight(1)
                                    .margin(left: 12)
                            }
                            .width(100.percent)
                            .height(56)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _ => this.openRecentSearchPeer(peer) })
                        }
                    }, keyGeneratorFunc: { peer: Chat, _idx: Int64 => "recent_${peer.peerType}_${peer.id}" })
                }
                .width(100.percent)
                .layoutWeight(1)
            }
            .width(100.percent)
            .layoutWeight(1)
        }
    }

    @Builder
    func buildDedicatedSearchSurface() {
        Column {
            if (this.downloadsPaneActive) {
                Column {
                    ChatListDownloadsPane(query: this.searchKeyword)
                }
                .width(100.percent)
                .layoutWeight(1)
            } else if (this.searchKeyword.isEmpty() && this.searchPane == "chats") {
                Column {
                    ChatListSearchRecentPeersComponent()
                }
                .width(100.percent)
                .alignItems(HorizontalAlign.Start)
                .padding(top: 16)
                this.buildRecentSearchSection()
            } else {
                Column {
                    this.buildListContent()
                }
                .width(100.percent)
                .layoutWeight(1)
            }

            // 消息多选面板（iOS ChatListSearchMessageSelectionPanelNode：删除 / 分享 / 转发）
            if (this.searchSelectionActive) {
                Column {
                    Row {
                        Text(this.localized("Common_Cancel", "Cancel"))
                            .fontSize(17)
                            .fontColor(0x317AFF)
                            .onClick({ _ => this.exitSearchSelection() })
                        Blank().layoutWeight(1)
                        Text("${this.searchSelectedKeys.size} ${this.localized("Common_Selected", "Selected")}")
                            .fontSize(15)
                            .fontColor(this.presentation.textColor)
                        Blank().layoutWeight(1)
                        Text(" ").width(52)
                    }
                    .width(100.percent)
                    .height(36)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    Row {
                        Image(@r(app.media.clist_ic_delete))
                            .width(24).height(24)
                            .fillColor(if (this.searchSelectedKeys.isEmpty()) { 0xC7C7CC } else { 0x317AFF })
                            .onClick({ _ => this.deleteSearchSelection() })
                        Blank().layoutWeight(1)
                        Image(@r(app.media.misc_ic_share))
                            .width(24).height(24)
                            .fillColor(if (this.searchSelectedKeys.isEmpty()) { 0xC7C7CC } else { 0x317AFF })
                            .onClick({ _ => this.shareSearchSelection() })
                        Blank().layoutWeight(1)
                        Image(@r(app.media.chatroom_ic_forward))
                            .width(24).height(24)
                            .fillColor(if (this.canForwardSearchSelection()) { 0x317AFF } else { 0xC7C7CC })
                            .onClick({ _ => this.forwardSearchSelection() })
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 24, right: 24)
                    .alignItems(VerticalAlign.Center)
                }
                .width(100.percent)
                .backgroundColor(this.presentation.navBarColor)
            }

            Scroll {
                Row {
                    Text(this.localized("DialogList_Title", "Chats")).fontSize(15)
                        .fontWeight(if (this.publicPostsPaneActive || this.downloadsPaneActive || this.searchPane != "chats") { FontWeight.Normal } else { FontWeight.Medium })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(if (this.publicPostsPaneActive || this.downloadsPaneActive || this.searchPane != "chats") { Color.Transparent } else { Color(this.presentation.backgroundColor) })
                        .borderRadius(18)
                        .onClick({ _ =>
                            this.publicPostsPaneActive = false
                            this.downloadsPaneActive = false
                            this.searchPane = "chats"
                        })
                    if (this.showPublicPostsTab) {
                        Text(this.localized("ChatList_Search_FilterPublicPosts", "Public Posts")).fontSize(15)
                            .fontWeight(if (this.publicPostsPaneActive) { FontWeight.Medium } else { FontWeight.Normal })
                            .padding(left: 16, right: 16, top: 8, bottom: 8)
                            .backgroundColor(if (this.publicPostsPaneActive) { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                            .borderRadius(18)
                            .onClick({ _ =>
                                this.publicPostsPaneActive = true
                                this.downloadsPaneActive = false
                                this.searchPane = "chats"
                            })
                    }
                    // S9-11：Channels 分类（ChatList_Search_FilterChannels）
                    Text(this.localized("ChatList_Search_FilterChannels", "Channels")).fontSize(15)
                        .fontWeight(if (this.searchPane == "channels") { FontWeight.Medium } else { FontWeight.Normal })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(if (this.searchPane == "channels") { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                        .borderRadius(18)
                        .onClick({ _ => this.selectChannelsPane() })
                    Text(trSource("Apps")).fontSize(15).padding(left: 16, right: 16, top: 8, bottom: 8)
                    Text(trSource("Posts")).fontSize(15).padding(left: 16, right: 16, top: 8, bottom: 8)
                    Text(this.localized("ChatList_Search_FilterMedia", "Media")).fontSize(15)
                        .fontWeight(if (this.searchPane == "media") { FontWeight.Medium } else { FontWeight.Normal })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(if (this.searchPane == "media") { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                        .borderRadius(18)
                        .onClick({ _ => this.selectSearchPane("media") })
                    // defaultAvailableSearchPanes (SPC:102-123): Downloads follows
                    // Media and exists only while there are downloads.
                    if (this.downloadsPaneActive || hasRecentDownloads()) {
                        Text(this.localized("ChatList_Search_FilterDownloads", "Downloads")).fontSize(15)
                            .fontWeight(if (this.downloadsPaneActive) { FontWeight.Medium } else { FontWeight.Normal })
                            .padding(left: 16, right: 16, top: 8, bottom: 8)
                            .backgroundColor(if (this.downloadsPaneActive) { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                            .borderRadius(18)
                            .onClick({ _ =>
                                this.downloadsPaneActive = true
                                this.publicPostsPaneActive = false
                                this.searchPane = "chats"
                            })
                    }
                    Text(this.localized("ChatList_Search_FilterLinks", "Links")).fontSize(15)
                        .fontWeight(if (this.searchPane == "links") { FontWeight.Medium } else { FontWeight.Normal })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(if (this.searchPane == "links") { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                        .borderRadius(18)
                        .onClick({ _ => this.selectSearchPane("links") })
                    Text(this.localized("ChatList_Search_FilterFiles", "Files")).fontSize(15)
                        .fontWeight(if (this.searchPane == "files") { FontWeight.Medium } else { FontWeight.Normal })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(if (this.searchPane == "files") { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                        .borderRadius(18)
                        .onClick({ _ => this.selectSearchPane("files") })
                    Text(this.localized("ChatList_Search_FilterMusic", "Music")).fontSize(15)
                        .fontWeight(if (this.searchPane == "music") { FontWeight.Medium } else { FontWeight.Normal })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(if (this.searchPane == "music") { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                        .borderRadius(18)
                        .onClick({ _ => this.selectSearchPane("music") })
                    Text(this.localized("ChatList_Search_FilterVoice", "Voice")).fontSize(15)
                        .fontWeight(if (this.searchPane == "voice") { FontWeight.Medium } else { FontWeight.Normal })
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(if (this.searchPane == "voice") { Color(this.presentation.backgroundColor) } else { Color.Transparent })
                        .borderRadius(18)
                        .onClick({ _ => this.selectSearchPane("voice") })
                }
                .padding(left: 12, right: 12)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width(100.percent)
            .height(48)

            if (this.externalSearchVisible) {
                // tab 栏搜索胶囊（MainTabPage.floatingTabBar）占据这条底带并持有焦点；本页不叠
                // 第二个输入框，只留与它等高的占位，让筛选条整条落在胶囊之上。占位必须与
                // floatingTabBar 的真实占位一致：72 定高 + margin(bottom: 底部安全区 + 搜索态键盘高度)。
                // 此前固定 68：比胶囊带矮了 4 + 安全区，胶囊（responseRegion 56 高）压住筛选条下半截，
                // 点 Media/Links/... 和横向拖动都落到胶囊输入框上。
                // iOS 同样把筛选条放在底部搜索框上方、随键盘抬起（ChatListSearchContainerNode
                // filterContainerNode 布局在 inputHeight 之上）。
                Row {}
                    .width(100.percent)
                    .height(72.0 + getSafeAreaBottom() + (if (this.externalKeyboardInset > 0.0) { this.externalKeyboardInset } else { 0.0 }))
            } else {
            Row {
                Column {
                    SearchBar(
                        backArrow: false,
                        text: this.searchKeyword,
                        hint: this.localized("DialogList_SearchLabelCompact", "Search"),
                        onChange: { value: String => this.updateDedicatedSearch(value) },
                        onCancel: { => this.closeDedicatedSearch() },
                        showCancel: false,
                        loading: this.isSearchingMirror || this.isSearchingPeersMirror
                    )
                }
                .layoutWeight(1)
                Text("×")
                    .fontSize(30)
                    .fontColor(this.presentation.textColor)
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(this.presentation.backgroundColor)
                    .textAlign(TextAlign.Center)
                    .margin(right: 12)
                    .onClick({ _ => this.closeDedicatedSearch() })
            }
            .width(100.percent)
            .alignItems(VerticalAlign.Center)
            .padding(bottom: 8.0 + getSafeAreaBottom())
            }
        }
        .width(100.percent)
        .height(100.percent)
        // 沉浸式窗口：覆盖层铺满整屏，结果列表须让开状态栏（iOS 搜索结果从状态栏下沿开始）。
        .padding(top: getSafeAreaTop())
        .backgroundColor(this.presentation.cardColor)
    }

    public func build() {
        Stack {
        Column {
            // 1. 标题栏 (iOS-style: Edit ... Chats ... Compose)
            // P2-107: 编辑模式下显示 "Done" + 选中计数；普通模式显示 "Edit" + Compose
            Row {
                if (this.isEditMode) {
                    // P2-107: 编辑模式左侧：Select All / Deselect All
                    Text(if (this.isAllSelected()) { "Deselect All" } else { "Select All" })
                        .fontSize(15)
                        .fontColor(0x317AFF)
                        .onClick({ evt =>
                            if (this.isAllSelected()) {
                                this.selectedChatIds = ArrayList<Int64>()
                                this.refreshEditRows()
                            } else {
                                this.selectAllChats()
                            }
                        })
                } else if (this.currentFolderIdMirror == 1) {
                    // TC-0086 返修（diag-suite_settings_root-TC-0086.md「M-2」）：归档态返回
                    // 按钮，setCurrentFolder(0) 此前全仓零调用点，用户进入归档视图后没有任何
                    // UI 手段返回主列表。分支顺序固定为 isEditMode → 归档态 → root 态（编辑态
                    // 优先），与源侧 ChatListController.swift:7180 一致。判据读裸 @State 镜像
                    // currentFolderIdMirror（D-129，见字段声明处注释），不跨对象嵌套读
                    // this.viewModel.currentFolderId。先例：a8998a341^:ChatListPage.cj:874-888。
                    Text("‹ Back")
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .onClick({ _ => this.viewModel.setCurrentFolder(0) })
                } else {
                    // iOS-26 parity: near-black label inside a subtle light pill (Liquid Glass nav).
                    // CTL-CHATS-001/CTL-SHARED-001: ChatListHeader 按压 alpha 0.6 瞬时 / 0.2s 释放
                    Text(this.localized("Common_Edit", "Edit"))
                        .fontSize(17)
                        .fontColor(this.presentation.textColor)
                        .height(36)
                        .padding(left: 12, right: 12)
                        .borderRadius(18)
                        .backgroundColor(this.presentation.backgroundColor)
                        .textAlign(TextAlign.Center)
                        .opacity(if (this.editBtnPressed) { 0.6 } else { 1.0 })
                        .onTouch({ evt =>
                            match (evt.eventType) {
                                case TouchType.Down => this.editBtnPressed = true
                                case _ =>
                                    safeAnimateTo({ => this.getUIContext() }, AnimateParam(duration: 200, curve: Curve.EaseInOut), { =>
                                        this.editBtnPressed = false
                                    })
                            }
                        })
                        .onClick({ _ => this.enterEditMode() })
                }

                Blank()
                    .layoutWeight(1)

                if (this.isEditMode) {
                    // P2-107: 编辑模式中间：已选中计数
                    Text(if (this.selectedChatIds.isEmpty()) { this.localized("DialogList_Title", "Chats") } else { "${this.selectedChatIds.size} ${this.localized("Common_Selected", "Selected")}" })
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                } else if (this.currentFolderIdMirror == 1) {
                    // TC-0086 返修（「M-3」）：归档态标题，对位源侧
                    // ChatList_ArchivedChatsTitle（ChatListController.swift:7158，"Archived
                    // Chats"）。不带 .translate(x: 8.0)——那是 root 态为让位左侧 pill 的补偿，
                    // 归档态左侧是文字返回控件，不需要。先例：a8998a341^:ChatListPage.cj:924-932。
                    Text(this.localized("ChatList_ArchivedChatsTitle", "Archived Chats"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                } else {
                    Text(this.localized("DialogList_Title", "Chats"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                        .translate(x: 8.0)
                }

                Blank()
                    .layoutWeight(1)

                if (this.isEditMode) {
                    // P2-RETRO-chatlist: 手搓"Done"文字按钮 → ProgressNavButton 原子
                    Row {
                        ProgressNavButton(
                            title: "Done",
                            onClick: { => this.exitEditMode() },
                            color: 0x317AFF
                        )
                    }
                } else if (this.currentFolderIdMirror == 1) {
                    // TC-0086 返修（「M-4」）：归档态右上「⋯」按钮，触发 M-5 菜单
                    // （buildArchiveMoreMenu()）。对位源侧 ChatListController.swift:3932
                    // openArchiveMoreMenu(sourceView:gesture:)。fillColor 取值：diag-round9 F-2
                    // 返修恢复了本文件的 presentation 订阅，故随同一导航栏内同批兄弟节点
                    // （Text(trSource("Edit")) / Text(trSource("Chats")) 的 fontColor）一并改回
                    // this.presentation.textColor，不再是孤立字面量 0x000000。
                    Column {
                        Image(@r(app.media.media_ic_more))
                            .width(22)
                            .height(22)
                            .fillColor(this.presentation.textColor)
                    }
                    .width(40)
                    .height(44)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick({ _ => this.showArchiveMoreMenu = true })
                } else {
                    // iOS-26 parity（v2 spec 纠偏#3）：右侧两个控件——story/add 圆环 + compose 笔。
                    // iOS 实际截图（chats.png）双图标确证；story 功能未迁移，点按为诚实 stub（toast）。
                    Row {
                        if (this.proxyConfigured) {
                            Column {
                                Image(@r(app.media.clist_ic_proxy))
                                    .width(22)
                                    .height(22)
                                    .fillColor(if (this.viewModel.hasActiveProxy) { this.presentation.accentColor } else { this.presentation.textColor })
                            }
                            .width(40)
                            .height(44)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .onClick({ _ => routerPush("ProxySettingsPage", "") })
                        }
                        Column {
                            // 注意：此 SVG 为描边式（虚线圆+加号），勿加 fillColor（会整体填黑）
                            Image(@r(app.media.clist_ic_story_add))
                                .width(24)
                                .height(24)
                        }
                        .width(40)
                        .height(44)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .onClick({ _ => showToast("Stories are not available yet") })

                        Column {
                            // iOS composePressed（CLC:4799）：铅笔直接打开 New Message（ComposeController）
                            ComposeButtonTooltip(onPress: { => routerPush("ComposePage", "") })
                        }
                        .width(40)
                        .height(44)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                    }
                    .alignItems(VerticalAlign.Center)
                }
            }
            .width(100.percent)
            // 本仓是沉浸式窗口：EntryAbility.applyImmersiveWindowLayout() 启动时全局设了
            // setWindowLayoutFullScreen(true) + 透明系统栏，内容区顶到屏幕边。origin/main
            // 不是沉浸式布局（本文件多处注释写着「非全屏布局下窗口内容区被系统栏切掉」），
            // 所以它的表头不留顶部安全区；整取过来后「Chats」标题与状态栏时钟/电量重叠。
            // 恢复我方原有的留白（对位 c6bb0ba70 本文件 :994-995）。
            .height(52.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)
            .alignItems(VerticalAlign.Center)

            Column {
                Row {
                    Image(@r(app.media.clist_ic_search))
                        .width(18)
                        .height(18)
                        .fillColor(0x8E8E93)
                        .margin(right: 8)
                    Text(this.localized("DialogList_SearchLabelCompact", "Search"))
                        .fontSize(17)
                        .fontColor(0x8E8E93)
                }
                .width(384)
                .height(36)
                .borderRadius(10)
                .backgroundColor(this.presentation.backgroundColor)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .onClick({ _ =>
                    this.showSearch = true
                    this.onSearchVisibilityChange(true)
                    this.startSearchMirrorSync()
                })
            }
            .width(100.percent)
            .backgroundColor(this.presentation.navBarColor)
            .padding(left: 8, right: 8, bottom: 8)
            .alignItems(HorizontalAlign.Center)

            // P2-108: 连接状态 header（Connecting / Updating / Waiting for network）
            // 对应 iOS ChatListController NetworkStatusTitle：仅在非 online 状态时显示
            // 不再附加 `&& displayList.isEmpty()`：iOS 的 NetworkStatusTitle 只取决于连接状态，
            // 与列表是否有内容无关。原条件会导致本地缓存一上屏，"Connecting/Updating" 提示
            // 就消失 —— 离线时用户看到列表却没有任何离线指示，反而更具误导性。
            if (this.viewModel.connectionStatus != "online") {
                Row {
                    LoadingProgress()
                        .width(18)
                        .height(18)
                        .color(0xFFFFFF)
                        .margin(right: 8)
                    Text(this.connectionStatusText())
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Medium)
                }
                .width(100.percent)
                .height(36)
                .padding(left: 16, right: 16)
                .backgroundColor(0x8E8E93)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
            }

            // P2-108: 代理 header（走代理时显示，对应 iOS connectsViaProxy banner）
            // 资源保真修复：真实矢量图标（Chat List/ProxyShieldIcon.imageset/ic_proxymain.pdf 转 SVG）替代 emoji 字形
            if (this.viewModel.hasActiveProxy) {
                Row {
                    Image(@r(app.media.clist_ic_proxy))
                        .width(14)
                        .height(14)
                        .fillColor(0xFFFFFF)
                        .margin(right: 6)
                    Text("Connected via proxy")
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                }
                .width(100.percent)
                .height(32)
                .padding(left: 16, right: 16)
                .backgroundColor(0x317AFF)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
                .onClick({ evt =>
                    routerPush("ProxySettingsPage", "")
                })
            }

            // 2. 文件夹 tab 栏（P2-101）
            // 从服务端 messages.getDialogFilters 真拉，有多个文件夹时显示横向可滚动 tab
            // 单文件夹（只有 All）或空时隐藏（iOS 语义）
            // tab 包含未读 badge（viewModel.getUnreadCountForFilter）
            // iOS 归档（groupId .group(1)）的 ChatListController 不带文件夹 tab 栏。
            // 显隐判据是裸 Bool @State（见 folderTabsVisible 声明处），不再在 if 里经方法调用
            // 间接读 ArrayList 镜像。
            if (this.folderTabsVisible) {
                Scroll() {
                    Row {
                        // "All" tab（filterId = -1，总是第一个）。
                        // 返修（D-115 命中修复）：本 tab 结构曾通过带参数 @Builder 函数
                        // this.buildFolderTab(name, filterId) 调用；真机验证发现该带参
                        // @Builder 函数从 ForEach.itemGeneratorFunc 闭包内调用会坍缩渲染
                        // 为空（10/11 个文件夹节点消失，唯有本行"静态字面量直调"能渲染）。
                        // 现改为闭包内直接内联展开 UI 结构（不经过任何 @Builder 函数），
                        // 对齐 ChatFoldersPage.cj:1097-1194 已验证有效的写法；"All" 与
                        // 服务端文件夹共用同一套内联结构，保证选中态/未读 badge/点击态一致。
                        Column {
                            Row {
                                if (this.folderTabUnreadCount(-1) > 0 && !this.isFolderTabActive(-1)) {
                                    Badge(
                                        count: Int32(this.folderTabUnreadCount(-1)),
                                        style: BadgeStyle(
                                            color: Color(0xFFFFFF),
                                            fontSize: 10,
                                            badgeSize: 16,
                                            badgeColor: Color(0xFF3B30)
                                        ),
                                        position: BadgePosition.RightTop
                                    ) {
                                        Text(this.localized("ChatList_Tabs_All", "All"))
                                            .fontSize(15)
                                            .fontWeight(if (this.isFolderTabActive(-1)) { FontWeight.Bold } else { FontWeight.Normal })
                                            .fontColor(if (this.isFolderTabActive(-1)) { 0x317AFF } else { this.presentation.textColor })
                                            .padding(right: 10)
                                    }
                                } else {
                                    Text(this.localized("ChatList_Tabs_All", "All"))
                                        .fontSize(15)
                                        .fontWeight(if (this.isFolderTabActive(-1)) { FontWeight.Bold } else { FontWeight.Normal })
                                        .fontColor(if (this.isFolderTabActive(-1)) { 0x317AFF } else { this.presentation.textColor })
                                }
                            }
                            .padding(left: 12, right: 12, top: 8, bottom: 4)
                            // 返修三（宽度坍缩修复）：本指示条曾 .width(100.percent)；外层 Row
                            // (:638) 本身无宽度约束，100% 会向上传播撑满整个 Scroll 视口宽度，
                            // 致使本 tab Column 被拉伸到近全屏（真机 dumpLayout 实测 ~1252px），
                            // 无法与其余 tab 并排。去掉显式宽度，让指示条与其兄弟 Row（文字/badge）
                            // 一样收缩到内容宽度（对齐 HorizontalPeerComponent.cj:64-118、
                            // AppearanceSettingsPage.cj:1553-1575 横向 Scroll 场景：条目内部不使用
                            // .width(100.percent) 撑满型子元素，宽度交由内容自身决定）。
                            Row { }
                                .height(2)
                                .backgroundColor(this.folderTabIndicatorColor(-1))
                        }
                        .alignItems(HorizontalAlign.Center)
                        // 长按 All Chats → Edit Folders（CLC:1262-1270）
                        .onTouch({ evt => this.handleFolderTabTouch(evt, -1) })
                        .onClick({ evt =>
                            this.handleFolderTabTap(-1)
                        })
                        // 服务端文件夹 tab（返修：读裸 @State 镜像字段，不再直接读
                        // this.viewModel.dialogFilters，理由见 folderTabsMirror 声明处注释）。
                        // 显式提供 keyGeneratorFunc（对齐 ChatFoldersPage.cj:1194-1201 已验证
                        // 有效的同款修复）：folderTabsMirror 从空 ArrayList<ChatFolder> 首次整体
                        // 重赋值为服务端返回的非空 ArrayList<ChatFolder>（对象数据类型数组项）时，
                        // 真机验证默认键值生成规则未能让 ForEach 正确渲染新增节点（dumpLayout 只见
                        // 静态 "All" tab，服务端 tab 全部缺失，即使 hilog 证实镜像字段已同步到位）。
                        // 用 folder.id（每个 folder 唯一且持久）派生键值，使框架正确识别并渲染。
                        //
                        // 返修二（D-115 命中修复）：itemGeneratorFunc 闭包内不再调用带参数
                        // @Builder 函数 this.buildFolderTab(folder.name, folder.id)（真机验证
                        // 坍缩为 0 节点），改为闭包内直接内联展开同款 UI 结构（Column/Row/Badge/
                        // Text/底部指示条），与上方 "All" tab 内联结构、以及本文件已验证有效的
                        // ForEach 闭包内联范式（ChatFoldersPage.cj:1097-1194）保持一致。
                        ForEach(this.folderTabsMirror, itemGeneratorFunc: { folder: ChatFolder, _idx: Int64 =>
                            if (folder.id != 0) {
                            Column {
                                Row {
                                    if (this.folderTabUnreadCount(folder.id) > 0 && !this.isFolderTabActive(folder.id)) {
                                        Badge(
                                            count: Int32(this.folderTabUnreadCount(folder.id)),
                                            style: BadgeStyle(
                                                color: Color(0xFFFFFF),
                                                fontSize: 10,
                                                badgeSize: 16,
                                                badgeColor: Color(0xFF3B30)
                                            ),
                                            position: BadgePosition.RightTop
                                        ) {
                                            Text(trSource(folder.name))
                                                .fontSize(15)
                                                .fontWeight(if (this.isFolderTabActive(folder.id)) { FontWeight.Bold } else { FontWeight.Normal })
                                                .fontColor(if (this.isFolderTabActive(folder.id)) { 0x317AFF } else { this.presentation.textColor })
                                                .padding(right: 10)
                                        }
                                    } else {
                                        Text(trSource(folder.name))
                                            .fontSize(15)
                                            .fontWeight(if (this.isFolderTabActive(folder.id)) { FontWeight.Bold } else { FontWeight.Normal })
                                            .fontColor(if (this.isFolderTabActive(folder.id)) { 0x317AFF } else { this.presentation.textColor })
                                    }
                                }
                                .padding(left: 12, right: 12, top: 8, bottom: 4)
                                // 返修三（宽度坍缩修复，同 -1/"All" tab 上方注释理由）：去掉
                                // .width(100.percent)，指示条随 Column 收缩到内容宽度，使多个
                                // 服务端 tab 能在 Scroll 内并排横排，而非各占近全屏一个 tab。
                                Row { }
                                    .height(2)
                                    .backgroundColor(this.folderTabIndicatorColor(folder.id))
                            }
                            .alignItems(HorizontalAlign.Center)
                            // 长按自定义文件夹 → Edit Folder / Add Chats / Read All / Mute All / Share / Remove
                            .onTouch({ evt => this.handleFolderTabTouch(evt, folder.id) })
                            .onClick({ evt =>
                                this.handleFolderTabTap(folder.id)
                            })
                            }
                        }, keyGeneratorFunc: { folder: ChatFolder, _idx: Int64 =>
                            folder.id.toString()
                        })
                    }
                    .padding(left: 8, right: 8)
                    .alignItems(VerticalAlign.Center)
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width(100.percent)
                .height(44)
                .backgroundColor(this.presentation.navBarColor)
                .onAreaChange({ _: Area, newArea: Area =>
                    this._folderBarMounted = true
                    match (newArea.globalPosition.y) {
                        case Some(top) => this.folderBarBottomY = top.value + newArea.height.value
                        case None => ()
                    }
                })
                // 真实挂载证据（看门狗判据 + 上机对照 hilog）。
                .onAppear({ =>
                    this._folderBarMounted = true
                    Hilog.info(0, "CjTelegram",
                        "[ChatListPage] folder tab bar mounted filters=${this.folderTabsMirror.size}")
                })
                .onDisAppear({ =>
                    this._folderBarMounted = false
                    Hilog.info(0, "CjTelegram", "[ChatListPage] folder tab bar unmounted")
                })
            }

            // 3. 搜索态不在本列内铺第二套搜索框 / RECENT / 结果列表：搜索界面整块由
            // buildDedicatedSearchSurface() 覆盖层承担（对位 iOS searchDisplayController 盖在
            // 会话列表之上、只有一套搜索 UI，ChatListController.swift activateSearch）。此前这里
            // 还有一个隐藏在覆盖层下的 SearchBar（中文 hint）+ RECENT/CONTACTS + 第二份结果 List，
            // 两份 List 共用 chatListScroller，且隐藏层仍参与命中与布局树。
            // 4. 加载状态 / 空状态 / 聊天列表
            // CTL-CHATS-004: iOS Chats 下拉没有刷新 spinner（下拉是 search/stories reveal，
            // ChatListNavigationBar.swift 无 UIRefreshControl）。移除 Refresh 包裹，
            // 保留 List 自身 Spring 回弹；数据刷新依赖轮询 + 推送（不损失功能）。
            Column {
                if (!this.isSearchActive()) {
                    this.buildListContent()
                }
            }
            .width(100.percent)
            .layoutWeight(1)

            // P2-107: 编辑模式底部批量操作栏（在 Refresh 之上，仅编辑模式显示）
            this.buildBatchActionBar()
            // TC-0016 第四轮返修：群组退群/删除专属确认卡片（z 层在 buildActionSheet 之上，
            // 因为触发时机是 buildActionSheet 已 dismiss 之后）
            this.buildDeleteChatPeerSheet()
            // Phase T1: Compose 菜单 (iOS-style action sheet 覆盖层)
            this.buildComposeMenu()
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.presentation.cardColor)
        // 上下文菜单要把自己夹在可视区内，需要知道页面尺寸
        .onAreaChange({ _: Area, newArea: Area =>
            this.screenWidthVp = newArea.width.value
            this.screenHeightVp = newArea.height.value
            // 内容区在窗口里的顶 Y = 顶部安全区高度。浮层铺满整块屏幕，
            // 菜单要夹在这条线以下（见 contextUsableTop）。
            match (newArea.globalPosition.y) {
                case Some(top) => this.contentTopVp = top.value
                case None => ()
            }
        })
        // 同上：沉浸式窗口下列表底部要自己让开底部安全区，否则内容顶到屏幕下沿。
        // 对位 c6bb0ba70 本文件 :1317。
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
        .onDisAppear({ => this.cleanup() })

        if (this.showSearch || this.externalSearchVisible) {
            this.buildDedicatedSearchSurface()
        }

        // 长按上下文菜单挂在**最外层 Stack 的最后**，而不是内容 Column 里。
        // 对齐 iOS 的 presentInGlobalOverlay：它是独立于页面内容的全屏层，
        // 因此标题栏、搜索入口、文件夹 tab 全部被模糊底盖住。
        // 之前挂在内容 Column 内参与纵向流，覆盖不到标题栏，导航栏和搜索按钮仍然露着。
        this.buildActionSheet()
        // TC-0086 返修（「M-5」）：归档态导航栏「⋯」More 菜单，挂在最外层 Stack 的末尾
        // （与上方 buildActionSheet() 同理：对齐 iOS presentInGlobalOverlay，挂进内容
        // Column 会盖不住导航栏）。
        this.buildArchiveMoreMenu()
        // 文件夹 tab / 归档行 / 搜索消息结果的上下文菜单（同样挂最外层，盖住导航栏）
        this.buildListMenu()
        // S1-47：搜索结果 Add to Contacts 的 NewContactScreen 底部表单
        this.buildNewContactSheet()
        }
        .width(100.percent)
        .height(100.percent)
    }

    /**
     * P2-108: 提取列表内容为独立方法供 Refresh 包裹
     * 包含：骨架屏 / 空状态 / 真实聊天列表
     *
     * 分支必须保持三段，且**不得**再插入 `else if (this.isPageLoading)`：
     *   1. isPageLoading && displayList 为空 → 骨架屏
     *   2. displayList 为空（且非搜索有结果） → 空状态
     *   3. else                              → 真实列表（有数据就渲染，与加载态无关）
     *
     * 原实现在 1 和 2 之间还有一个「刷新中但已有数据 → 居中转圈」分支，其注释自称
     * "不遮盖既有列表内容下方"，但实现是 Column{LoadingProgress+Text} 配
     * layoutWeight(1) + justifyContent(Center)，**整个替换掉了内容区**。
     * 后果：displayList 已有 12 条本地缓存会话，却因 isPageLoading 仍为 true
     * 而只显示"正在加载对话..."，ViewModel 侧「本地缓存先上屏」的能力被 UI 层完全抵消。
     *
     * 对齐 iOS：有数据就渲染数据，加载态绝不阻塞内容；同步/连接状态由上方的
     * NetworkStatusTitle header 呈现（对应 iOS ChatListController），而非占满内容区。
     */
    @Builder
    func buildListContent() {
            if (this.isPageLoading && this.displayList.isEmpty()) {
                // 首次加载且尚无数据：铺一列骨架屏微光占位（Telegram 列表首次加载行为）。
                // 数据到了（displayList 非空）或加载结束，本分支自然退出 → ArkUI 销毁这些
                // SkeletonRow / ShimmerView 子组件，iterations:-1 的声明式动画随组件销毁停止，
                // 不泄漏。
                Column {
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                    SkeletonRow()
                }
                .width(100.percent)
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
            } else if (this.displayList.isEmpty()
                && !(this.isSearchActive() && !this.searchKeyword.isEmpty()
                     && (!this.searchGlobalPeerResultsMirror.isEmpty()
                         || !this.searchGlobalResultsMirror.isEmpty()
                         || this.searchPane != "chats"
                         || !this.publicPostsMirror.isEmpty()
                         || this.isSearchingPublicPostsMirror
                         || this.isSearchingPeersMirror
                         || this.isSearchingMirror))) {
                // P2-110: iOS-faithful 三态空状态
                // 1. 特定文件夹空 → "This folder is empty" (iOS ChatListEmptyNode folder 语义)
                // 2. 搜索无结果  → "No Results" (iOS localSearch/globalSearch empty)
                // 3. 主列表空   → "No messages yet" + New Message CTA (iOS main chatList empty)
                // P2-102: 搜索模式下若有全局结果（peer 或 messages），跳过空状态直接显示 List
                Column {
                    Text(this.emptyStateIcon())
                        .fontSize(64)
                        .margin(bottom: 16)

                    Text(this.emptyStateTitleText())
                        .fontSize(20)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(this.presentation.textColor)
                        .margin(bottom: 8)

                    Text(this.emptyStateSubtitleText())
                        .fontSize(15)
                        .fontColor(0x8E8E93)
                        .textAlign(TextAlign.Center)
                        .margin(bottom: 24)

                    if (!this.isSearchActive() && !this.isInSpecificFolder()) {
                        Button(trSource("New Message"))
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0xFFFFFF)
                            .backgroundColor(0x317AFF)
                            .borderRadius(14)
                            .padding(left: 28, right: 28, top: 13, bottom: 13)
                            .onClick({ evt =>
                                routerPush("ComposePage", "")
                            })
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .padding(left: 40, right: 40)
            } else {
                // 聊天列表 + 搜索结果（P2-102 三段式）
                List(scroller: this.chatListScroller) {
                    // 主列表顶部：归档入口（有归档聊天时显示）
                    // 资源保真修复：真实矢量图标（Chat/Context Menu/Archive.imageset/ic_lt_archive.pdf 转 SVG）替代 emoji 字形
                    if (this.shouldShowArchiveRow()) {
                        ListItem {
                            Row {
                                Image(@r(app.media.clist_ic_archive))
                                    .width(20)
                                    .height(20)
                                    .fillColor(0x317AFF)
                                    .margin(right: 12)
                                Text(this.localized("ChatList_ArchivedChatsTitle", "Archived Chats"))
                                    .fontSize(16)
                                    .fontColor(0x317AFF)
                                    .layoutWeight(1)
                                // S1-66：未读归档会话数徽标（iOS ChatListItem groupReference 灰色 badge）
                                if (this.archiveUnreadChatsMirror > 0) {
                                    Text("${this.archiveUnreadChatsMirror}")
                                        .fontSize(13)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(0xFFFFFF)
                                        .padding(left: 7, right: 7, top: 2, bottom: 2)
                                        .backgroundColor(0xB6B6BB)
                                        .borderRadius(11)
                                        .margin(right: 8)
                                }
                                Text("›")
                                    .fontSize(20)
                                    .fontColor(0xC7C7CC)
                            }
                            .width(100.percent)
                            .padding(left: 16, right: 16, top: 12, bottom: 12)
                            .backgroundColor(this.presentation.cardColor)
                            // 长按 → Mark All as Read / Hide Above the List（ChatContextMenus.swift:19-49）
                            .onTouch({ evt => this.handleArchiveRowTouch(evt) })
                            .onClick({ evt =>
                                this.handleArchiveRowTap()
                            })
                            .onAreaChange({ _: Area, newArea: Area =>
                                this.archiveRowHeight = newArea.height.value
                                match (newArea.globalPosition.y) {
                                    case Some(top) => this.archiveRowTopY = top.value
                                    case None => ()
                                }
                            })
                        }
                        .width(100.percent)
                        // iOS groupReferenceRevealOptions（ChatListItem.swift:792-805）：左滑 Hide / Pin
                        .swipeAction(end: { =>
                            bind(this.buildArchiveSwipePanel, this)()
                        })
                    }
                    // ---- 搜索激活且有关键词：显示 DIALOGS / GLOBAL PEERS / MESSAGES 三段 ----
                    if (this.isSearchActive() && !this.searchKeyword.isEmpty() && !this.publicPostsPaneActive && this.searchPane == "chats") {
                        // Section 1: DIALOGS — 本地匹配的对话
                        if (!this.displayList.isEmpty()) {
                            ListItem {
                                ChatListSearchItemHeaderComponent(headerType: ChatListSearchHeaderType.LocalPeers)
                            }
                            .width(100.percent)
                        }
                    }
                    // ---- 正常对话列表（非搜索 或 搜索中本地匹配）----
                    // P2-107: 编辑模式下每行左侧显示选择圈（Toggle checkbox），禁用 swipe。
                    //         普通模式保持原有 swipe 行为不变（回归安全）。
                    if (this.isEditMode) {
                        // P2-107: 编辑模式列表（有 checkbox，无 swipeAction）
                        ForEach(this.displayList, itemGenerator: { entry: ChatEntry, _idx2: Int64 =>
                            ListItem {
                                Row {
                                    // CTL-CHATS-001: 选择圈槽位随 chatEditShift 滑入(iOS x=-w/2+alpha 0.4 spring)
                                    // iOS ItemListSelectableControlNode：22pt 圆形勾选，未选描边
                                    // itemCheckColors.strokeColor，已选实心 accent + 白勾；它只是视觉，
                                    // 整行点按切换选中（ChatListItem 编辑态 tap → toggle selection）。
                                    // 不用 Toggle：Toggle 自持 isOn 状态，行点按改选中后 isOn 回写会再触发
                                    // onChange，一次点按被翻转两次，选中永远落不下来。
                                    Stack {
                                        Column {}
                                            .width(22)
                                            .height(22)
                                            .borderRadius(11)
                                            .borderWidth(if (this.isChatSelected(entry.chat.id)) { 0 } else { 1.5 })
                                            .borderColor(0xC7C7CC)
                                            .backgroundColor(if (this.isChatSelected(entry.chat.id)) { Color(0xFF317AFF) } else { Color.Transparent })
                                        Image(@r(app.media.media_ic_check))
                                            .width(16)
                                            .height(16)
                                            .fillColor(0xFFFFFF)
                                            .opacity(if (this.isChatSelected(entry.chat.id)) { 1.0 } else { 0.0 })
                                    }
                                    .width(this.chatEditShift)
                                    .height(44)
                                    .clip(true)
                                    .opacity(this.chatEditShift / 44.0)
                                    .alignContent(Alignment.Center)
                                    .onClick({ _ => this.toggleChatSelection(entry.chat.id) })
                                    Column {
                                        ChatListItem(
                                            chat: entry.chat,
                                            isTyping: this.viewModel.isTyping(entry.chat.id) && entry.chat.peerType == "user",
                                            onClick: { =>
                                                this.toggleChatSelection(entry.chat.id)
                                            },
                                            onLongPress: { _y: Float64, _h: Float64 =>
                                                this.toggleChatSelection(entry.chat.id)
                                            }
                                        )
                                    }
                                    .layoutWeight(1)
                                    // iOS 编辑态置顶会话带重排手柄（ItemListRevealOptions 的 reorder control），
                                    // 按住上下拖动调整置顶顺序，松手即提交（ChatListNode reorderItems）。
                                    if (entry.chat.isPinned) {
                                        Text("≡")
                                            .fontSize(26)
                                            .fontColor(0xC7C7CC)
                                            .width(44)
                                            .height(56)
                                            .textAlign(TextAlign.Center)
                                            .onTouch({ evt => this.handlePinnedReorderTouch(evt, entry.chat.id) })
                                    }
                                }
                                .width(100.percent)
                                .alignItems(VerticalAlign.Center)
                                .translate(y: if (this.reorderChatId == entry.chat.id) { this.reorderOffsetY } else { 0.0 })
                                .zIndex(if (this.reorderChatId == entry.chat.id) { 1 } else { 0 })
                                .onAreaChange({ _: Area, newArea: Area =>
                                    this.editRowHeight = newArea.height.value
                                })
                            }
                            .width(100.percent)
                        }, keyGeneratorFunc: { entry: ChatEntry, _idx2: Int64 =>
                            // 选中态进键：勾选圈随选中变化必然重建（ForEach 项内属性不保证跟随
                            // 页面 @State 重算），由 refreshEditRows() 重新发布 displayList 触发。
                            "${entry}_sel${this.isChatSelected(entry.chat.id)}"
                        })
                    } else if (!(this.isSearchActive() && (this.publicPostsPaneActive || this.searchPane != "chats"))) {
                        // 普通模式：原有 swipeAction 行为不变
                        ForEach(this.displayList, itemGenerator: { entry: ChatEntry, index: Int64 =>
                            ListItem {
                                ChatListItem(
                                    chat: entry.chat,
                                    isTyping: this.viewModel.isTyping(entry.chat.id) && entry.chat.peerType == "user",
                                    onClick: { =>
                                        // 点按即导航。已读提交（本地投影发布 → 本页重建行、冷启动
                                        // 快照落盘、服务端 readHistory）统一由 ChatRoomPage.ensureLoaded
                                        // 在首屏内容之后完成（对位 iOS ChatControllerImpl：已读由历史
                                        // 视图加载触发，不在列表点按时做），不再挡在转场之前。
                                        chatOpenPerfBegin(entry.chat.id, entry.chat.peerType)
                                        if (this.isSearchActive() && !this.searchKeyword.isEmpty()) {
                                            getChatListSearchRecentPeersService().addRecentPeer(entry.chat)
                                        }
                                        setSelectedChat(entry.chat.id, entry.chat.name, entry.chat.peerType)
                                        setSelectedChatDraft(entry.chat.draftText)
                                        setSelectedChatUsername(entry.chat.username)
                                        routerPush("ChatRoomPage", entry.chat.name)
                                        chatOpenPerfMark("navigateIssued")
                                    },
                                    onLongPress: { y: Float64, h: Float64 =>
                                        // 对齐 iOS：长按出上下文菜单，多选编辑走导航栏 Edit 入口
                                        this.presentChatActionSheet(entry.chat, sourceY: y, sourceHeight: h)
                                    },
                                    // 手指不抬起也能直接滑到某个动作上松手执行
                                    onLongPressMove: { x: Float64, y: Float64 =>
                                        this.handleContextGestureMove(x, y)
                                    },
                                    onLongPressEnd: { =>
                                        this.handleContextGestureEnd()
                                    }
                                )
                            }
                            .swipeAction(
                                // 归档内没有左侧动作（iOS leftRevealOptions 仅根列表），归档态不挂 start
                                // builder：此前挂的是渲染为空的 builder，本绑定下空 builder 会塌成
                                // "宽度=剩余空间"的空块（见下方注释的真机隔离实验），会干扰行布局。
                                start: if (this.currentFolderIdMirror == 1) { None<CustomBuilder> } else { Some<CustomBuilder>({ =>
                                    // TC-0012 深层修复（第二轮，真机隔离实验证实）：
                                    // 真机 dumpLayout + hilog swiperIndex 逐步隔离实验证实，ArkUI-CJ 当前
                                    // 版本的 ListItem.swipeAction(start:/end:) CustomBuilder 插槽内，任何
                                    // 顶层为容器组件（Row/Column/Flex）且带子节点的写法都会坍缩为 0 子节点
                                    // 空块（宽度回退为剩余空间），与 start/end 位置、内部 if/else 写法、
                                    // 是否显式声明宽度均无关——仅有"顶层为单个叶子组件（无子节点，如
                                    // Text/Button，内容为组件自身 text 属性）"才能正确渲染（详见
                                    // featureX.md Hand-off，含真机隔离实验完整记录）。
                                    // 已改为叶子 Text 单按钮：保留原「标记已读/未读」单一动作语义。
                                    // iOS leftRevealOptions（ChatListItem.swift:881-906）：根列表右滑
                                    // Read/Unread + Pin/Unpin；归档内没有左侧动作。与 end 侧同一 bind 模板渲染。
                                    bind(this.buildSwipeStartPanel, this)()
                                }) },
                                end: { =>
                                    // TC-0452 round2 返修（D-135 更正后的修复模板，同 SettingsPage.cj/
                                    // DevicesPage.cj 等五处先例）：这个 CustomBuilder 体在 ForEach 逐行
                                    // 构建期会被预求值一次，赋值写在这里会被"最后构建的那一行"覆盖，
                                    // 面板渲染只经 bind(...)()，不在这个体内做任何 this.field = 赋值。
                                    // 行身份镜像的唯一写入点改为下面的 onOffsetChange。
                                    bind(this.buildSwipeEndPanel, this)()
                                },
                                onOffsetChange: { offset: Float64 =>
                                    // 真正的逐行滑动开合事件回调（非 CustomBuilder，不受构建期预
                                    // 求值影响），可以安全读闭包捕获的 entry。offset != 0 表示本行
                                    // 正在/已经滑出；offset 归零（关闭）不写，避免用另一行的关闭事件
                                    // 覆盖当前正打开行的镜像。
                                    if (offset != 0.0) {
                                        this.swipeRowChatId = entry.chat.id
                                        this.swipeRowChatName = entry.chat.name
                                        this.swipeRowPeerType = entry.chat.peerType
                                        this.swipeRowMuted = entry.chat.isMuted
                                        this.swipeRowArchived = this.currentFolderIdMirror == 1
                                        this.swipeRowUnread = entry.chat.unreadCount > 0 || entry.chat.isMarkedUnread
                                        this.swipeRowPinned = entry.chat.isPinned
                                    }
                                }
                            )
                        }, keyGeneratorFunc: { entry: ChatEntry, _idx3: Int64 =>
                            this.swipeRowKey(entry)
                        })
                    }

                    // iOS ChatListSearchListPaneNode 段序：本地 CHATS AND CONTACTS 在前，GLOBAL SEARCH、
                    // MESSAGES 在后（此前两段排在 displayList 之前，DIALOGS 标题与本地行被隔开）。
                    if (this.isSearchActive() && !this.searchKeyword.isEmpty() && !this.publicPostsPaneActive && this.searchPane == "chats") {
                        // Section 2: GLOBAL PEERS — contacts.search 远端 peer 结果
                        if (this.isSearchingPeersMirror) {
                            ListItem {
                                Row {
                                    LoadingProgress()
                                        .width(20)
                                        .height(20)
                                        .color(0x317AFF)
                                        .margin(right: 8)
                                    Text("Searching...")
                                        .fontSize(14)
                                        .fontColor(0x8E8E93)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(this.presentation.cardColor)
                            }
                            .width(100.percent)
                        } else if (!this.searchGlobalPeerResultsMirror.isEmpty()) {
                            ListItem {
                                ChatListSearchItemHeaderComponent(headerType: ChatListSearchHeaderType.GlobalPeers)
                            }
                            .width(100.percent)
                            ForEach(this.searchGlobalPeerResultsMirror, itemGenerator: { peerChat: Chat, _idx: Int64 =>
                                ListItem {
                                    ChatListItem(
                                        chat: peerChat,
                                        isTyping: false,
                                        onClick: { =>
                                            // P2-102: 记录最近搜索的 peer
                                            getChatListSearchRecentPeersService().addRecentPeer(peerChat)
                                            setSelectedChat(peerChat.id, peerChat.name, peerChat.peerType)
                                            setSelectedChatDraft("")
                                            setSelectedChatUsername(peerChat.username)
                                            routerPush("ChatRoomPage", peerChat.name)
                                        },
                                        onLongPress: { y: Float64, h: Float64 =>
                                            this.presentChatActionSheet(peerChat, sourceY: y, sourceHeight: h, fromSearch: true)
                                        },
                                        onLongPressMove: { x: Float64, y: Float64 =>
                                            this.handleContextGestureMove(x, y)
                                        },
                                        onLongPressEnd: { =>
                                            this.handleContextGestureEnd()
                                        }
                                    )
                                }
                                .width(100.percent)
                            }, keyGeneratorFunc: { peerChat: Chat, _idx: Int64 =>
                                // 行身份必须随 peer 变：ChatListItem 的 onClick 是创建时捕获的普通闭包，
                                // 默认 index 键下换一批结果只刷新 @Prop chat，点击仍跳到旧 peer。
                                "gpeer_${peerChat.peerType}_${peerChat.id}"
                            })
                        }
                        // PUBLIC POSTS —— # 查询时 Chats 结果里最多 3 条 + 「Show More >」
                        // （SLP:1128-1133；数据 channels.searchPosts，SLP:2764-2804）
                        if (this.isSearchingPublicPostsMirror && this.publicPostsMirror.isEmpty()) {
                            ListItem {
                                Row {
                                    LoadingProgress()
                                        .width(20)
                                        .height(20)
                                        .color(0x317AFF)
                                        .margin(right: 8)
                                    Text("Searching...")
                                        .fontSize(14)
                                        .fontColor(0x8E8E93)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(this.presentation.cardColor)
                            }
                            .width(100.percent)
                        } else if (!this.publicPostsMirror.isEmpty()) {
                            ListItem {
                                Row {
                                    Text(this.localized("DialogList_SearchSectionPublicPosts", "Public Posts").toAsciiUpper())
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .layoutWeight(1)
                                    Text("${this.localized("ChatList_Search_ShowMore", "Show More")} >")
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .onClick({ _ => this.openPublicPostsPane() })
                                }
                                .width(100.percent)
                                .height(28)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(this.presentation.backgroundColor)
                            }
                            .width(100.percent)
                            ForEach(this.firstPublicPosts(), itemGenerator: { msgChat: Chat, _idx: Int64 =>
                                ListItem {
                                    Row {
                                        if (this.searchSelectionActive) {
                                            Stack {
                                                Toggle(ToggleType.Checkbox, isOn: this.isSearchMessageSelected(msgChat))
                                                    .size(width: 24, height: 24)
                                                    .selectedColor(0x317AFF)
                                                    .onChange({ _isOn: Bool =>
                                                        this.toggleSearchSelection(msgChat)
                                                    })
                                            }
                                            .width(44)
                                            .height(44)
                                            .alignContent(Alignment.Center)
                                        }
                                        ChatListItem(
                                            chat: msgChat,
                                            isTyping: false,
                                            onClick: { =>
                                                this.onSearchMessageTap(msgChat)
                                            },
                                            onLongPress: { y: Float64, h: Float64 =>
                                                this.openSearchMessageMenu(msgChat, y, h)
                                            }
                                        )
                                    }
                                    .width(100.percent)
                                    .alignItems(VerticalAlign.Center)
                                }
                                .width(100.percent)
                            }, keyGeneratorFunc: { msgChat: Chat, _idx: Int64 =>
                                "ppost_${msgChat.peerType}_${msgChat.id}_${msgChat.searchMessageId}_${this.searchSelectionActive}_${this.isSearchMessageSelected(msgChat)}"
                            })
                        }
                        // Section 3: MESSAGES — messages.searchGlobal 消息搜索结果（按消息成行）
                        if (this.isSearchingMirror) {
                            // iOS ChatListSearchListPaneNode 只把 isSearching 反映为搜索框 activity
                            // 指示器（无文字行）；这里的行仅保留 spinner，不带硬编码文案。
                            ListItem {
                                Row {
                                    LoadingProgress()
                                        .width(20)
                                        .height(20)
                                        .color(0x317AFF)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16, right: 16)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(this.presentation.cardColor)
                            }
                            .width(100.percent)
                        } else if (!this.searchGlobalResultsMirror.isEmpty() || this.messagesSearchScope != "all") {
                            // S9-23：MESSAGES 段头右侧 "From All Chats ˅"（ChatListSearchListPaneNode:1240-1256
                            // actionTitle = filterTitle + chevron），点开范围菜单。
                            ListItem {
                                Row {
                                    Text(this.localized("DialogList_SearchSectionMessages", "Messages").toAsciiUpper())
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .fontWeight(FontWeight.Medium)
                                    Blank().layoutWeight(1)
                                    Row {
                                        Text(this.messagesScopeTitle())
                                            .fontSize(13)
                                            .fontColor(0x8E8E93)
                                            .fontWeight(FontWeight.Medium)
                                        Image(@r(app.media.item_list_disclosure_arrow))
                                            .width(6)
                                            .height(10)
                                            .fillColor(0x8E8E93)
                                            .rotate(angle: Float32(90.0))
                                            .margin(left: 6)
                                    }
                                    .alignItems(VerticalAlign.Center)
                                    .padding(top: 4, bottom: 4)
                                    .onAreaChange({ _: Area, newArea: Area =>
                                        match ((newArea.globalPosition.x, newArea.globalPosition.y)) {
                                            case (Some(x), Some(y)) =>
                                                this.messagesScopeAnchorX = x.value + newArea.width.value / 2.0
                                                this.messagesScopeAnchorTop = y.value
                                                this.messagesScopeAnchorBottom = y.value + newArea.height.value
                                            case _ => ()
                                        }
                                    })
                                    .onClick({ _ => this.presentMessagesScopeMenu() })
                                }
                                .width(100.percent)
                                .height(28)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(0xF2F2F7)
                            }
                            .width(100.percent)
                            if (this.searchGlobalResultsMirror.isEmpty()) {
                                ListItem {
                                    Text(this.localized("ChatList_Search_NoResults", "No Results"))
                                        .fontSize(15)
                                        .fontColor(0x8E8E93)
                                        .width(100.percent)
                                        .height(60)
                                        .textAlign(TextAlign.Center)
                                }
                                .width(100.percent)
                            }
                            ForEach(this.searchGlobalResultsMirror, itemGenerator: { msgChat: Chat, _idx: Int64 =>
                                ListItem {
                                    Row {
                                        if (this.searchSelectionActive) {
                                            Stack {
                                                Toggle(ToggleType.Checkbox, isOn: this.isSearchMessageSelected(msgChat))
                                                    .size(width: 24, height: 24)
                                                    .selectedColor(0x317AFF)
                                                    .onChange({ _isOn: Bool =>
                                                        this.toggleSearchSelection(msgChat)
                                                    })
                                            }
                                            .width(44)
                                            .height(44)
                                            .alignContent(Alignment.Center)
                                        }
                                        ChatListItem(
                                            chat: msgChat,
                                            isTyping: false,
                                            onClick: { =>
                                                this.onSearchMessageTap(msgChat)
                                            },
                                            onLongPress: { y: Float64, h: Float64 =>
                                                this.openSearchMessageMenu(msgChat, y, h)
                                            }
                                        )
                                    }
                                    .width(100.percent)
                                    .alignItems(VerticalAlign.Center)
                                }
                                .width(100.percent)
                            }, keyGeneratorFunc: { msgChat: Chat, _idx: Int64 =>
                                "gmsg_${msgChat.peerType}_${msgChat.id}_${msgChat.searchMessageId}_${this.searchSelectionActive}_${this.isSearchMessageSelected(msgChat)}"
                            })
                        }
                    }
                    // 分类标签（Media / Links / Files / Music / Voice）：各会话里的该类消息，按消息成行
                    // S9-11：Channels 分类 —— CHANNELS YOU JOINED（本地广播频道）+ RECOMMENDED CHANNELS
                    // （channels.getChannelRecommendations），对位 ChatListSearchListPaneNode:4194-4260。
                    if (this.isSearchActive() && this.searchPane == "channels") {
                        if (!this.channelsJoinedMirror.isEmpty()) {
                            ListItem {
                                Row {
                                    Text(this.localized("ChatList_Search_SectionLocalChannels", "CHANNELS YOU JOINED"))
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .fontWeight(FontWeight.Medium)
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .height(28)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(0xF2F2F7)
                            }
                            .width(100.percent)
                            ForEach(this.channelsJoinedMirror, itemGenerator: { peerChat: Chat, _idx: Int64 =>
                                ListItem {
                                    ChatListItem(
                                        chat: peerChat,
                                        isTyping: false,
                                        onClick: { =>
                                            setSelectedChat(peerChat.id, peerChat.name, peerChat.peerType)
                                            setSelectedChatDraft("")
                                            setSelectedChatUsername(peerChat.username)
                                            routerPush("ChatRoomPage", peerChat.name)
                                        },
                                        onLongPress: { y: Float64, h: Float64 =>
                                            this.presentChatActionSheet(peerChat, sourceY: y, sourceHeight: h, fromSearch: true)
                                        },
                                        onLongPressMove: { x: Float64, y: Float64 =>
                                            this.handleContextGestureMove(x, y)
                                        },
                                        onLongPressEnd: { =>
                                            this.handleContextGestureEnd()
                                        }
                                    )
                                }
                                .width(100.percent)
                            }, keyGeneratorFunc: { peerChat: Chat, _idx: Int64 => "chpane_joined_${peerChat.id}" })
                        }
                        if (this.isLoadingChannelsMirror && this.channelsRecommendedMirror.isEmpty()) {
                            ListItem {
                                Row {
                                    LoadingProgress()
                                        .width(20)
                                        .height(20)
                                        .color(0x317AFF)
                                }
                                .width(100.percent)
                                .height(44)
                                .justifyContent(FlexAlign.Center)
                            }
                            .width(100.percent)
                        } else if (!this.channelsRecommendedMirror.isEmpty()) {
                            ListItem {
                                Row {
                                    Text(this.localized("ChatList_Search_SectionRecommendedChannels", "RECOMMENDED CHANNELS"))
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .fontWeight(FontWeight.Medium)
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .height(28)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(0xF2F2F7)
                            }
                            .width(100.percent)
                            ForEach(this.channelsRecommendedMirror, itemGenerator: { peerChat: Chat, _idx: Int64 =>
                                ListItem {
                                    ChatListItem(
                                        chat: peerChat,
                                        isTyping: false,
                                        onClick: { =>
                                            setSelectedChat(peerChat.id, peerChat.name, peerChat.peerType)
                                            setSelectedChatDraft("")
                                            setSelectedChatUsername(peerChat.username)
                                            routerPush("ChatRoomPage", peerChat.name)
                                        },
                                        onLongPress: { y: Float64, h: Float64 =>
                                            this.presentChatActionSheet(peerChat, sourceY: y, sourceHeight: h, fromSearch: true)
                                        },
                                        onLongPressMove: { x: Float64, y: Float64 =>
                                            this.handleContextGestureMove(x, y)
                                        },
                                        onLongPressEnd: { =>
                                            this.handleContextGestureEnd()
                                        }
                                    )
                                }
                                .width(100.percent)
                            }, keyGeneratorFunc: { peerChat: Chat, _idx: Int64 => "chpane_rec_${peerChat.id}" })
                        } else if (this.channelsJoinedMirror.isEmpty() && !this.isLoadingChannelsMirror) {
                            ListItem {
                                Column {
                                    Text(this.localized("ChatList_Search_RecommendedChannelsEmpty_Title", "No Channels Yet..."))
                                        .fontSize(17)
                                        .fontWeight(FontWeight.Medium)
                                        .fontColor(this.presentation.textColor)
                                        .margin(top: 32, bottom: 6)
                                    Text(this.localized("ChatList_Search_RecommendedChannelsEmpty_Text", "You are not currently subscribed to any channel."))
                                        .fontSize(15)
                                        .fontColor(0x8E8E93)
                                        .textAlign(TextAlign.Center)
                                }
                                .width(100.percent)
                                .alignItems(HorizontalAlign.Center)
                                .padding(left: 32, right: 32)
                            }
                            .width(100.percent)
                        }
                    }
                    if (this.isSearchActive() && this.searchPane != "chats" && this.searchPane != "channels") {
                        if (this.isSearchingFilterMirror && this.filterResultsMirror.isEmpty()) {
                            ListItem {
                                Row {
                                    LoadingProgress()
                                        .width(20)
                                        .height(20)
                                        .color(0x317AFF)
                                }
                                .width(100.percent)
                                .height(44)
                                .justifyContent(FlexAlign.Center)
                            }
                            .width(100.percent)
                        } else if (this.filterResultsMirror.isEmpty()) {
                            ListItem {
                                Text(this.localized("ChatList_Search_NoResults", "No Results"))
                                    .fontSize(17)
                                    .fontColor(0x8E8E93)
                                    .width(100.percent)
                                    .height(88)
                                    .textAlign(TextAlign.Center)
                            }
                            .width(100.percent)
                        } else {
                            ForEach(this.filterResultsMirror, itemGenerator: { msgChat: Chat, _idx: Int64 =>
                                ListItem {
                                    ChatListItem(
                                        chat: msgChat,
                                        isTyping: false,
                                        onClick: { =>
                                            this.onSearchMessageTap(msgChat)
                                        },
                                        onLongPress: { y: Float64, h: Float64 =>
                                            this.openSearchMessageMenu(msgChat, y, h)
                                        }
                                    )
                                }
                                .width(100.percent)
                            }, keyGeneratorFunc: { msgChat: Chat, _idx: Int64 =>
                                "fpane_${this.searchPane}_${msgChat.peerType}_${msgChat.id}_${msgChat.searchMessageId}"
                            })
                        }
                    }
                    // Public Posts 标签：只列帖子（SCN:339-341 切到 .publicPosts pane）
                    if (this.isSearchActive() && !this.searchKeyword.isEmpty() && this.publicPostsPaneActive) {
                        if (this.isSearchingPublicPostsMirror && this.publicPostsMirror.isEmpty()) {
                            ListItem {
                                Row {
                                    LoadingProgress()
                                        .width(20)
                                        .height(20)
                                        .color(0x317AFF)
                                        .margin(right: 8)
                                    Text("Searching...")
                                        .fontSize(14)
                                        .fontColor(0x8E8E93)
                                }
                                .width(100.percent)
                                .height(44)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(this.presentation.cardColor)
                            }
                            .width(100.percent)
                        } else {
                            ListItem {
                                Row {
                                    Text(this.localized("DialogList_SearchSectionPublicPosts", "Public Posts").toAsciiUpper())
                                        .fontSize(13)
                                        .fontColor(0x8E8E93)
                                        .layoutWeight(1)
                                }
                                .width(100.percent)
                                .height(28)
                                .padding(left: 16, right: 16)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(this.presentation.backgroundColor)
                            }
                            .width(100.percent)
                            ForEach(this.publicPostsMirror, itemGenerator: { msgChat: Chat, _idx: Int64 =>
                                ListItem {
                                    Row {
                                        if (this.searchSelectionActive) {
                                            Stack {
                                                Toggle(ToggleType.Checkbox, isOn: this.isSearchMessageSelected(msgChat))
                                                    .size(width: 24, height: 24)
                                                    .selectedColor(0x317AFF)
                                                    .onChange({ _isOn: Bool =>
                                                        this.toggleSearchSelection(msgChat)
                                                    })
                                            }
                                            .width(44)
                                            .height(44)
                                            .alignContent(Alignment.Center)
                                        }
                                        ChatListItem(
                                            chat: msgChat,
                                            isTyping: false,
                                            onClick: { =>
                                                this.onSearchMessageTap(msgChat)
                                            },
                                            onLongPress: { y: Float64, h: Float64 =>
                                                this.openSearchMessageMenu(msgChat, y, h)
                                            }
                                        )
                                    }
                                    .width(100.percent)
                                    .alignItems(VerticalAlign.Center)
                                }
                                .width(100.percent)
                            }, keyGeneratorFunc: { msgChat: Chat, _idx: Int64 =>
                                "ppane_${msgChat.peerType}_${msgChat.id}_${msgChat.searchMessageId}_${this.searchSelectionActive}_${this.isSearchMessageSelected(msgChat)}"
                            })
                        }
                    }
                    // iOS parity（TC-SCROLL）：底部 content inset 占位——对应 iOS
                    // TabBarController.intrinsicInsets.bottom=49+安全区（悬浮 tab bar 不挡末条）
                    ListItem {
                        Row {}.height(88)
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
                .backgroundColor(this.presentation.cardColor)
                .divider(ListDividerOptions(strokeWidth: 1, color: 0xF0F0F0, startMargin: 88, endMargin: 0))
                // iOS parity：alwaysBounceVertical=true（ListView.swift:508）——内容不足也可回弹
                .edgeEffect(EdgeEffect.Spring)
                // 对齐 iOS ChatListNode：滚到已加载区间末尾时填补下一段 ChatListHole，
                // 继续 getDialogs 拉更早的会话，直到服务端没有更多。搜索态展示的是搜索结果，不翻页。
                .onReachEnd({ =>
                    if (!this.isSearchActive()) { this.viewModel.loadMoreDialogs() }
                })
                .onScrollIndex({ first: Int32, _last: Int32, _center: Int32 =>
                    this.listFirstVisibleIndex = Int64(first)
                })
                .onDidScroll({ _delta: Float64, _state: ScrollState =>
                    this.onChatListScrolled()
                })
                .onTouch({ evt => this.handleChatListPull(evt) })
                // 上下文菜单打开期间列表不再响应滑动。
                // 对齐 iOS：ContextGesture 激活时会 cancelOtherGestures + cancelParentGestures
                // （ContextGesture.swift:166-172），把列表的滚动手势直接掐掉，
                // 于是「按住不放滑动选动作」不会同时把列表滚走。
                .enableScrollInteraction(!this.showActionSheet && this.reorderChatId == 0)
            }
    }

    /**
     * P2-107: 批量操作底部栏（编辑模式专用）
     * iOS Toolbar: leftAction=Read/Unread, middleAction=Archive, rightAction=Delete
     * 含静音按钮（iOS toolbar 无，Telegram HarmonyOS 惯例补充）
     * 批量删除走二次确认 showAlert(destructive: true)。
     * 按钮激活状态：selectedChatIds 非空时才 enabled（iOS 行为）。
     * R-107 合规：@Builder 内不用 for/let，所有计算逻辑通过 helper 方法调用。
     */
    @Builder
    func buildBatchActionBar() {
        // iOS 编辑态 toolbar（ChatListController.swift:7053-7100）：三个文字动作
        //   根列表：Read All（未选）/ Read（已选）· Archive · Delete
        //   归档内：Read · Unarchive · Delete
        if (this.isEditMode) {
            Column {
                Divider()
                    .color(this.presentation.dividerColor)
                    .strokeWidth(1)
                Row {
                    Text(this.batchReadTitle())
                        .fontSize(17)
                        .fontColor(if (this.batchReadEnabled()) { 0x317AFF } else { 0xC7C7CC })
                        .onClick({ evt =>
                            if (this.batchReadEnabled()) { this.doBatchRead() }
                        })
                    Blank().layoutWeight(1)
                    Text(if (this.currentFolderIdMirror == 1) { this.localized("ChatList_UnarchiveAction", "Unarchive") } else { this.localized("ChatList_ArchiveAction", "Archive") })
                        .fontSize(17)
                        .fontColor(if (this.selectedChatIds.isEmpty()) { 0xC7C7CC } else { 0x317AFF })
                        .onClick({ evt =>
                            this.doBatchArchive()
                        })
                    Blank().layoutWeight(1)
                    Text(this.localized("Common_Delete", "Delete"))
                        .fontSize(17)
                        .fontColor(if (this.selectedChatIds.isEmpty()) { 0xC7C7CC } else { 0x317AFF })
                        .onClick({ evt =>
                            this.presentBatchDeleteSheet()
                        })
                }
                .width(100.percent)
                .height(49)
                .padding(left: 16, right: 16)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(this.presentation.navBarColor)
            }
            .width(100.percent)
            .backgroundColor(this.presentation.navBarColor)
        }
    }

    /**
     * 上下文菜单里的会话预览卡。
     *
     * iOS 嵌的是真实的 ChatController（.previewing），我们把路由页塞不进浮层，
     * 改为「顶部 peer 头 + 本地库最近若干条气泡」自绘。数据全部来自
     * MessageHistoryStore.loadLocalMessages —— 不发请求，因而与 iOS 的
     * canReadHistory=false 一样不会把消息读掉。
     *
     * 气泡用 isMultiSelectMode: true 挂载，借此关掉行上的长按识别，
     * 预览内不会再套一层上下文菜单（同 MessageContextOverlay 的做法）。
     */
    @Builder
    func buildContextPreview() {
        Stack(alignContent: Alignment.TopStart) {
            // 聊天壁纸 —— iOS 预览的是真实会话页，自然带壁纸；此前是纯白，一眼就不像聊天
            Image(this.previewWallpaperUri())
                .width(100.percent)
                .height(100.percent)
                .objectFit(ImageFit.Cover)

            Column {
                // 导航栏：标题居中 + 副标题，头像在右（对齐 iOS 聊天页导航栏布局）
                Row {
                    Column {
                        Text(this.selectedChatName)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.textColor)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                        if (this.contextPreviewSubtitle.size > 0) {
                            Text(this.contextPreviewSubtitle)
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .maxLines(1)
                                .margin(top: 1)
                        }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Center)
                    Avatar(
                        avatarUrl: this.contextPreviewAvatar,
                        displayName: this.selectedChatName,
                        avatarSize: 32,
                        peerId: this.selectedChatId
                    )
                }
                .width(100.percent)
                .height(52)
                .padding(left: 12, right: 12)
                .alignItems(VerticalAlign.Center)
                .backgroundColor(this.presentation.backgroundColor)

                // 最近消息。预览态没有输入栏 —— 与 iOS 一致
                // （ChatControllerNode.swift:1790 previewing 时不挂 inputPanelNode）。
                //
                // 必须是真正的可滚动 List，不能是静态 Column，三个原因：
                //   1. iOS 的预览就是活的 history node，可以滑动；
                //   2. Column 内容超高时从顶部排布、底部溢出被裁掉，看到的是最早那几条 ——
                //      表现为「预览截的位置不对」；List + scrollEdge(Bottom) 才是「最新在底部」；
                //   3. AnimatedSticker/AnimatedEmoji 组件靠 onVisibleAreaChange 才开始渲染，
                //      未就绪时 opacity=0；静态容器里该回调不触发，贴纸与大表情气泡整块透明，
                //      表现为「有些气泡在预览层不显示」。
                Stack(alignContent: Alignment.BottomEnd) {
                    List(scroller: this.contextPreviewScroller) {
                        ForEach(this.contextPreviewMessages.toArray(), itemGenerator: { msg: Message, _i: Int64 =>
                            ListItem {
                                MessageBubble(
                                    message: msg,
                                    voicePlaybackEpoch: 0,
                                    peerType: this.selectedChatPeerType,
                                    isMultiSelectMode: true
                                )
                            }
                        }, keyGenerator: { msg: Message, _idx: Int64 =>
                            // 必须给 key。缺省 key 是**下标**，向上翻页头插 N 条后每一项的
                            // 下标都变了 → ForEach 判定「全表换了」→ 整表重建 → 滚动位置丢失
                            // → onScrollIndex 又落回小值 → 再次预取，就是那个无限循环。
                            // 键的构成与聊天室一致：身份段用 stableId（本地消息换服务端号时不失配），
                            // 内容段保证媒体路径/状态回填后能原地更新。
                            previewItemKey(msg)
                        })
                    }
                    .width(100.percent)
                    .height(100.percent)
                    .scrollBar(BarState.Off)
                    .edgeEffect(EdgeEffect.Spring)
                    // 向上翻到顶继续读本地历史
                    .onReachStart({ => this.loadOlderPreviewMessages() })
                    .onScrollIndex({ first: Int32, last: Int32, _center: Int32 =>
                        this.contextPreviewFirstVisible = Int64(first)
                        // 本地优先后补页很便宜，预取提前到距顶 12 条，让用户撞不到边界
                        if (Int64(first) <= 12) {
                            this.loadOlderPreviewMessages()
                        }
                        // iOS shouldDisplayDownButton：离开最新端即显示下箭头。
                        // 只在值真的变化时写 @State —— onScrollIndex 每帧都会回调，
                        // 无条件赋值会持续触发重渲染。
                        let atLatest = Int64(last) >= this.contextPreviewMessages.size - 1
                        if (this.contextPreviewShowScrollDown == atLatest) {
                            this.contextPreviewShowScrollDown = !atLatest
                        }
                    })

                    // 回到最新（iOS ChatHistoryNavigationButtons 的圆形下箭头）
                    if (this.contextPreviewShowScrollDown) {
                        Row {
                            Image(@r(app.media.chatroom_ic_scroll_down))
                                .width(20)
                                .height(20)
                        }
                        .width(40)
                        .height(40)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                        .backgroundColor(0xF2FFFFFF)
                        .borderRadius(20)
                        .shadow(radius: 8.0, color: 0x26000000, offsetX: 0.0, offsetY: 2.0)
                        .margin(right: 10, bottom: 10)
                        .onClick({ _evt => this.scrollPreviewToLatest() })
                    }
                }
                .width(100.percent)
                .layoutWeight(1)
            }
            .width(100.percent)
            .height(100.percent)
        }
        .width(this.previewWidth())
        .height(this.previewHeight())
        .backgroundColor(this.presentation.cardColor)
        // iOS ControllerContentNode.cornerRadius = 30
        .borderRadius(30)
        .clip(true)
        .position(x: 12.0, y: this.previewY())
        // 从被按行处弹出（iOS 用 animateSpring 把 position.y 从行中心推到预览中心）
        .translate(y: this.previewOffsetY)
        .scale(x: this.actionPanelScale, y: this.actionPanelScale)
        .opacity(if (this.actionPanelPresented) { 1.0 } else { 0.0 })
        // 点预览即进入会话 —— iOS 通过 dismissPreviewing 把预览升格为真正的聊天页
        .onClick({ _evt => this.openPreviewedChat() })
    }

    /** 预览卡的壁纸；与 ChatRoomPage.rootWallpaperUri 同源 */
    private func previewWallpaperUri(): String {
        let path = getChatBgDisplayPath()
        if (path.startsWith("file://")) { return path }
        if (path.size > 0) { return "file://${path}" }
        return ""
    }

    /**
     * Phase E: 长按操作菜单（@Builder 独立方法，避免在 buildListContent 内放 overlay）
     */
    @Builder
    func buildActionSheet() {
            if (this.showActionSheet) {
                // iOS 的上下文菜单是独立浮层（presentInGlobalOverlay），不是贴底的 sheet：
                // 半透明模糊底 + 一块锚在被按行附近的内联面板，面板从行中心弹簧展开
                // （ContextControllerExtractedPresentationNode.swift:1414-1415 duration 0.42 / damping 104）。
                Stack(alignContent: Alignment.TopStart) {
                    // 背景：iOS contextMenu.dimColor = #000a26 @20% + 模糊
                    // （DefaultDayPresentationTheme.swift:1043-1046，ContextSourceContainer.swift:643-657）
                    Column { }
                        .width(100.percent)
                        .height(100.percent)
                        .backdropBlur(22.0)
                        .backgroundColor(0x33000A26)
                        .onClick({ evt =>
                            this.dismissChatContextMenu()
                        })

                    // 会话预览卡（只读；数据来自本地库，不产生已读回执）
                    this.buildContextPreview()

                    // 操作菜单
                    Column {


                        // ==================== 动作项 ====================
                        //
                        // 顺序与条件对齐 iOS chatContextMenuItems（1:1 会话、主列表）：
                        //   ① 标记已读 / 标记未读   :348 / :358
                        //   ② 置顶 / 取消置顶       :390
                        //   ③ 静音 / 取消静音       :460
                        //   ④ 删除（destructive）   :543
                        //
                        // 只有这 4 项：带 .separator + Select 的那段（:975-980）属于
                        // chatForumTopicMenuItems，主列表的 chatContextMenuItems 签名里
                        // 根本没有 canSelect 参数（ChatContextMenus.swift:56）。
                        //
                        // 去掉了原来的「归档」与「清除历史」：
                        //   归档：iOS 的 archiveEnabled 同时要求 !isSavedMessages 与
                        //         peerId == account.peerId（ChatContextMenus.swift:365），
                        //         两条互斥 → 该项在会话列表长按菜单里根本不出现；
                        //   清除历史：iOS 的会话列表菜单里没有这一项（只在会话资料页）。

                        // 动作行由 chatActionItems 决定（buildChatActionItems），行几何与
                        // chatActionRowTop 一致：每行 44，行间 1vp 分隔线。
                        ForEach(this.chatActionItems, itemGeneratorFunc: { item: ChatListMenuItem, idx: Int64 =>
                            Column {
                                if (idx > 0) {
                                    Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)
                                }
                                Row {
                                    if (item.icon == "read") {
                                        Image(@r(app.media.clist_ic_read)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else if (item.icon == "unread") {
                                        Image(@r(app.media.clist_ic_unread)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else if (item.icon == "pin") {
                                        Image(@r(app.media.clist_ic_pin)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else if (item.icon == "unpin") {
                                        Image(@r(app.media.clist_ic_unpin)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else if (item.icon == "mute") {
                                        Image(@r(app.media.clist_ic_mute)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else if (item.icon == "unmute") {
                                        Image(@r(app.media.clist_ic_unmute)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else if (item.icon == "delete") {
                                        Image(@r(app.media.clist_ic_delete)).width(20).height(20).fillColor(0xFF3B30).margin(left: 16)
                                    } else if (item.icon == "add") {
                                        Image(@r(app.media.clist_ic_newcontact)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else if (item.icon == "folder") {
                                        Image(@r(app.media.itemlist_ic_remove)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    } else {
                                        Image(@r(app.media.itemlist_ic_plus)).width(20).height(20).fillColor(this.presentation.textColor).margin(left: 16)
                                    }
                                    Text(item.title)
                                        .fontSize(17)
                                        .fontColor(if (item.destructive) { 0xFF3B30 } else { this.presentation.textColor })
                                        .margin(left: 12)
                                    Blank().layoutWeight(1)
                                }
                                .width(100.percent)
                                .height(44)
                                .alignItems(VerticalAlign.Center)
                                .backgroundColor(if (this.actionHighlightIndex == idx) { this.presentation.itemHighlightedBackgroundColor } else { this.presentation.cardColor })
                                .onTouch({ evt =>
                                    match (evt.eventType) {
                                        case TouchType.Down => this.handleRowPress(idx)
                                        case TouchType.Move =>
                                            if (evt.touches.size > 0) {
                                                this.handlePanelTouchMove(evt.touches[0].screenX, evt.touches[0].screenY)
                                            }
                                        case TouchType.Up => this.handleRowRelease()
                                        case _ => this.handlePanelTouchCancel()
                                    }
                                })
                            }
                            .width(100.percent)
                        }, keyGeneratorFunc: { item: ChatListMenuItem, idx: Int64 =>
                            "${idx}_${item.key}_${item.title}"
                        })
                    }
                    .width(CHAT_ACTION_PANEL_WIDTH)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(14)
                    .clip(true)
                    // 右缘内缩 12（actionsEdgeInset），纵向锚在被按行下方
                    .position(x: this.actionPanelX(), y: this.actionPanelY())
                    .scale(x: this.actionPanelScale, y: this.actionPanelScale)
                    .opacity(if (this.actionPanelPresented) { 1.0 } else { 0.0 })
                    // 面板顶部的窗口 Y —— 把长按手势的触点映射到具体动作行（见 handleContextGestureMove）
                    .onAreaChange({ _: Area, newArea: Area =>
                        match (newArea.globalPosition.y) {
                            case Some(top) => this.actionPanelTop = top.value
                            case None => ()
                        }
                        match (newArea.globalPosition.x) {
                            case Some(left) => this.actionPanelLeft = left.value
                            case None => ()
                        }
                    })
                }
                .width(100.percent)
                .height(100.percent)
                .position(x: 0, y: 0)
                // 浮层只能铺满应用窗口；状态栏与底部导航条在窗口之外，
                // 由 setContextSystemBars 染成同色补齐（expandSafeArea 在非全屏布局下无效）。
                .onAreaChange({ _: Area, newArea: Area =>
                    this.overlayHeightVp = newArea.height.value
                })
                .onAppear({ => reportTabModalOverlay(true) })
                .onDisAppear({ => reportTabModalOverlay(false) })
            }
    }

    /**
     * 通用上下文菜单（iOS ContextController .list 样式）：文字在左、图标在右，分组间 8vp 分隔。
     */
    @Builder
    func buildListMenu() {
        if (this.showListMenu) {
            Stack(alignContent: Alignment.TopStart) {
                Column { }
                    .width(100.percent)
                    .height(100.percent)
                    .backdropBlur(22.0)
                    .backgroundColor(0x33000A26)
                    .onClick({ _ => this.dismissListMenu() })
                Column {
                    ForEach(this.listMenuItems, itemGeneratorFunc: { item: ChatListMenuItem, idx: Int64 =>
                        Column {
                            if (item.separatorBefore) {
                                Row { }
                                    .width(100.percent)
                                    .height(8)
                                    .backgroundColor(this.presentation.contextMenuSeparatorColor)
                            } else if (idx > 0) {
                                Divider().color(this.presentation.dividerColor).strokeWidth(1)
                            }
                            Row {
                                Text(item.title)
                                    .fontSize(if (item.key == RECENT_CLEAR_INFO_KEY) { 14 } else { 17 })
                                    .fontColor(if (item.destructive) { this.presentation.contextMenuDestructiveColor } else { this.presentation.contextMenuPrimaryColor })
                                    .maxLines(if (item.key == RECENT_CLEAR_INFO_KEY) { 2 } else { 1 })
                                    .textOverflow(TextOverflow.Ellipsis)
                                    .layoutWeight(1)
                                if (item.icon == "edit") {
                                    Image(@r(app.media.chatroom_ic_edit)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "add") {
                                    Image(@r(app.media.itemlist_ic_plus)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "readAll" || item.icon == "read") {
                                    Image(@r(app.media.clist_ic_read)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "mute") {
                                    Image(@r(app.media.clist_ic_mute)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "unmute") {
                                    Image(@r(app.media.clist_ic_unmute)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "link") {
                                    Image(@r(app.media.chatroom_ic_link)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "delete") {
                                    Image(@r(app.media.clist_ic_delete)).width(22).height(22).fillColor(this.presentation.contextMenuDestructiveColor)
                                } else if (item.icon == "pin") {
                                    Image(@r(app.media.clist_ic_pin)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "unpin") {
                                    Image(@r(app.media.clist_ic_unpin)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "select") {
                                    Image(@r(app.media.chatroom_ic_select)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "forward") {
                                    Image(@r(app.media.chatroom_ic_forward)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "goto") {
                                    Image(@r(app.media.loc_ic_goto)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                } else if (item.icon == "check") {
                                    Image(@r(app.media.vc_ic_ctx_check)).width(22).height(22).fillColor(this.presentation.contextMenuPrimaryColor)
                                }
                            }
                            .width(100.percent)
                            .height(44)
                            .padding(left: 16, right: 16)
                            .alignItems(VerticalAlign.Center)
                            .onClick({ _ =>
                                // 说明行对位 iOS action: nil 的 ContextMenuActionItem，点了不关菜单也不执行。
                                if (item.key != RECENT_CLEAR_INFO_KEY) { this.performListMenuAction(item.key) }
                            })
                        }
                        .width(100.percent)
                    }, keyGeneratorFunc: { item: ChatListMenuItem, idx: Int64 =>
                        "${idx}_${item.key}"
                    })
                }
                .width(LIST_MENU_WIDTH)
                .backgroundColor(this.presentation.contextMenuBackgroundColor)
                .borderRadius(14)
                .clip(true)
                .position(x: this.listMenuX, y: this.listMenuY)
            }
            .width(100.percent)
            .height(100.percent)
            .position(x: 0, y: 0)
        }
    }

    /**
     * TC-0012 第三轮返修：swipeAction end 侧多按钮面板（@Builder 无参成员函数，D-115 合规）。
     * 对齐 iOS 左滑三个内联彩色按钮：静音/删除/归档（`workflow_output/e2e/reference/ios/TC-0012`）。
     * 读取镜像 @State 字段（swipeRow*），不接受参数、不读闭包捕获的 entry（D-115/D-125 合规）。
     * 若真机验证此 @Builder 函数形态仍坍缩为 0 子节点，需回退到上一轮单叶子"更多"方案
     * 并在 featureX.md 如实记录（详见本轮 Hand-off）。
     */
    @Builder
    func buildSwipeEndPanel() {
        // iOS revealOptions（ChatListItem.swift:739-790）：根列表 Mute/Unmute · Delete · Archive；
        // 归档内 Pin/Unpin · Delete · Unarchive。颜色取 DefaultDayPresentationTheme.itemDisclosureActions。
        Row {
            if (this.currentFolderIdMirror == 1) {
                Column {
                    Text(if (this.swipeRowPinned) { this.localized("DialogList_Unpin", "Unpin") } else { this.localized("DialogList_Pin", "Pin") })
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(74)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(0x00C900)
                .onClick({ evt =>
                    this.viewModel.togglePinChat(this.swipeRowChatId)
                })
            } else {
                Column {
                    Text(if (this.swipeRowMuted) { this.localized("ChatList_Unmute", "Unmute") } else { this.localized("ChatList_Mute", "Mute") })
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(74)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(0xF09A37)
                .onClick({ evt =>
                    this.viewModel.toggleMuteChatWithUndo(this.swipeRowChatId)
                })
            }

            Column {
                Text(this.localized("Common_Delete", "Delete"))
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
            }
            .width(74)
            .height(100.percent)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(0xFF3824)
            .onClick({ evt =>
                this.doSwipeRowDelete()
            })

            Column {
                Text(if (this.currentFolderIdMirror == 1) { this.localized("ChatList_UnarchiveAction", "Unarchive") } else { this.localized("ChatList_ArchiveAction", "Archive") })
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
            }
            .width(74)
            .height(100.percent)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(0xBCBCC3)
            .onClick({ evt =>
                this.doSwipeRowArchiveToggle()
            })
        }
        .height(100.percent)
    }

    @Builder
    func buildArchiveSwipePanel() {
        Row {
            Column {
                Text(if (this.archiveHidden) { this.localized("ChatList_UnhideAction", "Pin") } else { this.localized("ChatList_HideAction", "Hide") })
                    .fontSize(13)
                    .fontColor(0xFFFFFF)
                    .textAlign(TextAlign.Center)
            }
            .width(74)
            .height(100.percent)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(if (this.archiveHidden) { 0x00C900 } else { 0xBCBCC3 })
            .onClick({ evt =>
                this.toggleArchiveHidden()
            })
        }
        .height(100.percent)
    }

    @Builder
    func buildSwipeStartPanel() {
        if (this.currentFolderIdMirror != 1) {
            Row {
                Column {
                    Text(if (this.swipeRowUnread) { this.localized("DialogList_Read", "Read") } else { this.localized("DialogList_Unread", "Unread") })
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(74)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(if (this.swipeRowUnread) { 0xBCBCC3 } else { 0x0088FF })
                .onClick({ evt =>
                    let cid = this.swipeRowChatId
                    this.viewModel.toggleMarkUnread(cid)
                    this.closeSwipeRow(cid)
                })

                Column {
                    Text(if (this.swipeRowPinned) { this.localized("DialogList_Unpin", "Unpin") } else { this.localized("DialogList_Pin", "Pin") })
                        .fontSize(13)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                }
                .width(74)
                .height(100.percent)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(0x00C900)
                .onClick({ evt =>
                    this.viewModel.togglePinChat(this.swipeRowChatId)
                })
            }
            .height(100.percent)
        }
    }

    // 删除确认卡片继续使用本地浮层容器，但执行链与新版 main 保持一致：先乐观移除，
    // 5 秒内允许 Undo，窗口结束后才提交真实 deleteDialog RPC。
    func deleteSheetAvatarInitial(): String {
        if (this.selectedChatAvatarText.size > 0) {
            return this.selectedChatAvatarText.toRuneArray()[0].toString()
        }
        return "?"
    }

    func deleteSheetConfirmationText(): String {
        // iOS ChatListController.deletePeerChat：群主可全局删除时用 .deleteAndLeave 文案
        // （ChatList_DeleteAndLeaveGroupConfirmation）
        if (this.canDeleteSelectedChatGlobally()) {
            return getDeleteChatPeerActionSheetService().confirmationText(
                this.selectedChatName, this.selectedChatPeerType, DeleteChatPeerActionType.DeleteAndLeave
            )
        }
        return getDeleteChatPeerActionSheetService().confirmationText(
            this.selectedChatName, this.selectedChatPeerType, DeleteChatPeerActionType.Delete
        )
    }

    func selectedChatIsGroupLike(): Bool {
        match (getRealChatListService().getCachedChat(this.selectedChatId)) {
            case Some(chat) => return chat.isMegagroup || !chat.isChannel
            case None => return this.selectedChatPeerType == "chat"
        }
    }

    /**
     * iOS ChatListController.canDeletePeerGloballyAsCreator（:6062）：
     *   channel → isCreator && 无用户名（私有）
     *   legacyGroup → creator
     */
    func canDeleteSelectedChatGlobally(): Bool {
        let pt = this.selectedChatPeerType
        if (pt != "chat" && pt != "channel") { return false }
        match (getRealChatListService().getCachedChat(this.selectedChatId)) {
            case Some(chat) =>
                if (!chat.isCreator) { return false }
                if (pt == "channel") { return chat.username.size == 0 }
                return true
            case None => return false
        }
    }

    func deleteSheetActionButtonText(): String {
        return getDeleteChatPeerActionSheetService().actionButtonText(DeleteChatPeerActionType.Delete)
    }

    /**
     * S1-51：iOS deletePeerChat（CLC:5440-5462）canClear —— 群（legacyGroup / 私有超级群）与 bot
     * 的删除表多一项 Clear History；广播频道、带公开用户名的超级群没有。
     */
    func canClearSelectedChatHistory(): Bool {
        let pt = normalizeDialogPeerType(this.selectedChatPeerType)
        if (pt == "chat") { return true }
        if (pt == "channel") {
            match (getRealChatListService().getCachedChat(this.selectedChatId)) {
                case Some(chat) => return chat.isMegagroup && chat.username.size == 0
                case None => return false
            }
        }
        if (pt == "user") {
            match (this.viewModel.getChatById(this.selectedChatId)) {
                case Some(chat) => return chat.isBot
                case None => return false
            }
        }
        return false
    }

    func deleteSheetClearHistoryText(): String {
        var isBot = false
        match (this.viewModel.getChatById(this.selectedChatId)) {
            case Some(chat) => isBot = chat.isBot && normalizeDialogPeerType(chat.peerType) == "user"
            case None => ()
        }
        if (isBot) {
            return this.localized("DialogList_DeleteBotClearHistory", "Clear Chat History")
        }
        return this.localized("DialogList_ClearHistoryConfirmation", "Clear History")
    }

    /**
     * S1-51：Clear History → 非群主分支（CLC:5581-5670 !canRemoveGlobally）弹 Warning!
     * （ChatList_DeleteSavedMessagesConfirmationTitle/Text）→ Delete All → beginClear(.forLocalPeer)
     * （messages.deleteHistory just_clear，会话保留在列表、本端消息清空）。
     */
    func confirmClearSelectedChatHistory(): Unit {
        let chatId = this.selectedChatId
        Hilog.info(0, "CjTelegram", "[ChatListPage] clear-history warning chatId=${chatId}")
        let cancel = AlertDialogButtonOptions(value: this.localized("Common_Cancel", "Cancel"), action: { =>
            this.showDeleteChatPeerSheet = false
        })
        let confirm = AlertDialogButtonOptions(
            value: this.localized("ChatList_DeleteSavedMessagesConfirmationAction", "Delete All"),
            fontColor: 0xFFFF3B30,
            action: { =>
                Hilog.info(0, "CjTelegram", "[ChatListPage] clear-history confirmed chatId=${chatId}")
                this.showDeleteChatPeerSheet = false
                this.viewModel.clearChatHistory(chatId)
                showToast(this.localized("Undo_ChatCleared", "Chat cleared"))
            }
        )
        getUIContext().showAlertDialog(AlertDialogParamWithButtons(
            title: this.localized("ChatList_DeleteSavedMessagesConfirmationTitle", "Warning!"),
            message: this.localized("ChatList_DeleteSavedMessagesConfirmationText", "This will delete all messages in this chat.").replace("**", ""),
            primaryButton: cancel,
            secondaryButton: confirm,
            autoCancel: true
        ))
    }

    @Builder
    func buildDeleteChatPeerSheet() {
            if (this.showDeleteChatPeerSheet) {
                Column {
                    Column { }
                        .width(100.percent)
                        .layoutWeight(1)
                        .backgroundColor(0x66000000)
                        .onClick({ evt =>
                            this.showDeleteChatPeerSheet = false
                        })

                    Column {
                        if (this.selectedChatAvatarLocalPath.size > 0) {
                            Image(this.selectedChatAvatarLocalPath)
                                .width(60)
                                .height(60)
                                .borderRadius(30)
                                .objectFit(ImageFit.Cover)
                                .margin(top: 24, bottom: 12)
                        } else {
                            Stack {
                                Text(this.deleteSheetAvatarInitial())
                                    .fontSize(26)
                                    .fontColor(0xFFFFFF)
                                    .fontWeight(FontWeight.Medium)
                            }
                            .width(60)
                            .height(60)
                            .borderRadius(30)
                            .backgroundColor(this.selectedChatAvatarColor)
                            .margin(top: 24, bottom: 12)
                        }

                        Text(this.selectedChatName)
                            .fontSize(17)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(this.presentation.textColor)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                            .margin(bottom: 8)

                        Text(this.deleteSheetConfirmationText())
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .textAlign(TextAlign.Center)
                            .maxLines(3)
                            .margin(left: 20, right: 20, bottom: 20)

                        if (this.canDeleteSelectedChatGlobally()) {
                            // iOS ChatList_DeleteForCurrentUser / ChatList_DeleteForAllMembers（群主专属双按钮，
                            // CLC:5491-5560）：前者退出（leave），后者经 Warning! 确认后为所有人删除。
                            Button(this.localized("ChatList_DeleteForCurrentUser", "Delete just for me"))
                                .width(100.percent)
                                .height(50)
                                .fontSize(17)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(0xFF3B30)
                                .borderRadius(10)
                                .margin(left: 16, right: 16, bottom: 8)
                                .onClick({ _ =>
                                    this.showDeleteChatPeerSheet = false
                                    this.viewModel.schedulePeerChatRemoval(
                                        this.selectedChatId,
                                        deleteGloballyIfPossible: false
                                    )
                                })
                            Button(if (this.selectedChatIsGroupLike()) { "Delete for all members" } else { "Delete for all subscribers" })
                                .width(100.percent)
                                .height(50)
                                .fontSize(17)
                                .fontColor(0xFF3B30)
                                .backgroundColor(this.presentation.backgroundColor)
                                .borderRadius(10)
                                .margin(left: 16, right: 16, bottom: 8)
                                .onClick({ _ =>
                                    this.confirmDeleteSelectedForAll()
                                })
                        } else {
                            // S1-51：iOS 非群主群 / bot 的删除表先给 Clear History（accent 色），再给 Delete（CLC:5581）。
                            if (this.canClearSelectedChatHistory()) {
                                Button(this.deleteSheetClearHistoryText())
                                    .width(100.percent)
                                    .height(50)
                                    .fontSize(17)
                                    .fontColor(0x317AFF)
                                    .backgroundColor(this.presentation.backgroundColor)
                                    .borderRadius(10)
                                    .margin(left: 16, right: 16, bottom: 8)
                                    .onClick({ _ =>
                                        this.confirmClearSelectedChatHistory()
                                    })
                            }
                            Button(this.deleteSheetActionButtonText())
                                .width(100.percent)
                                .height(50)
                                .fontSize(17)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(0xFF3B30)
                                .borderRadius(10)
                                .margin(left: 16, right: 16, bottom: 8)
                                .onClick({ _ =>
                                    this.showDeleteChatPeerSheet = false
                                    this.viewModel.schedulePeerChatRemoval(
                                        this.selectedChatId,
                                        deleteGloballyIfPossible: false
                                    )
                                })
                        }

                        Button(trSource("Cancel"))
                            .width(100.percent)
                            .height(50)
                            .fontSize(17)
                            .fontColor(0x317AFF)
                            .backgroundColor(this.presentation.backgroundColor)
                            .borderRadius(10)
                            .margin(left: 16, right: 16, bottom: 16)
                            .onClick({ _ =>
                                this.showDeleteChatPeerSheet = false
                            })
                    }
                    .width(100.percent)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(topLeft: 14, topRight: 14)
                }
                .width(100.percent)
                .height(100.percent)
                .position(x: 0, y: 0)
                .onAppear({ => reportTabModalOverlay(true) })
                .onDisAppear({ => reportTabModalOverlay(false) })
            }
    }

    /**
     * Phase T1: Compose 菜单 (@Builder 独立方法)
     */
    @Builder
    func buildComposeMenu() {
            if (this.showComposeMenu) {
                Column {
                    // 遮罩
                    Column { }
                        .width(100.percent)
                        .layoutWeight(1)
                        .backgroundColor(0x66000000)
                        .onClick({ evt =>
                            this.showComposeMenu = false
                        })

                    // 操作菜单
                    Column {
                        // 标题
                        Row {
                            Text("New")
                                .fontSize(17)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.presentation.textColor)
                        }
                        .width(100.percent)
                        .height(50)
                        .justifyContent(FlexAlign.Center)

                        Divider().color(this.presentation.dividerColor).strokeWidth(1)

                        // New Message
                        // 资源保真修复：Compose 菜单图标全部换成真实矢量 SVG（原 emoji 字形）。
                        // "New Message" 来源 Chat/Context Menu/MessageBubble.imageset（iOS 原生已是 SVG，
                        // 直接归一化 viewBox/fill 接入，无需 PDF 转换）。
                        Row {
                            Image(@r(app.media.clist_ic_newmessage))
                                .width(20)
                                .height(20)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 12)
                            Text(trSource("New Message"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                            Text("›")
                                .fontSize(20)
                                .fontColor(0xC7C7CC)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            this.showComposeMenu = false
                            routerPush("ComposePage", "")
                        })

                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)

                        // New Group（来源 Contact List/CreateGroupActionIcon.imageset/ic_group.pdf，
                        // 与 iOS ComposeControllerNode.swift:45 实际使用的图标一致）
                        Row {
                            Image(@r(app.media.clist_ic_newgroup))
                                .width(20)
                                .height(20)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 12)
                            Text(trSource("New Group"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                            Text("›")
                                .fontSize(20)
                                .fontColor(0xC7C7CC)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            this.showComposeMenu = false
                            routerPush("CreateGroupPage", "")
                        })

                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)

                        // New Channel（来源 Contact List/CreateChannelActionIcon.imageset/ic_channel.pdf，
                        // 与 iOS ComposeControllerNode.swift:51 实际使用的图标一致）
                        Row {
                            Image(@r(app.media.clist_ic_newchannel))
                                .width(20)
                                .height(20)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 12)
                            Text(trSource("New Channel"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                            Text("›")
                                .fontSize(20)
                                .fontColor(0xC7C7CC)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            this.showComposeMenu = false
                            routerPush("CreateChannelPage", "")
                        })

                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)

                        // New Secret Chat（来源 Chat/Context Menu/Lock.imageset/Lock.pdf，
                        // Telegram 惯例用锁形图标表达端到端加密/密聊语义）
                        Row {
                            Image(@r(app.media.clist_ic_secretchat))
                                .width(20)
                                .height(20)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 12)
                            Text(trSource("New Secret Chat"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                            Text("›")
                                .fontSize(20)
                                .fontColor(0xC7C7CC)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            this.showComposeMenu = false
                            Hilog.info(0, "CjTelegram", "[ChatListPage] New Secret Chat tapped (not yet implemented)")
                        })

                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)

                        // New Contact（来源 Contact List/AddMemberIcon.imageset/ic_addmember.pdf，
                        // 与 iOS ComposeControllerNode.swift:48 实际使用的图标一致）
                        Row {
                            Image(@r(app.media.clist_ic_newcontact))
                                .width(20)
                                .height(20)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 12)
                            Text(trSource("New Contact"))
                                .fontSize(17)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                            Text("›")
                                .fontSize(20)
                                .fontColor(0xC7C7CC)
                        }
                        .width(100.percent)
                        .height(56)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            this.showComposeMenu = false
                            routerPush("AddContactPage", "new")
                        })

                        // Cancel 按钮
                        Column {
                            Button(trSource("Cancel"))
                                .width(100.percent)
                                .height(56)
                                .fontSize(17)
                                .fontColor(0x317AFF)
                                .backgroundColor(this.presentation.cardColor)
                                .borderRadius(14)
                                .onClick({ evt =>
                                    this.showComposeMenu = false
                                })
                        }
                        .padding(left: 8, right: 8, top: 8, bottom: 34)
                        .backgroundColor(this.presentation.backgroundColor)
                    }
                    .backgroundColor(this.presentation.cardColor)
                    .borderRadius(topLeft: 14, topRight: 14)
                }
                .width(100.percent)
                .height(100.percent)
                .position(x: 0, y: 0)
                .onAppear({ => reportTabModalOverlay(true) })
                .onDisAppear({ => reportTabModalOverlay(false) })
            }
    }

    /**
     * TC-0086 返修（diag-suite_settings_root-TC-0086.md「M-5」）：归档态导航栏「⋯」More
     * 菜单本体。对位源侧 ChatListController.swift:3932 openArchiveMoreMenu(sourceView:gesture:)
     * → :3945-3959。菜单项两项，条件对位源侧：
     *   1. Archive Settings（ChatList_Archive_ContextSettings，:3945-3953）—— 无条件出现。
     *   2. How Does It Work?（ChatList_Archive_ContextInfo，:3956-3959）—— 仅当归档列表非空
     *      （源侧 `if !archiveChatList.items.isEmpty`）才出现。本轮不新建 archivedCountMirror
     *      镜像（8bdce1cb8 已无该字段），直接读 this.viewModel.archiveChatList.size——与本菜单
     *      同一次点击内求值、不跨异步回调，无 D-129 风险（先例：同文件 :1795
     *      `this.viewModel.currentFolderId == 0 && this.viewModel.archiveChatList.size > 0`
     *      同款读法）。
     *   第 3 项 ChatList_ContextSelectChats（:3963-3971，进入多选）不迁移：进入编辑态，归目标侧
     *   已有的 enterEditMode() 路径，且不在本 case 判据面内，本轮只恢复 A 链路入口。
     * 卡片背景：diag-round9 F-2 返修恢复本文件的 presentation 订阅后，随同文件
     * buildComposeMenu() 卡片容器同批改回 this.presentation.cardColor。遮罩 0x66000000
     * 维持字面量不动（非零 alpha 前缀，D-175 相关坑：presentation 字段是裸 6 位 RGB，
     * 不能替代半透明遮罩的取值）。
     * 先例：a8998a341^:ChatListPage.cj:2386-2450。
     */
    @Builder
    func buildArchiveMoreMenu() {
        if (this.showArchiveMoreMenu) {
            Stack(alignContent: Alignment.TopEnd) {
                // 遮罩（点击取消）
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x66000000)
                    .onClick({ evt =>
                        this.showArchiveMoreMenu = false
                    })

                Column {
                    Row {
                        Image(@r(app.media.clist_ic_archive))
                            .width(20)
                            .height(20)
                            .fillColor(this.presentation.textColor)
                            .margin(right: 12)
                        Text(trSource("Archive Settings"))
                            .fontSize(16)
                            .fontColor(this.presentation.textColor)
                            .layoutWeight(1)
                    }
                    .width(100.percent)
                    .height(48)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .onClick({ evt =>
                        this.showArchiveMoreMenu = false
                        routerPush("ArchiveSettingsPage", "")
                    })

                    if (this.viewModel.archiveChatList.size > 0) {
                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)
                        Row {
                            Image(@r(app.media.callui_ic_info))
                                .width(20)
                                .height(20)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 12)
                            Text(trSource("How Does It Work?"))
                                .fontSize(16)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            this.showArchiveMoreMenu = false
                            routerPush("ArchiveInfoPage", "")
                        })
                        // ChatList_ContextSelectChats（CLC:3974-3984）→ editPressed：进入多选
                        Divider().color(this.presentation.dividerColor).strokeWidth(1).margin(left: 48)
                        Row {
                            Image(@r(app.media.chatroom_ic_select))
                                .width(20)
                                .height(20)
                                .fillColor(this.presentation.textColor)
                                .margin(right: 12)
                            Text(this.localized("ChatList_ContextSelectChats", "Select Chats"))
                                .fontSize(16)
                                .fontColor(this.presentation.textColor)
                                .layoutWeight(1)
                        }
                        .width(100.percent)
                        .height(48)
                        .padding(left: 16, right: 16)
                        .alignItems(VerticalAlign.Center)
                        .onClick({ evt =>
                            this.showArchiveMoreMenu = false
                            this.enterEditMode()
                        })
                    }
                }
                .width(220)
                .backgroundColor(this.presentation.cardColor)
                .borderRadius(12)
                .margin(top: 52, right: 12)
            }
            .width(100.percent)
            .height(100.percent)
            .position(x: 0, y: 0)
        }
    }
}
