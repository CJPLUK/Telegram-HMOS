package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * 聊天记录导入服务 — 封装三步 MTProto 导入流程并跟踪进度：
 *   1. messages.initHistoryImport  -> 获取 importId
 *   2. messages.uploadImportedMedia (每个媒体文件)
 *   3. messages.startHistoryImport -> 提交导入
 *
 * P2-090: 支持 CloudGroup → Supergroup 自动转换（messages.migrateChat）。
 * P2-092: 集成 ProgressEstimator 剩余时间估算。
 * P2-094: MTProto 错误 5 分类真实映射。
 *
 * 复用 LegacyDataImportService 的 TL 调用链。
 * 对应 iOS 源：submodules/ChatImportUI/Sources/ChatImportActivityScreen.swift (ImportManager)
 */

private var _chatImportServiceInstance: Option<ChatImportService> = None

public func getChatImportService(): ChatImportService {
    match (_chatImportServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatImportService()
            _chatImportServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 导入状态 — 对应 iOS ImportManager.State
 *
 * P2-094: errorKind 是 ImportErrorKind 枚举真实分类（非 generic 一刀切）。
 * P2-092: remainingSeconds 由 ProgressEstimator 估算（None 表示尚未可估算）。
 */
public class ChatImportState {
    public var phase: String = "idle"
    public var totalBytes: Int64 = 0
    public var uploadedBytes: Int64 = 0
    public var totalMediaBytes: Int64 = 0
    public var uploadedMediaBytes: Int64 = 0
    public var errorKind: ImportErrorKind = ImportErrorKind.Generic
    public var isDone: Bool = false
    public var isError: Bool = false
    public var remainingSeconds: Float64 = -1.0  // -1 = 未知; >=0 = 秒数

    public func progressFraction(): Float64 {
        if (this.totalBytes == 0) {
            return 1.0
        }
        return Float64(this.uploadedBytes) / Float64(this.totalBytes)
    }
}

/**
 * 媒体条目描述
 */
public class ChatImportMediaEntry {
    public var data: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var fileName: String = ""
    public var mimeType: String = ""

    public init(data!: Array<Byte>, fileName!: String, mimeType!: String) {
        this.data = data
        this.fileName = fileName
        this.mimeType = mimeType
    }
}

/**
 * P2-090: CloudGroup → Supergroup 转换结果
 * 若目标群是普通 chat（peerType=="chat"），导入前需先 migrateChat 升级为 supergroup。
 * 成功后新的 supergroup 信息在 newChannelId / newChannelAccessHash 中。
 */
public class GroupMigrationResult {
    public var success: Bool = false
    public var newChannelId: Int64 = 0
    public var newChannelAccessHash: Int64 = 0
    public var errorMessage: String = ""

    public init(
        success!: Bool,
        newChannelId!: Int64,
        newChannelAccessHash!: Int64,
        errorMessage!: String
    ) {
        this.success = success
        this.newChannelId = newChannelId
        this.newChannelAccessHash = newChannelAccessHash
        this.errorMessage = errorMessage
    }
}

public class ChatImportService {

    /**
     * P2-090: 将普通群（chat）迁移升级为 supergroup，以满足历史导入要求。
     *
     * 对应 iOS：ConvertGroupToSupergroup.swift — messages.migrateChat#a2875319
     * 触发条件：peerType == "chat"（普通群），导入前检测。
     *
     * chatId: 普通群 chatId（Int64）
     * 返回 GroupMigrationResult，success=false 时展示错误并终止导入。
     *
     * 响应解析：Updates 四变体（0x74ae4240/0x725b04c3/0x78d4dec1/0xe317af7e）。
     * parseMigrateChatResult 从 updates#74ae4240/updatesCombined 的 chats[] 中提取
     * isChannel=true 且 id != 原 chatId 的新 Channel 条目。
     * 若提取失败（parse 异常/变体不携带 chats），返回 success=false, errorMessage="migration_needs_peer_refresh"。
     */
    public func migrateGroupToSupergroup(chatId!: Int64): GroupMigrationResult {
        Hilog.info(0, "CjTelegram", "[ChatImportService] migrateGroupToSupergroup chatId=${chatId}")

        let client = getMTProtoClient()
        let req = MessagesMigrateChat()
        req.chatId = chatId

        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ChatImportService] migrateGroupToSupergroup: empty response")
            return GroupMigrationResult(
                success: false,
                newChannelId: 0,
                newChannelAccessHash: 0,
                errorMessage: "Migration failed: no response"
            )
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR) {
            let errCode = d.readInt32()
            let errMsg = d.readString()
            Hilog.info(0, "CjTelegram", "[ChatImportService] migrateGroupToSupergroup RPC error ${errCode} ${errMsg}")
            return GroupMigrationResult(
                success: false,
                newChannelId: 0,
                newChannelAccessHash: 0,
                errorMessage: "Migration failed: ${errMsg}"
            )
        }

        // Updates 变体之一 — 解析 chats[] 提取真实新 Channel id/accessHash
        // parseMigrateChatResult 在 updates#74ae4240 的 chats 向量中找 isChannel=true 且 id != chatId 的条目
        Hilog.info(0, "CjTelegram", "[ChatImportService] migrateGroupToSupergroup: parsing Updates for new channel")
        let (newChanId, newChanHash) = parseMigrateChatResult(responseData, chatId)
        if (newChanId != 0) {
            Hilog.info(0, "CjTelegram", "[ChatImportService] migrateGroupToSupergroup success: newChannelId=${newChanId}")
            return GroupMigrationResult(
                success: true,
                newChannelId: newChanId,
                newChannelAccessHash: newChanHash,
                errorMessage: ""
            )
        }
        // 未能从 Updates 提取真实 channelId（parse 失败或变体不携带 chats）
        // 诚实降级：不以旧 chatId 冒充 newChannelId 发 initHistoryImport，
        // 让调用方重新通过 checkHistoryImportPeer 刷新真实 peer 后重试。
        Hilog.info(0, "CjTelegram", "[ChatImportService] migrateGroupToSupergroup: could not extract real newChannelId, requesting peer refresh")
        return GroupMigrationResult(
            success: false,
            newChannelId: 0,
            newChannelAccessHash: 0,
            errorMessage: "migration_needs_peer_refresh"
        )
    }

    /**
     * 执行完整聊天记录导入流程，通过 onProgress 回调汇报状态变化。
     * 调用链：[migrateChat if needed] → initHistoryImport → uploadImportedMedia* → startHistoryImport
     *
     * P2-090: peerType=="chat" 时先自动调用 migrateGroupToSupergroup。
     * P2-092: 通过 ProgressEstimator 估算剩余时间，写入 state.remainingSeconds。
     * P2-094: MTProto 错误真实分类 5 类，写入 state.errorKind。
     *
     * peerId / peerAccessHash / peerType: 目标对话
     * fileData / fileName: 导入的主 .txt/.zip 文件
     * mediaEntries: 附带媒体文件列表（可空）
     * onProgress: 每次状态更新调用（在调用线程上触发，调用方负责 launch{} UI 切换）
     */
    public func startImport(
        peerId!: Int64,
        peerAccessHash!: Int64,
        peerType!: String,
        fileData!: Array<Byte>,
        fileName!: String,
        mediaEntries!: Array<ChatImportMediaEntry>,
        onProgress!: (ChatImportState) -> Unit
    ): Unit {
        let state = ChatImportState()
        let mainFileSize = Int64(fileData.size)
        var totalMediaBytes: Int64 = 0
        for (entry in mediaEntries) {
            totalMediaBytes += Int64(entry.data.size)
        }
        state.totalBytes = mainFileSize + totalMediaBytes
        state.totalMediaBytes = totalMediaBytes
        state.uploadedBytes = 0
        state.uploadedMediaBytes = 0
        state.phase = "uploading"

        onProgress(state)

        let svc = getLegacyDataImportService()

        var effectivePeerId = peerId
        var effectivePeerAccessHash = peerAccessHash
        var effectivePeerType = peerType

        // P2-090: 普通群（chat）需先升级为 supergroup 才能导入
        if (peerType == "chat") {
            Hilog.info(0, "CjTelegram", "[ChatImportService] peerType=chat, migrating to supergroup first")
            state.phase = "migrating"
            onProgress(state)

            let migResult = this.migrateGroupToSupergroup(chatId: peerId)
            if (!migResult.success) {
                state.isError = true
                state.phase = "error"
                state.errorKind = ImportErrorKind.InvalidChatType
                onProgress(state)
                return
            }
            // 迁移成功后改用真实 supergroup channelId（从 migrateChat Updates.chats 提取）
            effectivePeerId = migResult.newChannelId
            effectivePeerAccessHash = migResult.newChannelAccessHash
            effectivePeerType = "channel"
            Hilog.info(0, "CjTelegram", "[ChatImportService] migrated to channel peerId=${effectivePeerId}")
        }

        // P2-092: 创建 ProgressEstimator
        let estimator = ImportProgressEstimator()

        let errBuf = Array<ImportErrorKind>(1, {_i: Int64 => ImportErrorKind.Generic})
        let importId = svc.initHistoryImportWithError(
            peerId: effectivePeerId,
            peerAccessHash: effectivePeerAccessHash,
            peerType: effectivePeerType,
            fileData: fileData,
            fileName: fileName,
            mediaCount: Int32(mediaEntries.size),
            errorKind: errBuf
        )

        if (importId == 0) {
            Hilog.info(0, "CjTelegram", "[ChatImportService] initHistoryImport failed")
            state.isError = true
            state.phase = "error"
            state.errorKind = errBuf[0]
            onProgress(state)
            return
        }

        state.uploadedBytes = mainFileSize
        state.phase = "uploading_media"
        let frac = state.progressFraction()
        let remaining = estimator.update(progress: frac)
        if (remaining >= 0.0) {
            state.remainingSeconds = remaining
        }
        onProgress(state)

        // P2-091: 3-路并发上传媒体（对应 iOS ImportManager.updateState 中 activeEntries.count >= 3 门控）
        // 实现: 将媒体条目分成最大3个并发 spawn 槽，每批最多3个并发，等待一批完成后再取下一批。
        // 上传结果通过 Future<Bool> get() 同步收集，任一失败立即终止。
        //
        // R-111 合规: 所有 var（mediaIdx / effectivePeerId / effectivePeerAccessHash /
        //   effectivePeerType）在每次循环体开始时绑定为 let，供 Array 初始化器 lambda 捕获。
        let totalMedia = mediaEntries.size
        var mediaIdx: Int64 = 0
        let concurrencySlots: Int64 = 3

        // bind current effective peer values to let for lambda capture (R-111)
        let constPeerId = effectivePeerId
        let constPeerHash = effectivePeerAccessHash
        let constPeerType = effectivePeerType
        let constImportId = importId
        let constSvc = svc
        let constMediaEntries = mediaEntries

        var mediaBatchFailed = false

        while (mediaIdx < totalMedia && !mediaBatchFailed) {
            let batchStart = mediaIdx
            let batchEnd = if (batchStart + concurrencySlots < totalMedia) {
                batchStart + concurrencySlots
            } else {
                totalMedia
            }
            let batchSize = batchEnd - batchStart

            // 每批 Future 数组：Array 初始化器 lambda 里只捕获 let 变量（R-111 合规）
            // spawn 在 lambda 里被触发，立刻返回 Future，所有 spawn 并发运行
            let futures = Array<Future<Bool>>(batchSize, { slotIdx: Int64 =>
                let entryIdx = batchStart + slotIdx
                let entry = constMediaEntries[entryIdx]
                let cData = entry.data
                let cFileName = entry.fileName
                let cMime = entry.mimeType

                spawn {
                    Hilog.info(0, "CjTelegram", "[ChatImportService] concurrent slot ${slotIdx}: ${cFileName}")
                    let errBufSlot = Array<ImportErrorKind>(1, {_ei: Int64 => ImportErrorKind.Generic})
                    constSvc.uploadImportedMediaWithError(
                        peerId: constPeerId,
                        peerAccessHash: constPeerHash,
                        peerType: constPeerType,
                        importId: constImportId,
                        mediaData: cData,
                        mediaFileName: cFileName,
                        mimeType: cMime,
                        errorKind: errBufSlot
                    )
                }
            })

            // 顺序 await 每个 Future，收集成功/失败结果
            var slotIdx2: Int64 = 0
            while (slotIdx2 < batchSize) {
                let ok = futures[slotIdx2].get()
                let entryIdx2 = batchStart + slotIdx2
                let entryForProgress = constMediaEntries[entryIdx2]
                if (!ok) {
                    Hilog.info(0, "CjTelegram", "[ChatImportService] uploadImportedMedia failed for ${entryForProgress.fileName}")
                    state.isError = true
                    state.phase = "error"
                    state.errorKind = ImportErrorKind.Generic
                    mediaBatchFailed = true
                } else {
                    state.uploadedMediaBytes += Int64(entryForProgress.data.size)
                    state.uploadedBytes = mainFileSize + state.uploadedMediaBytes
                    let frac2 = state.progressFraction()
                    let rem2 = estimator.update(progress: frac2)
                    if (rem2 >= 0.0) {
                        state.remainingSeconds = rem2
                    }
                }
                slotIdx2 += 1
            }

            onProgress(state)
            mediaIdx = batchEnd
        }

        if (mediaBatchFailed) {
            return
        }

        state.phase = "starting"
        onProgress(state)

        let started = svc.startHistoryImport(
            peerId: effectivePeerId,
            peerAccessHash: effectivePeerAccessHash,
            peerType: effectivePeerType,
            importId: importId
        )

        if (!started) {
            Hilog.info(0, "CjTelegram", "[ChatImportService] startHistoryImport failed")
            state.isError = true
            state.phase = "error"
            state.errorKind = ImportErrorKind.Generic
            onProgress(state)
            return
        }

        state.isDone = true
        state.phase = "done"
        state.uploadedBytes = state.totalBytes
        state.uploadedMediaBytes = state.totalMediaBytes
        state.remainingSeconds = 0.0
        Hilog.info(0, "CjTelegram", "[ChatImportService] Import complete")
        onProgress(state)
    }
}
