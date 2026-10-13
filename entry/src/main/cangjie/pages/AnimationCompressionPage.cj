package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getAnimationCompressionService
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * AnimationCompressionPage — 动画帧压缩功能页面（animation_compression feature）
 *
 * 对应 iOS AnimationCompressor（AnimationCompression submodule）
 *
 * 功能:
 * - 展示动画帧压缩能力（JPEG / WebP 格式，可调质量）
 * - 调用 AnimationCompressionService 执行本地媒体压缩
 * - 显示预估压缩后尺寸，支持实时质量参数调整
 *
 * 说明:
 * - iOS 使用 Metal GPU DCT + DctHuffman 压缩算法（无 HarmonyOS 对应能力，deferred）
 * - HarmonyOS 使用 ImageKit ImagePacker 提供等效 JPEG/WebP 压缩
 * - 无 MTProto TL 方法（N/A）：动画压缩是纯客户端本地能力
 *
 * 入口: MainTabPage.pageMap 通过 pushPathByName("AnimationCompressionPage") 跳转
 */
@HybridComponentEntry
@Component
public class AnimationCompressionPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    @State var jpegQuality: Float64 = 80.0
    @State var webpQuality: Float64 = 80.0
    @State var frameSize: Int32 = 512
    @State var estimatedJpegKb: Int64 = 0
    @State var estimatedWebpKb: Int64 = 0
    @State var isCompressing: Bool = false
    @State var lastResultMsg: String = ""
    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        this.refreshEstimates()
    }

    private func refreshEstimates(): Unit {
        let service = getAnimationCompressionService()
        let jq = UInt8(this.jpegQuality)
        let wq = UInt8(this.webpQuality)
        let w = this.frameSize
        let h = this.frameSize
        this.estimatedJpegKb = service.estimateCompressedSize(width: w, height: h, quality: jq) / Int64(1024)
        this.estimatedWebpKb = service.estimateCompressedSize(width: w, height: h, quality: wq) / Int64(1024)
    }

    private func handleCompressJpeg(): Unit {
        if (this.isCompressing) {
            return
        }
        this.isCompressing = true
        this.lastResultMsg = "Compressing as JPEG..."
        let quality = UInt8(this.jpegQuality)
        let _ = spawn {
            let service = getAnimationCompressionService()
            let result = service.compressFrame(filePath: "", quality: quality)
            launch {
                this.isCompressing = false
                if (result.size > 0) {
                    this.lastResultMsg = "JPEG compressed"
                    Hilog.info(0, "CjTelegram", "[AnimationCompressionPage] JPEG done")
                } else {
                    this.lastResultMsg = "No source file (demo: see estimated size)"
                    Hilog.info(0, "CjTelegram", "[AnimationCompressionPage] JPEG empty")
                }
            }
        }
    }

    private func handleCompressWebP(): Unit {
        if (this.isCompressing) {
            return
        }
        this.isCompressing = true
        this.lastResultMsg = "Compressing as WebP..."
        let quality = UInt8(this.webpQuality)
        let _ = spawn {
            let service = getAnimationCompressionService()
            let result = service.compressFrameToWebP(filePath: "", quality: quality)
            launch {
                this.isCompressing = false
                if (result.size > 0) {
                    this.lastResultMsg = "WebP compressed"
                    Hilog.info(0, "CjTelegram", "[AnimationCompressionPage] WebP done")
                } else {
                    this.lastResultMsg = "No source file (demo: see estimated size)"
                    Hilog.info(0, "CjTelegram", "[AnimationCompressionPage] WebP empty")
                }
            }
        }
    }

    private func handleCompressWithMaxSize(): Unit {
        if (this.isCompressing) {
            return
        }
        this.isCompressing = true
        this.lastResultMsg = "Compressing with 8x8 alignment..."
        let quality = UInt8(this.jpegQuality)
        let sz = this.frameSize
        let _ = spawn {
            let service = getAnimationCompressionService()
            let frame = service.compressFrameWithMaxSize(filePath: "", targetWidth: sz, targetHeight: sz, quality: quality)
            launch {
                this.isCompressing = false
                if (frame.data.size > 0) {
                    this.lastResultMsg = "Scaled JPEG compressed"
                    Hilog.info(0, "CjTelegram", "[AnimationCompressionPage] MaxSize done")
                } else {
                    this.lastResultMsg = "No source file (8x8-aligned target applied)"
                    Hilog.info(0, "CjTelegram", "[AnimationCompressionPage] MaxSize empty")
                }
            }
        }
    }

    private func getJpegQualityLabel(): String {
        return "JPEG Quality: " + Int64(this.jpegQuality).toString()
    }

    private func getWebpQualityLabel(): String {
        return "WebP Quality: " + Int64(this.webpQuality).toString()
    }

    private func getFrameSizeLabel(): String {
        return "Frame Size: " + this.frameSize.toString() + " x " + this.frameSize.toString() + " px"
    }

    private func getJpegEstimateLabel(): String {
        return "Est. JPEG: ~" + this.estimatedJpegKb.toString() + " KB"
    }

    private func getWebpEstimateLabel(): String {
        return "Est. WebP: ~" + this.estimatedWebpKb.toString() + " KB"
    }

    public func build() {
        Column {
                Row {
                    Text(trSource("Back"))
                        .fontSize(17)
                        .fontColor(0x317AFF)
                        .onClick({ _evt =>
                            routerPop()
                        })
                    Blank().layoutWeight(1)
                    Text("Animation Compression")
                        .fontSize(17)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0x000000)
                    Blank().layoutWeight(1)
                    Text("    ")
                        .fontSize(17)
                }
                .width(100.percent)
                .height(56.0 + getSafeAreaTop())
                .padding(left: 16, right: 16, top: getSafeAreaTop())
                .backgroundColor(0xF7F7F7)
                .alignItems(VerticalAlign.Center)

                Divider().color(0xE5E5EA).strokeWidth(0.5)

                Scroll {
                    Column {
                        Column {
                            Text("Frame Compression")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                                .margin(bottom: 4)
                            Text("Compress animation frames (GIF/WebM) using ImageKit.")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                            Text("iOS: Metal GPU DCT (deferred on HarmonyOS)")
                                .fontSize(12)
                                .fontColor(0xAAAAAA)
                                .width(100.percent)
                                .margin(top: 2)
                            Text("MTProto: N/A (local compression only)")
                                .fontSize(12)
                                .fontColor(0xAAAAAA)
                                .width(100.percent)
                                .margin(top: 2)
                        }
                        .width(100.percent)
                        .padding(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 16, bottom: 0)

                        Column {
                            Text(this.getFrameSizeLabel())
                                .fontSize(15)
                                .fontColor(0x000000)
                                .width(100.percent)
                                .margin(bottom: 8)

                            Row {
                                Text("256")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                Slider(value: Float64(this.frameSize), min: Float64(256.0), max: Float64(1024.0), step: Float64(8.0))
                                    .layoutWeight(1)
                                    .trackColor(0xE5E5EA)
                                    .selectedColor(0x317AFF)
                                    .onChange({ val: Float64, _mode: SliderChangeMode =>
                                        this.frameSize = Int32(val)
                                        this.refreshEstimates()
                                    })
                                Text("1024")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                            }
                            .width(100.percent)
                            .alignItems(VerticalAlign.Center)

                            Text(this.getJpegEstimateLabel())
                                .fontSize(13)
                                .fontColor(0x34C759)
                                .width(100.percent)
                                .margin(top: 4)
                            Text(this.getWebpEstimateLabel())
                                .fontSize(13)
                                .fontColor(0x5856D6)
                                .width(100.percent)
                                .margin(top: 2)
                        }
                        .width(100.percent)
                        .padding(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 12, bottom: 0)

                        Column {
                            Text(this.getJpegQualityLabel())
                                .fontSize(15)
                                .fontColor(0x000000)
                                .width(100.percent)
                                .margin(bottom: 8)

                            Row {
                                Text("1")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                Slider(value: this.jpegQuality, min: Float64(1.0), max: Float64(100.0), step: Float64(1.0))
                                    .layoutWeight(1)
                                    .trackColor(0xE5E5EA)
                                    .selectedColor(0x317AFF)
                                    .onChange({ val: Float64, _mode: SliderChangeMode =>
                                        this.jpegQuality = val
                                        this.refreshEstimates()
                                    })
                                Text("100")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                            }
                            .width(100.percent)
                            .alignItems(VerticalAlign.Center)

                            Button("Compress as JPEG")
                                .width(100.percent)
                                .height(44)
                                .fontSize(15)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.isCompressing) { 0xAAAAAA } else { 0x317AFF })
                                .borderRadius(8)
                                .margin(top: 12)
                                .onClick({ _evt => this.handleCompressJpeg() })
                        }
                        .width(100.percent)
                        .padding(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 12, bottom: 0)

                        Column {
                            Text(this.getWebpQualityLabel())
                                .fontSize(15)
                                .fontColor(0x000000)
                                .width(100.percent)
                                .margin(bottom: 8)

                            Row {
                                Text("1")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                                Slider(value: this.webpQuality, min: Float64(1.0), max: Float64(100.0), step: Float64(1.0))
                                    .layoutWeight(1)
                                    .trackColor(0xE5E5EA)
                                    .selectedColor(0x5856D6)
                                    .onChange({ val: Float64, _mode: SliderChangeMode =>
                                        this.webpQuality = val
                                        this.refreshEstimates()
                                    })
                                Text("100")
                                    .fontSize(12)
                                    .fontColor(0x8E8E93)
                            }
                            .width(100.percent)
                            .alignItems(VerticalAlign.Center)

                            Button("Compress as WebP")
                                .width(100.percent)
                                .height(44)
                                .fontSize(15)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.isCompressing) { 0xAAAAAA } else { 0x5856D6 })
                                .borderRadius(8)
                                .margin(top: 12)
                                .onClick({ _evt => this.handleCompressWebP() })
                        }
                        .width(100.percent)
                        .padding(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 12, bottom: 0)

                        Column {
                            Text("8x8 Block-Aligned Compression")
                                .fontSize(15)
                                .fontColor(0x000000)
                                .width(100.percent)
                                .margin(bottom: 4)
                            Text("Scales to nearest 8-pixel boundary (iOS DCT threadgroup constraint)")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                                .margin(bottom: 12)

                            Button("Compress with Max Size")
                                .width(100.percent)
                                .height(44)
                                .fontSize(15)
                                .fontColor(0xFFFFFF)
                                .backgroundColor(if (this.isCompressing) { 0xAAAAAA } else { 0xFF9500 })
                                .borderRadius(8)
                                .onClick({ _evt => this.handleCompressWithMaxSize() })
                        }
                        .width(100.percent)
                        .padding(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 12, bottom: 0)

                        if (this.isCompressing) {
                            Row {
                                LoadingProgress().width(20).height(20).color(0x317AFF)
                                Text("  Processing...")
                                    .fontSize(14)
                                    .fontColor(0x317AFF)
                            }
                            .width(100.percent)
                            .justifyContent(FlexAlign.Center)
                            .margin(top: 20)
                        } else if (this.lastResultMsg.size > 0) {
                            Text(this.lastResultMsg)
                                .fontSize(14)
                                .fontColor(0x34C759)
                                .width(100.percent)
                                .textAlign(TextAlign.Center)
                                .padding(16)
                                .margin(top: 8)
                        }

                        Column {
                            Text("Supported Formats")
                                .fontSize(13)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(0x000000)
                                .width(100.percent)
                                .margin(bottom: 8)
                            Text("Input:  JPEG / PNG / WebP / GIF (first frame)")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                            Text("Output: JPEG / WebP")
                                .fontSize(13)
                                .fontColor(0x8E8E93)
                                .width(100.percent)
                                .margin(top: 4)
                            Text("DCT/Huffman pipeline: deferred (no Metal on HarmonyOS)")
                                .fontSize(12)
                                .fontColor(0xAAAAAA)
                                .width(100.percent)
                                .margin(top: 4)
                        }
                        .width(100.percent)
                        .padding(16)
                        .backgroundColor(0xFFFFFF)
                        .borderRadius(12)
                        .margin(left: 16, right: 16, top: 12, bottom: 32)
                    }
                    .width(100.percent)
                }
                .layoutWeight(1)
                .scrollBar(BarState.Off)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xF2F2F7)
        .padding(bottom: getSafeAreaBottom())
        .onAppear({ => this.ensureLoaded() })
    }
}
