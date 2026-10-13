package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.TLTextEntity
import ohos_app_cangjie_entry.services.getChatTextLinkEditService

/**
 * 文本链接编辑弹窗组件
 *
 * 对应 iOS: chatTextLinkEditController (ChatTextLinkEditUI/Sources/ChatTextLinkEditController.swift)
 *
 * 功能:
 * - 显示被选中文本（只读）
 * - URL 输入框（Stack overlay Text 提示方案）
 * - URL 合法性实时校验（http / https / tg / ton / tonsite）
 * - Done — 构建 TLTextEntity 并回调 onApply
 * - Cancel — 回调 onDismiss
 *
 * 使用方:
 *   ChatTextLinkEditUIComponent(
 *       linkText: "selected text",
 *       initialUrl: "https://example.com",
 *       selOffset: Int32(0),
 *       selLength: Int32(13),
 *       onApply: { entity: TLTextEntity => ... },
 *       onDismiss: { => ... }
 *   )
 */
@Component
public class ChatTextLinkEditUIComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()

    // 被选中的文本（只读展示，与 iOS alertText 对应）
    var linkText: String = ""

    // 已有 URL（编辑时预填，添加时为空）
    var initialUrl: String = ""

    // 选区在整条消息文本中的偏移和长度（用于构建 TLTextEntity）
    var selOffset: Int32 = 0
    var selLength: Int32 = 0

    // 回调：应用新 URL；entity.url 为空字符串表示移除链接
    var onApply: (TLTextEntity) -> Unit = { _e: TLTextEntity => }

    // 回调：取消
    var onDismiss: () -> Unit = { => }

    // 内部编辑状态
    @State var urlInput: String = ""
    @State var hasError: Bool = false
    @State var isInitialized: Bool = false

    private func isEditMode(): Bool {
        return this.initialUrl.size > 0
    }

    private func titleText(): String {
        if (this.isEditMode()) {
            return "Edit Link"
        }
        return "Add Link"
    }

    private func doApply() {
        let svc = getChatTextLinkEditService()
        let trimmed = this.urlInput
        if (trimmed.size == 0) {
            // 空 URL — 表示移除链接（与 iOS apply("", nil) 对应）
            let entity = svc.buildTextUrlEntity(this.selOffset, this.selLength, "")
            this.onApply(entity)
            return
        }
        let normalized = svc.normalizeUrl(trimmed)
        if (svc.isValidLinkUrl(normalized)) {
            this.hasError = false
            let entity = svc.buildTextUrlEntity(this.selOffset, this.selLength, normalized)
            Hilog.info(0, "CjTelegram", "[ChatTextLinkEditUI] apply url=${normalized}")
            this.onApply(entity)
        } else {
            this.hasError = true
            Hilog.info(0, "CjTelegram", "[ChatTextLinkEditUI] invalid url rejected")
        }
    }

    public override func aboutToAppear(): Unit {
        if (!this.isInitialized) {
            this.urlInput = this.initialUrl
            this.isInitialized = true
        }
    }

    public func build() {
        Column {
            // 标题行
            Row {
                Text(this.titleText())
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
            }
            .width(100.percent)
            .padding(top: 16, bottom: 12)

            // 被选中文本展示（只读）
            if (this.linkText.size > 0) {
                Row {
                    Text(this.linkText)
                        .fontSize(14)
                        .fontColor(0x3C3C43)
                        .maxLines(2)
                        .textOverflow(TextOverflow.Ellipsis)
                        .width(100.percent)
                        .padding(left: 16, right: 16, top: 8, bottom: 8)
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(8)
                }
                .width(100.percent)
                .padding(left: 16, right: 16, bottom: 12)
            }

            // URL 输入区域（Stack overlay Text 提示方案）
            Stack {
                // 占位符文字（只在输入为空时显示，放在底层）
                if (this.urlInput.size == 0) {
                    Text("URL (e.g. https://example.com)")
                        .fontSize(15)
                        .fontColor(0xC7C7CC)
                        .padding(left: 14)
                        .width(100.percent)
                        .height(44)
                        .enabled(false)
                }

                TextInput(text: this.urlInput)
                    .width(100.percent)
                    .height(44)
                    .fontSize(15)
                    .fontColor(0x000000)
                    .backgroundColor(if (this.urlInput.size == 0) { Color.Transparent } else { 0xFFFFFF })
                    .borderRadius(8)
                    .padding(left: 12, right: 12)
                    .border(
                        width: 1,
                        color: if (this.hasError) { 0xFF3B30 } else { 0xC6C6C8 },
                        style: BorderStyle.Solid
                    )
                    .onChange({ value: String =>
                        this.urlInput = value
                        if (this.hasError && value.size > 0) {
                            this.hasError = false
                        }
                    })
                    .onSubmit({ _enterKey =>
                        this.doApply()
                    })
            }
            .width(100.percent)
            .height(44)
            .padding(left: 16, right: 16, bottom: 4)

            // 错误提示
            if (this.hasError) {
                Row {
                    Text("Invalid URL. Use http, https, tg, ton or tonsite.")
                        .fontSize(12)
                        .fontColor(0xFF3B30)
                        .padding(left: 16, right: 16)
                }
                .width(100.percent)
                .padding(bottom: 8)
            } else {
                Row {}
                    .height(8)
            }

            // 操作按钮行
            Row {
                // Cancel
                Button(trSource("Cancel"))
                    .layoutWeight(1)
                    .height(44)
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(0xF2F2F7)
                    .borderRadius(10)
                    .margin(right: 8)
                    .onClick({ evt =>
                        this.hasError = false
                        this.onDismiss()
                    })

                // Done
                Button(trSource("Done"))
                    .layoutWeight(1)
                    .height(44)
                    .fontSize(16)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x007AFF)
                    .borderRadius(10)
                    .onClick({ evt =>
                        this.doApply()
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 8, bottom: 16)
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
        .borderRadius(14)
        .padding(top: 0)
    }
}
