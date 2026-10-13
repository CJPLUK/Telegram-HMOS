package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.collection.ArrayList
import std.unicode.*
import ohos_app_cangjie_entry.app.getSafeAreaTop
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{StickerItem, StickerPackInfo, getStickersService, getShareControllerService, showToast}

@HybridComponentEntry
@Component
public class EmojiStickerPacksPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var packs: Array<StickerPackInfo> = Array<StickerPackInfo>()
    @State var packCovers: Array<StickerItem> = Array<StickerItem>()
    @State var loading: Bool = true
    @State var suggestAnimatedEmoji: Bool = true
    @State var loaded: Bool = false
    @State var editing: Bool = false
    @State var selectedPackIds: Array<Int64> = Array<Int64>()
    @State var operating: Bool = false
    @State var dragFromIdx: Int64 = -1
    @State var dragStartScreenY: Float64 = 0.0
    @State var dragMoved: Bool = false
    @State var archivedCount: Int32 = 0
    @State var loadingArchived: Bool = true

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let _ = spawn {
            let service = getStickersService()
            let result = service.getEmojiStickers()
            let values = ArrayList<StickerPackInfo>()
            if (result.success) {
                for (pack in result.packs) { values.add(pack) }
            }
            let array = values.toArray()
            let initialCovers = Array<StickerItem>(array.size, { index: Int64 => array[index].cover })
            let suggest = service.readLocalSetting("stickers_suggest_anim_emoji")
            launch {
                if (result.success) { this.packs = array; this.packCovers = initialCovers }
                this.suggestAnimatedEmoji = suggest
                this.loading = false
            }
            let resolvedCovers = ArrayList<StickerItem>()
            for (pack in array) {
                var cover = pack.cover
                if (cover.documentId == 0) {
                    let detail = service.getStickerSet(pack.id, pack.accessHash)
                    if (detail.success && !detail.stickers.isEmpty()) { cover = detail.stickers[0] }
                }
                resolvedCovers.add(cover)
            }
            launch { if (result.success) { this.packCovers = resolvedCovers.toArray() } }
        }
        let _ = spawn {
            let archived = getStickersService().getArchivedStickers(emojis: true)
            launch {
                if (archived.success) { this.archivedCount = Int32(archived.packs.size) }
                this.loadingArchived = false
            }
        }
    }

    private func setSuggestAnimatedEmoji(value: Bool): Unit {
        this.suggestAnimatedEmoji = value
        let _ = spawn {
            getStickersService().persistLocalSetting("stickers_suggest_anim_emoji", value)
        }
    }

    private func openPack(pack: StickerPackInfo): Unit {
        let param = pack.id.toString() + "|" + pack.accessHash.toString() + "|" + pack.shortName
        setPending("StickerPackPreviewPage", param)
        routerPush("StickerPackPreviewPage")
    }

    private func isSelected(packId: Int64): Bool {
        for (id in this.selectedPackIds) { if (id == packId) { return true } }
        return false
    }

    private func toggleSelected(packId: Int64): Unit {
        let values = ArrayList<Int64>()
        var found = false
        for (id in this.selectedPackIds) {
            if (id == packId) { found = true } else { values.add(id) }
        }
        if (!found) { values.add(packId) }
        this.selectedPackIds = values.toArray()
    }

    private func finishEditing(): Unit {
        this.editing = false
        this.selectedPackIds = Array<Int64>()
    }

    private func operateSelected(archive: Bool): Unit {
        if (this.selectedPackIds.isEmpty() || this.operating) { return }
        let ids = ArrayList<Int64>()
        let hashes = ArrayList<Int64>()
        for (pack in this.packs) {
            if (this.isSelected(pack.id)) { ids.add(pack.id); hashes.add(pack.accessHash) }
        }
        if (ids.isEmpty()) { return }
        this.operating = true
        let _ = spawn {
            let service = getStickersService()
            if (archive) {
                let _ = service.toggleStickerSets(ids, hashes, true)
            } else {
                var index: Int64 = 0
                while (index < ids.size) {
                    let _ = service.uninstallStickerSet(ids[index], hashes[index])
                    index = index + 1
                }
            }
            let refreshed = service.getEmojiStickers()
            let values = refreshed.packs.toArray()
            launch {
                if (refreshed.success) { this.packs = values }
                this.operating = false
                this.finishEditing()
            }
        }
    }

    private func confirmSelectedOperation(archive: Bool): Unit {
        let count = this.selectedPackIds.size
        if (count == 0 || this.operating) { return }
        let noun = if (count == 1) { "Emoji Pack" } else { "Emoji Packs" }
        let action = if (archive) { "Archive" } else { "Delete" }
        let operation = SheetInfo(
            title: "${action} ${count} ${noun}",
            action: { => this.operateSelected(archive) }
        )
        let cancel = ActionSheetButtonOptions(value: "Cancel", action: { => () })
        getUIContext().showActionSheet(ActionSheetOptions(
            title: None,
            message: None,
            confirm: cancel,
            sheets: [operation],
            autoCancel: true
        ))
    }

    private func shareSelected(): Unit {
        var links = ""
        for (pack in this.packs) {
            if (this.isSelected(pack.id) && !pack.shortName.isEmpty()) {
                if (!links.isEmpty()) { links = links + "\n" }
                links = links + "https://t.me/addemoji/" + pack.shortName
            }
        }
        if (!links.isEmpty()) { let _ = getShareControllerService().shareInviteLinkViaSystem(links) }
    }

    private func movePack(fromIdx: Int64, toIdx: Int64): Unit {
        let oldPacks = this.packs
        let oldCovers = this.packCovers
        let size = oldPacks.size
        if (fromIdx < 0 || toIdx < 0 || fromIdx >= size || toIdx >= size || fromIdx == toIdx) { return }
        let packBuffer = ArrayList<StickerPackInfo>()
        let coverBuffer = ArrayList<StickerItem>()
        for (pack in oldPacks) { packBuffer.add(pack) }
        let canMoveCover = oldCovers.size == size
        if (canMoveCover) { for (cover in oldCovers) { coverBuffer.add(cover) } }
        let movedPack = packBuffer[fromIdx]
        if (fromIdx < toIdx) {
            var index = fromIdx
            while (index < toIdx) {
                packBuffer[index] = packBuffer[index + 1]
                index = index + 1
            }
        } else {
            var index = fromIdx
            while (index > toIdx) {
                packBuffer[index] = packBuffer[index - 1]
                index = index - 1
            }
        }
        packBuffer[toIdx] = movedPack
        if (canMoveCover) {
            let movedCover = coverBuffer[fromIdx]
            if (fromIdx < toIdx) {
                var index = fromIdx
                while (index < toIdx) {
                    coverBuffer[index] = coverBuffer[index + 1]
                    index = index + 1
                }
            } else {
                var index = fromIdx
                while (index > toIdx) {
                    coverBuffer[index] = coverBuffer[index - 1]
                    index = index - 1
                }
            }
            coverBuffer[toIdx] = movedCover
        }
        this.packs = packBuffer.toArray()
        if (canMoveCover) { this.packCovers = coverBuffer.toArray() }
        let order = ArrayList<Int64>()
        for (pack in packBuffer) { order.add(pack.id) }
        let _ = spawn {
            let service = getStickersService()
            let success = service.reorderStickerSets(order, emojis: true)
            if (success) {
                service.persistLocalSetting("stickers_dynamic_pack_order", false)
                launch { showToast("Dynamic Pack Order Turned Off") }
            } else {
                launch { this.packs = oldPacks; this.packCovers = oldCovers }
            }
        }
    }

    private func handlePackReorderTouch(event: TouchEvent, index: Int64): Unit {
        match (event.eventType) {
            case TouchType.Down =>
                if (event.touches.size > 0) {
                    this.dragFromIdx = index
                    this.dragStartScreenY = event.touches[0].screenY
                    this.dragMoved = false
                }
            case TouchType.Move =>
                if (this.dragFromIdx == index && event.touches.size > 0) {
                    let delta = event.touches[0].screenY - this.dragStartScreenY
                    if (delta > 12.0 || delta < -12.0) { this.dragMoved = true }
                }
            case TouchType.Up =>
                if (this.dragFromIdx == index && event.changedTouches.size > 0) {
                    let delta = event.changedTouches[0].screenY - this.dragStartScreenY
                    var rowOffset: Int64 = 0
                    if (delta >= 90.0) { rowOffset = Int64((delta + 90.0) / 180.0) }
                    else if (delta <= -90.0) { rowOffset = Int64((delta - 90.0) / 180.0) }
                    var target = index + rowOffset
                    if (target < 0) { target = 0 }
                    if (target >= Int64(this.packs.size)) { target = Int64(this.packs.size) - 1 }
                    if (this.dragMoved && target != index) { this.movePack(index, target) }
                }
                this.dragFromIdx = -1
                this.dragMoved = false
            case TouchType.Cancel =>
                this.dragFromIdx = -1
                this.dragMoved = false
            case _ => ()
        }
    }

    @Builder
    func packRow(pack: StickerPackInfo, index: Int64) {
        Row {
            Row {
                if (this.editing) {
                    Stack(alignContent: Alignment.Center) {
                        if (this.isSelected(pack.id)) {
                            Text("✓").fontSize(16).fontColor(0xFFFFFFFF)
                        }
                    }
                    .width(28).height(28).borderRadius(14)
                    .backgroundColor(if (this.isSelected(pack.id)) { this.presentation.accentColor } else { Color.Transparent })
                    .border(width: if (this.isSelected(pack.id)) { 0.0 } else { 1.5 }, color: this.presentation.secondaryTextColor)
                    .margin(right: 8)
                }
                if (index < Int64(this.packCovers.size) && this.packCovers[index].documentId != 0) {
                    StickerGridCell(item: this.packCovers[index], size: 44.0)
                } else {
                    Column {
                        Text(if (pack.title.isEmpty()) { "E" } else { pack.title.toRuneArray()[0].toString() })
                            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.presentation.accentColor)
                    }
                    .width(44).height(44).borderRadius(10).backgroundColor(this.presentation.backgroundColor)
                    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                }
                Column {
                    Text(pack.title).fontSize(17).fontWeight(FontWeight.Medium)
                        .fontColor(this.presentation.textColor).maxLines(1)
                    Text("${pack.count} emoji").fontSize(15)
                        .fontColor(this.presentation.secondaryTextColor).margin(top: 1)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start).margin(left: 12)
            }
            .layoutWeight(1).height(60).alignItems(VerticalAlign.Center)
            .onClick({ _ =>
                if (this.editing) { this.toggleSelected(pack.id) } else { this.openPack(pack) }
            })
            if (this.editing) {
                Stack(alignContent: Alignment.Center) {
                    Text("☰").fontSize(20).fontColor(this.presentation.secondaryTextColor)
                }
                .width(44).height(60)
                .backgroundColor(if (this.dragFromIdx == index) { 0x12007AFF } else { Color.Transparent })
                .onTouch({ event: TouchEvent => this.handlePackReorderTouch(event, index) })
            }
        }
        .width(100.percent).height(60).padding(left: 12, right: 16)
        .alignItems(VerticalAlign.Center)
        if (index + 1 < Int64(this.packs.size)) { ItemListSeparator(leftInset: 72) }
    }

    @Builder
    func suggestionSectionContent() {
        ItemListToggleRow(
            title: "Suggest Animated Emoji",
            isOn: this.suggestAnimatedEmoji,
            onChange: { value => this.setSuggestAnimatedEmoji(value) }
        )
    }

    @Builder
    func editToolbar() {
        Row {
            Button("Delete").fontSize(16)
                .fontColor(if (this.selectedPackIds.isEmpty()) { this.presentation.secondaryTextColor } else { 0xFFFF3B30 })
                .height(44).backgroundColor(this.presentation.cardColor).borderRadius(22)
                .enabled(!this.selectedPackIds.isEmpty()).onClick({ _ => this.confirmSelectedOperation(false) })
            Blank().layoutWeight(1)
            Button("Archive").fontSize(16)
                .fontColor(if (this.selectedPackIds.isEmpty()) { this.presentation.secondaryTextColor } else { this.presentation.accentColor })
                .height(44).backgroundColor(this.presentation.cardColor).borderRadius(22)
                .enabled(!this.selectedPackIds.isEmpty()).onClick({ _ => this.confirmSelectedOperation(true) })
            Blank().layoutWeight(1)
            Button("Share").fontSize(16)
                .fontColor(if (this.selectedPackIds.isEmpty()) { this.presentation.secondaryTextColor } else { this.presentation.accentColor })
                .height(44).backgroundColor(this.presentation.cardColor).borderRadius(22)
                .enabled(!this.selectedPackIds.isEmpty()).onClick({ _ => this.shareSelected() })
        }
        .width(100.percent).height(72).padding(left: 20, right: 20)
        .backgroundColor(this.presentation.navBarColor)
    }

    public func build() {
        Column {
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back)).width(8).height(14)
                        .fillColor(this.presentation.accentColor).margin(right: 4)
                    Text("Back").fontSize(16).fontColor(this.presentation.accentColor)
                }.width(70).onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text("Emoji").fontSize(18).fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Text(if (this.editing) { "Done" } else { "Edit" })
                    .fontSize(16).fontColor(this.presentation.accentColor)
                    .width(70).textAlign(TextAlign.End)
                    .onClick({ _ => if (this.editing) { this.finishEditing() } else { this.editing = true } })
            }
            .width(100.percent).height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)

            Scroll {
                Column {
                    if (!this.loadingArchived && this.archivedCount > 0) {
                        Column {
                            ItemListDisclosureRow(
                                title: "Archived Emoji",
                                value: this.archivedCount.toString(),
                                icon: @r(app.media.settings_sticker_archived),
                                onClick: { => routerPush("ArchivedStickerPacksPage", "emoji") }
                            )
                        }
                        .backgroundColor(this.presentation.cardColor).borderRadius(10).clip(true)
                        .margin(left: 16, right: 16, top: 18)
                    }
                    Column { this.suggestionSectionContent() }
                        .backgroundColor(this.presentation.cardColor).borderRadius(10).clip(true)
                        .margin(left: 16, right: 16, top: if (!this.loadingArchived && this.archivedCount > 0) { 12 } else { 18 })
                    ItemListSectionFooter(
                        text: "Animated emoji suggestions appear as you type an emoji.", topPad: 7
                    )
                    if (this.loading) {
                        Column { LoadingProgress().width(28).height(28).color(this.presentation.accentColor) }
                            .height(100).width(100.percent).justifyContent(FlexAlign.Center)
                    } else if (!this.packs.isEmpty()) {
                        Column {
                            ForEach(this.packs, itemGenerator: { pack: StickerPackInfo, index: Int64 =>
                                this.packRow(pack, index)
                            })
                        }
                        .backgroundColor(this.presentation.cardColor).borderRadius(10).clip(true)
                        .margin(left: 16, right: 16, top: 20)
                    }
                    ItemListSectionFooter(
                        text: "Emoji packs can be reordered or removed from this list.", topPad: 8
                    )
                    Column {}.height(24)
                }.width(100.percent).height(100.percent)
            }.layoutWeight(1).scrollBar(BarState.Off)
            if (this.editing) { this.editToolbar() }
        }
        .width(100.percent).height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .onAppear({ => this.ensureLoaded() })
    }
}
