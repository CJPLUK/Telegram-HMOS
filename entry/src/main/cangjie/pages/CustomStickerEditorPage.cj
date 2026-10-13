package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.components.StickerGridCell

/**
 * 聊天内自定义贴纸编辑器。
 *
 * 对齐 iOS MediaEditorScreenImpl(.stickerEditor)：相册素材进入独立编辑页；裁剪、旋转、
 * 涂鸦和纯色背景抠除都会生成真实 WebP；完成后提供发送、收藏、加入已有包、创建新包。
 * 处理和上传都在后台线程执行，UI 只发布状态。
 */
@HybridComponentEntry
@Component
public class CustomStickerEditorPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var sourcePath: String = ""
    @State var currentPath: String = ""
    @State var previousPath: String = ""
    @State var peerType: String = "user"
    @State var peerId: Int64 = 0
    @State var emoji: String = "🎭"
    @State var isProcessing: Bool = false
    @State var errorMessage: String = ""
    @State var showActions: Bool = false
    @State var showPackPicker: Bool = false
    @State var installedPacks: Array<StickerPackInfo> = Array<StickerPackInfo>(0, repeat: StickerPackInfo())
    @State var loaded: Bool = false
    private var awaitingEditResult: Bool = false

    private func ensureLoaded(): Unit {
        if (!this.loaded) {
            this.loaded = true
            let raw = takePending("CustomStickerEditorPage")
            let parts = this.splitParam(raw)
            if (parts.size >= 3) {
                this.peerType = parts[0]
                this.peerId = parseCustomStickerPeerId(parts[1])
                this.sourcePath = parts[2]
                this.currentPath = parts[2]
            }
            this.loadInstalledPacks()
        }
    }

    /**
     * NavDestination 返回时组件不会再次触发 onAppear；以重新可见作为编辑结果交接点。
     * 这与项目中 LocationPage 接收子页选择结果的生命周期策略一致。
     */
    private func consumePendingEditResult(): Unit {
        if (!this.awaitingEditResult) { return }
        this.awaitingEditResult = false
        match (getDrawingFlattenService().getLastResult()) {
            case Some(pixelMap) =>
                let oldPath = this.currentPath
                getDrawingFlattenService().clearLastResult()
                this.isProcessing = true
                let _ = spawn {
                    let path = getImageCompressionService().prepareStaticStickerPixelMapWebP(pixelMap)
                    launch {
                        this.isProcessing = false
                        if (!path.isEmpty()) {
                            this.previousPath = oldPath
                            this.currentPath = path
                        } else {
                            this.errorMessage = "Could not apply the edit"
                        }
                    }
                }
            case None => ()
        }
    }

    private func splitParam(raw: String): Array<String> {
        let result = ArrayList<String>()
        let runes = raw.toRuneArray()
        var segment = ArrayList<Rune>()
        var separators: Int64 = 0
        for (rune in runes) {
            if (rune == r'|' && separators < 2) {
                result.add(String(segment.toArray()))
                segment = ArrayList<Rune>()
                separators = separators + 1
            } else {
                segment.add(rune)
            }
        }
        result.add(String(segment.toArray()))
        return result.toArray()
    }

    private func loadInstalledPacks(): Unit {
        let cached = getStickersService().getCachedAllStickers().packs.toArray()
        if (!cached.isEmpty()) { this.installedPacks = cached }
        let _ = spawn {
            let packs = getStickersService().getAllStickers().packs.toArray()
            launch { this.installedPacks = packs }
        }
    }

    private func openCrop(): Unit {
        getDrawingFlattenService().clearLastResult()
        this.awaitingEditResult = true
        routerPush("CropEditorScreen", this.currentPath)
    }

    private func openDrawing(): Unit {
        getDrawingFlattenService().clearLastResult()
        this.awaitingEditResult = true
        routerPush("DrawingScreen", this.currentPath)
    }

    private func applyCutout(): Unit {
        if (this.isProcessing) { return }
        this.isProcessing = true
        this.errorMessage = ""
        let input = this.currentPath
        let _ = spawn {
            let output = getImageCompressionService().prepareCutoutStickerWebP(input)
            launch {
                this.isProcessing = false
                if (output.isEmpty()) {
                    this.errorMessage = "Background removal works best on a clear, flat background"
                } else {
                    this.previousPath = input
                    this.currentPath = output
                }
            }
        }
    }

    private func undoLastEdit(): Unit {
        if (this.previousPath.isEmpty()) { return }
        let old = this.currentPath
        this.currentPath = this.previousPath
        this.previousPath = old
    }

    /** ArkUI 的本地 Image source 必须是 file URI；相册桥接返回的是纯沙箱路径。 */
    private func previewUri(): String {
        if (this.currentPath.isEmpty() || this.currentPath.startsWith("file://")) {
            return this.currentPath
        }
        return "file://" + this.currentPath
    }

    private func normalizedStickerPath(): String {
        if (this.currentPath.endsWith(".webp")) { return this.currentPath }
        return getImageCompressionService().prepareStaticStickerWebP(this.currentPath)
    }

    private func inputItemFromPath(path: String): StickerSetInputItem {
        let item = StickerSetInputItem()
        var rawPath = path
        if (rawPath.startsWith("file://")) { rawPath = rawPath[7..] }
        item.documentBytes = readFileBytes(rawPath)
        item.fileName = "custom_sticker.webp"
        item.mimeType = "image/webp"
        item.emoji = if (this.emoji.isEmpty()) { "🎭" } else { this.emoji }
        return item
    }

    private func performStandaloneAction(action: String): Unit {
        if (this.isProcessing) { return }
        this.showActions = false
        this.isProcessing = true
        this.errorMessage = ""
        let peerType = this.peerType
        let peerId = this.peerId
        let _ = spawn {
            let path = this.normalizedStickerPath()
            if (path.isEmpty()) {
                launch {
                    this.isProcessing = false
                    this.errorMessage = "Could not prepare this sticker"
                }
                return
            }
            let item = this.inputItemFromPath(path)
            if (item.documentBytes.isEmpty()) {
                launch {
                    this.isProcessing = false
                    this.errorMessage = "Could not read this sticker"
                }
                return
            }
            let sticker = getStickerPackAuthorService().uploadStandaloneSticker(item)
            var success = sticker.documentId != 0
            if (success && action == "send") {
                success = getStickersService().sendSticker(peerType, peerId, sticker).success
            } else if (success && action == "favorite") {
                success = getStickersService().faveSticker(sticker)
            }
            let finalSuccess = success
            launch {
                this.isProcessing = false
                if (finalSuccess) {
                    routerPop()
                } else {
                    this.errorMessage = "Sticker upload failed. Please try again."
                }
            }
        }
    }

    private func addToPack(pack: StickerPackInfo): Unit {
        if (this.isProcessing) { return }
        this.showPackPicker = false
        this.isProcessing = true
        let selected = pack
        let _ = spawn {
            let path = this.normalizedStickerPath()
            let item = this.inputItemFromPath(path)
            let result = getStickerPackAuthorService().addStickerToSet(
                selected.id, selected.accessHash, item)
            launch {
                this.isProcessing = false
                if (result.success) {
                    routerPop()
                } else {
                    this.errorMessage = "Could not add the sticker to ${selected.title}"
                }
            }
        }
    }

    private func createNewPack(): Unit {
        this.showPackPicker = false
        let _ = spawn {
            let path = this.normalizedStickerPath()
            launch {
                if (!path.isEmpty()) {
                    routerPush("ImportStickerPackPage", "New Sticker Pack|" + path)
                }
            }
        }
    }

    public func build() {
        Stack(alignContent: Alignment.Bottom) {
            Column {
                Row {
                    Button(trSource("Cancel"))
                        .fontSize(15)
                        .fontColor(0xFFFFFF)
                        .backgroundColor(Color.Transparent)
                        .onClick({ _evt => routerPop() })
                    Blank()
                    Text(trSource("Sticker"))
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                    Blank()
                    Button(trSource("Done"))
                        .fontSize(15)
                        .fontColor(0x58A6FF)
                        .backgroundColor(Color.Transparent)
                        .enabled(!this.isProcessing)
                        .onClick({ _evt => this.showActions = true })
                }
                .width(100.percent)
                .height(52)
                .padding(left: 8, right: 8)
                .alignItems(VerticalAlign.Center)

                Stack(alignContent: Alignment.Center) {
                    if (!this.currentPath.isEmpty()) {
                        Image(this.previewUri())
                            .width(88.percent)
                            .height(88.percent)
                            .objectFit(ImageFit.Contain)
                    }
                    if (this.isProcessing) {
                        Column { LoadingProgress().width(34).height(34).color(0xFFFFFF) }
                            .width(100.percent).height(100.percent)
                            .backgroundColor(0x55000000)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                    }
                }
                .layoutWeight(1)
                .width(100.percent)

                if (!this.errorMessage.isEmpty()) {
                    Text(this.errorMessage)
                        .fontSize(12)
                        .fontColor(0xFFFF6B6B)
                        .padding(left: 16, right: 16, bottom: 6)
                        .textAlign(TextAlign.Center)
                }

                Row {
                    Text("Related emoji")
                        .fontSize(13)
                        .fontColor(0xA8A8AD)
                    TextInput(text: this.emoji)
                        .width(70)
                        .height(36)
                        .fontSize(22)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(0xFF2A2A2D)
                        .borderRadius(10)
                        .margin(left: 10)
                        .onChange({ value: String => this.emoji = value })
                }
                .height(46)
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)

                Row {
                    this.toolButton("✨", "Cut Out", "cutout")
                    this.toolButton("▣", "Crop", "crop")
                    this.toolButton("✎", "Draw", "draw")
                    this.toolButton("↶", "Undo", "undo")
                }
                .width(100.percent)
                .height(76)
                .backgroundColor(0xFF1C1C1E)
                .justifyContent(FlexAlign.SpaceEvenly)
            }
            .width(100.percent)
            .height(100.percent)
            .backgroundColor(0xFF000000)
            .onVisibleAreaChange([0.0, 1.0], { isVisible: Bool, ratio: Float64 =>
                if (isVisible && ratio > 0.9) { this.consumePendingEditResult() }
            })

            if (this.showActions || this.showPackPicker) {
                Column {}
                    .width(100.percent)
                    .height(100.percent)
                    .backgroundColor(0x66000000)
                    .onClick({ _evt =>
                        this.showActions = false
                        this.showPackPicker = false
                    })
                if (this.showPackPicker) { this.packPickerSheet() } else { this.actionSheet() }
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }

    @Builder
    func toolButton(icon: String, title: String, action: String) {
        Column {
            Text(icon).fontSize(23).fontColor(0xFFFFFF)
            Text(title).fontSize(11).fontColor(0xD1D1D6).margin(top: 3)
        }
        .width(76)
        .height(64)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .opacity(if (action == "undo" && this.previousPath.isEmpty()) { 0.35 } else { 1.0 })
        .onClick({ _evt =>
            if (action == "cutout") { this.applyCutout() }
            else if (action == "crop") { this.openCrop() }
            else if (action == "draw") { this.openDrawing() }
            else { this.undoLastEdit() }
        })
    }

    @Builder
    func actionSheet() {
        Column {
            Text(trSource("Send")).fontSize(17).fontColor(0x317AFF).height(54).width(100.percent)
                .textAlign(TextAlign.Center).onClick({ _evt => this.performStandaloneAction("send") })
            Divider().color(0xE5E5EA).strokeWidth(0.5)
            Text(trSource("Add to Favorites")).fontSize(17).fontColor(0x317AFF).height(54).width(100.percent)
                .textAlign(TextAlign.Center).onClick({ _evt => this.performStandaloneAction("favorite") })
            Divider().color(0xE5E5EA).strokeWidth(0.5)
            Text("Add to Sticker Pack").fontSize(17).fontColor(0x317AFF).height(54).width(100.percent)
                .textAlign(TextAlign.Center).onClick({ _evt =>
                    this.showActions = false
                    this.showPackPicker = true
                })
            Text(trSource("Cancel")).fontSize(17).fontWeight(FontWeight.Medium).height(54).width(100.percent)
                .textAlign(TextAlign.Center).margin(top: 8).onClick({ _evt => this.showActions = false })
        }
        .width(94.percent)
        .padding(top: 4, bottom: 4)
        .backgroundColor(0xF7FFFFFF)
        .borderRadius(16)
        .margin(bottom: 18)
    }

    @Builder
    func packPickerSheet() {
        Column {
            Text("Add to Sticker Pack")
                .fontSize(17).fontWeight(FontWeight.Bold).height(48)
            Scroll {
                Column {
                    Row {
                        Text("+").fontSize(26).fontColor(0x317AFF).width(48).textAlign(TextAlign.Center)
                        Text("Create New Pack").fontSize(16).layoutWeight(1)
                    }
                    .width(100.percent).height(52).onClick({ _evt => this.createNewPack() })
                    ForEach(this.installedPacks, itemGenerator: { pack: StickerPackInfo, _idx: Int64 =>
                        Row {
                            if (pack.cover.documentId != 0) {
                                StickerGridCell(item: pack.cover, size: 40.0)
                            } else {
                                Column {}.width(40).height(40)
                            }
                            Column {
                                Text(pack.title).fontSize(15).maxLines(1)
                                Text("${pack.count} stickers").fontSize(12).fontColor(0x8E8E93)
                            }
                            .layoutWeight(1).alignItems(HorizontalAlign.Start).margin(left: 10)
                        }
                        .width(100.percent).height(58).padding(left: 12, right: 12)
                        .onClick({ _evt => this.addToPack(pack) })
                    })
                }
            }
            .height(300)
            Text(trSource("Cancel")).fontSize(17).fontColor(0x317AFF).height(50).width(100.percent)
                .textAlign(TextAlign.Center).onClick({ _evt => this.showPackPicker = false })
        }
        .width(94.percent)
        .backgroundColor(0xF7FFFFFF)
        .borderRadius(16)
        .margin(bottom: 18)
    }
}

/** 避免 Hybrid 宏展开后 Int64.parse 与 ArkUI 同名类型冲突。 */
private func parseCustomStickerPeerId(value: String): Int64 {
    var result: Int64 = 0
    var negative = false
    let runes = value.toRuneArray()
    var index: Int64 = 0
    if (!runes.isEmpty() && runes[0] == r'-') {
        negative = true
        index = 1
    }
    while (index < Int64(runes.size)) {
        let digit = UInt32(runes[index])
        if (digit < 48u32 || digit > 57u32) { return 0 }
        result = result * 10 + Int64(digit - 48u32)
        index = index + 1
    }
    return if (negative) { -result } else { result }
}
