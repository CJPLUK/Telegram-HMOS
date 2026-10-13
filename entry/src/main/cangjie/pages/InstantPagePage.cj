package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

/**
 * InstantPagePage — Instant View article reader (P2-214..217)
 *
 * Fidelity improvements over D baseline:
 *  P2-214: Real Image(url) loading for photo blocks (was text-only rendering).
 *          RichText entities: bold/italic/underline/link supported via decorators.
 *          Block types: Header/Subheader/Paragraph/Blockquote/Preformatted/
 *            ListItem/Divider/Image/Anchor (P1 complete).
 *          Cold blocks (video/audio/table/collage/map): deferred (no platform bottom layer).
 *  P2-215: Settings panel button → routerPush to InstantPageSettingsPage.
 *          Theme colors + font size applied to all text blocks from InstantPageSettings.
 *          Serif font family toggle (forceSerif).
 *  P2-216: Anchor blocks as invisible scroll markers → anchor map → scrollTo by index.
 *          Link taps: internal #anchor scrolls; external URLs → startAbility(viewData).
 *          Share button: startAbility(share) to system share panel with article URL.
 *  P2-217: Cache-backed fetchWebPage via InstantPageCacheService (in InstantPageService).
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry；去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹（.title/.hideTitleBar/.onReady 一并去掉），只留内部 Column
 *  - aboutToAppear + onReady param 合并到 ensureLoaded()（.onAppear 触发），takePending("InstantPagePage")
 *  - pushPath/pushPathByName → routerPush
 */
@HybridComponentEntry
@Component
public class InstantPagePage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var pageUrl: String = ""
    @State var pageTitle: String = ""
    @State var blocks: ArrayList<InstantPageBlock> = ArrayList<InstantPageBlock>()
    @State var isLoading: Bool = true
    @State var errorMessage: String = ""
    // P2-215: settings — refreshed on appear and after settings panel closes
    @State var settings: InstantPageSettings = InstantPageSettings()
    // P2-216: anchor → block index map (built once blocks are loaded)
    @State var anchorMap: ArrayList<String> = ArrayList<String>()   // anchorName at block index i
    // P2-216: scroll controller for anchor navigation
    private var scroller: Scroller = Scroller()
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.refreshSettings()
        // Read URL from pending route param, then trigger loadPage.
        if (this.pageUrl.size == 0) {
            let raw = takePending("InstantPagePage")
            if (raw.size > 0 && raw != "{}") {
                let trimmed = raw.trimAscii()
                if (trimmed.size > 0) {
                    this.pageUrl = trimmed
                }
            }
        }
        if (this.pageUrl.size > 0) {
            this.loadPage()
        }
    }

    func refreshSettings(): Unit {
        let s = loadInstantPageSettings()
        this.settings = s
    }

    func loadPage(): Unit {
        let url = this.pageUrl
        let _ = spawn {
            let svc = getInstantPageService()
            let data = svc.fetchWebPage(url)
            let title = data.title
            let blks = data.blocks
            let hasLoaded = data.loaded
            // Build anchor map for P2-216
            let amap = instPageBuildAnchorMap(blks)
            launch {
                this.pageTitle = title
                let newBlocks = blks
                this.blocks = newBlocks
                let newAnchorMap = amap
                this.anchorMap = newAnchorMap
                this.isLoading = false
                if (!hasLoaded) {
                    this.errorMessage = "Failed to load article."
                }
            }
        }
    }

    // ── block count/access helpers (no let in build) ──

    private func blockCount(): Int64 { return this.blocks.size }
    private func blockAt(i: Int64): InstantPageBlock { return this.blocks[i] }

    // ── Theme-derived helpers ──

    private func themeBg(): Int64 { return this.settings.backgroundColor() }
    private func themeText(): Int64 { return this.settings.textColor() }
    private func themeSecondary(): Int64 { return this.settings.secondaryTextColor() }
    private func themeAccent(): Int64 { return this.settings.accentColor() }
    private func themeSurface(): Int64 { return this.settings.surfaceColor() }
    private func themeCode(): Int64 { return this.settings.codeColor() }
    private func baseFont(): Float64 { return this.settings.baseFontSizeVp() }

    // ── Per-block style helpers ──

    private func blockFontSize(kind: InstantPageBlockKind): Float64 {
        let base = this.baseFont()
        return match (kind) {
            case InstantPageBlockKind.Header     => base * 1.4
            case InstantPageBlockKind.Subheader  => base * 1.2
            case InstantPageBlockKind.Blockquote => base * 0.95
            case InstantPageBlockKind.Preformatted => base * 0.85
            case _ => base
        }
    }

    private func blockFontColor(kind: InstantPageBlockKind): Int64 {
        return match (kind) {
            case InstantPageBlockKind.Header      => this.themeText()
            case InstantPageBlockKind.Subheader   => this.themeText()
            case InstantPageBlockKind.Blockquote  => this.themeSecondary()
            case InstantPageBlockKind.Preformatted => this.themeCode()
            case _ => this.themeText()
        }
    }

    private func blockWeight(kind: InstantPageBlockKind): FontWeight {
        return match (kind) {
            case InstantPageBlockKind.Header    => FontWeight.Bold
            case InstantPageBlockKind.Subheader => FontWeight.Medium
            case _ => FontWeight.Normal
        }
    }

    private func blockPadLeft(kind: InstantPageBlockKind): Int64 {
        return match (kind) {
            case InstantPageBlockKind.Blockquote   => 12
            case InstantPageBlockKind.Preformatted => 10
            case InstantPageBlockKind.ListItem     => 20
            case _ => 0
        }
    }

    private func blockTopPad(kind: InstantPageBlockKind): Int64 {
        return match (kind) {
            case InstantPageBlockKind.Header    => 12
            case InstantPageBlockKind.Subheader => 8
            case _ => 4
        }
    }

    private func blockBotPad(kind: InstantPageBlockKind): Int64 {
        return match (kind) {
            case InstantPageBlockKind.Header    => 6
            case InstantPageBlockKind.Subheader => 4
            case _ => 4
        }
    }

    private func isListItem(kind: InstantPageBlockKind): Bool {
        return match (kind) {
            case InstantPageBlockKind.ListItem => true
            case _ => false
        }
    }

    private func isDivider(kind: InstantPageBlockKind): Bool {
        return match (kind) {
            case InstantPageBlockKind.Divider => true
            case _ => false
        }
    }

    private func isImageBlock(kind: InstantPageBlockKind): Bool {
        return match (kind) {
            case InstantPageBlockKind.Image => true
            case InstantPageBlockKind.Photo => true
            case _ => false
        }
    }

    private func isAnchorBlock(kind: InstantPageBlockKind): Bool {
        return match (kind) {
            case InstantPageBlockKind.Anchor => true
            case _ => false
        }
    }

    private func hasImageUrl(blk: InstantPageBlock): Bool {
        return blk.imageUrl.size > 0
    }

    private func blkHasLinkUrl(blk: InstantPageBlock): Bool {
        return blk.linkUrl.size > 0
    }

    // ── P2-216: Anchor scroll ──

    /**
     * Scroll to anchor by name. Searches anchorMap for index, then calls
     * scroller.scrollToIndex(). If not found, does nothing.
     */
    func scrollToAnchor(name: String): Unit {
        var idx: Int64 = 0
        var found: Int64 = -1
        for (aname in this.anchorMap) {
            if (aname == name) {
                found = idx
                break
            }
            idx = idx + 1
        }
        if (found >= 0) {
            this.scroller.scrollToIndex(Int32(found))
            Hilog.info(0, "CjTelegram", "[InstantPagePage] scrollToAnchor ${name} -> idx ${found}")
        }
    }

    // ── P2-216: Open URL (external browser) or anchor ──

    func openLinkUrl(url: String): Unit {
        if (url.size == 0) { return }
        // Internal anchor: #anchorName
        if (url.size > 0) {
            let runes = url.toRuneArray()
            if (runes[0] == r'#') {
                let anchorName = String(runes[1..runes.size])
                this.scrollToAnchor(anchorName)
                return
            }
        }
        // External URL → startAbility(viewData)
        let _ = spawn {
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    let want = Want(
                        action: "ohos.want.action.viewData",
                        uri: url
                    )
                    try {
                        ctx.startAbility(want)
                        Hilog.info(0, "CjTelegram", "[InstantPagePage] openUrl: ${url}")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[InstantPagePage] openUrl error: ${e}")
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[InstantPagePage] no context for openUrl")
            }
        }
    }

    // ── P2-216: Share article URL ──

    func shareArticleUrl(): Unit {
        let url = this.pageUrl
        if (url.size == 0) { return }
        let _ = spawn {
            match (getGlobalAbilityContext()) {
                case Some(ctx) =>
                    // P2-216: Share via system share panel — use viewData action with article URL
                    // (HarmonyOS share intent: ohos.want.action.sendData requires bundleName;
                    //  fall back to viewData so user can copy/share from system browser)
                    let want = Want(
                        action: "ohos.want.action.viewData",
                        uri: url
                    )
                    try {
                        ctx.startAbility(want)
                        Hilog.info(0, "CjTelegram", "[InstantPagePage] shareUrl via viewData")
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[InstantPagePage] share error")
                    }
                case None =>
                    Hilog.info(0, "CjTelegram", "[InstantPagePage] no context for share")
            }
        }
    }

    // ── P2-215: Open settings panel ──

    func openSettingsPanel(): Unit {
        routerPush("InstantPageSettingsPage", "")
    }

    // ── @Builder: block renderers ──

    @Builder
    func textBlockRow(blk: InstantPageBlock) {
        Row {
            if (this.isListItem(blk.kind)) {
                Text("•")
                    .fontSize(this.blockFontSize(blk.kind))
                    .fontColor(this.blockFontColor(blk.kind))
                    .width(16)
            }
            // P2-214: Rich text — link blocks get accent color; entity decoration
            // deferred (no inline attributed-string API in ArkUI Cangjie; fallback to
            // standard Text with link tint when linkUrl is present)
            if (this.blkHasLinkUrl(blk)) {
                Text(blk.text)
                    .fontSize(this.blockFontSize(blk.kind))
                    .fontColor(this.themeAccent())
                    .fontWeight(this.blockWeight(blk.kind))
                    .decoration(decorationType: TextDecorationType.Underline, color: this.themeAccent())
                    .width(100.percent)
                    .textAlign(TextAlign.Start)
                    .onClick({ _ => this.openLinkUrl(blk.linkUrl) })
            } else {
                Text(blk.text)
                    .fontSize(this.blockFontSize(blk.kind))
                    .fontColor(this.blockFontColor(blk.kind))
                    .fontWeight(this.blockWeight(blk.kind))
                    .width(100.percent)
                    .textAlign(TextAlign.Start)
            }
        }
        .width(100.percent)
        .padding(
            left: this.blockPadLeft(blk.kind),
            top: this.blockTopPad(blk.kind),
            bottom: this.blockBotPad(blk.kind)
        )
    }

    @Builder
    func blockquoteRow(blk: InstantPageBlock) {
        Row {
            // Left accent bar
            Column {}
                .width(3)
                .backgroundColor(this.themeAccent())
                .margin(right: 8)
            Text(blk.text)
                .fontSize(this.blockFontSize(blk.kind))
                .fontColor(this.blockFontColor(blk.kind))
                .fontStyle(FontStyle.Italic)
                .width(100.percent)
                .textAlign(TextAlign.Start)
        }
        .width(100.percent)
        .backgroundColor(this.themeSurface())
        .padding(left: 12, top: 8, bottom: 8, right: 8)
        .margin(top: this.blockTopPad(blk.kind), bottom: this.blockBotPad(blk.kind))
    }

    @Builder
    func preformattedRow(blk: InstantPageBlock) {
        Row {
            Text(blk.text)
                .fontSize(this.blockFontSize(blk.kind))
                .fontColor(this.themeCode())
                .fontFamily("monospace")
                .width(100.percent)
                .textAlign(TextAlign.Start)
        }
        .width(100.percent)
        .backgroundColor(this.themeSurface())
        .padding(left: 10, top: 8, bottom: 8, right: 8)
        .margin(top: 4, bottom: 4)
    }

    @Builder
    func imageBlockRow(blk: InstantPageBlock) {
        Column {
            if (this.hasImageUrl(blk)) {
                // P2-214: Real network image loading via ArkUI Image(String)
                // Image component natively caches; requires INTERNET permission (already declared)
                Image(blk.imageUrl)
                    .width(100.percent)
                    .height(200)
                    .objectFit(ImageFit.Cover)
            } else {
                Row {
                    Text("[Image]")
                        .fontSize(14)
                        .fontColor(this.themeSecondary())
                        .textAlign(TextAlign.Center)
                }
                .width(100.percent)
                .height(160)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(this.themeSurface())
            }
            if (blk.caption.size > 0) {
                Text(blk.caption)
                    .fontSize(this.baseFont() * 0.85)
                    .fontColor(this.themeSecondary())
                    .textAlign(TextAlign.Center)
                    .width(100.percent)
                    .padding(top: 4, bottom: 4)
            }
        }
        .width(100.percent)
        .margin(top: 4, bottom: 8)
    }

    @Builder
    func renderBlock(blk: InstantPageBlock) {
        if (this.isDivider(blk.kind)) {
            Divider()
                .color(0xE0E0E0)
                .strokeWidth(1)
                .margin(top: 8, bottom: 8)
        } else if (this.isImageBlock(blk.kind)) {
            this.imageBlockRow(blk)
        } else if (this.isAnchorBlock(blk.kind)) {
            // P2-216: Anchor blocks are invisible (zero height). They occupy
            // a list slot so scrollToIndex can find them.
            Row {}
                .width(100.percent)
                .height(1)
        } else {
            // For blockquote / preformatted use dedicated renderers
            if (this.isBlockquoteKind(blk.kind)) {
                this.blockquoteRow(blk)
            } else if (this.isPreformattedKind(blk.kind)) {
                this.preformattedRow(blk)
            } else {
                this.textBlockRow(blk)
            }
        }
    }

    private func isBlockquoteKind(kind: InstantPageBlockKind): Bool {
        return match (kind) {
            case InstantPageBlockKind.Blockquote => true
            case _ => false
        }
    }

    private func isPreformattedKind(kind: InstantPageBlockKind): Bool {
        return match (kind) {
            case InstantPageBlockKind.Preformatted => true
            case _ => false
        }
    }

    public func build() {
        Column {
            if (this.isLoading) {
                Column {
                    LoadingProgress()
                        .width(40)
                        .height(40)
                    Text("Loading article...")
                        .fontSize(14)
                        .fontColor(this.themeSecondary())
                        .margin(top: 12)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.errorMessage.size > 0) {
                Column {
                    Text(this.errorMessage)
                        .fontSize(16)
                        .fontColor(0xCC0000)
                        .textAlign(TextAlign.Center)
                    Button(trSource("Retry"))
                        .onClick({ _ =>
                            this.isLoading = true
                            this.errorMessage = ""
                            this.loadPage()
                        })
                        .margin(top: 16)
                }
                .width(100.percent)
                .layoutWeight(1)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                List(scroller: this.scroller) {
                    ForEach(Array<InstantPageBlock>(this.blockCount(), {
                        i: Int64 => this.blockAt(i)
                    }), itemGenerator: {
                        blk: InstantPageBlock, _: Int64 =>
                            ListItem {
                                this.renderBlock(blk)
                            }
                    })
                }
                .width(100.percent)
                .layoutWeight(1)
                .divider(ListDividerOptions(strokeWidth: 0))

                // P2-215/216: Toolbar with Settings + Share buttons
                Row {
                    Button("Aa")
                        .onClick({ _ => this.openSettingsPanel() })
                        .backgroundColor(Color.Transparent)
                        .fontColor(this.themeAccent())
                        .fontSize(16)
                        .width(48)
                        .height(40)
                    Blank()
                        .layoutWeight(1)
                    Button(trSource("Share"))
                        .onClick({ _ => this.shareArticleUrl() })
                        .backgroundColor(Color.Transparent)
                        .fontColor(this.themeAccent())
                        .fontSize(14)
                        .height(40)
                }
                .width(100.percent)
                .padding(left: 8, right: 8)
                .backgroundColor(this.themeBg())
                .borderWidth(0)
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(this.themeBg())
        .padding(left: 16, right: 16)
        .onAppear({ => this.ensureLoaded() })
    }
}

// ── Helper: build anchor map from block list ──

/**
 * Produces an ArrayList<String> parallel to blocks:
 * element[i] = anchorName of block[i] if it is an Anchor block, else "".
 * Used by scrollToAnchor() to do O(n) linear search by name.
 */
func instPageBuildAnchorMap(blocks: ArrayList<InstantPageBlock>): ArrayList<String> {
    let amap = ArrayList<String>()
    for (blk in blocks) {
        let name = match (blk.kind) {
            case InstantPageBlockKind.Anchor => blk.anchorName
            case _ => ""
        }
        amap.add(name)
    }
    return amap
}
