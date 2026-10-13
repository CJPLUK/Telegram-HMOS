package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import ohos_app_cangjie_entry.services.getImageCompressionService
import ohos_app_cangjie_entry.services.getAppFilesDir

/**
 * 图片压缩 UI 组件（ImageCompression feature）
 *
 * 功能：
 *   - 输入图片路径后一键压缩（JPEG 质量可调）
 *   - 可设定最大像素边长进行缩放压缩
 *   - 显示压缩结果大小与状态
 *   - 调用 ImageCompressionService，非 mock/stub
 *
 * 使用方式：
 *   ImageCompressionComponent(imagePath: "/path/to/photo.jpg")
 */
@Component
public class ImageCompressionComponent {
    // 待压缩的源图片路径（由外部传入）
    public var imagePath: String = ""
    // 压缩完成回调：(outputPath: String, sizeBytes: Int64) -> Unit
    public var onCompressed: (String, Int64) -> Unit = { _p, _s => }

    // JPEG 质量 (0–100)
    @State var quality: Int64 = 80
    // 最大像素边长（0 表示不缩放）
    @State var maxPixels: Int64 = 1280
    // 是否启用尺寸缩放
    @State var enableResize: Bool = true
    // 压缩结果状态文本
    @State var statusText: String = ""
    // 压缩后文件大小（字节）
    @State var resultSize: Int64 = 0
    // 压缩后输出路径
    @State var outputPath: String = ""
    // 是否正在压缩
    @State var isProcessing: Bool = false

    public func aboutToAppear(): Unit {
        Hilog.info(0, "CjTelegram", "[ImageCompressionComponent] aboutToAppear")
    }

    /**
     * 执行压缩操作（在 spawn 中运行避免阻塞 UI）
     */
    private func doCompress() {
        if (this.imagePath.isEmpty()) {
            this.statusText = "No image selected"
            return
        }
        if (this.isProcessing) { return }
        this.isProcessing = true
        this.statusText = "Compressing..."
        this.resultSize = 0
        this.outputPath = ""

        let pathCopy = this.imagePath
        let qualityCopy = UInt8(this.quality)
        let maxPxCopy = Int32(this.maxPixels)
        let enableResizeCopy = this.enableResize

        let _ = spawn {
            let svc = getImageCompressionService()
            let bytes: Array<UInt8>
            if (enableResizeCopy && maxPxCopy > 0) {
                bytes = svc.compressToMaxPixelSize(pathCopy, maxPxCopy, qualityCopy)
            } else {
                bytes = svc.compressToJpeg(pathCopy, qualityCopy)
            }

            if (bytes.size == 0) {
                launch {
                    this.statusText = "Compression failed"
                    this.isProcessing = false
                }
            } else {
                let savedPath = this.saveCompressedBytes(bytes)
                let sz = Int64(bytes.size)
                launch {
                    this.resultSize = sz
                    this.outputPath = savedPath
                    this.statusText = if (savedPath.isEmpty()) { "Save failed" } else { "Done" }
                    this.isProcessing = false
                    this.onCompressed(savedPath, sz)
                }
            }
        }
    }

    /**
     * 将压缩后字节写入临时文件，返回绝对路径。
     * 失败返回空字符串。
     */
    private func saveCompressedBytes(bytes: Array<UInt8>): String {
        let filesDir = getAppFilesDir()
        if (filesDir.isEmpty()) { return "" }
        let dir = filesDir + "/compressed"
        let outPath = dir + "/compressed_output.jpg"
        try {
            FileIo.mkdir(dir)
        } catch (_e: Exception) {}
        try {
            let file = FileIo.open(outPath,
                mode: OpenMode.CREATE | OpenMode.READ_WRITE | OpenMode.TRUNC)
            FileIo.write(file.fd, bytes)
            FileIo.close(file.fd)
            return outPath
        } catch (_e: Exception) {
            return ""
        }
    }

    /**
     * 格式化字节数为可读字符串（KB/MB）
     */
    private func formatSize(): String {
        if (this.resultSize <= 0) { return "" }
        if (this.resultSize < 1024) {
            return "${this.resultSize} B"
        } else if (this.resultSize < 1048576) {
            let kb = this.resultSize / 1024
            return "${kb} KB"
        } else {
            let mb = this.resultSize / 1048576
            return "${mb} MB"
        }
    }

    public func build() {
        Column {
            // 标题行
            Row {
                Text("Image Compression")
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0xFF1C1C1E)
            }
            .width(100.percent)
            .padding(16)

            // 源路径显示
            Row {
                Text("Source:")
                    .fontSize(14)
                    .fontColor(0xFF8E8E93)
                    .width(80)
                Text(if (this.imagePath.isEmpty()) { "No image" } else { this.imagePath })
                    .fontSize(12)
                    .fontColor(0xFF1C1C1E)
                    .maxLines(2)
                    .textOverflow(TextOverflow.Ellipsis)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 4, bottom: 4)

            // JPEG 质量滑块
            Row {
                Text("Quality:")
                    .fontSize(14)
                    .fontColor(0xFF1C1C1E)
                    .width(80)
                Slider(value: Float64(this.quality), min: 1.0, max: 100.0, step: 1.0)
                    .width(160)
                    .onChange({ value: Float64, _mode: SliderChangeMode =>
                        this.quality = Int64(value)
                    })
                Text("${this.quality}")
                    .fontSize(14)
                    .fontColor(0xFF007AFF)
                    .width(36)
                    .textAlign(TextAlign.End)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 8)

            // 缩放开关
            Row {
                Text("Resize:")
                    .fontSize(14)
                    .fontColor(0xFF1C1C1E)
                    .width(80)
                Toggle(ToggleType.Switch, isOn: this.enableResize)
                    .onChange({ isOn: Bool =>
                        this.enableResize = isOn
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 4, bottom: 4)

            // 最大像素边长（仅 enableResize 时显示）
            if (this.enableResize) {
                Row {
                    Text("Max px:")
                        .fontSize(14)
                        .fontColor(0xFF1C1C1E)
                        .width(80)
                    Slider(value: Float64(this.maxPixels), min: 160.0, max: 4096.0, step: 160.0)
                        .width(160)
                        .onChange({ value: Float64, _mode: SliderChangeMode =>
                            this.maxPixels = Int64(value)
                        })
                    Text("${this.maxPixels}")
                        .fontSize(14)
                        .fontColor(0xFF007AFF)
                        .width(50)
                        .textAlign(TextAlign.End)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, top: 4, bottom: 8)
            }

            // 压缩按钮
            Button(if (this.isProcessing) { "Compressing..." } else { "Compress" })
                .width(200)
                .height(44)
                .borderRadius(22)
                .fontSize(16)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(if (this.isProcessing) { 0xFF8E8E93 } else { 0xFF007AFF })
                .margin(top: 12, bottom: 12)
                .onClick({ _evt =>
                    this.doCompress()
                })

            // 状态文本
            if (!this.statusText.isEmpty()) {
                Text(this.statusText)
                    .fontSize(13)
                    .fontColor(
                        if (this.statusText == "Done") { 0xFF34C759 }
                        else if (this.statusText == "Compressing...") { 0xFF007AFF }
                        else { 0xFFFF3B30 }
                    )
                    .margin(top: 4, bottom: 4)
            }

            // 结果大小
            if (this.resultSize > 0) {
                Row {
                    Text("Result size: ")
                        .fontSize(14)
                        .fontColor(0xFF8E8E93)
                    Text(this.formatSize())
                        .fontSize(14)
                        .fontColor(0xFF1C1C1E)
                        .fontWeight(FontWeight.Medium)
                }
                .margin(top: 4, bottom: 4)
            }

            // 输出路径
            if (!this.outputPath.isEmpty()) {
                Text("Saved: ${this.outputPath}")
                    .fontSize(11)
                    .fontColor(0xFF8E8E93)
                    .maxLines(2)
                    .textOverflow(TextOverflow.Ellipsis)
                    .padding(left: 16, right: 16, top: 4, bottom: 8)
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFF2F2F7)
        .borderRadius(12)
        .margin(left: 16, right: 16, top: 8, bottom: 8)
    }
}
