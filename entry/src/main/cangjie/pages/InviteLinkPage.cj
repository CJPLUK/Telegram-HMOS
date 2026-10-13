package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.InviteLinkData
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * P2-171: 单链接详情页 + 加入者列表
 *
 * 对应 iOS InviteLinksControllerNode / InviteLinksController 单链接详情界面。
 *
 * 功能:
 * - 显示邀请链接 URL、creator/created 元数据
 * - 通过 messages.getChatInviteImporters (link 参数) 真 wire 加载加入者列表
 * - 显示每个加入者: userId、日期、about、是否 via chatlist
 * - "View Join Requests" 按钮跳转 P2-172 JoinApprovalPage
 * - 复制链接、分页加载更多
 *
 * TL wire: getChatInviteImportersWithData (link=selectedLink, requested=false)
 * iOS ref: Api42.swift:6710 messages.getChatInviteImporters#df04dd4e
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title 一并去掉），只留内部 Stack
 *  - aboutToAppear 有实逻辑（loadImportersReset）→ ensureLoaded()（.onAppear 触发）
 *  - pushPathByName → routerPush
 */
@HybridComponentEntry
@Component
public class InviteLinkPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var linkUrl: String = ""
    @State var importers: Array<ChatInviteImporterData> = Array<ChatInviteImporterData>()
    @State var importerUsers: ArrayList<UserResponse> = ArrayList<UserResponse>()
    @State var totalCount: Int32 = 0
    @State var isLoading: Bool = true
    @State var isLoadingMore: Bool = false
    @State var hasMore: Bool = false
    @State var showCopiedToast: Bool = false
    @State var linkData: InviteLinkData = InviteLinkData()
    @State var lastOffsetDate: Int32 = 0
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.linkUrl = getSelectedInviteLinkUrl()
        if (this.linkUrl.size == 0) {
            this.isLoading = false
        } else {
            this.loadImportersReset()
        }
    }

    private func loadImportersReset(): Unit {
        this.isLoading = true
        this.lastOffsetDate = 0
        this.loadImportersImpl(false)
    }

    private func loadImportersMore(): Unit {
        this.isLoadingMore = true
        this.loadImportersImpl(true)
    }

    private func loadImportersImpl(append: Bool): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let linkParam = this.linkUrl
        let offsetDate = if (!append) { Int32(0) } else { this.lastOffsetDate }

        spawn {
            try {
                let svc = getInviteLinksService()
                let resp = svc.getChatInviteImportersWithData(
                    peerType, peerId,
                    link: linkParam,
                    requested: false,
                    offsetDate: offsetDate,
                    limit: 50
                )
                Hilog.info(0, "CjTelegram", "[InviteLinkPage] importers loaded")
                let newArr = resp.importers.toArray()
                let newUsers = resp.users
                let totalCnt = resp.count
                let hasMoreData = resp.importers.size >= 50

                let lastDate: Int32
                if (newArr.size > 0) {
                    lastDate = newArr[newArr.size - 1].date
                } else {
                    lastDate = 0
                }

                launch {
                    if (!append) {
                        this.importers = newArr
                        this.importerUsers = newUsers
                    } else {
                        let merged = ArrayList<ChatInviteImporterData>()
                        for (item in this.importers) { merged.add(item) }
                        for (item in newArr) { merged.add(item) }
                        this.importers = merged.toArray()
                        let mergedUsers = ArrayList<UserResponse>()
                        for (u in this.importerUsers) { mergedUsers.add(u) }
                        for (u in newUsers) { mergedUsers.add(u) }
                        this.importerUsers = mergedUsers
                    }
                    this.totalCount = totalCnt
                    this.hasMore = hasMoreData
                    this.lastOffsetDate = lastDate
                    this.isLoading = false
                    this.isLoadingMore = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteLinkPage] load failed")
                launch {
                    this.isLoading = false
                    this.isLoadingMore = false
                }
            }
        }
    }

    private func copyLink(): Unit {
        setClipboardText(this.linkUrl)
        this.showCopiedToast = true
        let _ = spawn {
            sleep(Duration.second * 2)
            launch { this.showCopiedToast = false }
        }
    }

    /**
     * P2-169: 通过鸿蒙系统分享面板分享邀请链接
     *
     * 对应 iOS InviteLinkViewController shareLink → UIActivityViewController
     * 拉起系统 share sheet（Want action=SEND）让用户选择分享目标应用。
     */
    private func shareLink(): Unit {
        let linkParam = this.linkUrl
        spawn {
            let svc = getShareControllerService()
            let ok = svc.shareInviteLinkViaSystem(linkParam)
            if (!ok) {
                Hilog.info(0, "CjTelegram", "[InviteLinkPage] shareLink: system share unavailable, fallback to copyLink")
                launch { this.copyLink() }
            }
        }
    }

    private func openJoinRequests(): Unit {
        routerPush("JoinApprovalPage", "")
    }

    private func getUserDisplayName(userId: Int64): String {
        for (u in this.importerUsers) {
            if (u.id == userId) {
                let name = (u.firstName + " " + u.lastName).trimAscii()
                if (name.size > 0) { return name }
                if (u.username.size > 0) { return "@" + u.username }
                return "User ${userId}"
            }
        }
        return "User ${userId}"
    }

    private func formatTimestamp(ts: Int32): String {
        if (ts == 0) { return "" }
        return "Joined ${ts}"
    }

    private func getImporterArray(): Array<ChatInviteImporterData> {
        return this.importers
    }

    public func build() {
        Stack {
            Column {
                if (this.isLoading) {
                    Column {
                        Text("Loading link details...")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else if (this.linkUrl.size == 0) {
                    Column {
                        Text("No link selected")
                            .fontSize(15)
                            .fontColor(0x8E8E93)
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                } else {
                    Scroll {
                        Column {
                            this.linkHeaderSection()
                            this.actionButtonsSection()
                            this.importersSection()
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

            if (this.showCopiedToast) {
                Column {
                    Text("Link copied!")
                        .fontSize(14)
                        .fontColor(0xFFFFFF)
                        .padding(left: 20, right: 20, top: 10, bottom: 10)
                        .backgroundColor(0x333333)
                        .borderRadius(20)
                }
                .width(100.percent)
                .height(100.percent)
                .justifyContent(FlexAlign.End)
                .alignItems(HorizontalAlign.Center)
                .padding(bottom: 100)
                .onClick({ _ =>
                    this.showCopiedToast = false
                })
            }
        }
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder func linkHeaderSection(): Unit {
        Text(trSource("INVITE LINK"))
            .fontSize(13)
            .fontColor(0x8E8E93)
            .margin(left: 16, top: 16, bottom: 8)
            .width(100.percent)

        Column {
            Row {
                Column {
                    Text(this.linkUrl)
                        .fontSize(14)
                        .fontColor(0x0088CC)
                        .maxLines(2)
                        .textOverflow(TextOverflow.Ellipsis)
                        .margin(bottom: 4)
                    Text("${this.totalCount} people joined")
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .padding(right: 8)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 16, bottom: 16)
        }
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16)
    }

    @Builder func actionButtonsSection(): Unit {
        Column {
            Row {
                Text(trSource("Copy Link"))
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                    .padding(top: 14, bottom: 14)
                    .onClick({ _ =>
                        this.copyLink()
                    })

                Row {}
                .width(1)
                .height(20)
                .backgroundColor(0xE5E5EA)

                Text(trSource("Share"))
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                    .padding(top: 14, bottom: 14)
                    .onClick({ _ =>
                        this.shareLink()
                    })
            }
            .width(100.percent)
            .backgroundColor(0xFFFFFF)
            .borderRadius(12)
            .alignItems(VerticalAlign.Center)

            Row {
                Text("View Join Requests")
                    .fontSize(14)
                    .fontColor(0x0088CC)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                    .padding(top: 14, bottom: 14)
                    .onClick({ _ =>
                        this.openJoinRequests()
                    })
            }
            .width(100.percent)
            .backgroundColor(0xFFFFFF)
            .borderRadius(12)
            .margin(top: 12)
        }
        .margin(left: 16, right: 16, top: 16)
    }

    @Builder func importersSection(): Unit {
        if (this.getImporterArray().size > 0) {
            Text("JOINED VIA THIS LINK (${this.totalCount})")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 8)
                .width(100.percent)

            Column {
                ForEach(this.getImporterArray(), itemGenerator: { item: ChatInviteImporterData, idx: Int64 =>
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
                                if (item.viaChatlist) {
                                    Text("via chatlist")
                                        .fontSize(11)
                                        .fontColor(0xAAAAAA)
                                        .margin(top: 2)
                                }
                            }
                            .alignItems(HorizontalAlign.Start)
                            .layoutWeight(1)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 12, bottom: 12)

                        if (idx < Int64(this.getImporterArray().size) - 1) {
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
        } else {
            Column {
                Text("No one has joined via this link yet.")
                    .fontSize(15)
                    .fontColor(0x8E8E93)
                    .textAlign(TextAlign.Center)
                    .margin(top: 32, bottom: 32)
            }
            .width(100.percent)
        }
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
                            this.loadImportersMore()
                        })
                }
            }
            .width(100.percent)
            .alignItems(HorizontalAlign.Center)
            .margin(bottom: 32)
        }
    }
}
