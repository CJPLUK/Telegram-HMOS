package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.utils.copyText
import ohos_app_cangjie_entry.router.*

/**
 * StickerPackPreviewPage — 贴纸包预览主页面
 *
 * 对应 iOS StickerPackScreen / StickerPackScreenNode / StickerPreviewControllerNode：
 * 展示贴纸包完整信息，包括：
 *   - 包名 / 贴纸数量
 *   - 贴纸网格（4 列，emoji alt 文字占位）
 *   - 底部安装 / 移除按钮
 *
 * 路由注册：MainTabPage.pageMap "StickerPackPreviewPage" 分支
 *   （需要 integration_contract ic_sticker_pack_preview_pagemap_register 接线）
 *
 * 路由参数格式：StickerPreviewPagePresentationArguments.toRouteParam()
 *   "packId|accessHash|shortName"
 *
 * 调用链：
 *   aboutToAppear
 *     → StickerPackPreviewService.getPackDetail(packId, accessHash)
 *         → StickersService.getStickerSet(packId, accessHash)
 *             → MTProtoClient.sendRequest()
 *   安装按钮 onClick
 *     → StickerPackPreviewService.installStickerSet(packId, accessHash)
 *         → StickersService.installStickerSet(packId, accessHash)
 *             → MTProtoClient.sendRequest()
 *   移除按钮 onClick
 *     → StickerPackPreviewService.uninstallStickerSet(packId, accessHash)
 *         → StickersService.uninstallStickerSet(packId, accessHash)
 *             → MTProtoClient.sendRequest()
 */
@HybridComponentEntry
@Component
public class StickerPackPreviewPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var loaded: Bool = false

    @State var packId: Int64 = 0
    @State var accessHash: Int64 = 0
    @State var shortName: String = ""

    @State var packTitle: String = ""
    @State var stickerCount: Int32 = 0
    @State var isInstalled: Bool = false
    @State var isLoading: Bool = true
    @State var loadError: Bool = false

    @State var stickerEmojis: Array<String> = Array<String>(0, repeat: "")
    @State var isActionInProgress: Bool = false

    // P2-377: Share sticker pack
    // t.me/addstickers/<short_name> URL — generated from shortName field
    @State var shareLinkCopied: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 混合迁移：原 onReady 经 NavDestination param 取参，改为 takePending。
        let raw = takePending("StickerPackPreviewPage")
        if (raw.size > 0 && raw != "{}") {
            // parseRouteParam 内部会 spawn loadPackDetail
            this.parseRouteParam(raw)
        } else {
            Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] ensureLoaded (no param)")
            let _ = spawn {
                this.loadPackDetail()
            }
        }
    }

    private func loadPackDetail(): Unit {
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] loadPackDetail start")
        let svc = getStickerPackPreviewService()
        var detail = StickerPackDetail()
        if (this.packId != 0) {
            detail = svc.getPackDetail(this.packId, this.accessHash)
        } else if (this.shortName.size > 0) {
            detail = svc.getPackDetailByName(this.shortName)
        }
        if (detail.success) {
            let title = detail.info.title
            let count = detail.info.count
            let installed = detail.info.isInstalled
            let stickerList = detail.stickers
            let emojiArr = Array<String>(stickerList.size, { i: Int64 =>
                let immutableList = stickerList
                if (immutableList[i].altEmoji.size > 0) {
                    immutableList[i].altEmoji
                } else {
                    "🎭"
                }
            })
            launch {
                this.packTitle = title
                this.stickerCount = count
                this.isInstalled = installed
                this.stickerEmojis = emojiArr
                this.isLoading = false
            }
        } else {
            launch {
                this.loadError = true
                this.isLoading = false
            }
        }
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] loadPackDetail done")
    }

    private func doInstall(): Unit {
        if (this.isActionInProgress) { return }
        launch {
            this.isActionInProgress = true
        }
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] doInstall")
        let packIdLocal = this.packId
        let accessHashLocal = this.accessHash
        let _ = spawn {
            let svc = getStickerPackPreviewService()
            let result = svc.installStickerSet(packIdLocal, accessHashLocal)
            launch {
                if (result.success) {
                    this.isInstalled = true
                }
                this.isActionInProgress = false
            }
            Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] install done")
        }
    }

    private func doUninstall(): Unit {
        if (this.isActionInProgress) { return }
        launch {
            this.isActionInProgress = true
        }
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] doUninstall")
        let packIdLocal = this.packId
        let accessHashLocal = this.accessHash
        let _ = spawn {
            let svc = getStickerPackPreviewService()
            let result = svc.uninstallStickerSet(packIdLocal, accessHashLocal)
            launch {
                if (result.success) {
                    this.isInstalled = false
                }
                this.isActionInProgress = false
            }
            Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] uninstall done")
        }
    }

    /**
     * P2-377: Share Sticker Pack
     *
     * 生成 t.me/addstickers/<short_name> URL（iOS 对应 StickerPackScreen.swift shareSubject）
     * 弹出 AlertDialog 展示链接 + 「复制链接」按钮
     *
     * iOS:
     *   case .url(let text):
     *       UIPasteboard.general.string = text
     *   shareSubject = .url(text: "https://t.me/addstickers/\(shortName)")
     */
    private func doShare(): Unit {
        let sn = this.shortName
        if (sn.size == 0) {
            Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] doShare: no shortName, skip")
            return
        }
        let shareUrl = "https://t.me/addstickers/" + sn
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] doShare url=${shareUrl}")
        let uiCtx = getUIContext()
        let closeBtn = AlertDialogButtonOptions(
            value: "Close",
            action: {=> ()}
        )
        let copyBtn = AlertDialogButtonOptions(
            value: "Copy Link",
            fontColor: 0xFF007AFF,
            action: {=>
                let ok = copyText(shareUrl)
                Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] copyLink ok=${ok}")
                launch { this.shareLinkCopied = ok }
            }
        )
        uiCtx.showAlertDialog(AlertDialogParamWithButtons(
            title: "Share Sticker Pack",
            message: shareUrl,
            primaryButton: closeBtn,
            secondaryButton: copyBtn,
            autoCancel: true
        ))
    }

    private func parseRouteParam(raw: String): Unit {
        if (raw.size == 0) { return }
        let args = StickerPreviewPagePresentationArguments.fromRouteParam(raw)
        this.packId = args.packId
        this.accessHash = args.accessHash
        this.shortName = args.shortName
        Hilog.info(0, "CjTelegram", "[StickerPackPreviewPage] parseRouteParam done")
        let _ = spawn {
            this.loadPackDetail()
        }
    }

    private func getActionButtonLabel(): String {
        if (this.isActionInProgress) {
            return "..."
        }
        if (this.isInstalled) {
            return "Remove"
        }
        return "Add"
    }

    private func getActionButtonColor(): Int64 {
        if (this.isInstalled) {
            return 0xFFFF3B30
        }
        return 0xFF007AFF
    }

    public func build() {
        Column {
                if (this.isLoading) {
                    this.buildLoadingView()
                } else if (this.loadError) {
                    this.buildErrorView()
                } else {
                    this.buildContentView()
                }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    private func buildLoadingView(): Unit {
        Column {
            Text(trSource("Loading..."))
                .fontSize(15)
                .fontColor(0xFF8E8E93)
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    private func buildErrorView(): Unit {
        Column {
            Text("Failed to load sticker pack")
                .fontSize(15)
                .fontColor(0xFF8E8E93)
                .textAlign(TextAlign.Center)
                .margin(bottom: 16)
            Button(trSource("Retry"))
                .fontSize(15)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(0xFF007AFF)
                .borderRadius(8)
                .height(40)
                .width(120)
                .onClick({ _ =>
                    launch {
                        this.isLoading = true
                        this.loadError = false
                    }
                    let _ = spawn { this.loadPackDetail() }
                })
        }
        .width(100.percent)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
    }

    @Builder
    private func buildContentView(): Unit {
        Column {
            this.buildPackHeader()
            this.buildStickerGrid()
            this.buildActionButton()
        }
        .width(100.percent)
        .height(100.percent)
    }

    @Builder
    private func buildPackHeader(): Unit {
        Row {
            Column {
                Text(if (this.packTitle.size > 0) { this.packTitle } else { "Sticker Pack" })
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(this.getStickerCountText())
                    .fontSize(13)
                    .fontColor(0xFF8E8E93)
                    .margin(top: 2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 16, bottom: 12)
        .backgroundColor(0xFFFFFFFF)
    }

    @Builder
    private func buildStickerGrid(): Unit {
        Grid() {
            ForEach(
                this.stickerEmojis,
                itemGeneratorFunc: { item: String, idx: Int64 =>
                    GridItem() {
                        Column {
                            Text(item)
                                .fontSize(36)
                                .textAlign(TextAlign.Center)
                        }
                        .width(100.percent)
                        .height(80)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .backgroundColor(0xFFFFFFFF)
                        .borderRadius(8)
                    }
                    .padding(4)
                }
            )
        }
        .columnsTemplate("1fr 1fr 1fr 1fr")
        .columnsGap(8)
        .rowsGap(8)
        .padding(left: 12, right: 12, top: 8, bottom: 8)
        .width(100.percent)
        .layoutWeight(1)
        .backgroundColor(0xFFF2F2F7)
    }

    @Builder
    private func buildActionButton(): Unit {
        Column {
            // P2-377: Share button — generates t.me/addstickers/<short_name>
            if (this.shortName.size > 0) {
                Row {
                    Button(if (this.shareLinkCopied) { "Link Copied!" } else { "Share" })
                        .fontSize(17)
                        .fontColor(0xFF007AFF)
                        .backgroundColor(0xFFE5F0FF)
                        .borderRadius(12)
                        .height(50)
                        .width(100.percent)
                        .onClick({ _ =>
                            this.doShare()
                        })
                }
                .padding(left: 16, right: 16, top: 12, bottom: 0)
                .width(100.percent)
            }
            Row {
                Button(this.getActionButtonLabel())
                    .fontSize(17)
                    .fontColor(0xFFFFFFFF)
                    .backgroundColor(this.getActionButtonColor())
                    .borderRadius(12)
                    .height(50)
                    .width(100.percent)
                    .enabled(!this.isActionInProgress)
                    .onClick({ _ =>
                        if (this.isInstalled) {
                            this.doUninstall()
                        } else {
                            this.doInstall()
                        }
                    })
            }
            .padding(left: 16, right: 16, top: 12, bottom: 24)
            .width(100.percent)
        }
        .width(100.percent)
        .backgroundColor(0xFFF2F2F7)
    }

    private func getStickerCountText(): String {
        let count = Int64(this.stickerCount)
        if (count == 0) {
            return this.stickerEmojis.size.toString() + " stickers"
        }
        return count.toString() + " stickers"
    }
}
