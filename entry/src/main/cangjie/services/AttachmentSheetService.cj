package ohos_app_cangjie_entry.services

/**
 * AttachmentSheetService — 附件面板 File / Audio 页签的数据源
 *
 * iOS 对位（AttachmentFileController.swift:742-760）：
 *   File 页签「Recently Sent Files」 = searchMessages(location: .sentMedia(tags: [.file]))
 *                                    → messages.searchSentMedia filter=inputMessagesFilterDocument
 *   Audio 页签「Chats Music」        = searchMessages(location: .general(scope: .everywhere, tags: [.music]))
 *                                    → messages.searchGlobal filter=inputMessagesFilterMusic
 * 列表项点选即按引用发送（InputMediaDocument），不重新上传。
 */

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.*

/** File/Audio 页签里的一条已有文档 */
public class AttachFileItem {
    public var messageId: Int64 = 0
    public var title: String = ""
    public var subtitle: String = ""
    public var docId: Int64 = 0
    public var accessHash: Int64 = 0
    public var fileReference: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var mimeType: String = ""
    public var size: Int64 = 0
    public var isMusic: Bool = false
    public init() {}
}

private var _attachmentSheetService: Option<AttachmentSheetService> = None

public func getAttachmentSheetService(): AttachmentSheetService {
    match (_attachmentSheetService) {
        case Some(s) => return s
        case None =>
            let s = AttachmentSheetService()
            _attachmentSheetService = Some(s)
            return s
    }
}

public class AttachmentSheetService {
    public init() {}

    /** 我发出过的文件（跨会话），iOS「Recently Sent Files」 */
    public func fetchRecentSentFiles(limit!: Int32 = 20): ArrayList<AttachFileItem> {
        let req = MessagesSearchSentMedia()
        req.q = ""
        req.filter = InputMessagesFilterDocument()
        req.limit = limit
        let data = getMTProtoClient().sendRequest(req.toBytes())
        return this.parseItems(data, false, "searchSentMedia")
    }

    /** 所有会话里的音乐文件，iOS「Chats Music」 */
    public func fetchChatsMusic(limit!: Int32 = 20): ArrayList<AttachFileItem> {
        let req = MessagesSearchGlobal()
        req.q = ""
        req.filter = InputMessagesFilterMusic()
        req.limit = limit
        let data = getMTProtoClient().sendRequest(req.toBytes())
        return this.parseItems(data, true, "searchGlobal(music)")
    }

    private func parseItems(data: Array<Byte>, isMusic: Bool, tag: String): ArrayList<AttachFileItem> {
        let items = ArrayList<AttachFileItem>()
        if (data.size < 4) {
            Hilog.info(0, "CjTelegram", "[AttachmentSheet] ${tag}: empty response")
            return items
        }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19) {
            let code = d.readInt32()
            let msg = d.readString()
            Hilog.info(0, "CjTelegram", "[AttachmentSheet] ${tag} RPC error ${code}: ${msg}")
            return items
        }
        try {
            let resp = MessagesHistoryResponse.deserialize(data)
            for (m in resp.messages) {
                if (m.documentId == 0) { continue }
                let it = AttachFileItem()
                it.messageId = Int64(m.id)
                it.docId = m.documentId
                it.accessHash = m.documentAccessHash
                it.fileReference = m.documentFileReference
                it.mimeType = m.documentMimeType
                it.size = m.documentSize
                it.isMusic = isMusic
                if (isMusic) {
                    let t = if (m.audioTitle.size > 0) { m.audioTitle } else if (m.documentFileName.size > 0) { m.documentFileName } else { "Audio" }
                    it.title = t
                    let who = if (m.audioPerformer.size > 0) { m.audioPerformer } else { "Unknown Artist" }
                    it.subtitle = who + "  ·  " + formatAttachFileSize(m.documentSize)
                } else {
                    it.title = if (m.documentFileName.size > 0) { m.documentFileName } else { "File" }
                    it.subtitle = formatAttachFileSize(m.documentSize)
                }
                items.add(it)
            }
            Hilog.info(0, "CjTelegram", "[AttachmentSheet] ${tag}: ${items.size} items")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[AttachmentSheet] ${tag} parse error: ${e}")
        }
        return items
    }
}

public func formatAttachFileSize(bytes: Int64): String {
    if (bytes <= 0) { return "" }
    if (bytes < 1024) { return "${bytes} B" }
    if (bytes < 1048576) { return "${bytes / 1024} KB" }
    let mb10 = bytes * 10 / 1048576
    return "${mb10 / 10}.${mb10 % 10} MB"
}
