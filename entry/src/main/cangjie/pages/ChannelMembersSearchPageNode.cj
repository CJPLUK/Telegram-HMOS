package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * ChannelMembersSearchPageNode — 频道/群组成员搜索与列表页
 *
 * 对应 iOS ChannelMembersSearchContainerNode / ChannelMembersSearchControllerNode。
 *
 * 功能：
 * - 显示全部成员列表（分页加载，pageSize=100）
 * - 实时搜索成员（输入框 → channels.getParticipants(filter=channelParticipantsSearch)）
 * - 显示管理员/创建者标记
 * - 点击成员跳转到 PeerInfoPage（设置 selectedChat 后跳转）
 *
 * 调用链（列表加载）：
 *   aboutToAppear → PeerInfoService.searchMembers(channelId, query="", offset=0, limit=100)
 *                → ChannelsGetParticipants(filter=channelParticipantsRecent)
 *                → MTProtoClient.sendRequest() → MemberSearchResult → UI
 *
 * 调用链（搜索）：
 *   TextInput.onChange → doSearch(query)
 *                     → PeerInfoService.searchMembers(channelId, query, offset=0, limit=50)
 *                     → ChannelsGetParticipants(filter=channelParticipantsSearch#0702a40e)
 *                     → MTProtoClient.sendRequest() → MemberSearchResult → UI
 *
 * 架构约束（D-002）：根容器必须是 NavDestination()。
 * 架构约束（S-64）：aboutToAppear 必须 public、spawn 结果用 let _ 接收。
 */
@HybridComponentEntry
@Component
public class ChannelMembersSearchPageNode {
    @State var searchQuery: String = ""
    @State var members: ArrayList<MemberInfo> = ArrayList<MemberInfo>()
    @State var totalCount: Int32 = 0
    @State var isLoading: Bool = true
    @State var isSearching: Bool = false
    @State var errorMessage: String = ""

    /** 当前分页偏移（加载更多时使用） */
    @State var currentOffset: Int32 = 0
    private let pageSize: Int32 = 100
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // Inject accessHash for current channel
        this.injectChannelAccessHash()
        // Load initial member list
        this.loadMembers("", 0)
    }

    /**
     * 从 RealChatListService 缓存注入 accessHash 到 PeerInfoService
     */
    private func injectChannelAccessHash(): Unit {
        let channelId = getSelectedChatId()
        let chatListService = getRealChatListService()
        match (chatListService.getCachedChat(channelId)) {
            case Some(chat) =>
                getPeerInfoService().registerChannelAccessHash(chat.id, chat.accessHash)
            case None => ()
        }
    }

    /**
     * 加载成员列表（初始/分页）
     *
     * 调用链：loadMembers → PeerInfoService.searchMembers(channelId, "", offset, pageSize)
     *   → ChannelsGetParticipants(channelParticipantsRecent) → MTProtoClient.sendRequest()
     *   → MemberSearchResult → this.members
     */
    private func loadMembers(q: String, o: Int32): Unit {
        let channelId = getSelectedChatId()
        let ps = this.pageSize
        let _ = spawn {
            try {
                let infoService = getPeerInfoService()
                let result = infoService.searchMembers(channelId, q, o, ps)
                let fetchedMembers = result.members
                let total = result.totalCount
                let err = result.error
                launch {
                    if (err.size == 0) {
                        if (o == 0) {
                            this.members = fetchedMembers
                        } else {
                            // Append for pagination
                            for (m in fetchedMembers) {
                                this.members.add(m)
                            }
                        }
                        this.totalCount = total
                        this.errorMessage = ""
                    } else {
                        Hilog.info(0, "CjTelegram", "[ChannelMembersSearchPageNode] loadMembers error: ${err}")
                        this.errorMessage = "Failed to load members"
                    }
                    this.isLoading = false
                    this.isSearching = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[ChannelMembersSearchPageNode] loadMembers exception: ${e}")
                launch {
                    this.isLoading = false
                    this.isSearching = false
                    this.errorMessage = "Network error"
                }
            }
        }
    }

    /**
     * 执行成员搜索（由 TextInput.onChange 触发）
     *
     * 调用链：doSearch → PeerInfoService.searchMembers(channelId, query, 0, 50)
     *   → ChannelsGetParticipants(channelParticipantsSearch#0702a40e, q=query)
     *   → MTProtoClient.sendRequest() → MemberSearchResult
     */
    private func doSearch(query: String): Unit {
        this.isSearching = true
        if (query.size == 0) {
            this.isLoading = true
            this.loadMembers("", 0)
        } else {
            this.loadMembers(query, 0)
        }
    }

    /**
     * 加载更多成员（下拉到底部时触发）
     */
    private func loadMore(): Unit {
        if (this.isLoading || this.isSearching) { return }
        if (Int32(this.members.size) >= this.totalCount && this.totalCount > 0) { return }
        let newOffset = Int32(this.members.size)
        this.loadMembers(this.searchQuery, newOffset)
    }

    /**
     * 点击成员 → 跳转到该成员的 PeerInfoPage
     */
    private func openMemberProfile(member: MemberInfo): Unit {
        getPeerInfoService().registerUserAccessHash(member.userId, member.accessHash)
        routerPush("UserProfilePage", userProfileParam(member.userId, member.displayName()))
    }

    // ==================== UI ====================

    public func build() {
        Column {
                // ===== 搜索框 — P2-RETRO-search-c: TextInput → SearchBar 原子 =====
                // SearchBar 是 @Component，不能直接链内置属性（D-120），外包 Column 添加间距
                Column {
                    SearchBar(
                        loading: false,
                        backArrow: false,
                        text: this.searchQuery,
                        hint: "Search members",
                        onChange: { value: String =>
                            this.searchQuery = value
                            this.doSearch(value)
                        }
                    )
                }
                .width(100.percent)
                .backgroundColor(0xFFFFFF)

                // ===== 成员数标签 =====
                if (this.totalCount > 0) {
                    Row {
                        Text("${this.totalCount} members")
                            .fontSize(13)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .height(32)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)
                    .backgroundColor(0xF2F2F7)
                }

                // ===== 状态展示 =====
                if (this.isLoading) {
                    Column {
                        Text("Loading members...")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.errorMessage.size > 0) {
                    Column {
                        Text(this.errorMessage)
                            .fontSize(15)
                            .fontColor(0xFF3B30)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.members.size == 0) {
                    Column {
                        Text(if (this.searchQuery.size > 0) { "No results" } else { "No members" })
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    // ===== 成员列表 =====
                    List {
                        ForEach(Array<MemberInfo>(this.members.size, { i: Int64 => this.members[i] }),
                            itemGenerator: { member: MemberInfo, _idx: Int64 =>
                                ListItem {
                                    this.memberRow(member)
                                }
                            })
                        // 加载更多占位
                        if (Int32(this.members.size) < this.totalCount) {
                            ListItem {
                                Row {
                                    Text("Load more...")
                                        .fontSize(14)
                                        .fontColor(0x007AFF)
                                }
                                .width(100.percent)
                                .height(48)
                                .justifyContent(FlexAlign.Center)
                                .alignItems(VerticalAlign.Center)
                                .onClick({ _ => this.loadMore() })
                            }
                        }
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .divider(ListDividerOptions(strokeWidth: 1, color: 0xE5E5EA, startMargin: 60, endMargin: 0))
                    .backgroundColor(0xFFFFFF)
                }
            }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }

    /**
     * 单个成员行
     */
    @Builder private func memberRow(member: MemberInfo): Unit {
        Row {
            // 头像字母
            Column {
                Text(if (member.firstName.size > 0) {
                    member.firstName.toRuneArray()[0].toString()
                } else {
                    "?"
                })
                .fontSize(18)
                .fontColor(0xFFFFFF)
                .fontWeight(FontWeight.Bold)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor(0x317AFF)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin(right: 12)

            // 名字 + 角色
            Column {
                Text(member.displayName())
                    .fontSize(16)
                    .fontColor(0x000000)
                    .maxLines(1)

                if (member.isCreator) {
                    Text(if (member.rank.size > 0) { member.rank } else { "Owner" })
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                } else if (member.isAdmin) {
                    Text(if (member.rank.size > 0) { member.rank } else { "Admin" })
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                } else if (member.username.size > 0) {
                    Text("@${member.username}")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
        }
        .width(100.percent)
        .height(60)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(0xFFFFFF)
        .onClick({ _ => this.openMemberProfile(member) })
    }
}
