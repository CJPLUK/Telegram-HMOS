package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * 旧数据导入服务 — 封装 Telegram MTProto 聊天记录导入三步流程：
 *   1. messages.initHistoryImport  -> 获取 importId
 *   2. messages.uploadImportedMedia -> 上传媒体附件（可选）
 *   3. messages.startHistoryImport -> 提交导入
 *
 * P2-094: MTProto 错误映射 5 类（CHAT_ADMIN_REQUIRED / IMPORT_PEER_TYPE_INVALID /
 *         USER_IS_BLOCKED / FLOOD_WAIT / generic）。
 *
 * 对应 iOS 源：submodules/LegacyDataImport/Sources/LegacyDataImport.swift
 */

private var _legacyDataImportServiceInstance: Option<LegacyDataImportService> = None

public func getLegacyDataImportService(): LegacyDataImportService {
    match (_legacyDataImportServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = LegacyDataImportService()
            _legacyDataImportServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 导入进度状态
 */
public class ImportProgress {
    public var phase: String = "idle"
    public var uploadedParts: Int32 = 0
    public var totalParts: Int32 = 0
    public var errorMessage: String = ""
    public var importId: Int64 = 0
    public var success: Bool = false
}

/**
 * P2-094: MTProto 导入错误 5 分类
 *
 * 对应 iOS TelegramEngine.HistoryImport.InitImportError:
 *   chatAdminRequired  ← CHAT_ADMIN_REQUIRED
 *   invalidChatType    ← IMPORT_PEER_TYPE_INVALID / IMPORT_FORMAT_UNRECOGNIZED
 *   userBlocked        ← USER_IS_BLOCKED / PEER_ID_INVALID
 *   limitExceeded      ← FLOOD_WAIT / FLOOD_PREMIUM_WAIT
 *   generic            ← all others
 *
 * isRetryable: 用于 UI 层决定是否展示 Retry 按钮。
 * chatAdminRequired / invalidChatType / userBlocked 在原始 peer 上不可重试；
 * generic / limitExceeded 可重试（换 peer 或等待后重试）。
 */
public enum ImportErrorKind {
    | Generic
    | ChatAdminRequired
    | InvalidChatType
    | UserBlocked
    | LimitExceeded

    public func ordinal(): Int32 {
        match (this) {
            case Generic => 0
            case ChatAdminRequired => 1
            case InvalidChatType => 2
            case UserBlocked => 3
            case LimitExceeded => 4
        }
    }

    public operator func ==(rhs: ImportErrorKind): Bool {
        return this.ordinal() == rhs.ordinal()
    }

    public operator func !=(rhs: ImportErrorKind): Bool {
        return this.ordinal() != rhs.ordinal()
    }

    public func isRetryable(): Bool {
        match (this) {
            case Generic => true
            case LimitExceeded => true
            case _ => false
        }
    }

    public func userMessage(): String {
        match (this) {
            case ChatAdminRequired => "You must be an admin of this chat to import history."
            case InvalidChatType => "This chat type does not support history import."
            case UserBlocked => "The user has blocked you or is unavailable."
            case LimitExceeded => "Import limit reached. Please wait and try again."
            case _ => "Import failed. Please try again."
        }
    }
}

/**
 * P2-094: 将 MTProto RPC 错误字符串映射到 5 分类。
 * 对应 iOS TelegramEngineHistoryImport.swift L81-91 / L234-243 mapError 逻辑。
 */
public func classifyImportError(errorCode: Int32, errorMessage: String): ImportErrorKind {
    if (errorMessage == "CHAT_ADMIN_REQUIRED") {
        return ImportErrorKind.ChatAdminRequired
    } else if (errorMessage == "IMPORT_PEER_TYPE_INVALID" || errorMessage == "IMPORT_FORMAT_UNRECOGNIZED") {
        return ImportErrorKind.InvalidChatType
    } else if (errorMessage == "USER_IS_BLOCKED" || errorMessage == "PEER_ID_INVALID") {
        return ImportErrorKind.UserBlocked
    } else if (errorMessage == "FLOOD_WAIT" || errorMessage.contains("FLOOD_WAIT") || errorMessage == "FLOOD_PREMIUM_WAIT") {
        return ImportErrorKind.LimitExceeded
    } else {
        return ImportErrorKind.Generic
    }
}

public class LegacyDataImportService {

    /**
     * 初始化聊天记录导入。
     * 上传导入文件，调用 messages.initHistoryImport，返回 importId（>0 成功；0 失败）。
     * P2-094: errorKind out-parameter — caller 检查 importId==0 时通过此字段取得错误分类。
     */
    public func initHistoryImportWithError(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        fileData!: Array<Byte>,
        fileName!: String,
        mediaCount!: Int32,
        errorKind!: Array<ImportErrorKind>
    ): Int64 {
        Hilog.info(0, "CjTelegram", "[LegacyDataImport] initHistoryImport start")

        let client = getMTProtoClient()
        let uploadSvc = getFileUploadService()

        let inputFileOpt = uploadSvc.uploadFile(fileData, fileName)
        let inputFile: TLObject
        match (inputFileOpt) {
            case Some(f) =>
                inputFile = f
                Hilog.info(0, "CjTelegram", "[LegacyDataImport] File uploaded successfully")
            case None =>
                Hilog.info(0, "CjTelegram", "[LegacyDataImport] File upload failed")
                if (errorKind.size > 0) { errorKind[0] = ImportErrorKind.Generic }
                return 0
        }

        let req = MessagesInitHistoryImport()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.peerType = peerType
        req.file = inputFile
        req.mediaCount = mediaCount

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[LegacyDataImport] initHistoryImport: empty response")
            if (errorKind.size > 0) { errorKind[0] = ImportErrorKind.Generic }
            return 0
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            let kind = classifyImportError(errCode, errMsg)
            Hilog.info(0, "CjTelegram", "[LegacyDataImport] initHistoryImport RPC error ${errCode} ${errMsg}")
            if (errorKind.size > 0) { errorKind[0] = kind }
            return 0
        }

        let importId = d.readInt64()
        Hilog.info(0, "CjTelegram", "[LegacyDataImport] initHistoryImport success")
        return importId
    }

    /**
     * 初始化聊天记录导入（向后兼容版本，不返回错误分类）。
     */
    public func initHistoryImport(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        fileData!: Array<Byte>,
        fileName!: String,
        mediaCount!: Int32
    ): Int64 {
        let errBuf = Array<ImportErrorKind>(1, {_i: Int64 => ImportErrorKind.Generic})
        return this.initHistoryImportWithError(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            fileData: fileData,
            fileName: fileName,
            mediaCount: mediaCount,
            errorKind: errBuf
        )
    }

    /**
     * 上传单个媒体文件到导入会话。
     * 调用 messages.uploadImportedMedia，返回 true 成功。
     * P2-094: errorKind out-parameter。
     */
    public func uploadImportedMediaWithError(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        importId!: Int64,
        mediaData!: Array<Byte>,
        mediaFileName!: String,
        mimeType!: String,
        errorKind!: Array<ImportErrorKind>
    ): Bool {
        Hilog.info(0, "CjTelegram", "[LegacyDataImport] uploadImportedMedia start")

        let client = getMTProtoClient()
        let uploadSvc = getFileUploadService()

        let inputFileOpt = uploadSvc.uploadFile(mediaData, mediaFileName)
        let inputFile: TLObject
        match (inputFileOpt) {
            case Some(f) =>
                inputFile = f
                Hilog.info(0, "CjTelegram", "[LegacyDataImport] Media file uploaded")
            case None =>
                Hilog.info(0, "CjTelegram", "[LegacyDataImport] Media file upload failed")
                if (errorKind.size > 0) { errorKind[0] = ImportErrorKind.Generic }
                return false
        }

        let isPhoto = mimeType.startsWith("image/")
        let media: TLObject
        if (isPhoto) {
            let m = InputMediaUploadedPhoto()
            m.file = inputFile
            media = m
        } else {
            let m = InputMediaUploadedDocument()
            m.file = inputFile
            m.mimeType = mimeType
            media = m
        }

        let req = MessagesUploadImportedMedia()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.peerType = peerType
        req.importId = importId
        req.media = media

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[LegacyDataImport] uploadImportedMedia: empty response")
            if (errorKind.size > 0) { errorKind[0] = ImportErrorKind.Generic }
            return false
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            let kind = classifyImportError(errCode, errMsg)
            Hilog.info(0, "CjTelegram", "[LegacyDataImport] uploadImportedMedia RPC error ${errCode} ${errMsg}")
            if (errorKind.size > 0) { errorKind[0] = kind }
            return false
        }

        Hilog.info(0, "CjTelegram", "[LegacyDataImport] uploadImportedMedia success")
        return true
    }

    /**
     * 上传单个媒体文件（向后兼容版本，不返回错误分类）。
     */
    public func uploadImportedMedia(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        importId!: Int64,
        mediaData!: Array<Byte>,
        mediaFileName!: String,
        mimeType!: String
    ): Bool {
        let errBuf = Array<ImportErrorKind>(1, {_i: Int64 => ImportErrorKind.Generic})
        return this.uploadImportedMediaWithError(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            importId: importId,
            mediaData: mediaData,
            mediaFileName: mediaFileName,
            mimeType: mimeType,
            errorKind: errBuf
        )
    }

    /**
     * 提交导入——调用 messages.startHistoryImport，触发服务器处理导入文件。
     */
    public func startHistoryImport(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        importId!: Int64
    ): Bool {
        Hilog.info(0, "CjTelegram", "[LegacyDataImport] startHistoryImport start")

        let client = getMTProtoClient()

        let req = MessagesStartHistoryImport()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.peerType = peerType
        req.importId = importId

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[LegacyDataImport] startHistoryImport: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[LegacyDataImport] startHistoryImport RPC error ${errCode} ${errMsg}")
            return false
        }

        let isBoolTrue = (constructor == TLConstructors.BOOL_TRUE)
        Hilog.info(0, "CjTelegram", "[LegacyDataImport] startHistoryImport done")
        return isBoolTrue
    }

    /**
     * 完整导入流程（无媒体附件）：
     * initHistoryImport -> startHistoryImport
     */
    public func runImport(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        fileData!: Array<Byte>,
        fileName!: String,
        progress!: ImportProgress
    ): Bool {
        progress.phase = "uploading"
        progress.uploadedParts = 0
        progress.totalParts = 1

        let importId = initHistoryImport(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            fileData: fileData,
            fileName: fileName,
            mediaCount: 0
        )

        if (importId == 0) {
            progress.phase = "failed"
            progress.errorMessage = "Failed to initialize history import"
            return false
        }

        progress.importId = importId
        progress.uploadedParts = 1
        progress.phase = "starting"

        let started = startHistoryImport(
            peerId: peerId,
            peerAccessHash: peerAccessHash,
            peerType: peerType,
            importId: importId
        )

        if (!started) {
            progress.phase = "failed"
            progress.errorMessage = "Failed to start history import"
            return false
        }

        progress.phase = "done"
        progress.success = true
        Hilog.info(0, "CjTelegram", "[LegacyDataImport] runImport complete")
        return true
    }
}
