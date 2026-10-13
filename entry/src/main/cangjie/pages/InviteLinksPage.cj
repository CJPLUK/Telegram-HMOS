package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.models.InviteLinkData
import ohos_app_cangjie_entry.router.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * 邀请链接主页面（Invite Links Page）（混合工程迁移版）
 *
 * 展示群组/频道的邀请链接列表（永久链接 + 附加链接），
 * 支持创建/编辑/删除/复制链接。
 *
 * 使用 InviteLinksService 封装 TL 方法。
 * 参考：InviteLinkViewController, FolderInviteLinkListController
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与 .title，只留内容 + .onAppear
 *  - pushPathByName(name, "") → routerPush(name)
 *  - aboutToAppear 有实逻辑 → ensureLoaded()（loaded 守卫）
 */
// 混合嵌入页没有 onPageShow：编辑页创建/修改链接后通过本回调通知列表页重新拉取。
private var _inviteLinksRefreshHandler: Option<() -> Unit> = None

public func notifyInviteLinksChanged(): Unit {
    match (_inviteLinksRefreshHandler) {
        case Some(handler) => handler()
        case None => ()
    }
}

@HybridComponentEntry
@Component
public class InviteLinksPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var activeLinks: ArrayList<InviteLinkData> = ArrayList<InviteLinkData>()
    @State var revokedLinks: ArrayList<InviteLinkData> = ArrayList<InviteLinkData>()
    @State var isLoading: Bool = true
    @State var showRevokeConfirm: Bool = false
    @State var showDeleteConfirm: Bool = false
    @State var showCopiedToast: Bool = false
    @State var revokeTargetLink: String = ""
    @State var deleteTargetLink: String = ""
    @State var showDeleteAllRevokedConfirm: Bool = false
    @State var groupName: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.groupName = getSelectedChatName()
        _inviteLinksRefreshHandler = Some({ => this.loadInviteLinks() })
        this.loadInviteLinks()
    }

    private func loadInviteLinks(): Unit {
        this.isLoading = true
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        spawn {
            try {
                let svc = getInviteLinksService()
                let active = svc.getExportedChatInvites(peerType, peerId)
                let revoked = svc.getExportedChatInvites(peerType, peerId, revoked: true)
                launch {
                    this.activeLinks = active
                    this.revokedLinks = revoked
                    this.isLoading = false
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteLinksPage] Load failed")
                launch { this.isLoading = false }
            }
        }
    }

    private func createNewLink(): Unit {
        setPendingInviteLinkEdit("")
        routerPush("InviteLinkEditPage")
    }

    private func editLink(linkData: InviteLinkData): Unit {
        setPendingInviteLinkEdit(linkData.link)
        routerPush("InviteLinkEditPage")
    }

    private func viewLinkDetail(linkData: InviteLinkData): Unit {
        setSelectedInviteLinkUrl(linkData.link)
        routerPush("InviteLinkPage")
    }

    private func revokeLink(link: String): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        spawn {
            try {
                let ok = getInviteLinksService().editExportedChatInvite(peerType, peerId, link, revoked: true)
                if (ok) {
                    launch { this.loadInviteLinks() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteLinksPage] Revoke error")
            }
        }
        this.showRevokeConfirm = false
        this.revokeTargetLink = ""
    }

    private func deleteLink(link: String): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        spawn {
            try {
                let ok = getInviteLinksService().deleteExportedChatInvite(peerType, peerId, link)
                if (ok) {
                    launch { this.loadInviteLinks() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteLinksPage] Delete error")
            }
        }
        this.showDeleteConfirm = false
        this.deleteTargetLink = ""
    }

    /**
     * P2-170: 批量删除全部已撤销链接（messages.deleteRevokedExportedChatInvites）
     */
    private func deleteAllRevokedLinks(): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        spawn {
            try {
                let ok = getInviteLinksService().deleteRevokedExportedChatInvites(peerType, peerId)
                if (ok) {
                    launch { this.loadInviteLinks() }
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[InviteLinksPage] DeleteAllRevoked error")
            }
        }
        this.showDeleteAllRevokedConfirm = false
    }

    private func copyLinkToClipboard(link: String): Unit {
        setClipboardText(link)
        this.showCopiedToast = true
        let _ = spawn {
            sleep(Duration.second * 2)
            launch { this.showCopiedToast = false }
        }
    }

    /**
     * P2-169: 通过鸿蒙系统分享面板分享邀请链接
     *
     * 对应 iOS InviteLinksController shareLink → UIActivityViewController
     * 拉起系统 share sheet（Want action=SEND）让用户选择分享目标应用。
     * 若系统面板拉起失败则降级为复制到剪贴板。
     */
    private func shareLinkViaSystem(link: String): Unit {
        let linkParam = link
        spawn {
            let svc = getShareControllerService()
            let ok = svc.shareInviteLinkViaSystem(linkParam)
            if (!ok) {
                Hilog.info(0, "CjTelegram", "[InviteLinksPage] shareLinkViaSystem: fallback to clipboard for ${linkParam}")
                launch { this.copyLinkToClipboard(linkParam) }
            }
        }
    }

    private func findPermanentLink(): String {
        for (link in this.activeLinks) {
            if (link.isPermanent) {
                return link.link
            }
        }
        return ""
    }

    private func getPermanentUsageText(): String {
        for (link in this.activeLinks) {
            if (link.isPermanent) {
                return "${link.usageCount} joined"
            }
        }
        return ""
    }

    private func getTemporaryLinks(): Array<InviteLinkData> {
        let temp = ArrayList<InviteLinkData>()
        for (link in this.activeLinks) {
            if (!link.isPermanent) {
                temp.add(link)
            }
        }
        return temp.toArray()
    }

    private func getLinkTitle(linkData: InviteLinkData): String {
        if (linkData.title.size > 0) {
            return linkData.title
        }
        if (linkData.isPermanent) {
            return "Permanent Link"
        }
        return "Invite Link"
    }

    private func getLinkInfoText(linkData: InviteLinkData): String {
        var info = "${linkData.usageCount} joined"
        if (linkData.usageLimit > 0) {
            info = info + " / ${linkData.usageLimit} limit"
        }
        if (linkData.requestsCount > 0) {
            info = info + " / ${linkData.requestsCount} pending"
        }
        if (linkData.requestNeeded) {
            info = info + " (approval required)"
        }
        return info
    }

    public func build() {
        Stack {
            Column {
                if (this.isLoading) {
                    Column {
                        Text("Loading invite links...")
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
                            this.permanentLinkSection()
                            this.createNewLinkButton()
                            this.additionalLinksSection()
                            this.revokedLinksSection()
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
                .onClick({ evt =>
                    this.showCopiedToast = false
                })
            }

            if (this.showRevokeConfirm) {
                this.revokeConfirmDialog()
            }
            if (this.showDeleteConfirm) {
                this.deleteConfirmDialog()
            }
            if (this.showDeleteAllRevokedConfirm) {
                this.deleteAllRevokedConfirmDialog()
            }
        }
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder private func permanentLinkSection(): Unit {
        if (this.findPermanentLink().size > 0) {
            Text("PRIMARY LINK")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 16, bottom: 8)
                .width(100.percent)

            Column {
                Row {
                    Row {
                        // 资源保真修复：真实矢量图标（Item List/Icons/Link.imageset 转 SVG，复用 chatroom_ic_link）替代 emoji 字形
                        Image(@r(app.media.chatroom_ic_link))
                            .width(20)
                            .height(20)
                            .fillColor(0x00C853)
                    }
                    .width(44)
                    .height(44)
                    .justifyContent(FlexAlign.Center)
                    .backgroundColor(0xE8F8ED)
                    .borderRadius(22)
                    .margin(right: 12)

                    Column {
                        Text(trSource("Permanent Link"))
                            .fontSize(17)
                            .fontColor(0x000000)
                        Text(this.findPermanentLink())
                            .fontSize(13)
                            .fontColor(0x0088CC)
                            .margin(top: 2)
                            .maxLines(1)
                            .textOverflow(TextOverflow.Ellipsis)
                        Text(this.getPermanentUsageText())
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                            .margin(top: 4)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 12, bottom: 12)

                Row {
                    Text(trSource("Copy Link"))
                        .fontSize(14)
                        .fontColor(0x0088CC)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(0xE3F2FD)
                        .borderRadius(16)
                        .onClick({ evt =>
                            this.copyLinkToClipboard(this.findPermanentLink())
                        })
                    Text(trSource("Share"))
                        .fontSize(14)
                        .fontColor(0x0088CC)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(0xE3F2FD)
                        .borderRadius(16)
                        .margin(left: 8)
                        .onClick({ evt =>
                            this.shareLinkViaSystem(this.findPermanentLink())
                        })
                    Text("Details")
                        .fontSize(14)
                        .fontColor(0x0088CC)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(0xE3F2FD)
                        .borderRadius(16)
                        .margin(left: 8)
                        .onClick({ evt =>
                            for (link in this.activeLinks) {
                                if (link.isPermanent) {
                                    this.viewLinkDetail(link)
                                    break
                                }
                            }
                        })
                }
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)
            }
            .backgroundColor(0xFFFFFF)
            .borderRadius(12)
            .margin(left: 16, right: 16)

            Text("Anyone can use this link to join your group.")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, right: 16, top: 8)
        }
    }

    @Builder private func createNewLinkButton(): Unit {
        Column {
            Row {
                Row {
                    Text("+")
                        .fontSize(22)
                        .fontColor(0x0088CC)
                        .fontWeight(FontWeight.Bold)
                }
                .width(40)
                .height(40)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(0xE3F2FD)
                .borderRadius(20)
                .margin(right: 12)

                Text("Create New Link")
                    .fontSize(17)
                    .fontColor(0x0088CC)
            }
            .width(100.percent)
            .height(56)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)
            .onClick({ evt =>
                this.createNewLink()
            })
        }
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .margin(left: 16, right: 16, top: 24)
    }

    @Builder private func additionalLinksSection(): Unit {
        if (this.getTemporaryLinks().size > 0) {
            Text("ADDITIONAL LINKS")
                .fontSize(13)
                .fontColor(0x8E8E93)
                .margin(left: 16, top: 24, bottom: 8)
                .width(100.percent)

            Column {
                ForEach(this.getTemporaryLinks(), itemGenerator: { linkData: InviteLinkData, idx: Int64 =>
                    Column {
                        Row {
                            Row {
                                // 资源保真修复：真实矢量图标（Item List/Icons/Link.imageset 转 SVG，复用 chatroom_ic_link）替代 emoji 字形
                                Image(@r(app.media.chatroom_ic_link))
                                    .width(18)
                                    .height(18)
                                    .fillColor(0x0088CC)
                            }
                            .width(40)
                            .height(40)
                            .justifyContent(FlexAlign.Center)
                            .backgroundColor(0xE3F2FD)
                            .borderRadius(20)
                            .margin(right: 12)

                            Column {
                                Text(this.getLinkTitle(linkData))
                                    .fontSize(16)
                                    .fontColor(0x000000)
                                Text(linkData.link)
                                    .fontSize(13)
                                    .fontColor(0x0088CC)
                                    .margin(top: 2)
                                    .maxLines(1)
                                    .textOverflow(TextOverflow.Ellipsis)
                                Text(this.getLinkInfoText(linkData))
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 4)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .layoutWeight(1)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 10, bottom: 6)

                        Row {
                            Text("Details")
                                .fontSize(13)
                                .fontColor(0x0088CC)
                                .padding(left: 12, right: 12, top: 6, bottom: 6)
                                .backgroundColor(0xE3F2FD)
                                .borderRadius(14)
                                .onClick({ evt2 =>
                                    this.viewLinkDetail(linkData)
                                })
                            Text(trSource("Copy"))
                                .fontSize(13)
                                .fontColor(0x0088CC)
                                .padding(left: 12, right: 12, top: 6, bottom: 6)
                                .backgroundColor(0xE3F2FD)
                                .borderRadius(14)
                                .margin(left: 8)
                                .onClick({ evt2 =>
                                    this.copyLinkToClipboard(linkData.link)
                                })
                            Text(trSource("Share"))
                                .fontSize(13)
                                .fontColor(0x0088CC)
                                .padding(left: 12, right: 12, top: 6, bottom: 6)
                                .backgroundColor(0xE3F2FD)
                                .borderRadius(14)
                                .margin(left: 8)
                                .onClick({ evt2 =>
                                    this.shareLinkViaSystem(linkData.link)
                                })
                            Text(trSource("Edit"))
                                .fontSize(13)
                                .fontColor(0x0088CC)
                                .padding(left: 12, right: 12, top: 6, bottom: 6)
                                .backgroundColor(0xE3F2FD)
                                .borderRadius(14)
                                .margin(left: 8)
                                .onClick({ evt2 =>
                                    this.editLink(linkData)
                                })
                            Text(trSource("Revoke"))
                                .fontSize(13)
                                .fontColor(0xFF3B30)
                                .padding(left: 12, right: 12, top: 6, bottom: 6)
                                .backgroundColor(0xFFE6E6)
                                .borderRadius(14)
                                .margin(left: 8)
                                .onClick({ evt2 =>
                                    this.revokeTargetLink = linkData.link
                                    this.showRevokeConfirm = true
                                })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 10)
                    }
                })
            }
            .backgroundColor(0xFFFFFF)
            .borderRadius(12)
            .margin(left: 16, right: 16)
        }
    }

    @Builder private func revokedLinksSection(): Unit {
        if (this.revokedLinks.size > 0) {
            Row {
                Text("REVOKED LINKS")
                    .fontSize(13)
                    .fontColor(0x8E8E93)
                    .layoutWeight(1)
                Text(trSource("Delete All"))
                    .fontSize(13)
                    .fontColor(0xFF3B30)
                    .margin(right: 16)
                    .onClick({ evt =>
                        this.showDeleteAllRevokedConfirm = true
                    })
            }
            .width(100.percent)
            .margin(top: 24, bottom: 8)
            .padding(left: 16)

            Column {
                ForEach(this.revokedLinks.toArray(), itemGenerator: { linkData: InviteLinkData, idx: Int64 =>
                    Column {
                        Row {
                            Row {
                                // 资源保真修复：真实矢量图标（Item List/Icons/Link.imageset 转 SVG，复用 chatroom_ic_link）替代 emoji 字形
                                Image(@r(app.media.chatroom_ic_link))
                                    .width(18)
                                    .height(18)
                                    .fillColor(0x8E8E93)
                            }
                            .width(40)
                            .height(40)
                            .justifyContent(FlexAlign.Center)
                            .backgroundColor(0xF2F2F7)
                            .borderRadius(20)
                            .margin(right: 12)

                            Column {
                                Text(this.getLinkTitle(linkData))
                                    .fontSize(16)
                                    .fontColor(0x8E8E93)
                                Text("Revoked")
                                    .fontSize(13)
                                    .fontColor(0xFF3B30)
                                    .margin(top: 2)
                                Text(this.getLinkInfoText(linkData))
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                    .margin(top: 4)
                            }
                            .alignItems(HorizontalAlign.Start)
                            .layoutWeight(1)
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 10, bottom: 6)
                        .opacity(0.6)

                        Row {
                            Text(trSource("Delete"))
                                .fontSize(13)
                                .fontColor(0xFF3B30)
                                .padding(left: 16, right: 16, top: 6, bottom: 6)
                                .backgroundColor(0xFFE6E6)
                                .borderRadius(14)
                                .onClick({ evt2 =>
                                    this.deleteTargetLink = linkData.link
                                    this.showDeleteConfirm = true
                                })
                        }
                        .width(100.percent)
                        .padding(left: 16, right: 16, bottom: 10)
                    }
                })
            }
            .backgroundColor(0xFFFFFF)
            .borderRadius(12)
            .margin(left: 16, right: 16, bottom: 40)
        }
    }

    @Builder private func revokeConfirmDialog(): Unit {
        Column {
            Column {
                Text(trSource("Revoke Link"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)

                Text("Are you sure you want to revoke this link? People will no longer be able to join using it.")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 20)

                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ evt =>
                            this.showRevokeConfirm = false
                            this.revokeTargetLink = ""
                        })

                    Text(trSource("Revoke"))
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ evt =>
                            this.revokeLink(this.revokeTargetLink)
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
        .onClick({ evt =>
            this.showRevokeConfirm = false
            this.revokeTargetLink = ""
        })
    }

    @Builder private func deleteConfirmDialog(): Unit {
        Column {
            Column {
                Text(trSource("Delete Link"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)

                Text("Are you sure you want to delete this link from the list?")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 20)

                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ evt =>
                            this.showDeleteConfirm = false
                            this.deleteTargetLink = ""
                        })

                    Text(trSource("Delete"))
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ evt =>
                            this.deleteLink(this.deleteTargetLink)
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
        .onClick({ evt =>
            this.showDeleteConfirm = false
            this.deleteTargetLink = ""
        })
    }

    /**
     * P2-170: 批量删除全部撤销链接确认对话框
     */
    @Builder private func deleteAllRevokedConfirmDialog(): Unit {
        Column {
            Column {
                Text(trSource("Delete All Revoked Links"))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .margin(bottom: 8)

                Text("Are you sure you want to delete all revoked links? This action cannot be undone.")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 20)

                Row {
                    Text(trSource("Cancel"))
                        .fontSize(17)
                        .fontColor(0x0088CC)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ evt =>
                            this.showDeleteAllRevokedConfirm = false
                        })

                    Text(trSource("Delete All"))
                        .fontSize(17)
                        .fontColor(0xFF3B30)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick({ evt =>
                            this.deleteAllRevokedLinks()
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
        .onClick({ evt =>
            this.showDeleteAllRevokedConfirm = false
        })
    }
}
