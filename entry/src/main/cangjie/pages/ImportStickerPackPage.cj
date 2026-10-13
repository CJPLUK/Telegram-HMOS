package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * ImportStickerPackPage — 导入第三方贴纸包主页面
 *
 * 对应 iOS ImportStickerPackUI/Sources/ImportStickerPackController.swift
 *   + ImportStickerPackControllerNode.swift
 *
 * 功能流程：
 *   1. 进入页面时通过路由参数获取预填标题和初始贴纸 URI 列表
 *   2. 展示贴纸网格预览（调用 ImportStickerPackService）
 *   3. 用户输入贴纸包名称
 *   4. 点击"Create Sticker Set" → 调用 ImportStickerPackService.startImport()
 *   5. 成功后跳转 StickerPackPreviewPage
 *   6. 点击"Cancel" → 弹出当前页面
 *
 * 路由参数格式（takePending，?String）：
 *   "title|uri1|uri2|..."  — 竖线分隔，首段为包标题，后续为贴纸 URI
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title/.hideTitleBar/.onReady 一并去掉），只留内部 Column
 *  - onReady param 接收 → ensureLoaded()（.onAppear 触发）内 takePending("ImportStickerPackPage")
 *  - pushPathByName → routerPush；pop → routerPop
 */
@HybridComponentEntry
@Component
public class ImportStickerPackPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var packTitle: String = ""
    @State var stickerUris: Array<String> = Array<String>(0, repeat: "")
    @State var stickerEmojis: Array<String> = Array<String>(0, repeat: "")
    @State var isUploading: Bool = false
    @State var errorMessage: String = ""
    @State var inputPackTitle: String = ""
    @State var touchDownTime: Int64 = 0
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("ImportStickerPackPage")
        let param = if (raw == "{}") { "" } else { raw }
        this.parseRouteParam(param)
    }

    private func parseRouteParam(raw: String): Unit {
        Hilog.info(0, "CjTelegram", "[ImportStickerPackPage] parseRouteParam start")
        let svc = getImportStickerPackService()
        svc.reset()
        if (raw.size == 0) {
            Hilog.info(0, "CjTelegram", "[ImportStickerPackPage] no route param")
            return
        }
        let runes = raw.toRuneArray()
        let segments = splitByPipe(runes)
        if (segments.size > 0) {
            let title = segments[0]
            svc.setPackTitle(title)
            launch {
                this.packTitle = title
                this.inputPackTitle = title
            }
        }
        var uriList = ArrayList<String>()
        var emojiList = ArrayList<String>()
        var si: Int64 = 1
        while (si < Int64(segments.size)) {
            let uri = segments[Int64(si)]
            if (uri.size > 0) {
                svc.addStickerItem(uri, "🎭")
                uriList.add(uri)
                emojiList.add("🎭")
            }
            si = si + 1
        }
        let immU = uriList
        let uriArr = Array<String>(immU.size, { i: Int64 => immU[i] })
        let immE = emojiList
        let emojiArr = Array<String>(immE.size, { i: Int64 => immE[i] })
        launch {
            this.stickerUris = uriArr
            this.stickerEmojis = emojiArr
        }
        Hilog.info(0, "CjTelegram", "[ImportStickerPackPage] parseRouteParam done uris=${uriList.size}")
    }

    private func splitByPipe(runes: Array<Rune>): Array<String> {
        let result = ArrayList<String>()
        var seg = ArrayList<Rune>()
        var i: Int64 = 0
        while (i < Int64(runes.size)) {
            if (runes[i] == r'|') {
                result.add(String(seg.toArray()))
                seg = ArrayList<Rune>()
            } else {
                seg.add(runes[i])
            }
            i = i + 1
        }
        result.add(String(seg.toArray()))
        return Array<String>(result.size, { j: Int64 =>
            let immR = result
            immR[j]
        })
    }

    private func doCreate(): Unit {
        if (this.isUploading) { return }
        let titleToSet = this.inputPackTitle
        if (titleToSet.size == 0) {
            launch {
                this.errorMessage = "Please enter a sticker pack name"
            }
            return
        }
        let svc = getImportStickerPackService()
        svc.setPackTitle(titleToSet)
        if (!svc.canCreate()) {
            launch {
                this.errorMessage = "Add at least one sticker"
            }
            return
        }
        launch {
            this.isUploading = true
            this.errorMessage = ""
        }
        let _ = spawn {
            let service = getImportStickerPackService()
            service.startImport()
            let success = service.currentState.uploadSuccess
            let errMsg = service.currentState.errorMessage
            launch {
                this.isUploading = false
                if (success) {
                    routerPush("StickerPackPreviewPage", "0".toString())
                } else {
                    this.errorMessage = if (errMsg.size > 0) { errMsg } else { "Import failed" }
                }
            }
            Hilog.info(0, "CjTelegram", "[ImportStickerPackPage] import result success=${success}")
        }
    }

    private func doRemoveSticker(index: Int64): Unit {
        let svc = getImportStickerPackService()
        svc.removeStickerItem(index)
        let count = svc.getStickerCount()
        let uriArr = Array<String>(count, { i: Int64 =>
            svc.getStickerUri(i)
        })
        let emojiArr = Array<String>(count, { i: Int64 =>
            svc.getStickerEmoji(i)
        })
        launch {
            this.stickerUris = uriArr
            this.stickerEmojis = emojiArr
        }
        Hilog.info(0, "CjTelegram", "[ImportStickerPackPage] removed sticker ${index}")
    }

    private func getCreateButtonColor(): Int64 {
        if (this.isUploading) {
            return 0xFFAEAEB2
        }
        return 0xFF007AFF
    }

    private func getCreateButtonLabel(): String {
        if (this.isUploading) {
            return "Creating..."
        }
        return "Create Sticker Set"
    }

    private func getStickerCountLabel(): String {
        let count = this.stickerUris.size
        if (count == 1) {
            return "1 sticker"
        }
        return count.toString() + " stickers"
    }

    public func build() {
        Column {
            this.buildHeaderInfo()
            this.buildNameInput()
            this.buildStickerGrid()
            this.buildActionButtons()
            if (this.errorMessage.size > 0) {
                this.buildErrorBanner()
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    private func buildHeaderInfo(): Unit {
        Row {
            Column {
                Text(if (this.packTitle.size > 0) { this.packTitle } else { "New Sticker Pack" })
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF000000)
                    .maxLines(1)
                    .textOverflow(TextOverflow.Ellipsis)
                Text(this.getStickerCountLabel())
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
    private func buildNameInput(): Unit {
        Column {
            Text("Sticker Pack Name")
                .fontSize(13)
                .fontColor(0xFF8E8E93)
                .margin(bottom: 6)
                .width(100.percent)
            TextInput(text: this.inputPackTitle)
                .fontSize(15)
                .fontColor(0xFF000000)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(8)
                .height(44)
                .width(100.percent)
                .onChange({ value: String =>
                    this.inputPackTitle = value
                })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 12)
        .backgroundColor(0xFFF2F2F7)
    }

    @Builder
    private func buildStickerGrid(): Unit {
        if (this.stickerUris.size == 0) {
            Column {
                Text("No stickers selected")
                    .fontSize(15)
                    .fontColor(0xFF8E8E93)
                    .textAlign(TextAlign.Center)
            }
            .width(100.percent)
            .height(120)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(0xFFFFFFFF)
            .margin(bottom: 12)
        } else {
            Grid() {
                ForEach(
                    this.stickerUris,
                    itemGeneratorFunc: { uri: String, idx: Int64 =>
                        GridItem() {
                            Column {
                                if (uri.size > 0) {
                                    Image(uri)
                                        .width(64)
                                        .height(64)
                                        .objectFit(ImageFit.Contain)
                                        .borderRadius(8)
                                } else {
                                    Column {
                                        Text(if (idx < Int64(this.stickerEmojis.size)) {
                                            this.stickerEmojis[idx]
                                        } else {
                                            "🎭"
                                        })
                                            .fontSize(32)
                                            .textAlign(TextAlign.Center)
                                    }
                                    .width(64)
                                    .height(64)
                                    .justifyContent(FlexAlign.Center)
                                    .alignItems(HorizontalAlign.Center)
                                    .backgroundColor(0xFFF2F2F7)
                                    .borderRadius(8)
                                }
                            }
                            .width(100.percent)
                            .height(80)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .border(width: 1, color: 0xFFE5E5EA)
                            .borderRadius(10)
                            .onTouch({ evt =>
                                match (evt.eventType) {
                                    case TouchType.Down =>
                                        launch { this.touchDownTime = evt.timestamp }
                                    case TouchType.Up =>
                                        let duration = evt.timestamp - this.touchDownTime
                                        if (duration > 500_000_000) {
                                            Hilog.info(0, "CjTelegram", "[ImportStickerPackPage] long press remove sticker")
                                            launch { this.doRemoveSticker(idx) }
                                        }
                                        launch { this.touchDownTime = 0 }
                                    case TouchType.Cancel =>
                                        launch { this.touchDownTime = 0 }
                                    case _ => ()
                                }
                            })
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
    }

    @Builder
    private func buildActionButtons(): Unit {
        Column {
            Button(this.getCreateButtonLabel())
                .fontSize(17)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(this.getCreateButtonColor())
                .borderRadius(12)
                .height(50)
                .width(100.percent)
                .enabled(!this.isUploading)
                .onClick({ _ =>
                    this.doCreate()
                })
            Button(trSource("Cancel"))
                .fontSize(17)
                .fontColor(0xFF007AFF)
                .backgroundColor(0xFFFFFFFF)
                .borderRadius(12)
                .height(50)
                .width(100.percent)
                .margin(top: 10)
                .onClick({ _ =>
                    routerPop()
                })
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 12, bottom: 24)
    }

    @Builder
    private func buildErrorBanner(): Unit {
        Row {
            Text(this.errorMessage)
                .fontSize(13)
                .fontColor(0xFFFF3B30)
                .textAlign(TextAlign.Center)
                .width(100.percent)
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 8, bottom: 8)
        .backgroundColor(0xFFFFF2F2)
    }
}
