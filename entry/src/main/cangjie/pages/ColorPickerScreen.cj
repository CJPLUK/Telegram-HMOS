package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*
import ohos_app_cangjie_entry.router.*

// ColorPickerScreen — color palette grid + opacity slider for DrawingUI
// Adapted from iOS DrawingUI/Sources/ColorPickerScreen.swift (palette colors, opacity)

@HybridComponentEntry
@Component
public class ColorPickerScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // Selected color communicated back via DrawingService
    @State var selectedIndex: Int64 = 0
    @State var opacity: Float64 = 1.0
    @State var brushSize: Float64 = 6.0
    @State var loaded: Bool = false

    // Column count matches iOS palette: 12 per row
    private let columnsPerRow: Int64 = 12

    private func drawingService(): DrawingService {
        return getDrawingService()
    }

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let svc = this.drawingService()
        this.opacity = svc.getOpacity()
        this.brushSize = svc.getCurrentSize()
    }

    private func colorForIndex(idx: Int64): UInt32 {
        if (idx < 0 || idx >= Int64(drawingPaletteColors.size)) {
            return 0xFFFFFF
        }
        return drawingPaletteColors[idx]
    }

    private func isSelectedIndex(idx: Int64): Bool {
        return idx == this.selectedIndex
    }

    private func onSelectColor(idx: Int64): Unit {
        this.selectedIndex = idx
        let svc = this.drawingService()
        svc.setOpacity(this.opacity)
        svc.selectPaletteColor(idx)
    }

    private func opacityToPercent(): String {
        let pct = Int64(this.opacity * 100.0)
        return "${pct}%"
    }

    private func brushSizeLabel(): String {
        let sz = Int64(this.brushSize)
        return "${sz}pt"
    }

    func build() {
        Column() {
                // Title bar row
                Row() {
                    Text("Color")
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                    Blank()
                    Button(trSource("Done"))
                        .fontSize(15)
                        .fontColor(0x007AFF)
                        .backgroundColor(Color.Transparent)
                        .onClick({ _ =>
                            let svc = this.drawingService()
                            svc.setOpacity(this.opacity)
                            svc.setCurrentSize(this.brushSize)
                            routerPop()
                        })
                }
                .width(100.percent)
                .padding(16)

                // Palette grid: 10 rows × 12 columns
                Grid() {
                    ForEach(Array<Int64>(Int64(drawingPaletteColors.size), { i: Int64 => i }),
                        itemGenerator: { idx: Int64, _gi: Int64 =>
                            GridItem() {
                                Stack() {
                                    // Color swatch
                                    Column() {}
                                        .width(100.percent)
                                        .height(100.percent)
                                        .backgroundColor(Int64(this.colorForIndex(idx)))
                                    // Selection ring overlay
                                    if (this.isSelectedIndex(idx)) {
                                        Column() {}
                                            .width(100.percent)
                                            .height(100.percent)
                                            .borderWidth(2)
                                            .borderColor(0xFFFFFF)
                                            .borderRadius(3)
                                    }
                                }
                                .width(100.percent)
                                .height(100.percent)
                                .onClick({ _ => this.onSelectColor(idx) })
                            }
                        })
                }
                .columnsTemplate("1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr")
                .rowsGap(2)
                .columnsGap(2)
                .width(100.percent)
                .height(200)
                .padding(16)

                // Opacity slider row
                Column() {
                    Row() {
                        Text("Opacity")
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .width(80)
                        Slider(
                            value: this.opacity,
                            min: 0.0,
                            max: 1.0,
                            step: 0.01
                        )
                        .trackColor(0x555555)
                        .selectedColor(0xFFFFFF)
                        .width(1.0)
                        .layoutWeight(1)
                        .onChange({ value: Float64, _mode: SliderChangeMode =>
                            this.opacity = value
                            let svc = this.drawingService()
                            svc.setOpacity(value)
                        })
                        Text(this.opacityToPercent())
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .width(44)
                            .textAlign(TextAlign.End)
                    }
                    .width(100.percent)
                    .padding(16)

                    // Brush size slider row
                    Row() {
                        Text("Size")
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .width(80)
                        Slider(
                            value: this.brushSize,
                            min: 1.0,
                            max: 60.0,
                            step: 1.0
                        )
                        .trackColor(0x555555)
                        .selectedColor(0xFFFFFF)
                        .width(1.0)
                        .layoutWeight(1)
                        .onChange({ value: Float64, _mode: SliderChangeMode =>
                            this.brushSize = value
                            let svc = this.drawingService()
                            svc.setCurrentSize(value)
                        })
                        Text(this.brushSizeLabel())
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .width(44)
                            .textAlign(TextAlign.End)
                    }
                    .width(100.percent)
                    .padding(16)
                }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x1C1C1E)
        .onAppear({ => this.ensureLoaded() })
    }
}
