package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.ReentrantMutex

/**
 * 待发消息队列服务 — TelegramCore PendingMessages 核心层
 *
 * 对应 iOS TelegramCore/Sources/PendingMessages/EnqueueMessage.swift 的消息入队 / 发送管道：
 *   - 入队 (enqueue) → 乐观渲染（status=pending）
 *   - 调用 RealMessageService → messages.sendMessage / sendMedia
 *   - 收到服务端确认 → status=sent
 *   - 失败 → status=failed，可通过 retryFailed() 重入队列
 *
 * 真实 TL 链：
 *   enqueueMessage → processQueue → RealMessageService.sendMessage → messages.sendMessage (TL)
 *   enqueuePhotoMessage → processQueue → RealMessageService.sendPhoto → messages.sendMedia (TL)
 */

// ==================== PendingMessageStatus ====================

public enum PendingMessageStatus {
    | Pending
    | Sending
    | Sent
    | Failed
}

// ==================== PendingMessage ====================

/**
 * 待发消息队列条目
 *
 * 每条出队的消息在本地保留一个 PendingMessage 实例，
 * 直到服务端确认发送成功（status=Sent）或被明确取消。
 */
public class PendingMessage {
    // 本地唯一 ID（自增字符串，由队列分配）
    public var localId: String = ""
    // 目标对等方类型（"user" / "chat" / "channel"）
    public var peerType: String = "user"
    // 目标对等方 ID
    public var peerId: Int64 = 0
    // 消息类型："text" / "photo" / "document" / "voice" / "video"
    public var messageType: String = "text"
    // 文本内容（文本消息）或说明文字（媒体消息）
    public var content: String = ""
    // 媒体数据（照片/文档/语音/视频的二进制数据）
    public var mediaData: Array<Byte> = Array<Byte>(0, repeat: 0)
    // 媒体文件名
    public var mediaFileName: String = ""
    // 媒体 MIME 类型
    public var mediaMimeType: String = ""
    // 回复消息 ID（0 = 非回复模式）
    public var replyToMsgId: Int32 = 0
    // 服务端确认后的真实消息 ID
    public var serverMessageId: Int32 = 0
    // 服务端时间戳
    public var serverDate: Int32 = 0
    // 当前发送状态
    public var status: PendingMessageStatus = PendingMessageStatus.Pending
    // 已重试次数（超过 maxRetries 不再自动重试）
    public var retryCount: Int32 = 0
    // 最大自动重试次数
    public var maxRetries: Int32 = 3
    // 错误信息（status=Failed 时填充）
    public var errorMessage: String = ""

    public init() {}
}

// ==================== 全局单例 ====================

private var _pendingMessagesServiceInstance: Option<TelegramCore_PendingMessagesService> = None

/**
 * 获取全局待发消息服务单例
 */
public func getPendingMessagesService(): TelegramCore_PendingMessagesService {
    match (_pendingMessagesServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_PendingMessagesService()
            _pendingMessagesServiceInstance = Some(inst)
            return inst
    }
}

// ==================== TelegramCore_PendingMessagesService ====================

/**
 * 待发消息管理核心服务
 *
 * 维护三个子队列：
 *   - unsentQueue:  等待首次发送（status=Pending）
 *   - sendingQueue: 正在发送中（status=Sending）
 *   - failedQueue:  发送失败，等待手动重试（status=Failed）
 *
 * 线程模型：
 *   - 入队操作在调用方线程（通常是 UI 线程）执行
 *   - processQueue() 在后台 spawn 中执行，逐条调用 MTProto
 *   - queueMutex 保护队列访问，防止并发修改
 */
public class TelegramCore_PendingMessagesService {
    // 待发队列（Pending 状态）
    private var unsentQueue: ArrayList<PendingMessage> = ArrayList<PendingMessage>()
    // 发送中队列（Sending 状态）
    private var sendingQueue: ArrayList<PendingMessage> = ArrayList<PendingMessage>()
    // 失败队列（Failed 状态）
    private var failedQueue: ArrayList<PendingMessage> = ArrayList<PendingMessage>()
    // 本地 ID 计数器
    private var localIdCounter: Int64 = 0
    // 是否有后台 processQueue 线程在运行
    private var isProcessing: Bool = false
    // 互斥锁保护队列和 isProcessing 标志
    private var queueMutex: ReentrantMutex = ReentrantMutex()

    public init() {}

    // ==================== 入队接口 ====================

    /**
     * 入队文本消息
     *
     * 立即返回本地 ID，乐观状态=Pending；后台线程异步调用 messages.sendMessage。
     *
     * @param peerType  "user" / "chat" / "channel"
     * @param peerId    目标对等方 ID
     * @param content   消息文本
     * @param replyToMsgId 被回复消息 ID（0 = 不回复）
     * @return localId  可用于追踪该消息的本地标识符
     */
    public func enqueueMessage(peerType: String, peerId: Int64, content: String,
                                replyToMsgId!: Int32 = 0): String {
        let msg = PendingMessage()
        synchronized(this.queueMutex) {
            this.localIdCounter += 1
            msg.localId = "local_${this.localIdCounter}"
        }
        msg.peerType = peerType
        msg.peerId = peerId
        msg.messageType = "text"
        msg.content = content
        msg.replyToMsgId = replyToMsgId
        msg.status = PendingMessageStatus.Pending

        synchronized(this.queueMutex) {
            this.unsentQueue.add(msg)
        }
        Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Enqueued text msg localId=${msg.localId} to peer=${peerId}")
        this.scheduleProcessQueue()
        return msg.localId
    }

    /**
     * 入队照片消息
     *
     * 后台线程调用 messages.sendMedia (InputMediaUploadedPhoto)。
     *
     * @param peerType   目标对等方类型
     * @param peerId     目标对等方 ID
     * @param photoData  照片字节数据
     * @param fileName   文件名
     * @param caption    说明文字
     * @param replyToMsgId 被回复消息 ID（0 = 不回复）
     * @return localId
     */
    public func enqueuePhotoMessage(peerType: String, peerId: Int64, photoData: Array<Byte>,
                                     fileName: String, caption: String,
                                     replyToMsgId!: Int32 = 0): String {
        let msg = PendingMessage()
        synchronized(this.queueMutex) {
            this.localIdCounter += 1
            msg.localId = "local_${this.localIdCounter}"
        }
        msg.peerType = peerType
        msg.peerId = peerId
        msg.messageType = "photo"
        msg.content = caption
        msg.mediaData = photoData
        msg.mediaFileName = fileName
        msg.mediaMimeType = "image/jpeg"
        msg.replyToMsgId = replyToMsgId
        msg.status = PendingMessageStatus.Pending

        synchronized(this.queueMutex) {
            this.unsentQueue.add(msg)
        }
        Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Enqueued photo msg localId=${msg.localId} to peer=${peerId}")
        this.scheduleProcessQueue()
        return msg.localId
    }

    /**
     * 入队文档消息（文件/视频/语音等）
     *
     * 后台线程调用 messages.sendMedia (InputMediaUploadedDocument)。
     *
     * @param peerType   目标对等方类型
     * @param peerId     目标对等方 ID
     * @param fileData   文件字节数据
     * @param fileName   文件名
     * @param mimeType   MIME 类型
     * @param caption    说明文字
     * @param replyToMsgId 被回复消息 ID（0 = 不回复）
     * @return localId
     */
    public func enqueueDocumentMessage(peerType: String, peerId: Int64, fileData: Array<Byte>,
                                        fileName: String, mimeType: String, caption: String,
                                        replyToMsgId!: Int32 = 0): String {
        let msg = PendingMessage()
        synchronized(this.queueMutex) {
            this.localIdCounter += 1
            msg.localId = "local_${this.localIdCounter}"
        }
        msg.peerType = peerType
        msg.peerId = peerId
        msg.messageType = "document"
        msg.content = caption
        msg.mediaData = fileData
        msg.mediaFileName = fileName
        msg.mediaMimeType = mimeType
        msg.replyToMsgId = replyToMsgId
        msg.status = PendingMessageStatus.Pending

        synchronized(this.queueMutex) {
            this.unsentQueue.add(msg)
        }
        Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Enqueued document msg localId=${msg.localId} fileName=${fileName}")
        this.scheduleProcessQueue()
        return msg.localId
    }

    // ==================== 重试接口 ====================

    /**
     * 将所有失败消息重新入队（重试发送）
     *
     * 对应 iOS EnqueueMessage.swift 的 resendMessages() — 把 failed 状态消息放回 unsent 队列。
     */
    public func retryFailed(): Unit {
        var movedCount: Int64 = 0
        synchronized(this.queueMutex) {
            let toRetry = ArrayList<PendingMessage>()
            for (msg in this.failedQueue) {
                toRetry.add(msg)
            }
            for (msg in toRetry) {
                msg.status = PendingMessageStatus.Pending
                msg.errorMessage = ""
                this.unsentQueue.add(msg)
                movedCount += 1
            }
            this.failedQueue = ArrayList<PendingMessage>()
        }
        if (movedCount > 0) {
            Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Retrying ${movedCount} failed messages")
            this.scheduleProcessQueue()
        }
    }

    /**
     * 重试单条失败消息（通过 localId 定位）
     *
     * @param localId 要重试的消息的本地 ID
     * @return 是否找到并成功重入队
     */
    public func retryMessage(localId: String): Bool {
        var found = false
        synchronized(this.queueMutex) {
            var foundIdx: Int64 = -1
            var idx: Int64 = 0
            while (idx < this.failedQueue.size) {
                if (this.failedQueue[idx].localId == localId) {
                    foundIdx = idx
                    break
                }
                idx += 1
            }
            if (foundIdx >= 0) {
                let msg = this.failedQueue[foundIdx]
                msg.status = PendingMessageStatus.Pending
                msg.errorMessage = ""
                msg.retryCount += 1
                this.unsentQueue.add(msg)
                let newFailed = ArrayList<PendingMessage>()
                var i2: Int64 = 0
                while (i2 < this.failedQueue.size) {
                    if (i2 != foundIdx) { newFailed.add(this.failedQueue[i2]) }
                    i2 += 1
                }
                this.failedQueue = newFailed
                found = true
            }
        }
        if (found) {
            Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Retrying message localId=${localId}")
            this.scheduleProcessQueue()
        }
        return found
    }

    /**
     * 取消待发消息（从 unsent/failed 队列移除）
     *
     * 正在发送中（sending 状态）的消息无法取消。
     *
     * @param localId 要取消的消息本地 ID
     * @return 是否成功移除
     */
    public func cancelMessage(localId: String): Bool {
        var removed = false
        synchronized(this.queueMutex) {
            let newUnsent = ArrayList<PendingMessage>()
            for (msg in this.unsentQueue) {
                if (msg.localId == localId) {
                    removed = true
                } else {
                    newUnsent.add(msg)
                }
            }
            if (removed) {
                this.unsentQueue = newUnsent
            } else {
                let newFailed = ArrayList<PendingMessage>()
                for (msg in this.failedQueue) {
                    if (msg.localId == localId) {
                        removed = true
                    } else {
                        newFailed.add(msg)
                    }
                }
                if (removed) { this.failedQueue = newFailed }
            }
        }
        if (removed) {
            Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Cancelled message localId=${localId}")
        }
        return removed
    }

    // ==================== 状态查询 ====================

    /**
     * 获取全部待发消息列表（Pending + Sending + Failed）的快照
     */
    public func getAllPendingMessages(): ArrayList<PendingMessage> {
        let snapshot = ArrayList<PendingMessage>()
        synchronized(this.queueMutex) {
            for (msg in this.unsentQueue) { snapshot.add(msg) }
            for (msg in this.sendingQueue) { snapshot.add(msg) }
            for (msg in this.failedQueue) { snapshot.add(msg) }
        }
        return snapshot
    }

    /**
     * 获取仅失败消息列表的快照
     */
    public func getFailedMessages(): ArrayList<PendingMessage> {
        let snapshot = ArrayList<PendingMessage>()
        synchronized(this.queueMutex) {
            for (msg in this.failedQueue) { snapshot.add(msg) }
        }
        return snapshot
    }

    /**
     * 查询特定 localId 消息的发送状态
     *
     * @return status 字符串："pending" / "sending" / "sent" / "failed" / "unknown"
     */
    public func getMessageStatus(localId: String): String {
        synchronized(this.queueMutex) {
            for (msg in this.unsentQueue) {
                if (msg.localId == localId) { return "pending" }
            }
            for (msg in this.sendingQueue) {
                if (msg.localId == localId) { return "sending" }
            }
            for (msg in this.failedQueue) {
                if (msg.localId == localId) { return "failed" }
            }
        }
        return "unknown"
    }

    /**
     * 待发队列是否为空（unsent + sending 均空）
     */
    public func isQueueEmpty(): Bool {
        synchronized(this.queueMutex) {
            return this.unsentQueue.isEmpty() && this.sendingQueue.isEmpty()
        }
        return true
    }

    // ==================== 内部处理 ====================

    /**
     * 触发后台队列处理（若未运行则启动一个 spawn）
     */
    private func scheduleProcessQueue(): Unit {
        synchronized(this.queueMutex) {
            if (this.isProcessing) {
                return
            }
            this.isProcessing = true
        }
        let _ = spawn {
            this.processQueue()
        }
    }

    /**
     * 队列处理循环
     *
     * 逐条取出 unsent 消息，调用 RealMessageService 执行真实 TL 发送：
     *   - 文本：messages.sendMessage (TL)
     *   - 照片：messages.sendMedia → InputMediaUploadedPhoto (TL)
     *   - 文档：messages.sendMedia → InputMediaUploadedDocument (TL)
     *
     * 发送成功 → status=Sent，从 sendingQueue 移除
     * 发送失败且未达上限 → 重入 unsentQueue
     * 失败且达上限 → 移入 failedQueue，status=Failed
     */
    private func processQueue(): Unit {
        Hilog.info(0, "CjTelegram", "[PendingMsgSvc] processQueue started")
        var keepGoing = true
        while (keepGoing) {
            // 取出下一条待发消息
            var nextMsg: Option<PendingMessage> = None
            synchronized(this.queueMutex) {
                if (!this.unsentQueue.isEmpty()) {
                    let msg = this.unsentQueue[0]
                    msg.status = PendingMessageStatus.Sending
                    let newUnsent = ArrayList<PendingMessage>()
                    var idx: Int64 = 1
                    while (idx < this.unsentQueue.size) {
                        newUnsent.add(this.unsentQueue[idx])
                        idx += 1
                    }
                    this.unsentQueue = newUnsent
                    this.sendingQueue.add(msg)
                    nextMsg = Some(msg)
                } else {
                    keepGoing = false
                }
            }

            match (nextMsg) {
                case None => break
                case Some(msg) =>
                    this.sendPendingMessage(msg)
            }
        }

        synchronized(this.queueMutex) {
            this.isProcessing = false
        }
        Hilog.info(0, "CjTelegram", "[PendingMsgSvc] processQueue finished")
    }

    /**
     * 执行单条消息的真实 TL 发送
     *
     * 成功：将消息从 sendingQueue 移除，记录 serverMessageId/serverDate。
     * 失败：根据重试次数决定是重入 unsentQueue 还是移入 failedQueue。
     */
    private func sendPendingMessage(msg: PendingMessage): Unit {
        let localId = msg.localId
        Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Sending localId=${localId} type=${msg.messageType} peer=${msg.peerId}")

        var success = false
        var serverMsgId: Int32 = 0
        var serverDate: Int32 = 0
        var errorMsg: String = ""

        try {
            let messageService = getRealMessageService()
            let msgType = msg.messageType

            if (msgType == "text") {
                // messages.sendMessage (TL)
                var result = SendMessageResult()
                if (msg.replyToMsgId > 0) {
                    result = messageService.sendMessageWithReply(
                        msg.peerType,
                        msg.peerId,
                        msg.content,
                        msg.replyToMsgId
                    )
                } else {
                    result = messageService.sendMessage(
                        msg.peerType,
                        msg.peerId,
                        msg.content
                    )
                }
                success = result.success
                serverMsgId = result.messageId
                serverDate = result.date
                if (!success) {
                    errorMsg = result.errorMessage
                }
            } else if (msgType == "photo") {
                // messages.sendMedia (InputMediaUploadedPhoto) via RealMessageService.sendPhoto
                let result = messageService.sendPhoto(
                    msg.peerType,
                    msg.peerId,
                    msg.mediaData,
                    msg.mediaFileName,
                    caption: msg.content,
                    replyToMsgId: msg.replyToMsgId
                )
                success = result.success
                serverMsgId = result.messageId
                serverDate = result.date
                if (!success) {
                    errorMsg = result.errorMessage
                }
            } else {
                // messages.sendMedia (InputMediaUploadedDocument) via RealMessageService.sendDocument
                let result = messageService.sendDocument(
                    msg.peerType,
                    msg.peerId,
                    msg.mediaData,
                    msg.mediaFileName,
                    mimeType: msg.mediaMimeType,
                    caption: msg.content
                )
                success = result.success
                serverMsgId = result.messageId
                serverDate = result.date
                if (!success) {
                    errorMsg = result.errorMessage
                }
            }
        } catch (e: Exception) {
            success = false
            errorMsg = e.toString()
            Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Send exception for localId=${localId}: ${e}")
        }

        // 根据结果更新队列
        synchronized(this.queueMutex) {
            // 从 sendingQueue 移除
            let newSending = ArrayList<PendingMessage>()
            for (m in this.sendingQueue) {
                if (m.localId != localId) { newSending.add(m) }
            }
            this.sendingQueue = newSending

            if (success) {
                // 发送成功：更新消息字段，不再保留于队列
                msg.status = PendingMessageStatus.Sent
                msg.serverMessageId = serverMsgId
                msg.serverDate = serverDate
                Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Sent localId=${localId} serverMsgId=${serverMsgId}")
            } else {
                // 发送失败：判断是否可以自动重试
                msg.retryCount += 1
                if (msg.retryCount < msg.maxRetries) {
                    msg.status = PendingMessageStatus.Pending
                    msg.errorMessage = errorMsg
                    this.unsentQueue.add(msg)
                    Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Will retry localId=${localId} (attempt ${msg.retryCount}/${msg.maxRetries})")
                } else {
                    msg.status = PendingMessageStatus.Failed
                    msg.errorMessage = errorMsg
                    this.failedQueue.add(msg)
                    Hilog.info(0, "CjTelegram", "[PendingMsgSvc] Failed permanently localId=${localId}: ${errorMsg}")
                }
            }
        }
    }
}
