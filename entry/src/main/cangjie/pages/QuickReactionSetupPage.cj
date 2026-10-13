package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos.resource.__GenerateResource__
import std.convert.*
import ohos_app_cangjie_entry.app.getSafeAreaTop
import ohos_app_cangjie_entry.components.*
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{StickerItem, getStickersService}

@HybridComponentEntry
@Component
public class QuickReactionSetupPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var selectedReaction: String = "❤️"
    @State var pickerVisible: Bool = false
    @State var previewReacted: Bool = false

    private func loadSelection(): Unit {
        let _ = spawn {
            let value = getStickersService().readLocalStringSetting("quick_reaction", "❤️")
            launch { this.selectedReaction = value }
        }
    }

    private func selectReaction(value: String): Unit {
        if (value.isEmpty()) { return }
        this.selectedReaction = value
        this.pickerVisible = false
        this.previewReacted = true
        let _ = spawn {
            getStickersService().persistLocalStringSetting("quick_reaction", value)
        }
    }

    private func selectCustomReaction(item: StickerItem): Unit {
        if (item.documentId != 0) {
            this.selectReaction("custom|${item.documentId}|${item.altEmoji}")
        }
    }

    private func selectCustomReactionId(documentId: Int64): Unit {
        if (documentId != 0) { this.selectReaction("custom|${documentId}|🙂") }
    }

    private func customReactionId(): Int64 {
        if (!this.selectedReaction.startsWith("custom|")) { return 0 }
        let parts = this.selectedReaction.split("|")
        if (parts.size < 2) { return 0 }
        return try { Int64.parse(parts[1]) } catch (_: Exception) { 0 }
    }

    private func reactionLabel(): String {
        if (!this.selectedReaction.startsWith("custom|")) { return this.selectedReaction }
        let parts = this.selectedReaction.split("|")
        if (parts.size >= 3 && !parts[2].isEmpty()) { return parts[2] }
        return "🙂"
    }

    private func openPicker(): Unit {
        startNextQuickReactionExpanded()
        this.pickerVisible = true
    }

    @Builder
    func selectedReactionArtwork(size: Float64) {
        if (this.customReactionId() != 0) {
            CustomEmojiImage(
                documentId: this.customReactionId(), size: size,
                autoplay: true
            )
        } else {
            Text(this.reactionLabel()).fontSize(size)
        }
    }

    @Builder
    func previewCard() {
        Stack(alignContent: Alignment.Center) {
            Row {}
                .width(100.percent).height(116).borderRadius(20)
                .linearGradient(angle: 90.0, colors: [
                    (Color(0xFF9FE1D2), 0.0), (Color(0xFFAFC2F5), 1.0)
                ])
            Row {
                Text("I hope you're enjoying your day as much as I am.")
                    .fontSize(17).fontColor(0xFF000000).maxLines(2).layoutWeight(1)
                Text("19:20").fontSize(13).fontColor(0xFF8E8E93).alignSelf(ItemAlign.End)
            }
            .width(82.percent).constraintSize(minHeight: 66)
            .padding(left: 12, right: 12, top: 9, bottom: 9)
            .backgroundColor(0xFFFFFFFF).borderRadius(18)
            if (this.previewReacted) {
                Stack(alignContent: Alignment.Center) { this.selectedReactionArtwork(26.0) }
                    .width(36).height(36).position(x: 288, y: 80)
            }
        }
        .width(100.percent).height(116)
        .onClick({ _ => this.previewReacted = !this.previewReacted })
    }

    @Builder
    func pickerPanel() {
        Stack(alignContent: Alignment.TopEnd) {
            QuickReactionBar(
                onSelectReaction: { value: String => this.selectReaction(value) },
                onSelectCustomReaction: { documentId: Int64 => this.selectCustomReactionId(documentId) },
                onClose: { => this.pickerVisible = false },
                closeNativeContextMenu: false,
                embeddedInPopup: true
            )
        }
        .width(330).height(326)
    }

    @Builder
    func reactionSelectionRow() {
        Row {
            Text("Choose Your Quick Reaction").fontSize(17)
                .fontColor(this.presentation.textColor).layoutWeight(1)
            Stack(alignContent: Alignment.Center) { this.selectedReactionArtwork(27.0) }
                .width(34).height(34)
        }
        .width(100.percent).height(52).padding(left: 16, right: 16)
        .onClick({ _ => this.openPicker() })
        .bindPopup(
            this.pickerVisible,
            CustomPopupOptions(
                builder: bind(this.pickerPanel, this),
                placement: Placement.Bottom,
                popupColor: Color.Transparent,
                enableArrow: false,
                autoCancel: true,
                radius: 26.vp,
                onStateChange: Option.Some({ evt: PopupStateChangeParam =>
                    if (!evt.isVisible) { this.pickerVisible = false }
                })
            )
        )
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
                Text("Quick Reaction").fontSize(18).fontWeight(FontWeight.Bold)
                    .fontColor(this.presentation.textColor)
                Blank().layoutWeight(1)
                Row {}.width(70)
            }
            .width(100.percent).height(56.0 + getSafeAreaTop())
            .padding(left: 16, right: 16, top: getSafeAreaTop())
            .backgroundColor(this.presentation.navBarColor)

            Scroll {
                Column {
                    ItemListSectionHeader(title: "DOUBLE TAP ON A MESSAGE TO REACT", topPad: 20)
                    Row { this.previewCard() }.padding(left: 16, right: 16)
                    ItemListSectionFooter(
                        text: "You can double tap on message for a quick reaction.", topPad: 7
                    )

                    Column { this.reactionSelectionRow() }
                        .backgroundColor(this.presentation.cardColor).borderRadius(10).clip(true)
                        .margin(left: 16, right: 16, top: 20)
                    ItemListSectionFooter(
                        text: "You can set any emoji as your quick reaction.", topPad: 7
                    )
                    Column {}.height(24)
                }.width(100.percent).height(100.percent)
            }.layoutWeight(1).scrollBar(BarState.Off)
        }
        .width(100.percent).height(100.percent)
        .backgroundColor(this.presentation.backgroundColor)
        .onAppear({ => this.loadSelection() })
    }
}
