package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * TelegramEngine.HistoryImport 引擎层 API 封装
 *
 * 对应 iOS 源：
 *   submodules/TelegramCore/Sources/TelegramEngine/HistoryImport/TelegramEngineHistoryImport.swift
 *
 * 调用链：
 *   checkInfo (messages.checkHistoryImport)
 *   → checkPeer (messages.checkHistoryImportPeer)
 *   → initSession (messages.initHistoryImport)
 *   → uploadMedia* (messages.uploadImportedMedia)
 *   → startImport (messages.startHistoryImport)
 *
 * 复用 LegacyDataImportService 的 initHistoryImport / uploadImportedMedia / startHistoryImport，
 * 本服务补充 checkHistoryImport 和 checkHistoryImportPeer 两个新 TL 方法。
 */

private var _historyImportServiceInstance: Option<HistoryImportService> = None

public func getHistoryImportService(): HistoryImportService {
    match (_historyImportServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = HistoryImportService()
            _historyImportServiceInstance = Some(inst)
            return inst
    }
}

// ============================================================
// 领域模型 — 对应 iOS TelegramEngine.HistoryImport 内部枚举
// ============================================================

/**
 * 导入文件头解析结果 — 对应 iOS ParsedInfo
 * kind: "privateChat" | "group" | "unknown"
 * title: 解析得到的对话标题（可为空字符串）
 */
public class HistoryImportParsedInfo {
    public var kind: String = "unknown"
    public var title: String = ""

    public init(kind!: String, title!: String) {
        this.kind = kind
        this.title = title
    }
}

/**
 * 导入会话句柄 — 对应 iOS Session
 * 由 initSession 返回，后续 uploadMedia / startImport 使用
 */
public class HistoryImportSession {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"
    public var importId: Int64 = 0

    public init(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        importId!: Int64
    ) {
        this.peerId = peerId
        this.peerAccessHash = peerAccessHash
        this.peerType = peerType
        this.importId = importId
    }
}

/**
 * 对话导入可行性检查结果 — 对应 iOS CheckPeerImportResult
 * allowed: 可直接导入；alert(confirmText): 需向用户展示确认文本
 */
public class HistoryImportPeerCheckResult {
    public var isAllowed: Bool = false
    public var confirmText: String = ""

    public init(isAllowed!: Bool, confirmText!: String) {
        this.isAllowed = isAllowed
        this.confirmText = confirmText
    }
}

// ============================================================
// HistoryImportService — 引擎层 API 实现
// ============================================================

public class HistoryImportService {

    /**
     * 解析导入文件头，识别对话类型（私聊 / 群组 / 未知）。
     * 对应 iOS：TelegramEngine.HistoryImport.getInfo(header:)
     * TL：messages.checkHistoryImport#43d4f254 import_head:string = messages.HistoryImportParsed
     *
     * 返回 None 表示解析失败或 RPC 错误。
     */
    public func checkImportInfo(importHead!: String): Option<HistoryImportParsedInfo> {
        Hilog.info(0, "CjTelegram", "[HistoryImportService] checkImportInfo start")

        let client = getMTProtoClient()
        let req = MessagesCheckHistoryImport()
        req.importHead = importHead

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] checkImportInfo: empty response")
            return None
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR) {
            let _ = d.readInt32()
            let _ = d.readString()
            Hilog.info(0, "CjTelegram", "[HistoryImportService] checkImportInfo RPC error")
            return None
        }

        // messages.historyImportParsed#1662af0b flags:# pm:flags.0?true group:flags.1?true title:flags.3?string = messages.HistoryImportParsed
        // Constructor: 0x1662af0b
        if (constructor != 0x1662af0b) {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] checkImportInfo: unexpected constructor")
            return None
        }

        let flags = d.readUInt32()
        // flags.3 = title present
        let hasTitle = (flags & (1 << 3)) != 0
        let title: String
        if (hasTitle) {
            title = d.readString()
        } else {
            title = ""
        }

        // flags.0 = pm (private chat), flags.1 = group
        let kind: String
        if ((flags & (1 << 0)) != 0) {
            kind = "privateChat"
        } else if ((flags & (1 << 1)) != 0) {
            kind = "group"
        } else {
            kind = "unknown"
        }

        Hilog.info(0, "CjTelegram", "[HistoryImportService] checkImportInfo success")
        return Some(HistoryImportParsedInfo(kind: kind, title: title))
    }

    /**
     * 检查指定对话是否允许导入聊天记录。
     * 对应 iOS：TelegramEngine.HistoryImport.checkPeerImport(peerId:)
     * TL：messages.checkHistoryImportPeer#5dc60f03 peer:InputPeer = messages.CheckedHistoryImportPeer
     *
     * 返回 None 表示检查失败（权限不足 / 对话类型不支持 / 用户被封禁等）。
     */
    public func checkPeerImport(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String
    ): Option<HistoryImportPeerCheckResult> {
        Hilog.info(0, "CjTelegram", "[HistoryImportService] checkPeerImport start")

        let client = getMTProtoClient()
        let req = MessagesCheckHistoryImportPeer()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.peerType = peerType

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] checkPeerImport: empty response")
            return None
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR) {
            let _ = d.readInt32()
            let _ = d.readString()
            Hilog.info(0, "CjTelegram", "[HistoryImportService] checkPeerImport RPC error")
            return None
        }

        // messages.checkedHistoryImportPeer#a24de717 confirm_text:string = messages.CheckedHistoryImportPeer
        // Constructor: 0xa24de717
        if (constructor != 0xa24de717) {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] checkPeerImport: unexpected constructor")
            return None
        }

        let confirmText = d.readString()
        let isAllowed = confirmText.isEmpty()
        Hilog.info(0, "CjTelegram", "[HistoryImportService] checkPeerImport success")
        return Some(HistoryImportPeerCheckResult(isAllowed: isAllowed, confirmText: confirmText))
    }

    /**
     * 初始化导入会话，上传主导入文件，返回 HistoryImportSession。
     * 对应 iOS：TelegramEngine.HistoryImport.initSession(peerId:file:mediaCount:)
     * TL：messages.initHistoryImport (复用 LegacyDataImportService.initHistoryImport)
     *
     * 返回 None 表示上传或 RPC 失败。
     */
    public func initSession(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        fileData!: Array<Byte>,
        fileName!: String,
        mediaCount!: Int32
    ): Option<HistoryImportSession> {
        Hilog.info(0, "CjTelegram", "[HistoryImportService] initSession start")

        let legacySvc = getLegacyDataImportService()
        let importId = legacySvc.initHistoryImport(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            fileData: fileData,
            fileName: fileName,
            mediaCount: mediaCount
        )

        if (importId == 0) {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] initSession failed")
            return None
        }

        Hilog.info(0, "CjTelegram", "[HistoryImportService] initSession success")
        return Some(HistoryImportSession(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            importId: importId
        ))
    }

    /**
     * 上传单个媒体文件到导入会话。
     * 对应 iOS：TelegramEngine.HistoryImport.uploadMedia(session:file:disposeFileAfterDone:fileName:mimeType:type:)
     * TL：messages.uploadImportedMedia (复用 LegacyDataImportService.uploadImportedMedia)
     *
     * 返回 true 表示上传成功。
     */
    public func uploadMedia(
        session!: HistoryImportSession,
        mediaData!: Array<Byte>,
        mediaFileName!: String,
        mimeType!: String
    ): Bool {
        Hilog.info(0, "CjTelegram", "[HistoryImportService] uploadMedia start")

        let legacySvc = getLegacyDataImportService()
        let ok = legacySvc.uploadImportedMedia(
            peerId: session.peerId,
            peerAccessHash: session.peerAccessHash,
            peerType: session.peerType,
            importId: session.importId,
            mediaData: mediaData,
            mediaFileName: mediaFileName,
            mimeType: mimeType
        )

        if (ok) {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] uploadMedia success")
        } else {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] uploadMedia failed")
        }
        return ok
    }

    /**
     * 提交导入，触发服务器处理已上传文件。
     * 对应 iOS：TelegramEngine.HistoryImport.startImport(session:)
     * TL：messages.startHistoryImport (复用 LegacyDataImportService.startHistoryImport)
     *
     * 返回 true 表示服务器确认开始处理。
     */
    public func startImport(session!: HistoryImportSession): Bool {
        Hilog.info(0, "CjTelegram", "[HistoryImportService] startImport start")

        let legacySvc = getLegacyDataImportService()
        let ok = legacySvc.startHistoryImport(
            peerId: session.peerId,
            peerAccessHash: session.peerAccessHash,
            peerType: session.peerType,
            importId: session.importId
        )

        if (ok) {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] startImport success")
        } else {
            Hilog.info(0, "CjTelegram", "[HistoryImportService] startImport failed")
        }
        return ok
    }

    /**
     * 完整导入流程：checkPeer → initSession → uploadMedia* → startImport。
     * onProgress 回调每步更新 ImportProgress 状态。
     */
    public func runFullImport(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        fileData!: Array<Byte>,
        fileName!: String,
        mediaEntries!: Array<ChatImportMediaEntry>,
        onProgress!: (ImportProgress) -> Unit
    ): Bool {
        let progress = ImportProgress()
        progress.phase = "checking_peer"
        onProgress(progress)

        let peerCheckOpt = checkPeerImport(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType
        )

        match (peerCheckOpt) {
            case None =>
                progress.phase = "failed"
                progress.errorMessage = "checkPeerImport failed"
                onProgress(progress)
                return false
            case Some(result) =>
                if (!result.isAllowed && result.confirmText.isEmpty()) {
                    progress.phase = "failed"
                    progress.errorMessage = "peer import not allowed"
                    onProgress(progress)
                    return false
                }
        }

        progress.phase = "uploading"
        onProgress(progress)

        let sessionOpt = initSession(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            fileData: fileData,
            fileName: fileName,
            mediaCount: Int32(mediaEntries.size)
        )

        let session: HistoryImportSession
        match (sessionOpt) {
            case None =>
                progress.phase = "failed"
                progress.errorMessage = "initSession failed"
                onProgress(progress)
                return false
            case Some(s) =>
                session = s
                progress.importId = s.importId
        }

        progress.totalParts = Int32(mediaEntries.size) + 1
        progress.uploadedParts = 1
        progress.phase = "uploading_media"
        onProgress(progress)

        for (entry in mediaEntries) {
            let ok = uploadMedia(
                session: session,
                mediaData: entry.data,
                mediaFileName: entry.fileName,
                mimeType: entry.mimeType
            )
            if (!ok) {
                progress.phase = "failed"
                progress.errorMessage = "uploadMedia failed"
                onProgress(progress)
                return false
            }
            progress.uploadedParts += 1
            onProgress(progress)
        }

        progress.phase = "starting"
        onProgress(progress)

        let started = startImport(session: session)
        if (!started) {
            progress.phase = "failed"
            progress.errorMessage = "startImport failed"
            onProgress(progress)
            return false
        }

        progress.phase = "done"
        progress.success = true
        onProgress(progress)
        Hilog.info(0, "CjTelegram", "[HistoryImportService] runFullImport complete")
        return true
    }
}
