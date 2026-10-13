package ohos_app_cangjie_entry.adapters

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.services.*

/**
 * 待发消息管理对外接口适配层
 *
 * 将 TelegramCore_PendingMessagesService 的核心能力封装为业务友好的接口，
 * 供 ChatRoomViewModel、UI 层及其他 feature 调用，屏蔽队列内部实现细节。
 *
 * 真实 TL 调用链（完整可追踪）：
 *   enqueueOutgoing (Adapter)
 *     → TelegramCore_PendingMessagesService.enqueueMessage
 *       → RealMessageService.sendMessage  (text)
 *         → MTProtoClient.sendRPCRequest  (messages.sendMessage TL)
 *
 *   enqueueOutgoingPhoto (Adapter)
 *     → TelegramCore_PendingMessagesService.enqueuePhotoMessage
 *       → RealMessageService.sendPhoto  (photo)
 *         → RealMessageService.uploadFile + MTProtoClient.sendRPCRequest  (messages.sendMedia TL)
 *
 *   enqueueOutgoingDocument (Adapter)
 *     → TelegramCore_PendingMessagesService.enqueueDocumentMessage
 *       → RealMessageService.sendDocument  (document)
 *         → RealMessageService.uploadFile + MTProtoClient.sendRPCRequest  (messages.sendMedia TL)
 */
public class TelegramCore_PendingMessagesAdapter {
    private var service: TelegramCore_PendingMessagesService

    public init() {
        this.service = getPendingMessagesService()
    }

    // ==================== 入队接口 ====================

    /**
     * 入队文本消息（对外主接口）
     *
     * 立即返回本地消息 ID（可用于 UI 乐观渲染），
     * 后台异步通过 messages.sendMessage TL 发送并更新状态。
     *
     * @param peerType    "user" / "chat" / "channel"
     * @param peerId      目标对等方 ID
     * @param content     消息文本内容
     * @return localId    本地消息标识符
     */
    public func enqueueOutgoing(peerType: String, peerId: Int64, content: String): String {
        Hilog.info(0, "CjTelegram", "[PendingMsgAdp] enqueueOutgoing peer=${peerId} content_len=${content.size}")
        return this.service.enqueueMessage(peerType, peerId, content)
    }

    /**
     * 入队文本消息（带回复）
     *
     * @param peerType     "user" / "chat" / "channel"
     * @param peerId       目标对等方 ID
     * @param content      消息文本内容
     * @param replyToMsgId 被回复消息 ID
     * @return localId
     */
    public func enqueueOutgoingReply(peerType: String, peerId: Int64, content: String,
                                      replyToMsgId: Int32): String {
        Hilog.info(0, "CjTelegram", "[PendingMsgAdp] enqueueOutgoingReply peer=${peerId} replyTo=${replyToMsgId}")
        return this.service.enqueueMessage(peerType, peerId, content, replyToMsgId: replyToMsgId)
    }

    /**
     * 入队照片消息
     *
     * 后台通过 messages.sendMedia (InputMediaUploadedPhoto) TL 发送。
     *
     * @param peerType   目标对等方类型
     * @param peerId     目标对等方 ID
     * @param photoData  照片字节数据
     * @param fileName   文件名
     * @param caption    说明文字
     * @return localId
     */
    public func enqueueOutgoingPhoto(peerType: String, peerId: Int64, photoData: Array<Byte>,
                                      fileName: String, caption: String): String {
        Hilog.info(0, "CjTelegram", "[PendingMsgAdp] enqueueOutgoingPhoto peer=${peerId} size=${photoData.size}")
        return this.service.enqueuePhotoMessage(peerType, peerId, photoData, fileName, caption)
    }

    /**
     * 入队文档消息（文件/视频/语音等）
     *
     * 后台通过 messages.sendMedia (InputMediaUploadedDocument) TL 发送。
     *
     * @param peerType   目标对等方类型
     * @param peerId     目标对等方 ID
     * @param fileData   文件字节数据
     * @param fileName   文件名
     * @param mimeType   MIME 类型
     * @param caption    说明文字
     * @return localId
     */
    public func enqueueOutgoingDocument(peerType: String, peerId: Int64, fileData: Array<Byte>,
                                         fileName: String, mimeType: String,
                                         caption: String): String {
        Hilog.info(0, "CjTelegram", "[PendingMsgAdp] enqueueOutgoingDocument peer=${peerId} fileName=${fileName}")
        return this.service.enqueueDocumentMessage(peerType, peerId, fileData, fileName, mimeType,
                                                    caption)
    }

    // ==================== 重试 / 取消 ====================

    /**
     * 重试单条失败消息
     *
     * @param localId 要重试的消息本地 ID
     * @return true 表示找到消息并成功重入队；false 表示未找到（已发送/已取消）
     */
    public func retryMessage(localId: String): Bool {
        Hilog.info(0, "CjTelegram", "[PendingMsgAdp] retryMessage localId=${localId}")
        return this.service.retryMessage(localId)
    }

    /**
     * 重试所有失败消息
     */
    public func retryAllFailed(): Unit {
        Hilog.info(0, "CjTelegram", "[PendingMsgAdp] retryAllFailed")
        this.service.retryFailed()
    }

    /**
     * 取消待发消息
     *
     * 只能取消 Pending 或 Failed 状态的消息；Sending 状态无法取消。
     *
     * @param localId 要取消的消息本地 ID
     * @return true 表示成功移除；false 表示消息不存在或正在发送中
     */
    public func cancelMessage(localId: String): Bool {
        Hilog.info(0, "CjTelegram", "[PendingMsgAdp] cancelMessage localId=${localId}")
        return this.service.cancelMessage(localId)
    }

    // ==================== 状态查询 ====================

    /**
     * 获取所有待发消息列表快照（Pending + Sending + Failed）
     *
     * @return PendingMessage 列表，可用于 UI 展示发送队列状态
     */
    public func getPendingMessages(): ArrayList<PendingMessage> {
        return this.service.getAllPendingMessages()
    }

    /**
     * 获取失败消息列表快照
     *
     * @return 所有 status=Failed 的 PendingMessage 列表
     */
    public func getFailedMessages(): ArrayList<PendingMessage> {
        return this.service.getFailedMessages()
    }

    /**
     * 查询消息发送状态
     *
     * @param localId 消息本地 ID
     * @return "pending" / "sending" / "sent" / "failed" / "unknown"
     */
    public func getMessageStatus(localId: String): String {
        return this.service.getMessageStatus(localId)
    }

    /**
     * 待发队列是否为空
     *
     * @return true 表示当前没有 Pending 或 Sending 中的消息
     */
    public func isQueueEmpty(): Bool {
        return this.service.isQueueEmpty()
    }
}
