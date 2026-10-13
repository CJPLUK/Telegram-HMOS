package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}
import ohos_app_cangjie_entry.core.storage.{PresentationSnapshot, currentPresentation}
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.services.{
    getThemesEngineService,
    getWallpaperBackgroundService,
    saveSelectedWallpaper,
    WallpaperInfo,
    WallpaperType,
    WallpaperItem,
    WallpaperListResult
}
import ohos_app_cangjie_entry.utils.{parseHexColor, hexStringFromColor}
import std.math.*
import std.collection.{ArrayList, HashMap}

private func colorClamp01(value: Float64): Float64 {
    return max(0.0, min(1.0, value))
}

private func pickerHsvToRgb(h: Float64, s: Float64, v: Float64): (Float64, Float64, Float64) {
    let hh = colorClamp01(h) * 6.0
    let c = colorClamp01(v) * colorClamp01(s)
    let regionFloat = floor(hh)
    let fraction = hh - regionFloat
    var region = Int64(regionFloat) % 6
    if (region < 0) { region = region + 6 }
    var x = c * fraction
    if (region % 2 == 1) { x = c * (1.0 - fraction) }
    var r = 0.0
    var g = 0.0
    var b = 0.0
    if (region == 0) { r = c; g = x }
    else if (region == 1) { r = x; g = c }
    else if (region == 2) { g = c; b = x }
    else if (region == 3) { g = x; b = c }
    else if (region == 4) { r = x; b = c }
    else { r = c; b = x }
    let m = colorClamp01(v) - c
    return (r + m, g + m, b + m)
}

private func pickerHsvToColor(h: Float64, s: Float64, v: Float64): UInt32 {
    let (r, g, b) = pickerHsvToRgb(h, s, v)
    return (UInt32(colorClamp01(r) * 255.0) << 16) |
        (UInt32(colorClamp01(g) * 255.0) << 8) |
        UInt32(colorClamp01(b) * 255.0)
}

private func pickerRgbToHsv(color: UInt32): (Float64, Float64, Float64) {
    let r = Float64((color >> 16) & 0xFF) / 255.0
    let g = Float64((color >> 8) & 0xFF) / 255.0
    let b = Float64(color & 0xFF) / 255.0
    let maximum = max(r, max(g, b))
    let minimum = min(r, min(g, b))
    let delta = maximum - minimum
    var hue = 0.0
    if (delta > 0.0) {
        if (maximum == r) {
            hue = (g - b) / delta
            if (hue < 0.0) { hue = hue + 6.0 }
        } else if (maximum == g) {
            hue = (b - r) / delta + 2.0
        } else {
            hue = (r - g) / delta + 4.0
        }
        hue = hue / 6.0
    }
    let saturation = if (maximum > 0.0) { delta / maximum } else { 0.0 }
    return (hue, saturation, maximum)
}

@Component
public class ThemeColorFieldCanvas {
    @Prop var hue: Float64
    @Prop var saturation: Float64
    @Prop var brightness: Float64
    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    @State var fieldWidth: Float64 = 320.0
    @State var fieldHeight: Float64 = 190.0

    private func refreshProbe(): String {
        this.draw()
        return ""
    }

    private func draw(): Unit {
        let w = this.fieldWidth
        let h = this.fieldHeight
        if (w <= 0.0 || h <= 0.0) { return }
        let columns: Int64 = 40
        let rows: Int64 = 24
        let cellWidth = w / Float64(columns)
        let cellHeight = h / Float64(rows)
        var row: Int64 = 0
        while (row < rows) {
            var column: Int64 = 0
            while (column < columns) {
                let hValue = Float64(column) / Float64(columns - 1)
                let sValue = 1.0 - Float64(row) / Float64(rows - 1)
                this.ctx.fillStyle = 0xFF000000 | pickerHsvToColor(hValue, sValue, this.brightness)
                this.ctx.fillRect(
                    Float64(column) * cellWidth,
                    Float64(row) * cellHeight,
                    cellWidth + 1.0,
                    cellHeight + 1.0
                )
                column++
            }
            row++
        }
        this.ctx.strokeStyle = 0xFFFFFFFF
        this.ctx.lineWidth = 3.0
        this.ctx.beginPath()
        this.ctx.arc(this.hue * w, (1.0 - this.saturation) * h, 12.0, 0.0, 6.283185307179586)
        this.ctx.stroke()
    }

    func build() {
        Stack {
            Text(this.refreshProbe()).height(0).fontSize(0)
            Canvas(this.ctx)
                .width(100.percent)
                .height(100.percent)
                .onReady({ => this.draw() })
                .onAreaChange({ _: Area, next: Area =>
                    this.fieldWidth = next.width.value
                    this.fieldHeight = next.height.value
                    this.draw()
                })
        }
        .width(100.percent)
        .height(205)
        .borderRadius(18)
        .clip(true)
    }
}

@Component
public class ThemeBrightnessStripCanvas {
    @Prop var hue: Float64
    @Prop var saturation: Float64
    @Prop var brightness: Float64
    private let ctx: CanvasRenderingContext2D = CanvasRenderingContext2D(RenderingContextSettings(antialias: true))
    @State var width: Float64 = 320.0

    private func refreshProbe(): String {
        this.draw()
        return ""
    }

    private func draw(): Unit {
        let gradient = this.ctx.createLinearGradient(0.0, 0.0, this.width, 0.0)
        gradient.addColorStop(0.0, 0xFF000000 | pickerHsvToColor(this.hue, this.saturation, 1.0))
        gradient.addColorStop(1.0, 0xFF000000)
        this.ctx.fillStyle = gradient
        this.ctx.fillRect(0.0, 0.0, this.width, 24.0)
    }

    func build() {
        Stack {
            Text(this.refreshProbe()).height(0).fontSize(0)
            Canvas(this.ctx)
                .width(100.percent)
                .height(24)
                .borderRadius(12)
                .onReady({ => this.draw() })
                .onAreaChange({ _: Area, next: Area => this.width = next.width.value; this.draw() })
        }
        .width(100.percent)
        .height(24)
    }
}

@HybridComponentEntry
@Component
public class ThemeAccentColorPickerPage {
    @StorageLink["presentation"] var presentation: PresentationSnapshot = currentPresentation()
    @State var loaded: Bool = false
    @State var section: Int32 = 0
    @State var hue: Float64 = 0.58
    @State var saturation: Float64 = 0.48
    @State var brightness: Float64 = 0.94
    @State var selectedBackgroundIndex: Int32 = 0
    @State var backgroundColors: Array<UInt32> = [0x81A9F0, 0x8FD0EE, 0xA5D8C6, 0xAAAEE0]
    @State var hexText: String = "#81A9F0"
    @State var animateMessages: Bool = false
    @State var colorFieldWidth: Float64 = 320.0
    @State var patternEnabled: Bool = false
    @State var patternFile: String = ""
    @State var patternIntensity: Float64 = 0.5
    @State var colorPanelCollapsed: Bool = false
    @State var displayPatternPanel: Bool = false
    @State var patternItems: ArrayList<WallpaperItem> = ArrayList<WallpaperItem>()
    @State var patternThumbUris: HashMap<String, String> = HashMap<String, String>()
    @State var selectedPatternSlug: String = ""
    @State var patternsRequested: Bool = false
    @State var createThemeAfterSet: Bool = false

    private func currentColor(): UInt32 {
        return pickerHsvToColor(this.hue, this.saturation, this.brightness)
    }

    private func loadColor(color: UInt32): Unit {
        let (h, s, v) = pickerRgbToHsv(color)
        this.hue = h
        this.saturation = s
        this.brightness = v
        this.hexText = "#" + hexStringFromColor(color, false).toAsciiUpper()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.createThemeAfterSet = takePending("ThemeAccentColorPickerPage").contains("createTheme")
        let wallpaper = getWallpaperBackgroundService().getCurrentWallpaper()
        if (wallpaper.gradientColors.size > 0) {
            this.backgroundColors = wallpaper.gradientColors
        } else {
            this.backgroundColors = [wallpaper.solidColor & 0x00FFFFFF]
        }
        this.patternEnabled = wallpaper.patternOverlayEnabled && wallpaper.patternFile.size > 0
        this.patternFile = wallpaper.patternFile
        this.patternIntensity = abs(wallpaper.patternIntensity)
        this.animateMessages = getThemesEngineService().getAnimateMessageColors()
        this.loadColor(this.backgroundColors[0])
    }

    private func colorForSection(sectionIndex: Int32): UInt32 {
        if (sectionIndex == 0) {
            if (this.backgroundColors.size > Int64(this.selectedBackgroundIndex)) {
                return this.backgroundColors[Int64(this.selectedBackgroundIndex)] & 0x00FFFFFF
            }
            return 0x81A9F0
        }
        if (sectionIndex == 1) {
            return getThemesEngineService().getAccentColor() & 0x00FFFFFF
        }
        let bubble = getThemesEngineService().getCustomBubbleColor() & 0x00FFFFFF
        return if (bubble == 0) { this.presentation.bubbleOutColor & 0x00FFFFFF } else { bubble }
    }

    private func selectSection(next: Int32): Unit {
        this.storeWorkingBackgroundColor()
        this.section = next
        this.loadColor(this.colorForSection(next))
        this.displayPatternPanel = false
    }

    private func storeWorkingBackgroundColor(): Unit {
        if (this.section != 0 || this.backgroundColors.size == 0) { return }
        let updated = Array<UInt32>(this.backgroundColors.size, { i: Int64 => this.backgroundColors[i] })
        updated[Int64(this.selectedBackgroundIndex)] = this.currentColor()
        this.backgroundColors = updated
    }

    private func updateHexText(): Unit {
        this.hexText = "#" + hexStringFromColor(this.currentColor(), false).toAsciiUpper()
        this.storeWorkingBackgroundColor()
    }

    private func applyHex(value: String): Unit {
        this.hexText = value
        match (parseHexColor(value)) {
            case Some(color) => this.loadColor(color & 0x00FFFFFF); this.storeWorkingBackgroundColor()
            case None => ()
        }
    }

    private func selectBackgroundColor(index: Int32): Unit {
        this.storeWorkingBackgroundColor()
        this.selectedBackgroundIndex = index
        this.loadColor(this.backgroundColors[Int64(index)] & 0x00FFFFFF)
    }

    private func handleColorFieldTouch(event: TouchEvent): Unit {
        if (event.touches.size == 0) { return }
        if (event.eventType == TouchType.Down || event.eventType == TouchType.Move) {
            this.hue = colorClamp01(event.touches[0].x / this.colorFieldWidth)
            this.saturation = 1.0 - colorClamp01(event.touches[0].y / 205.0)
            this.updateHexText()
        }
    }

    private func playColorAnimation(): Unit {
        if (this.section == 2) {
            this.animateMessages = true
            return
        }
        if (this.section != 0 || this.backgroundColors.size < 2) { return }
        this.storeWorkingBackgroundColor()
        let count = this.backgroundColors.size
        let shifted = Array<UInt32>(count, { i: Int64 =>
            this.backgroundColors[(i + 1) % count]
        })
        this.backgroundColors = shifted
        this.selectedBackgroundIndex = 0
        this.loadColor(shifted[0])
    }

    private func setPatternThumbUri(slug: String, uri: String): Unit {
        spawn(UIThread) {
            =>
            let next = HashMap<String, String>()
            for ((key, value) in this.patternThumbUris) { next[key] = value }
            next[slug] = uri
            this.patternThumbUris = next
            if (this.selectedPatternSlug == slug) {
                this.patternFile = uri
                this.patternEnabled = uri.size > 0
            }
        }
    }

    private func patternThumbUri(item: WallpaperItem): String {
        if (this.patternThumbUris.contains(item.slug)) { return this.patternThumbUris[item.slug] }
        return ""
    }

    private func requestPatternThumb(item: WallpaperItem): Unit {
        let service = getWallpaperBackgroundService()
        let cached = service.getCachedCloudWallpaperThumbUri(item)
        if (cached.size > 0) {
            this.setPatternThumbUri(item.slug, cached)
            return
        }
        let slug = item.slug
        service.downloadCloudWallpaperThumb(item, { uri: String =>
            if (uri.size > 0) { this.setPatternThumbUri(slug, uri) }
        })
    }

    private func requestPatterns(): Unit {
        if (this.patternsRequested) { return }
        this.patternsRequested = true
        getWallpaperBackgroundService().loadWallpapersFromCloud(0, { result: WallpaperListResult =>
            if (!result.success || result.notModified) { return }
            let patterns = ArrayList<WallpaperItem>()
            for (item in result.items) {
                if (item.isPattern && item.hasDocument && item.document.mimeType != "image/webp") {
                    patterns.add(item)
                }
            }
            spawn(UIThread) {
                =>
                this.patternItems = patterns
                if (this.selectedPatternSlug.size == 0 && patterns.size > 0) {
                    this.selectedPatternSlug = patterns[0].slug
                }
            }
            for (item in patterns) { this.requestPatternThumb(item) }
        })
    }

    private func togglePatternPanel(): Unit {
        if (this.section == 2) {
            this.animateMessages = !this.animateMessages
            return
        }
        if (this.displayPatternPanel) {
            this.displayPatternPanel = false
            this.colorPanelCollapsed = true
            this.patternEnabled = false
        } else {
            this.colorPanelCollapsed = false
            this.displayPatternPanel = true
            this.requestPatterns()
        }
    }

    private func selectPattern(item: WallpaperItem): Unit {
        this.selectedPatternSlug = item.slug
        this.patternIntensity = if (item.settings.hasIntensity) {
            min(1.0, abs(Float64(item.settings.intensity)) / 100.0)
        } else { 0.5 }
        let uri = this.patternThumbUri(item)
        this.patternFile = uri
        this.patternEnabled = uri.size > 0
    }

    private func onCancel(): Unit {
        if (this.displayPatternPanel) {
            this.displayPatternPanel = false
            this.patternEnabled = false
        } else {
            routerPop()
        }
    }

    private func onDone(): Unit {
        if (this.displayPatternPanel) {
            this.displayPatternPanel = false
        } else {
            this.onSet()
        }
    }

    private func onSet(): Unit {
        let color = this.currentColor()
        if (this.section == 0) {
            this.storeWorkingBackgroundColor()
            let info = WallpaperInfo()
            if (this.backgroundColors.size == 1) {
                info.wallpaperType = WallpaperType.SolidColor
                info.solidColor = 0xFF000000 | this.backgroundColors[0]
            } else {
                info.wallpaperType = WallpaperType.MultiColorGradient
                info.gradientColors = Array<UInt32>(this.backgroundColors.size, { i: Int64 => 0xFF000000 | this.backgroundColors[i] })
            }
            info.patternFile = this.patternFile
            info.patternOverlayEnabled = this.patternEnabled && this.patternFile.size > 0
            info.patternIntensity = this.patternIntensity
            saveSelectedWallpaper(info)
        } else if (this.section == 1) {
            getThemesEngineService().saveAccentColor(color)
        } else {
            getThemesEngineService().saveCustomBubbleColor(color)
            getThemesEngineService().saveAnimateMessageColors(this.animateMessages)
        }
        if (this.createThemeAfterSet) {
            // Source replaces ThemeAccentColorController with EditThemeController after the
            // colors result is committed, instead of stacking a second temporary page.
            routerReplaceTop("EditThemePage", "create")
        } else {
            routerPop()
        }
    }

    @Builder
    func segmentButton(index: Int32, title: String) {
        Text(title)
            .fontSize(15)
            .fontWeight(if (this.section == index) { FontWeight.Bold } else { FontWeight.Medium })
            .fontColor(0xFF000000)
            .textAlign(TextAlign.Center)
            .height(42)
            .layoutWeight(1)
            .backgroundColor(if (this.section == index) { 0x99FFFFFF } else { Color.Transparent })
            .borderRadius(21)
            .onClick({ _ => this.selectSection(index) })
    }

    @Builder
    func preview() {
        Stack {
            Column {}
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(if (this.section == 0) { this.currentColor() } else { this.colorForSection(0) })
            if (this.patternEnabled && this.patternFile.size > 0) {
                Image(this.patternFile)
                    .width(100.percent)
                    .height(100.percent)
                    .objectFit(ImageFit.Cover)
                    .opacity(this.patternIntensity)
            }
            Column {
                Row {
                    Text("Bob Harris\nYes, turn to camera.")
                        .fontSize(14)
                        .fontColor(0xFF222222)
                        .padding(12)
                        .backgroundColor(0xEEFFFFFF)
                        .borderRadius(16)
                    Blank().layoutWeight(1)
                }
                Row {
                    Blank().layoutWeight(1)
                    Text("Is that everything? 🤔")
                        .fontSize(14)
                        .fontColor(0xFF222222)
                        .padding(12)
                        .backgroundColor(if (this.section == 2) { this.currentColor() } else { this.colorForSection(2) })
                        .borderRadius(16)
                }
                Row {
                    Text("▶   0:23")
                        .fontSize(14)
                        .fontColor(if (this.section == 1) { this.currentColor() } else { this.colorForSection(1) })
                        .padding(12)
                        .backgroundColor(0xEEFFFFFF)
                        .borderRadius(16)
                    Blank().layoutWeight(1)
                }
            }
            .padding(left: 12, right: 12, top: 64)

            if (this.section != 1) {
                Row {
                    Button(if (this.section == 2) {
                        if (this.animateMessages) { "✓ Animate" } else { "Animate" }
                    } else {
                        if (this.patternEnabled) { "✓ Pattern" } else { "Pattern" }
                    })
                        .height(42)
                        .fontSize(15)
                        .fontColor(0xFFFFFFFF)
                        .backgroundColor(0x99000000)
                        .onClick({ _ => this.togglePatternPanel() })
                    Blank().layoutWeight(1)
                    Button("▶")
                        .width(46)
                        .height(46)
                        .borderRadius(23)
                        .fontSize(18)
                        .fontColor(0xFFFFFFFF)
                        .backgroundColor(0x99000000)
                        .onClick({ _ => this.playColorAnimation() })
                    Blank().layoutWeight(1)
                    Button("Colors")
                        .height(42)
                        .fontSize(15)
                        .fontColor(0xFFFFFFFF)
                        .backgroundColor(0x99000000)
                        .onClick({ _ =>
                            if (this.displayPatternPanel) {
                                this.displayPatternPanel = false
                                this.colorPanelCollapsed = false
                            } else {
                                this.colorPanelCollapsed = !this.colorPanelCollapsed
                            }
                        })
                }
                .width(100.percent)
                .padding(left: 18, right: 18, bottom: 12)
                .position(x: 0, y: 285)
            }
        }
        .width(100.percent)
        .height(350)
    }

    @Builder
    func colorControls() {
        Column {
            if (this.section == 0) {
                Row {
                    ForEach(Array<Int64>(this.backgroundColors.size, { i: Int64 => i }), itemGenerator: { i: Int64, _: Int64 =>
                        Stack {
                            Column {}
                                .width(38).height(38)
                                .borderRadius(19)
                                .backgroundColor(this.backgroundColors[i])
                            if (i == Int64(this.selectedBackgroundIndex)) {
                                Column {}
                                    .width(46).height(46)
                                    .borderRadius(23)
                                    .border(width: 3, color: 0xFFFFFFFF, radius: 23)
                            }
                        }
                        .width(50).height(50)
                        .onClick({ _ => this.selectBackgroundColor(Int32(i)) })
                    })
                    Blank().layoutWeight(1)
                    Text(this.hexText)
                        .fontSize(18)
                        .fontWeight(FontWeight.Medium)
                        .padding(left: 16, right: 16)
                }
                .width(100.percent)
                .height(58)
            } else {
                TextInput(text: this.hexText)
                    .fontSize(18)
                    .fontColor(0xFF111111)
                    .backgroundColor(0x88FFFFFF)
                    .borderRadius(22)
                    .height(48)
                    .onChange({ value: String => this.applyHex(value) })
            }

            Stack {
                ThemeColorFieldCanvas(
                    hue: this.hue,
                    saturation: this.saturation,
                    brightness: this.brightness
                )
                Column {}
                    .width(100.percent)
                    .height(205)
                    .onTouch({ event: TouchEvent => this.handleColorFieldTouch(event) })
            }
            .width(100.percent)
            .height(205)
            .onAreaChange({ _: Area, next: Area => this.colorFieldWidth = next.width.value })
            .margin(top: 8)

            Stack {
                ThemeBrightnessStripCanvas(
                    hue: this.hue,
                    saturation: this.saturation,
                    brightness: this.brightness
                )
                Slider(value: 1.0 - this.brightness, min: 0.0, max: 1.0, step: 0.001, style: SliderStyle.OutSet)
                    .trackColor(Color.Transparent)
                    .selectedColor(Color.Transparent)
                    .onChange({ value: Float64, _: SliderChangeMode => this.brightness = 1.0 - value; this.updateHexText() })
            }
            .width(100.percent)
            .height(36)
            .margin(top: 8)

            if (this.section == 2) {
                Row {
                    Text("Animate Colors").fontSize(16).fontColor(0xFF111111).layoutWeight(1)
                    Toggle(ToggleType.Switch, isOn: this.animateMessages)
                        .selectedColor(0xFF34C759)
                        .onChange({ value: Bool => this.animateMessages = value })
                }
                .height(46)
            }
        }
        .layoutWeight(1)
        .padding(left: 16, right: 16)
    }

    @Builder
    func patternControls() {
        Column {
            Text("Pattern")
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFF111111)
                .margin(top: 18, bottom: 8)
            if (this.patternItems.size == 0) {
                LoadingProgress().width(34).height(34).color(this.presentation.accentColor).margin(top: 42)
                Blank().layoutWeight(1)
            } else {
                Scroll {
                    Row {
                        ForEach(this.patternItems, itemGenerator: { item: WallpaperItem, _: Int64 =>
                            Stack {
                                Column {}
                                    .width(88).height(88)
                                    .backgroundColor(this.currentColor())
                                    .borderRadius(7)
                                if (this.patternThumbUri(item).size > 0) {
                                    Image(this.patternThumbUri(item))
                                        .width(88).height(88)
                                        .objectFit(ImageFit.Cover)
                                        .opacity(this.patternIntensity)
                                        .borderRadius(7)
                                }
                                if (this.selectedPatternSlug == item.slug) {
                                    Column {}
                                        .width(88).height(88)
                                        .border(width: 3, color: this.presentation.accentColor, radius: 7)
                                }
                            }
                            .width(100).height(112)
                            .padding(left: 6, right: 6, top: 12, bottom: 12)
                            .onClick({ _ => this.selectPattern(item) })
                        })
                    }
                    .padding(left: 6, right: 6)
                }
                .width(100.percent)
                .height(116)
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)

                Text("Pattern Intensity")
                    .fontSize(14)
                    .fontColor(0xFF111111)
                    .width(100.percent)
                    .padding(left: 16, right: 16)
                    .margin(top: 8)
                Slider(value: this.patternIntensity * 100.0, min: 0.0, max: 100.0, step: 1.0, style: SliderStyle.OutSet)
                    .selectedColor(this.presentation.accentColor)
                    .trackColor(0xFFD1D1D6)
                    .width(100.percent)
                    .padding(left: 16, right: 16)
                    .onChange({ value: Float64, _: SliderChangeMode =>
                        this.patternIntensity = value / 100.0
                    })
                Blank().layoutWeight(1)
            }
        }
        .layoutWeight(1)
        .width(100.percent)
        .backgroundColor(0xFFF2F2F7)
    }

    public func build() {
        Column {
            Stack(alignContent: Alignment.Top) {
                this.preview()
                Row {
                    this.segmentButton(0, "Background")
                    this.segmentButton(1, "Accent")
                    this.segmentButton(2, "Messages")
                }
                .height(48)
                .padding(3)
                .margin(left: 48, right: 48, top: getSafeAreaTop() + 12.0)
                .backgroundColor(0xCCF2F2F7)
                .borderRadius(24)
                .align(Alignment.Top)
            }
            .width(100.percent)
            .height(350)

            if (this.displayPatternPanel) {
                this.patternControls()
            } else if (this.colorPanelCollapsed) {
                Blank().layoutWeight(1)
            } else {
                this.colorControls()
            }

            Row {
                Button("Cancel")
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFF000000)
                    .backgroundColor(0xEEFFFFFF).borderRadius(28)
                    .height(56).layoutWeight(1)
                    .onClick({ _ => this.onCancel() })
                Button("Set")
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor(0xFF000000)
                    .backgroundColor(0xEEFFFFFF).borderRadius(28)
                    .height(56).layoutWeight(1)
                    .margin(left: 16)
                    .onClick({ _ => this.onDone() })
            }
            .width(100.percent)
            .padding(left: 24, right: 24, bottom: getSafeAreaBottom() + 12.0)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .onAppear({ => this.ensureLoaded() })
    }
}
