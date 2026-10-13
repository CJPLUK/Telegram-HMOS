package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

/**
 * 附件面板服务（ATCH-API-1）
 *
 * 职责：
 * - 持有当前聊天上下文（chatId / peerType）
 * - 封装附件类型对应的 TL 方法调用，调用链：
 *     AttachmentService.sendXxx()
 *       → getRealMessageService().sendXxx(peerType, peerId, ...)
 *         → MTProtoClient.sendRequest()
 * - 提供各附件类型的参数校验与日志
 *
 * 对应 iOS AttachmentController.swift (AttachmentButtonType 枚举 + 发送逻辑)
 */
public class AttachmentService {

    // ==================== 上下文 ====================

    public var chatId: Int64 = 0
    public var chatPeerType: String = "user"

    // ==================== 初始化 ====================

    public init() {}

    /**
     * 绑定聊天上下文（必须在使用前调用）
     */
    public func bindChat(peerType: String, peerId: Int64): Unit {
        this.chatPeerType = peerType
        this.chatId = peerId
    }

    // ==================== 发送能力 ====================

    /**
     * 发送照片附件
     *
     * 调用链：
     *   AttachmentService.sendPhoto()
     *     → getRealMessageService().sendPhoto(peerType, peerId, data, fileName)
     *       → FileUploadService.uploadFile() → MessagesUploadMedia / MessagesSendMedia
     *         → MTProtoClient.sendRequest()
     *
     * @param photoData  照片原始字节
     * @param fileName   文件名（含扩展名，如 photo.jpg）
     * @return SendMessageResult
     */
    public func sendPhoto(photoData: Array<Byte>, fileName: String): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[AttachmentService] sendPhoto chatId=${this.chatId} file=${fileName}")
        let msgService = getRealMessageService()
        return msgService.sendPhoto(this.chatPeerType, this.chatId, photoData, fileName)
    }

    /**
     * 发送文件附件（通用文档，含 PDF/Office/压缩包等）
     *
     * 调用链：
     *   AttachmentService.sendDocument()
     *     → getRealMessageService().sendDocument(peerType, peerId, data, fileName, mimeType)
     *       → MessagesUploadMedia / MessagesSendMedia → MTProtoClient.sendRequest()
     */
    public func sendDocument(fileData: Array<Byte>, fileName: String, mimeType: String): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[AttachmentService] sendDocument chatId=${this.chatId} file=${fileName} mime=${mimeType}")
        let msgService = getRealMessageService()
        return msgService.sendDocument(this.chatPeerType, this.chatId, fileData, fileName, mimeType: mimeType)
    }

    /**
     * 发送视频附件
     *
     * 调用链：
     *   AttachmentService.sendVideo()
     *     → getRealMessageService().sendVideo(peerType, peerId, data, fileName, duration, width, height)
     *       → MessagesUploadMedia / MessagesSendMedia → MTProtoClient.sendRequest()
     */
    public func sendVideo(
        videoData: Array<Byte>,
        fileName: String,
        duration: Int32,
        width: Int32,
        height: Int32
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[AttachmentService] sendVideo chatId=${this.chatId} file=${fileName} dur=${duration}")
        let msgService = getRealMessageService()
        return msgService.sendVideo(this.chatPeerType, this.chatId, videoData, fileName, duration: Float64(duration), width: width, height: height)
    }

    /**
     * 发送地理位置
     *
     * 调用链：
     *   AttachmentService.sendLocation()
     *     → getRealMessageService().sendLocation(peerType, peerId, lat, lng)
     *       → InputGeoPoint / InputMediaGeoPoint → MessagesSendMedia → MTProtoClient.sendRequest()
     */
    public func sendLocation(lat: Float64, lng: Float64): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[AttachmentService] sendLocation chatId=${this.chatId} lat=${lat} lng=${lng}")
        let msgService = getRealMessageService()
        return msgService.sendLocation(this.chatPeerType, this.chatId, lat, lng)
    }

    /**
     * 发送联系人名片
     *
     * 调用链：
     *   AttachmentService.sendContact()
     *     → getRealMessageService().sendContact(peerType, peerId, phone, firstName, lastName, vcard)
     *       → InputMediaContact → MessagesSendMedia → MTProtoClient.sendRequest()
     */
    public func sendContact(
        phoneNumber: String,
        firstName: String,
        lastName: String,
        vcard: String
    ): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[AttachmentService] sendContact chatId=${this.chatId} phone=${phoneNumber}")
        let msgService = getRealMessageService()
        return msgService.sendContact(this.chatPeerType, this.chatId, phoneNumber, firstName, lastName, vcard: vcard)
    }

    /**
     * 创建并发送投票
     *
     * 调用链：
     *   AttachmentService.sendPoll()
     *     → getRealMessageService().sendPoll(peerType, peerId, question, options)
     *       → InputMediaPoll → MessagesSendMedia → MTProtoClient.sendRequest()
     */
    public func sendPoll(question: String, options: ArrayList<String>): SendMessageResult {
        Hilog.info(0, "CjTelegram", "[AttachmentService] sendPoll chatId=${this.chatId} question=${question} options=${options.size}")
        let msgService = getRealMessageService()
        return msgService.sendPoll(this.chatPeerType, this.chatId, question, options)
    }
}

// ==================== DI 单例 ====================

private var _attachmentServiceInstance: Option<AttachmentService> = None

public func getAttachmentService(): AttachmentService {
    match (_attachmentServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = AttachmentService()
            _attachmentServiceInstance = Some(inst)
            return inst
    }
}
