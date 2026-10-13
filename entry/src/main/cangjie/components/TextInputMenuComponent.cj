package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.TLTextEntity
import ohos_app_cangjie_entry.services.getTextInputMenuService

/**
 * 文本格式菜单组件
 *
 * 对应 iOS: submodules/TextInputMenu/Sources/TextInputMenu.swift
 *
 * 功能:
 * - 横排展示 7 个格式按钮: Bold / Italic / Underline / Strikethrough / Link / Mono / Spoiler
 * - 点击格式按钮后调用 TextInputMenuService 构建对应 TLTextEntity 并通过 onApply 回调返回
 * - Link 按钮触发 onRequestLink 回调，由调用方弹出链接编辑弹窗
 * - 点击 Dismiss 或调用方关闭时触发 onDismiss 回调
 *
 * 使用方:
 *   TextInputMenuComponent(
 *       selectedText: "some text",
 *       selOffset: Int32(0),
 *       selLength: Int32(9),
 *       onApply: { entity: TLTextEntity => ... },
 *       onRequestLink: { => ... },
 *       onDismiss: { => ... }
 *   )
 */
@Component
public class TextInputMenuComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()

    // 被选中的文本（用于展示，不参与实体构建）
    public var selectedText: String = ""

    // 选区在整条消息文本中的字节偏移和长度
    public var selOffset: Int32 = 0
    public var selLength: Int32 = 0

    // 回调：应用格式实体（bold/italic/underline/strike/code/spoiler）
    public var onApply: (TLTextEntity) -> Unit = { _e: TLTextEntity => }

    // 回调：用户点击 Link，由调用方弹出 ChatTextLinkEditUIComponent
    public var onRequestLink: () -> Unit = { => }

    // 回调：关闭菜单
    public var onDismiss: () -> Unit = { => }

    private func applyBold() {
        let entity = getTextInputMenuService().buildBoldEntity(this.selOffset, this.selLength)
        Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] applyBold")
        this.onApply(entity)
    }

    private func applyItalic() {
        let entity = getTextInputMenuService().buildItalicEntity(this.selOffset, this.selLength)
        Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] applyItalic")
        this.onApply(entity)
    }

    private func applyUnderline() {
        let entity = getTextInputMenuService().buildUnderlineEntity(this.selOffset, this.selLength)
        Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] applyUnderline")
        this.onApply(entity)
    }

    private func applyStrike() {
        let entity = getTextInputMenuService().buildStrikeEntity(this.selOffset, this.selLength)
        Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] applyStrike")
        this.onApply(entity)
    }

    private func applyCode() {
        let entity = getTextInputMenuService().buildCodeEntity(this.selOffset, this.selLength)
        Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] applyCode")
        this.onApply(entity)
    }

    private func applySpoiler() {
        let entity = getTextInputMenuService().buildSpoilerEntity(this.selOffset, this.selLength)
        Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] applySpoiler")
        this.onApply(entity)
    }

    private func formatButtonBg(label: String): Int64 {
        if (label == "B") { return 0x007AFF }
        if (label == "I") { return 0x007AFF }
        if (label == "U") { return 0x007AFF }
        if (label == "S") { return 0x007AFF }
        if (label == "Mono") { return 0x007AFF }
        if (label == "Link") { return 0x007AFF }
        if (label == "Spoiler") { return 0x007AFF }
        return 0x007AFF
    }

    public func build() {
        Column {
            // 选中文本预览行（非空时显示）
            if (this.selectedText.size > 0) {
                Row {
                    Text(this.selectedText)
                        .fontSize(13)
                        .fontColor(0x3C3C43)
                        .maxLines(1)
                        .textOverflow(TextOverflow.Ellipsis)
                        .padding(left: 16, right: 16, top: 6, bottom: 2)
                }
                .width(100.percent)
            }

            // 格式按钮横排
            Row {
                // Bold
                Column {
                    Text("B")
                        .fontSize(15)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                        .width(36)
                        .height(36)
                        .backgroundColor(0x007AFF)
                        .borderRadius(8)
                }
                .onClick({ _evt =>
                    this.applyBold()
                })
                .margin(right: 6)

                // Italic
                Column {
                    Text("I")
                        .fontSize(15)
                        .fontStyle(FontStyle.Italic)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                        .width(36)
                        .height(36)
                        .backgroundColor(0x007AFF)
                        .borderRadius(8)
                }
                .onClick({ _evt =>
                    this.applyItalic()
                })
                .margin(right: 6)

                // Underline
                Column {
                    Text("U")
                        .fontSize(15)
                        .decoration(decorationType: TextDecorationType.Underline, color: 0xFFFFFF)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                        .width(36)
                        .height(36)
                        .backgroundColor(0x007AFF)
                        .borderRadius(8)
                }
                .onClick({ _evt =>
                    this.applyUnderline()
                })
                .margin(right: 6)

                // Strikethrough
                Column {
                    Text(trSource("S"))
                        .fontSize(15)
                        .decoration(decorationType: TextDecorationType.LineThrough, color: 0xFFFFFF)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                        .width(36)
                        .height(36)
                        .backgroundColor(0xFF3B30)
                        .borderRadius(8)
                }
                .onClick({ _evt =>
                    this.applyStrike()
                })
                .margin(right: 6)

                // Link
                Column {
                    Text(trSource("Link"))
                        .fontSize(12)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                        .width(40)
                        .height(36)
                        .backgroundColor(0x34C759)
                        .borderRadius(8)
                }
                .onClick({ _evt =>
                    Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] onRequestLink")
                    this.onRequestLink()
                })
                .margin(right: 6)

                // Mono
                Column {
                    Text("Mono")
                        .fontSize(11)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                        .width(44)
                        .height(36)
                        .backgroundColor(0x5856D6)
                        .borderRadius(8)
                }
                .onClick({ _evt =>
                    this.applyCode()
                })
                .margin(right: 6)

                // Spoiler
                Column {
                    Text(trSource("Spoiler"))
                        .fontSize(10)
                        .fontColor(0xFFFFFF)
                        .textAlign(TextAlign.Center)
                        .width(52)
                        .height(36)
                        .backgroundColor(0xFF9500)
                        .borderRadius(8)
                }
                .onClick({ _evt =>
                    this.applySpoiler()
                })
            }
            .width(100.percent)
            .padding(left: 12, right: 12, top: 8, bottom: 8)
            .justifyContent(FlexAlign.Start)

            // 关闭按钮行
            Row {
                Button(trSource("Done"))
                    .layoutWeight(1)
                    .height(38)
                    .fontSize(15)
                    .fontColor(0xFFFFFF)
                    .backgroundColor(0x007AFF)
                    .borderRadius(10)
                    .onClick({ _evt =>
                        Hilog.info(0, "CjTelegram", "[TextInputMenuComponent] onDismiss")
                        this.onDismiss()
                    })
            }
            .width(100.percent)
            .padding(left: 16, right: 16, bottom: 12)
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
        .borderRadius(14)
    }
}
