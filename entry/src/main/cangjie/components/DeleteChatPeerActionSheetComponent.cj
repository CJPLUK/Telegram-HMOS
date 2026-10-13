package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.DeleteChatPeerActionSheetService
import ohos_app_cangjie_entry.services.DeleteChatPeerActionType
import ohos_app_cangjie_entry.services.getDeleteChatPeerActionSheetService

/**
 * 删除会话确认项组件 — DeleteChatPeerActionSheetComponent
 *
 * 对应 iOS DeleteChatPeerActionSheetItem：
 *   头顶部圆形头像 → 对话名称 → 确认文案 → [操作按钮] [取消]
 *
 * 用法示例（ChatListPage 长按后展示）:
 *   DeleteChatPeerActionSheetComponent(
 *       peerName: chat.name,
 *       peerType: chat.peerType,
 *       peerId: chat.id,
 *       avatarText: chat.avatarText,
 *       avatarLocalPath: chat.avatarLocalPath,
 *       avatarColor: chat.avatarColor,
 *       action: DeleteChatPeerActionType.Delete,
 *       onDismiss: { => this.showDeleteSheet = false },
 *       onDeleted: { =>
 *           this.showDeleteSheet = false
 *           this.viewModel.removeChat(peerId)
 *       }
 *   )
 *
 * S-64 合规: aboutToAppear 声明为 public override func ... (): Unit
 * S-41/S-60 合规: build() 中无 let，所有计算提取为 private func
 */
@Component
public class DeleteChatPeerActionSheetComponent {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()

    // 对话名称
    var peerName: String = ""

    // 对话 peerType: "user" | "chat" | "channel"
    var peerType: String = "user"

    // 对话 peer ID
    var peerId: Int64 = 0

    // 头像占位文字（无真实头像时使用）
    var avatarText: String = ""

    // 真实头像本地路径（非空时显示图片）
    var avatarLocalPath: String = ""

    // 头像背景色（avatarText 模式使用）
    var avatarColor: Int64 = 0x317AFF

    // 操作类型：Delete / DeleteAndLeave / ClearHistory
    var action: DeleteChatPeerActionType = DeleteChatPeerActionType.Delete

    // 关闭回调（点取消 / 背景遮罩时）
    public var onDismiss: () -> Unit = { => }

    // 删除成功后的回调
    public var onDeleted: () -> Unit = { => }

    // 操作进行中状态
    @State var isLoading: Bool = false

    // ===================== 辅助计算方法 =====================

    private func hasRealAvatar(): Bool {
        return this.avatarLocalPath.size > 0
    }

    private func getAvatarInitial(): String {
        if (this.avatarText.size > 0) {
            return this.avatarText.toRuneArray()[0].toString()
        }
        return "?"
    }

    private func getConfirmationText(): String {
        return getDeleteChatPeerActionSheetService().confirmationText(
            this.peerName, this.peerType, this.action
        )
    }

    private func getActionButtonText(): String {
        return getDeleteChatPeerActionSheetService().actionButtonText(this.action)
    }

    // ===================== 操作方法 =====================

    private func onClickDelete(): Unit {
        if (this.isLoading) { return }
        this.isLoading = true
        let service = getDeleteChatPeerActionSheetService()
        let peerTypeCopy = this.peerType
        let peerIdCopy = this.peerId
        let actionCopy = this.action
        let _ = spawn {
            let success = service.performAction(peerTypeCopy, peerIdCopy, actionCopy)
            launch {
                this.isLoading = false
                if (success) {
                    Hilog.info(0, "CjTelegram", "[DeleteChatPeerActionSheetComponent] delete success: ${peerIdCopy}")
                    this.onDeleted()
                } else {
                    Hilog.info(0, "CjTelegram", "[DeleteChatPeerActionSheetComponent] delete failed: ${peerIdCopy}")
                    this.onDismiss()
                }
            }
        }
    }

    // ===================== UI =====================

    public func build() {
        Column {
            // 头像区域
            if (this.hasRealAvatar()) {
                Image(this.avatarLocalPath)
                    .width(60)
                    .height(60)
                    .borderRadius(30)
                    .objectFit(ImageFit.Cover)
                    .margin(bottom: 12)
            } else {
                Stack {
                    Text(this.getAvatarInitial())
                        .fontSize(26)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Medium)
                }
                .width(60)
                .height(60)
                .borderRadius(30)
                .backgroundColor(this.avatarColor)
                .margin(bottom: 12)
            }

            // 对话名称
            Text(this.peerName)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(0x000000)
                .maxLines(1)
                .textOverflow(TextOverflow.Ellipsis)
                .margin(bottom: 8)

            // 确认文案
            Text(this.getConfirmationText())
                .fontSize(14)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
                .maxLines(3)
                .margin(left: 20, right: 20, bottom: 20)

            // 操作按钮（红色 destructive）
            Button(this.getActionButtonText())
                .width(100.percent)
                .height(50)
                .fontSize(17)
                .fontColor(0xFFFFFF)
                .backgroundColor(if (this.isLoading) { 0xFFAAAA } else { 0xFF3B30 })
                .borderRadius(10)
                .margin(left: 16, right: 16, bottom: 8)
                .onClick({ _ =>
                    this.onClickDelete()
                })

            // 取消按钮
            Button(trSource("Cancel"))
                .width(100.percent)
                .height(50)
                .fontSize(17)
                .fontColor(0x317AFF)
                .backgroundColor(0xF2F2F7)
                .borderRadius(10)
                .margin(left: 16, right: 16, bottom: 16)
                .onClick({ _ =>
                    this.onDismiss()
                })
        }
        .width(100.percent)
        .padding(top: 24)
        .backgroundColor(0xFFFFFF)
        .alignItems(HorizontalAlign.Center)
    }
}
