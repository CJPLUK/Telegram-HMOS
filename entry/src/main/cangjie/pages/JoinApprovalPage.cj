package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.components.SearchBar
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-172: 加入审批页面（混合工程迁移版）
 *
 * 对应 iOS InvitationLinks.swift / InviteLinksController 入群请求管理界面。
 *
 * 功能:
 * 1. messages.getChatInviteImporters requested=true → 待审批请求列表（真 wire）
 * 2. 批准单个: messages.hideChatJoinRequest approved=true
 * 3. 拒绝单个: messages.hideChatJoinRequest approved=false
 * 4. 全部批准/全部拒绝: messages.hideAllChatJoinRequests
 * 5. 搜索栏: q 参数过滤
 * 6. 分页: offsetDate/offsetUser
 * 7. 空态显示
 * 8. 计数头部
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与 .title，只留内容 + .onAppear
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫）
 */
@HybridComponentEntry
@Component
public class JoinApprovalPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var requests: Array<ChatInviteImporterData> = Array<ChatInviteImporterData>()
    @State var requestUsers: ArrayList<UserResponse> = ArrayList<UserResponse>()
    @State var totalCount: Int32 = 0
    @State var isLoading: Bool = true
    @State var isLoadingMore: Bool = false
    @State var hasMore: Bool = false
    @State var searchQuery: String = ""
    @State var lastOffsetDate: Int32 = 0
    @State var showApproveAllConfirm: Bool = false
    @State var showDismissAllConfirm: Bool = false
    @State var processingUserId: Int64 = 0
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadRequestsReset()
    }

    private func loadRequestsReset(): Unit {
        this.isLoading = true
        this.lastOffsetDate = 0
        this.loadRequestsImpl(false)
    }

    private func loadRequestsMore(): Unit {
        this.isLoadingMore = true
        this.loadRequestsImpl(true)
    }

    private func loadRequestsImpl(append: Bool): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let q = this.searchQuery
        let offsetDate = if (!append) { Int32(0) } else { this.lastOffsetDate }

        spawn {
            try {
                let svc = getInviteLinksService()
                let resp = svc.getChatInviteImportersWithData(
                    peerType, peerId,
                    requested: true,
                    searchQuery: q,
                    offsetDate: offsetDate,
                    limit: 50
                )
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] requests loaded")
                let newArr = resp.importers.toArray()
                let newUsers = resp.users
                let total = resp.count
                let hasMoreData = resp.importers.size >= 50

                let lastDate: Int32
                if (newArr.size > 0) {
                    lastDate = newArr[newArr.size - 1].date
                } else {
                    lastDate = 0
                }

                launch {
                    if (!append) {
                        this.requests = newArr
                        this.requestUsers = newUsers
                    } else {
                        let merged = ArrayList<ChatInviteImporterData>()
                        for (item in this.requests) { merged.add(item) }
                        for (item in newArr) { merged.add(item) }
                        this.requests = merged.toArray()
                        let mergedUsers = ArrayList<UserResponse>()
                        for (u in this.requestUsers) { mergedUsers.add(u) }
                        for (u in newUsers) { mergedUsers.add(u) }
                        this.requestUsers = mergedUsers
                    }
                    this.totalCount = total
                    this.hasMore = hasMoreData
                    this.lastOffsetDate = lastDate
                    this.isLoading = false
                    this.isLoadingMore = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] load failed")
                launch {
                    this.isLoading = false
                    this.isLoadingMore = false
                }
            }
        }
    }

    private func approveUser(userId: Int64, accessHash: Int64): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let uid = userId
        let ah = accessHash
        this.processingUserId = uid

        spawn {
            try {
                let ok = getInviteLinksService().hideChatJoinRequest(
                    peerType, peerId, uid, ah, approved: true
                )
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] approve done")
                launch {
                    this.processingUserId = 0
                    if (ok) { this.loadRequestsReset() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] approve error")
                launch { this.processingUserId = 0 }
            }
        }
    }

    private func dismissUser(userId: Int64, accessHash: Int64): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let uid = userId
        let ah = accessHash
        this.processingUserId = uid

        spawn {
            try {
                let ok = getInviteLinksService().hideChatJoinRequest(
                    peerType, peerId, uid, ah, approved: false
                )
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] dismiss done")
                launch {
                    this.processingUserId = 0
                    if (ok) { this.loadRequestsReset() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] dismiss error")
                launch { this.processingUserId = 0 }
            }
        }
    }

    private func approveAll(): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let linkParam = getSelectedInviteLinkUrl()

        spawn {
            try {
                let ok = getInviteLinksService().hideAllChatJoinRequests(
                    peerType, peerId,
                    approved: true,
                    link: linkParam
                )
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] approveAll done")
                launch {
                    this.showApproveAllConfirm = false
                    if (ok) { this.loadRequestsReset() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] approveAll error")
                launch { this.showApproveAllConfirm = false }
            }
        }
    }

    private func dismissAll(): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let linkParam = getSelectedInviteLinkUrl()

        spawn {
            try {
                let ok = getInviteLinksService().hideAllChatJoinRequests(
                    peerType, peerId,
                    approved: false,
                    link: linkParam
                )
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] dismissAll done")
                launch {
                    this.showDismissAllConfirm = false
                    if (ok) { this.loadRequestsReset() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[JoinApprovalPage] dismissAll error")
                launch { this.showDismissAllConfirm = false }
            }
        }
    }

    private func onSearchChanged(q: String): Unit {
        this.searchQuery = q
        this.loadRequestsReset()
    }

    private func getUserDisplayName(userId: Int64): String {
        for (u in this.requestUsers) {
            if (u.id == userId) {
                let name = (u.firstName + " " + u.lastName).trimAscii()
                if (name.size > 0) { return name }
                if (u.username.size > 0) { return "@" + u.username }
                return "User ${userId}"
            }
        }
        return "User ${userId}"
    }

    private func getUserAccessHash(userId: Int64): Int64 {
        for (u in this.requestUsers) {
            if (u.id == userId) {
                return u.accessHash
            }
        }
        return 0
    }

    private func formatTimestamp(ts: Int32): String {
        if (ts == 0) { return "" }
        return "Requested ${ts}"
    }

    private func getRequestsArray(): Array<ChatInviteImporterData> {
        return this.requests
    }

    public func build() {
        Stack {
            Column {
                this.searchBarSection()

                if (this.isLoading) {
                    Column {
                        Text("Loading join requests...")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.getRequestsArray().size == 0) {
                    this.emptyStateSection()
                } else {
                    Scroll {
                        Column {
                            this.headerCountSection()
                            this.bulkActionsSection()
                            this.requestListSection()
                            this.loadMoreSection()
                        }
                        .width(100.percent)
                    }
                    .align(Alignment.Top)
                    .layoutWeight(1)
                }
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xF2F2F7)
            .padding(bottom: getSafeAreaBottom())

            if (this.showApproveAllConfirm) {
                this.approveAllDialog()
            }
            if (this.showDismissAllConfirm) {
                this.dismissAllDialog()
            }
        }
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder func searchBarSection(): Unit {
        // P2-RETRO-search-b: 手搓 TextInput → SearchBar 原子。
        // SearchBar 是 @Component，不能直接链内置属性，外包 Column 容器。
        // onSearchChanged 绑定原样接入（更新 searchQuery 并重置分页加载）。
        Column {
            SearchBar(
                loading: false,
                backArrow: false,
                text: this.searchQuery,
                hint: trSource("Search"),
                onChange: { val: String =>
                    this.onSearchChanged(val)
                }
            )
        }
        .width(100.percent)
        .backgroundColor(0xF2F2F7)
    }

    @Builder func headerCountSection(): Unit {
        Text("\${this.totalCount} JOIN REQUESTS")
            .fontSize(13)
            .fontColor(0x8E8E93)
            .margin(left: 16, top: 8, bottom: 8)
            .width(100.percent)
    }

    @Builder func bulkActionsSection(): Unit {
        if (this.getRequestsArray().size > 0) {
            Row {
                Text("Approve All")
                    .fontSize(14)
                    .fontColor(0x34C759)
                    .padding(left: 16, right: 16, top: 10, bottom: 10)
                    .backgroundColor(0xE8F8ED)
                    .borderRadius(10)
                    .onClick({ _ =>
                        this.showApproveAllConfirm = true
                    })

                Text("Dismiss All")
                    .fontSize(14)
                    .fontColor(0xFF3B30)
                    .padding(left: 16, right: 16, top: 10, bottom: 10)
                    .backgroundColor(0xFFE6E6)
                    .borderRadius(10)
                    .margin(left: 12)
                    .onClick({ _ =>
                        this.showDismissAllConfirm = true
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, bottom: 12)
        }
    }

    @Builder func requestListSection(): Unit {
        Column {
            ForEach(this.getRequestsArray(), itemGenerator: { item: ChatInviteImporterData, idx: Int64 =>
                Column {
                    Row {
                        Column {
                            Text(this.getUserDisplayName(item.userId))
                                .fontSize(16)
                                .fontColor(0x000000)
                                .fontWeight(FontWeight.Medium)
                            Text(this.formatTimestamp(item.date))
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .margin(top: 2)
                            if (item.about.size > 0) {
                                Text(item.about)
                                    .fontSize(13)
                                    .fontColor(0x6E6E73)
                                    .margin(top: 2)
                                    .maxLines(2)
                                    .textOverflow(TextOverflow.Ellipsis)
                            }
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)

                        if (this.processingUserId == item.userId) {
                            Text("...")
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                                .margin(left: 8)
                        } else {
                            Row {
                                Text(trSource("Approve"))
                                    .fontSize(13)
                                    .fontColor(0x34C759)
                                    .padding(left: 10, right: 10, top: 6, bottom: 6)
                                    .backgroundColor(0xE8F8ED)
                                    .borderRadius(8)
                                    .onClick({ _ =>
                                        this.approveUser(
                                            item.userId,
                                            this.getUserAccessHash(item.userId)
                                        )
                                    })

                                Text(trSource("Dismiss"))
                                    .fontSize(13)
                                    .fontColor(0xFF3B30)
                                    .padding(left: 10, right: 10, top: 6, bottom: 6)
                                    .backgroundColor(0xFFE6E6)
                                    .borderRadius(8)
                                    .margin(left: 8)
                                    .onClick({ _ =>
                                        this.dismissUser(
                                            item.userId,
                                            this.getUserAccessHash(item.userId)
                                        )
                                    })
                            }
                            .margin(left: 8)
                        }
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 12)

                    if (idx < Int64(this.getRequestsArray().size) - 1) {
                        Row {}
                        .width(100.percent)
                        .height(1)
                        .backgroundColor(0xE5E5EA)
                        .margin(left: 16)
                    }
                }
            })
        }
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16, bottom: 24)
    }

    @Builder func loadMoreSection(): Unit {
        if (this.hasMore) {
            Column {
                if (this.isLoadingMore) {
                    Text("Loading more...")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                        .padding(top: 16, bottom: 16)
                } else {
                    Text("Load More")
                        .fontSize(14)
                        .fontColor(0x0088CC)
                        .padding(top: 16, bottom: 16)
                        .onClick({ _ =>
                            this.loadRequestsMore()
                        })
                }
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
            .margin(bottom: 32)
        }
    }

    @Builder func emptyStateSection(): Unit {
        Column {
            Text("No Join Requests")
                .fontSize(17)
                .fontColor(0x000000)
                .fontWeight(FontWeight.Medium)
                .margin(bottom: 8)
            Text(if (this.searchQuery.size > 0) {
                "No requests match your search."
            } else {
                "There are no pending join requests for this group."
            })
                .fontSize(15)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
                .padding(left: 32, right: 32)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder func approveAllDialog(): Unit {
        Column {
            Column {
                Text("Approve All Requests")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)

                Text("All pending join requests will be approved. Are you sure?")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)

                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            this.showApproveAllConfirm = false
                        })

                    Text("Approve All")
                        .fontSize(17)
                        .fontColor(0x34C759)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            this.approveAll()
                        })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ =>
            this.showApproveAllConfirm = false
        })
    }

    @Builder func dismissAllDialog(): Unit {
        Column {
            Column {
                Text("Dismiss All Requests")
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)

                Text("All pending join requests will be dismissed. Are you sure?")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .textAlign(TextAlign.Center)
                    .margin(bottom: 20)

                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            this.showDismissAllConfirm = false
                        })

                    Text("Dismiss All")
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ _ =>
                            this.dismissAll()
                        })
                }
                .width(100.percent)
            }
            .width(80.percent)
            .padding(20)
            .backgroundColor(0xFFFFFF)
            .borderRadius(14)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x66000000)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick({ _ =>
            this.showDismissAllConfirm = false
        })
    }
}
