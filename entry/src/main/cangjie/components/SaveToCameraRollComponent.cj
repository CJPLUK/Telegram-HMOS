package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getSaveToCameraRollService

/**
 * 保存到相册组件（Save To Camera Roll Component）
 *
 * 对应 iOS SaveToCameraRoll.swift 的保存触发界面。
 * 提供一个按钮：点击后通过 SaveToCameraRollService 将指定文件保存到系统相册，
 * 并在按钮旁显示保存结果（保存中 / 成功 / 失败）。
 *
 * 用法示例：
 *   SaveToCameraRollComponent(filePath: "/data/storage/el2/.../photo.jpg", isVideo: false)
 */
@Component
public class SaveToCameraRollComponent {
    // 要保存的本地文件路径（file:// 或绝对路径均可，Service 会自动补全 file:// 前缀）
    public var filePath: String = ""
    // true 表示保存视频，false 表示保存图片
    public var isVideo: Bool = false
    // 保存完成后的可选回调（主线程调用）
    public var onSaved: (Bool) -> Unit = { _ok: Bool => }

    // 是否显示复制 URI 按钮（对应 iOS copyToPasteboard；D 级 URI 文本复制）
    public var showCopyUriButton: Bool = false
    // 复制完成后的可选回调
    public var onCopied: (Bool) -> Unit = { _ok: Bool => }

    // 按钮内部状态
    @State var isSaving: Bool = false
    @State var saveResult: String = ""  // "" / "success" / "error"
    @State var copyResult: String = ""  // "" / "copied" / "copy_error"

    public func aboutToAppear(): Unit {
        Hilog.info(0, "CjTelegram", "[SaveToCameraRollComponent] ready, isVideo=${this.isVideo}")
    }

    // ──────────────── helpers（不能在 build() 中用 let，提取为 func）────────────────

    private func buttonLabel(): String {
        if (this.isSaving) { return "Saving..." }
        if (this.saveResult == "success") { return "Saved" }
        if (this.saveResult == "error") { return "Failed" }
        return "Save to Gallery"
    }

    private func buttonColor(): Int64 {
        if (this.saveResult == "success") { return 0xFF34C759 }
        if (this.saveResult == "error") { return 0xFFFF3B30 }
        return 0xFF007AFF
    }

    private func isButtonDisabled(): Bool {
        return this.isSaving || this.saveResult == "success"
    }

    private func copyButtonLabel(): String {
        if (this.copyResult == "copied") { return "Copied!" }
        if (this.copyResult == "copy_error") { return "Copy failed" }
        return "Copy Link"
    }

    private func copyButtonColor(): Int64 {
        if (this.copyResult == "copied") { return 0xFF34C759 }
        if (this.copyResult == "copy_error") { return 0xFFFF3B30 }
        return 0xFF5856D6
    }

    // ──────────────── core action ────────────────

    /**
     * 执行保存：调用 SaveToCameraRollService（showAssetsCreationDialog 免权限异步弹窗），
     * 结果回调在主线程 launch 内触发，更新状态。
     */
    private func performSave(): Unit {
        if (this.isSaving || this.saveResult == "success") { return }
        if (this.filePath.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[SaveToCameraRollComponent] filePath is empty, skip")
            this.saveResult = "error"
            return
        }

        this.isSaving = true
        this.saveResult = ""
        let pathToSave = this.filePath
        let saveVideo = this.isVideo
        let service = getSaveToCameraRollService()

        let onResult = { ok: Bool =>
            launch {
                this.saveResult = if (ok) { "success" } else { "error" }
                this.isSaving = false
                this.onSaved(ok)
            }
        }
        if (saveVideo) {
            service.saveVideoToGallery(pathToSave, onResult)
        } else {
            service.saveImageToGallery(pathToSave, onResult)
        }
    }

    /**
     * 执行复制文件 URI 到剪贴板（对应 iOS copyToPasteboard）
     * D-tier 替代：复制 file:// URI 文本（原始字节 UDMF PixelMap 路径无文档支撑，defer）
     */
    private func performCopy(): Unit {
        if (this.filePath.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[SaveToCameraRollComponent] filePath empty, skip copy")
            this.copyResult = "copy_error"
            return
        }
        let pathToCopy = this.filePath
        let _ = spawn {
            let ok = getSaveToCameraRollService().copyMediaFileUri(pathToCopy)
            let res = if (ok) { "copied" } else { "copy_error" }
            launch {
                this.copyResult = res
                this.onCopied(ok)
            }
        }
    }

    // ──────────────── build ────────────────

    public func build() {
        Row {
            Button(this.buttonLabel())
                .backgroundColor(this.buttonColor())
                .fontColor(0xFFFFFFFF)
                .fontSize(15)
                .padding(top: 8, right: 16, bottom: 8, left: 16)
                .borderRadius(8)
                .enabled(!this.isButtonDisabled())
                .onClick({ _ =>
                    this.performSave()
                })
            if (this.showCopyUriButton) {
                Button(this.copyButtonLabel())
                    .backgroundColor(this.copyButtonColor())
                    .fontColor(0xFFFFFFFF)
                    .fontSize(15)
                    .padding(top: 8, right: 16, bottom: 8, left: 16)
                    .borderRadius(8)
                    .margin(left: 8)
                    .onClick({ _ =>
                        this.performCopy()
                    })
            }
        }
        .justifyContent(FlexAlign.Center)
        .width(100.percent)
        .padding(top: 4, bottom: 4)
    }
}
