package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import kit.ArkUI.launch
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.*
import ohos.resource.__GenerateResource__
import ohos.resource.AppResource

/**
 * 附件输入面板组件（ATIPN-UI-1）
 *
 * 布局（对应 iOS AttachmentTextInputPanelNode）：
 *   [ 附件按钮 📎 ][ TextArea 多行输入框 ][ 发送/语音按钮 ]
 *   下方可选：格式化工具条入口
 *
 * 数据流：
 *   TextArea.onChange → service.setText() → @State inputText 同步
 *   点击发送 → service.sendMessage() → RealMessageService → MTProtoClient.sendRequest()
 *
 * 外部回调（由宿主页面注入，如 ChatRoomPage）：
 *   onAttachmentTapped  — 点击附件按钮弹出 AttachmentPanel
 *   onVoiceRecordTapped — 点击语音按钮开始录音
 *   onFormatTapped      — 点击格式化按钮
 *   onMessageSent       — 发送成功后通知宿主刷新消息列表
 */
@Component
public class AttachmentTextInputPanelComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // ==================== 外部属性 ====================

    // 附件按钮点击回调
    public var onAttachmentTapped: () -> Unit = { => }
    // 语音按钮点击回调
    public var onVoiceRecordTapped: () -> Unit = { => }
    // 格式化按钮点击回调
    public var onFormatTapped: () -> Unit = { => }
    // 发送成功后通知宿主
    public var onMessageSent: () -> Unit = { => }

    // ==================== 内部状态 ====================

    @State var inputText: String = ""

    // ==================== 辅助方法 ====================

    private func getService(): AttachmentTextInputPanelService {
        return getAttachmentTextInputPanelService()
    }

    private func isSendMode(): Bool {
        return this.inputText.size > 0
    }

    private func doSend(): Unit {
        let svc = this.getService()
        svc.setText(this.inputText)
        let _ = spawn {
            let result = svc.sendMessage()
            if (result.success) {
                Hilog.info(0, "CjTelegram", "[AttachInputPanel] sendMessage OK")
                launch {
                    this.inputText = ""
                    this.onMessageSent()
                }
            } else {
                Hilog.info(0, "CjTelegram", "[AttachInputPanel] sendMessage failed")
            }
        }
    }

    // ==================== UI 构建 ====================

    public func build() {
        Column {
            // ---- 主输入行 ----
            Row {
                // 附件按钮（资源保真修复：Item List/AttachIcon.imageset/attach.pdf 转 SVG）
                Column {
                    Image(@r(app.media.media_ic_paperclip))
                        .width(22)
                        .height(22)
                        .fillColor(0x8E8E93)
                }
                .width(44)
                .height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .onClick({ _evt =>
                    this.onAttachmentTapped()
                })

                // 多行文本输入框（Stack overlay 实现提示文字覆盖层）
                Stack {
                    if (this.inputText.isEmpty()) {
                        Text(trSource("Message"))
                            .fontSize(16)
                            .fontColor(0x99000000)
                            .padding(left: 12, right: 0, top: 8, bottom: 8)
                            .alignSelf(ItemAlign.Start)
                    }
                    TextArea(text: this.inputText)
                        .fontSize(16)
                        .backgroundColor(Color.Transparent)
                        .onChange({ val =>
                            this.inputText = val
                            this.getService().setText(val)
                        })
                }
                .layoutWeight(1)
                .backgroundColor(0xF2F2F7)
                .borderRadius(20)
                .alignContent(Alignment.TopStart)

                // 发送 / 语音 按钮（资源保真修复：D-133 组件级 if/else 切换 @r() 图标资源，
                // Chat/Input/Text/SendIcon.imageset/send.pdf + Item List/Icons/Microphone.imageset/microphone.pdf 转 SVG）
                Column {
                    if (this.isSendMode()) {
                        Image(@r(app.media.media_ic_send))
                            .width(20)
                            .height(20)
                            .fillColor(0xFFFFFF)
                    } else {
                        Image(@r(app.media.media_ic_mic))
                            .width(20)
                            .height(20)
                            .fillColor(0x8E8E93)
                    }
                }
                .width(44)
                .height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor(if (this.isSendMode()) { 0x007AFF } else { Color.Transparent })
                .borderRadius(22)
                .margin(left: 6)
                .onClick({ _evt =>
                    if (this.isSendMode()) {
                        this.doSend()
                    } else {
                        this.onVoiceRecordTapped()
                    }
                })
            }
            .width(100.percent)
            .padding(left: 8, right: 8, top: 6, bottom: 6)
            .backgroundColor(0xFFFFFF)

            // ---- 格式化工具条入口（底部）----
            Row {
                Text("Aa")
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .padding(left: 16, right: 16, top: 6, bottom: 6)
                    .onClick({ _evt =>
                        this.onFormatTapped()
                    })
            }
            .width(100.percent)
            .justifyContent(FlexAlign.Start)
            .backgroundColor(0xFFFFFF)
            .border(width: 1, color: 0xE5E5EA, style: BorderStyle.Solid)
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
    }
}
