package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import ohos_app_cangjie_entry.app.getSafeAreaTop
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{StickerPackInfo, getStickersService}
import std.collection.ArrayList
import std.unicode.*

/** Source-equivalent archived sticker pack list reached from Stickers and Emoji. */
@HybridComponentEntry
@Component
public class ArchivedStickerPacksPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var packs: Array<StickerPackInfo> = Array<StickerPackInfo>()
    @State var loading: Bool = true
    @State var loadFailed: Bool = false
    @State var restoringId: Int64 = 0
    @State var loaded: Bool = false
    @State var mode: Int32 = 0

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let raw = takePending("ArchivedStickerPacksPage")
        if (raw == "emoji") { this.mode = 1 }
        else if (raw == "masks") { this.mode = 2 }
        this.loadPacks()
    }

    private func loadPacks(): Unit {
        this.loading = true
        this.loadFailed = false
        spawn {
            let result = getStickersService().getArchivedStickers(
                masks: this.mode == 2,
                emojis: this.mode == 1
            )
            let values = result.packs.toArray()
            spawn(UIThread) {
                =>
                this.packs = values
                this.loading = false
                this.loadFailed = !result.success
            }
        }
    }

    private func openPack(pack: StickerPackInfo): Unit {
        let param = pack.id.toString() + "|" + pack.accessHash.toString() + "|" + pack.shortName
        setPending("StickerPackPreviewPage", param)
        routerPush("StickerPackPreviewPage")
    }

    private func removePackFromList(packId: Int64): Unit {
        let values = ArrayList<StickerPackInfo>()
        for (pack in this.packs) {
            if (pack.id != packId) { values.add(pack) }
        }
        this.packs = values.toArray()
    }

    private func restorePack(pack: StickerPackInfo): Unit {
        if (this.restoringId != 0) { return }
        this.restoringId = pack.id
        let packId = pack.id
        let accessHash = pack.accessHash
        spawn {
            let success = getStickersService().installStickerSet(packId, accessHash, archived: false).success
            spawn(UIThread) {
                =>
                this.restoringId = 0
                if (success) { this.removePackFromList(packId) }
            }
        }
    }

    @Builder
    func buildPackRow(pack: StickerPackInfo, index: Int64) {
        Row {
            Stack {
                Column {}.width(44).height(44).borderRadius(10).backgroundColor(this.presentation.accentColor)
                Text(if (pack.title.size > 0) { pack.title.toRuneArray()[0].toString() } else { "S" })
                    .fontSize(20).fontWeight(FontWeight.Bold).fontColor(0xFFFFFFFF)
            }.width(44).height(44).margin(right: 12)
            Column {
                Text(pack.title).fontSize(17).fontColor(this.presentation.textColor).maxLines(1)
                Text("${pack.count} ${if (this.mode == 1) { "emoji" } else if (this.mode == 2) { "masks" } else { "stickers" }}")
                    .fontSize(14).fontColor(ITEM_LIST_TEXT_SECONDARY).margin(top: 2)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.restoringId == pack.id) {
                LoadingProgress().width(24).height(24).color(this.presentation.accentColor)
            } else {
                Button("Add")
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.presentation.accentColor)
                    .height(32)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _ => this.restorePack(pack) })
            }
        }
        .width(100.percent)
        .height(64)
        .padding(left: 16, right: 16)
        .alignItems(VerticalAlign.Center)
        .onClick({ _ => this.openPack(pack) })
        if (index + 1 < this.packs.size) { ItemListSeparator(leftInset: 72) }
    }

    public func build() {
        Column {
            Row {
                Row {
                    Image(@r(app.media.callui_v2_back)).width(8).height(14).fillColor(this.presentation.accentColor).margin(right: 4)
                    Text("Back").fontSize(16).fontColor(this.presentation.accentColor)
                }.onClick({ _ => routerPop() })
                Blank().layoutWeight(1)
                Text(if (this.mode == 1) { "Archived Emoji" } else if (this.mode == 2) { "Archived Masks" } else { "Archived Stickers" })
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row {}.width(60)
            }
            .width(100.percent)
            .height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.cardColor)
            .alignItems(VerticalAlign.Center)

            if (this.loading) {
                Column { LoadingProgress().width(30).height(30).color(this.presentation.accentColor) }
                    .layoutWeight(1).width(100.percent).justifyContent(FlexAlign.Center)
            } else if (this.loadFailed) {
                Column {
                    Text("Unable to load archived sticker packs").fontSize(15).fontColor(ITEM_LIST_TEXT_SECONDARY)
                    Button("Retry").margin(top: 12).onClick({ _ => this.loadPacks() })
                }.layoutWeight(1).width(100.percent).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            } else {
                Scroll {
                    Column {
                        ItemListSectionFooter(
                            text: if (this.mode == 1) {
                                "Emoji packs that you archive appear here. You can add them back at any time."
                            } else if (this.mode == 2) {
                                "Mask packs that you archive appear here. You can add them back at any time."
                            } else {
                                "Sticker packs that you archive appear here. You can add them back at any time."
                            },
                            topPad: 12
                        )
                        if (this.packs.size > 0) {
                            Column {
                                ForEach(this.packs, itemGenerator: { pack: StickerPackInfo, index: Int64 =>
                                    this.buildPackRow(pack, index)
                                })
                            }
                            .backgroundColor(this.presentation.cardColor)
                            .borderRadius(12)
                            .clip(true)
                            .margin(left: 16, right: 16, top: 8)
                        } else {
                            Text(if (this.mode == 1) { "No archived emoji packs" } else if (this.mode == 2) { "No archived mask packs" } else { "No archived sticker packs" })
                                .fontSize(15).fontColor(ITEM_LIST_TEXT_SECONDARY)
                                .width(100.percent).textAlign(TextAlign.Center).margin(top: 40)
                        }
                    }.width(100.percent).padding(bottom: 24)
                }.layoutWeight(1)
            }
        }
        .width(100.percent).height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .onAppear({ => this.ensureLoaded() })
    }
}
