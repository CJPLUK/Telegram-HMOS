package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * 附件输入面板数据层服务（ATIPN-API-1）
 *
 * 职责：
 * - 持有当前输入文本状态
 * - 封装 sendMessage 能力，调用链：
 *   AttachmentTextInputPanelService.sendMessage()
 *     → RealMessageService.sendMessage()
 *       → MTProtoClient.sendRequest()
 * - 提供 clearText / setText 状态管理
 * - 提供 isVoiceMode 切换（文本为空 → 语音，有文本 → 发送）
 *
 * 对应 iOS AttachmentTextInputPanelNode（Action Buttons + Text Input 逻辑）
 */
public class AttachmentTextInputPanelService {

    // ==================== 状态 ====================

    public var inputText: String = ""
    public var chatId: Int64 = 0
    public var chatPeerType: String = "user"

    // 回复模式（可被外部设置）
    public var replyToMsgId: Int32 = 0

    // ==================== 初始化 ====================

    public init() {}

    /**
     * 绑定聊天上下文（必须在使用前调用）
     */
    public func bindChat(peerType: String, peerId: Int64): Unit {
        this.chatPeerType = peerType
        this.chatId = peerId
    }

    // ==================== 文本状态管理 ====================

    public func setText(text: String): Unit {
        this.inputText = text
    }

    public func clearText(): Unit {
        this.inputText = ""
    }

    public func isVoiceMode(): Bool {
        return this.inputText.size == 0
    }

    // ==================== 发送能力 ====================

    /**
     * 发送消息
     *
     * 调用链：
     *   AttachmentTextInputPanelService.sendMessage()
     *     → RealMessageService.sendMessage(peerType, peerId, message)
     *       → MessagesSendMessage.toBytes() → MTProtoClient.sendRequest()
     *
     * @return SendMessageResult，调用方判断 success 字段
     */
    public func sendMessage(): SendMessageResult {
        let text = this.inputText
        let msgService = getRealMessageService()
        Hilog.info(0, "CjTelegram", "[AttachTextInputSvc] sendMessage chatId=${this.chatId}")
        let result: SendMessageResult
        if (this.replyToMsgId != 0) {
            result = msgService.sendMessageWithReply(
                this.chatPeerType,
                this.chatId,
                text,
                this.replyToMsgId
            )
        } else {
            result = msgService.sendMessage(
                this.chatPeerType,
                this.chatId,
                text
            )
        }
        if (result.success) {
            this.clearText()
            this.replyToMsgId = 0
        }
        return result
    }
}

// ==================== DI 单例 ====================

private var _attachTextInputPanelServiceInstance: Option<AttachmentTextInputPanelService> = None

public func getAttachmentTextInputPanelService(): AttachmentTextInputPanelService {
    match (_attachTextInputPanelServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AttachmentTextInputPanelService()
            _attachTextInputPanelServiceInstance = Some(inst)
            return inst
    }
}
