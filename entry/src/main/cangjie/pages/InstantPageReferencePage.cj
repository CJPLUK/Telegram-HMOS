package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * InstantPageReferencePage — Instant View gallery/reference sub-page
 *
 * Renders a reference or gallery view for an Instant View article.
 * Corresponds to InstantPageReferenceController + InstantPageGalleryController (iOS).
 *
 * Receives state via @State fields (set before push by caller):
 *   referenceText  — anchor caption / reference text
 *   sourceUrl      — original article URL
 *   galleryItems   — comma-separated list of image captions (optional)
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title/.hideTitleBar 一并去掉），只留内部 Column
 *  - aboutToAppear 有实逻辑（loadReferenceContent）→ ensureLoaded()（.onAppear 触发）
 */
@HybridComponentEntry
@Component
public class InstantPageReferencePage {
    @State var referenceText: String = ""
    @State var sourceUrl: String = ""
    @State var galleryItems: String = ""
    @State var isLoading: Bool = true
    @State var blocks: ArrayList<InstantPageBlock> = ArrayList<InstantPageBlock>()
    @State var currentGalleryIndex: Int64 = 0
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.loadReferenceContent()
    }

    func loadReferenceContent(): Unit {
        let refText = this.referenceText
        let _ = spawn {
            let svc = getInstantPageService()
            let blks = svc.buildReferenceBlocks(refText)
            launch {
                this.blocks = blks
                this.isLoading = false
            }
        }
    }

    private func blockCount(): Int64 {
        return this.blocks.size
    }

    private func blockAt(i: Int64): InstantPageBlock {
        return this.blocks[i]
    }

    private func blockFontSizeForKind(kind: InstantPageBlockKind): Int64 {
        return match (kind) {
            case InstantPageBlockKind.Subheader => 18
            case _ => 16
        }
    }

    private func blockWeightForKind(kind: InstantPageBlockKind): FontWeight {
        return match (kind) {
            case InstantPageBlockKind.Subheader => FontWeight.Bold
            case _ => FontWeight.Normal
        }
    }

    private func parseGalleryItems(): ArrayList<String> {
        let items = ArrayList<String>()
        if (this.galleryItems.size == 0) { return items }
        var current = ""
        for (ch in this.galleryItems.toRuneArray()) {
            if (ch == r',') {
                if (current.size > 0) {
                    items.add(current)
                    current = ""
                }
            } else {
                current = current + String(ch)
            }
        }
        if (current.size > 0) { items.add(current) }
        return items
    }

    private func galleryItemCount(): Int64 {
        return this.parseGalleryItems().size
    }

    private func galleryCurrentCaption(): String {
        let gItems = this.parseGalleryItems()
        if (gItems.size == 0) { return "" }
        if (this.currentGalleryIndex < gItems.size) {
            return gItems[this.currentGalleryIndex]
        }
        return ""
    }

    private func galleryMaxIndex(): Int64 {
        let cnt = this.galleryItemCount()
        if (cnt > 0) { return cnt - 1 }
        return 0
    }

    private func hasGallery(): Bool {
        return this.galleryItemCount() > 0
    }

    private func hasSourceUrl(): Bool {
        return this.sourceUrl.size > 0
    }

    @Builder
    func gallerySection() {
        if (this.hasGallery()) {
            Column {
                Row {
                    Text("[Gallery Image]")
                        .fontSize(14)
                        .fontColor(0x888888)
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent)
                .height(200)
                .backgroundColor(0xF5F5F5)
                .justifyContent(FlexAlign.Center)

                Row {
                    Button("<")
                        .onClick({ _ =>
                            if (this.currentGalleryIndex > 0) {
                                this.currentGalleryIndex = this.currentGalleryIndex - 1
                            }
                        })
                        .width(40)
                        .height(40)

                    Text(this.galleryCurrentCaption())
                        .fontSize(13)
                        .fontColor(0x444444)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)

                    Button(">")
                        .onClick({ _ =>
                            if (this.currentGalleryIndex < this.galleryMaxIndex()) {
                                this.currentGalleryIndex = this.currentGalleryIndex + 1
                            }
                        })
                        .width(40)
                        .height(40)
                }
                .width(100.percent)
                .padding(left: 8, right: 8, top: 8)

                Text("${this.currentGalleryIndex + 1} / ${this.galleryItemCount()}")
                    .fontSize(12)
                    .fontColor(0x888888)
                    .textAlign(TextAlign.Center)
                    .margin(top: 4, bottom: 8)
            }
            .width(100.percent)
            .margin(bottom: 16)
        }
    }

    @Builder
    func sourceUrlSection() {
        if (this.hasSourceUrl()) {
            Row {
                Text("Open original article")
                    .fontSize(14)
                    .fontColor(0x2563EB)
                    .decoration(decorationType: TextDecorationType.Underline, color: 0x2563EB)
            }
            .width(100.percent)
            .margin(top: 24)
            .onClick({ _ =>
                let _ = spawn {
                    Hilog.info(0, "CjTelegram", "[InstantPageRef] open original url")
                }
            })
        }
    }

    public func build() {
        Column {
            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                    Text("Loading reference...")
                        .fontSize(14)
                        .fontColor(0x888888)
                        .margin(top: 12)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                Scroll() {
                    Column {
                        this.gallerySection()
                        Divider()
                            .color(0xE0E0E0)
                            .strokeWidth(1)
                            .margin(bottom: 12)
                        ForEach(Array<InstantPageBlock>(this.blockCount(), {
                            i: Int64 => this.blockAt(i)
                        }), itemGenerator: {
                            blk: InstantPageBlock, _: Int64 =>
                                Row {
                                    Text(blk.text)
                                        .fontSize(this.blockFontSizeForKind(blk.kind))
                                        .fontWeight(this.blockWeightForKind(blk.kind))
                                        .fontColor(0x222222)
                                        .width(100.percent)
                                        .textAlign(TextAlign.Start)
                                }
                                .width(100.percent)
                                .padding(top: 6, bottom: 6)
                        })
                        this.sourceUrlSection()
                    }
                    .width(100.percent)
                    .padding(left: 16, right: 16, top: 12, bottom: 24)
                }
                .width(100.percent)
                .layoutWeight(1)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .onAppear({ => this.ensureLoaded() })
    }
}
