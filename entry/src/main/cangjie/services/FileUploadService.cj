package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.collection.HashMap
import std.random.Random
import std.sync.*
import std.time.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*

// ============================================================
// P2-250: Enhanced File Upload Service
//
// Adds on top of the existing serial upload (Phase D):
//   Gap 1 — Small-file MD5 checksum:
//            Small files (<10 MB, use inputFile / InputFileUploaded)
//            have md5_checksum filled with the hex-encoded MD5 of the
//            entire file. Large files (inputFileBig) carry no MD5 —
//            aligns with iOS MultipartUpload.swift MultipartIntermediateResult.
//   Gap 2 — Parallel chunk upload + per-chunk retry:
//            Up to UPLOAD_PARALLEL_SLOTS concurrent saveFilePart /
//            saveBigFilePart requests per file. Each chunk is retried
//            independently up to CHUNK_MAX_RETRIES times with exponential
//            backoff before the whole upload is considered failed.
//            The upload is NOT cancelled by a single failed chunk; only
//            if all retries of a chunk are exhausted is the upload aborted.
//   Gap 3 — Progress / priority / cancel:
//            Per-upload UploadTask tracks bytes uploaded and supports
//            cancel. The priority parameter is accepted per-upload call for
//            future multi-file scheduling use; single-file calls run immediately.
//            Multi-file priority scheduling is deferred — see emitted IC.
//            Progress callback: (bytesUploaded: Int64, totalBytes: Int64) -> Unit.
//   Gap 4 — Optional gzip wrapping per chunk:
//            When useCompression=true, each chunk's serialized TL request
//            body is passed through wrapGzipIfBeneficial (from Inflate.cj)
//            before sending. iOS: Download.swift wrapMethodBody(useCompression).
// ============================================================

// ---- constants ----
// iOS MultipartUpload：>10 MB 或调用方标记 large（视频/文件）→ 512 KB + saveBigFilePart；
// 其余（照片/语音/缩略图）→ 128 KB + saveFilePart；每文件 parallelParts = 3；
// 上传走独立连接（getUploadMTProtoClient，最多 4 条 × 3 在途）。
private let UPLOAD_PART_SMALL: Int64 = 131072        // 128 KB
private let UPLOAD_PART_BIG: Int64 = 524288          // 512 KB
private let BIG_FILE_THRESHOLD: Int64 = 10485760     // 10 MB
private let UPLOAD_PARALLEL_PARTS: Int64 = 3         // per-file concurrent parts (iOS parallelParts)
private let UPLOAD_PARALLEL_SLOTS: Int64 = 12        // global cap = 4 connections × 3 in-flight
private let CHUNK_MAX_RETRIES: Int32 = 3             // per-chunk retry limit

// ---- upload task status ----
public class UploadStatus {
    public static let QUEUED: Int32 = 0
    public static let RUNNING: Int32 = 1
    public static let CANCELLED: Int32 = 2
    public static let COMPLETED: Int32 = 3
    public static let FAILED: Int32 = 4
}

// ---- per-file upload task (shared between scheduler and worker threads) ----
public class UploadTask {
    public let fileId: Int64
    public let priority: Int32       // higher = more urgent
    public let totalBytes: Int64

    private let taskMon: Monitor = Monitor()
    private var statusField: Int32 = UploadStatus.QUEUED
    private var bytesUploadedField: Int64 = 0

    public init(fileId: Int64, priority: Int32, totalBytes: Int64) {
        this.fileId = fileId
        this.priority = priority
        this.totalBytes = totalBytes
    }

    public func getStatus(): Int32 {
        synchronized(taskMon) {
            return statusField
        }
    }

    public func setStatus(s: Int32): Unit {
        synchronized(taskMon) {
            statusField = s
            taskMon.notifyAll()
        }
    }

    public func getBytesUploaded(): Int64 {
        synchronized(taskMon) {
            return bytesUploadedField
        }
    }

    public func addBytesUploaded(n: Int64): Unit {
        synchronized(taskMon) {
            bytesUploadedField += n
        }
    }

    // Block caller until task exits RUNNING.
    public func waitUntilNotRunning(): Unit {
        synchronized(taskMon) {
            while (statusField == UploadStatus.RUNNING) {
                let _ = taskMon.wait(timeout: Duration.millisecond * 500)
            }
        }
    }
}

// ---- bounded concurrency slot manager (same design as P2-249 FileDownloadService) ----
private class UploadSlotManager {
    private let mon: Monitor = Monitor()
    private let maxSlots: Int64
    private var usedSlots: Int64 = 0

    public init(maxSlots: Int64) {
        this.maxSlots = maxSlots
    }

    public func acquire(): Unit {
        synchronized(mon) {
            while (usedSlots >= maxSlots) {
                let _ = mon.wait(timeout: Duration.millisecond * 100)
            }
            usedSlots += 1
        }
    }

    public func release(): Unit {
        synchronized(mon) {
            if (usedSlots > 0) {
                usedSlots -= 1
            }
            mon.notify()
        }
    }
}

// ---- shared state for parallel chunk workers ----
// All fields mutated under chunkMon; IO never held under chunkMon.
private class ChunkUploadState {
    public let chunkMon: Monitor = Monitor()
    // next chunk index to claim (monotonically increasing)
    private var nextPartIdx: Int32 = 0
    public let totalParts: Int32
    // counts of in-flight + completed parts
    private var pendingCount: Int32 = 0
    private var completedCount: Int32 = 0
    // set if any chunk exhausted all retries
    private var aborted: Bool = false

    public init(totalParts: Int32) {
        this.totalParts = totalParts
    }

    // Claim the next chunk index. Returns -1 if all parts claimed or aborted.
    public func claimNextPart(): Int32 {
        synchronized(chunkMon) {
            if (aborted) {
                return Int32(-1)
            }
            if (nextPartIdx >= totalParts) {
                return Int32(-1)
            }
            let idx = nextPartIdx
            nextPartIdx += 1
            pendingCount += 1
            return idx
        }
    }

    // Called when a chunk send succeeded.
    public func markPartDone(partIdx: Int32): Unit {
        synchronized(chunkMon) {
            completedCount += 1
            pendingCount -= 1
            chunkMon.notifyAll()
        }
    }

    // Called when all retries for a chunk are exhausted. Sets aborted flag and
    // decrements pendingCount exactly once (the slot claimed by claimNextPart).
    // Other workers will see isAborted() == true on their next loop iteration and exit.
    public func setAborted(): Unit {
        synchronized(chunkMon) {
            if (!aborted) {
                aborted = true
                pendingCount -= 1
                chunkMon.notifyAll()
            }
        }
    }

    public func isAborted(): Bool {
        synchronized(chunkMon) {
            return aborted
        }
    }

    public func isAllDone(): Bool {
        synchronized(chunkMon) {
            return !aborted && completedCount >= totalParts
        }
    }

    public func getPending(): Int32 {
        synchronized(chunkMon) {
            return pendingCount
        }
    }
}

// ---- MD5 hex helper ----
// imgmenu 批次实证修复（真机 cppcrash 定位）：stdx.crypto.digest.MD5 的接口方法调用
// （md5.write/finish）在真机 schd-worker 线程触发仓颉运行时致命断言
// "Check failed: index < funcTableSize"（GetMethodOuterTI，SIGABRT，try/catch 不可捕获），
// 导致 sendPhoto/sendDocument 上传完成后必崩（faultlog：
// cppcrash-com.hmcangjie.telegram-20260721205402613 / -20260721212853253，帧位
// ChatRoomViewModel::sendPhoto+4172 / sendDocument+4384，崩溃点即本函数内联处——
// hilog 证据："[FileUpload] Upload complete" 之后、"Small file MD5" 之前中断）。
// MTProto 协议明确 inputFileUploaded.md5_checksum 可传空串（core.telegram.org：
// "In case the file's md5 checksum was not computed, pass an empty string"；TDLib 亦传空），
// 故此处跳过 MD5 计算按协议合法路径返回空串，服务端跳过校验，功能不受影响。
// TODO(stdx-md5-abort)：待仓颉运行时修复 stdx digest 接口分发后可恢复真实 MD5
// （PassportService.cj 同样引用 stdx MD5，存在同类风险，见 spawn 任务）。
private func computeMd5Hex(data: Array<Byte>): String {
    let _ = data.size
    return ""
}

// ---- exponential backoff helper ----
// Returns milliseconds to sleep before retry attempt n (0-indexed).
// n=0 → 200ms, n=1 → 400ms, n=2 → 800ms
private func retryBackoffMs(attempt: Int32): Int64 {
    var ms: Int64 = 200
    var i: Int32 = 0
    while (i < attempt) {
        ms = ms * 2
        i += 1
    }
    return ms
}

// ---- global singleton ----
private var _fileUploadInstance: Option<FileUploadService> = None
private let _fileUploadInitMon: Monitor = Monitor()

public func getFileUploadService(): FileUploadService {
    synchronized(_fileUploadInitMon) {
        match (_fileUploadInstance) {
            case Some(inst) => return inst
            case None =>
                let inst = FileUploadService()
                _fileUploadInstance = Some(inst)
                return inst
        }
    }
}

// ---- main service class ----
public class FileUploadService {
    private static let _rand = Random()

    // active task registry: fileId -> UploadTask
    private let taskMon: Monitor = Monitor()
    private var activeTasks: HashMap<Int64, UploadTask> = HashMap<Int64, UploadTask>()
    // S3-25: caller tag (local message id) -> fileId, so "Cancel Sending" can abort the
    // upload of one pending message (iOS PendingMessageManager cancels the media upload).
    private var tagToFileId: HashMap<Int64, Int64> = HashMap<Int64, Int64>()

    // bounded concurrency slots (shared across all uploads of this service instance)
    private let slotManager: UploadSlotManager = UploadSlotManager(UPLOAD_PARALLEL_SLOTS)

    // ================================================================
    // PUBLIC API
    // ================================================================

    /**
     * Upload a file with parallel chunks, per-chunk retry, MD5 (small files),
     * progress callback, and cancel support.
     *
     * @param data          raw file bytes
     * @param fileName      file name (sent to Telegram)
     * @param priority      upload priority (higher = sooner in queue, default 10)
     * @param useCompression  wrap each chunk body with gzip_packed if beneficial
     * @param onProgress    called after each successful chunk: (uploaded, total) bytes
     * @return Some(TLObject) = InputFileUploaded (small) or InputFileBig (large)
     *         None on failure or cancellation
     */
    public func uploadFile(
        data: Array<Byte>,
        fileName: String,
        priority!: Int32 = 10,
        useCompression!: Bool = false,
        largeHint!: Bool = false,
        onProgress!: (Int64, Int64) -> Unit = { _, _ => },
        uploadTag!: Int64 = 0
    ): Option<TLObject> {
        Hilog.info(0, "CjTelegram", "[FileUpload] uploadFile: name=${fileName}, size=${data.size}, prio=${priority}, large=${largeHint} tag=${uploadTag}")

        let fileId = generateFileId()
        let totalBytes = Int64(data.size)
        var cancelledBeforeStart = false
        synchronized(taskMon) {
            if (uploadTag != 0) {
                // A cancel that arrived while the file was still being read.
                if (tagToFileId.contains(uploadTag) && tagToFileId[uploadTag] == -1) {
                    cancelledBeforeStart = true
                    let _ = tagToFileId.remove(uploadTag)
                } else {
                    tagToFileId[uploadTag] = fileId
                }
            }
        }
        if (cancelledBeforeStart) {
            Hilog.info(0, "CjTelegram", "[FileUpload] upload tag=${uploadTag} cancelled before start")
            return None
        }
        let isBigFile = totalBytes >= BIG_FILE_THRESHOLD || largeHint
        let chunkSize = if (isBigFile) { UPLOAD_PART_BIG } else { UPLOAD_PART_SMALL }
        let totalParts = Int32((totalBytes + chunkSize - 1) / chunkSize)

        Hilog.info(0, "CjTelegram", "[FileUpload] fileId=${fileId}, parts=${totalParts}x${chunkSize / 1024}KB, big=${isBigFile}, useCompression=${useCompression}")

        // Register task
        let task = UploadTask(fileId, priority, totalBytes)
        synchronized(taskMon) {
            activeTasks[fileId] = task
        }
        task.setStatus(UploadStatus.RUNNING)

        let success = this.runParallelChunkedUpload(
            task, data, fileId, totalParts, isBigFile, chunkSize, useCompression, onProgress
        )

        // Deregister task
        synchronized(taskMon) {
            let _ = activeTasks.remove(fileId)
            if (uploadTag != 0) { let _ = tagToFileId.remove(uploadTag) }
        }

        if (!success) {
            task.setStatus(UploadStatus.FAILED)
            Hilog.info(0, "CjTelegram", "[FileUpload] Upload failed or cancelled: fileId=${fileId}")
            return None
        }

        task.setStatus(UploadStatus.COMPLETED)
        Hilog.info(0, "CjTelegram", "[FileUpload] Upload complete: fileId=${fileId}, parts=${totalParts}")

        if (isBigFile) {
            let inputFile = InputFileBig()
            inputFile.id = fileId
            inputFile.parts = totalParts
            inputFile.name = fileName
            return Some(inputFile)
        } else {
            // Small file: compute MD5 of entire file (iOS MultipartUpload md5Digest)
            let md5Hex = computeMd5Hex(data)
            Hilog.info(0, "CjTelegram", "[FileUpload] Small file MD5: ${md5Hex}")
            let inputFile = InputFileUploaded()
            inputFile.id = fileId
            inputFile.parts = totalParts
            inputFile.name = fileName
            inputFile.md5Checksum = md5Hex
            return Some(inputFile)
        }
    }

    /**
     * S3-25: cancel the upload registered under a caller tag (local message id).
     * Returns true when an upload was found (running or not yet started).
     */
    public func cancelUploadByTag(uploadTag: Int64): Bool {
        var fileId: Int64 = 0
        synchronized(taskMon) {
            if (tagToFileId.contains(uploadTag)) {
                fileId = tagToFileId[uploadTag]
            } else {
                // Not started yet (file still being read): leave a tombstone.
                tagToFileId[uploadTag] = -1
            }
        }
        Hilog.info(0, "CjTelegram", "[FileUpload] cancelUploadByTag tag=${uploadTag} fileId=${fileId}")
        if (fileId > 0) {
            this.cancelUpload(fileId)
            return true
        }
        return false
    }

    /**
     * Cancel a running upload. Waits for the task to stop.
     */
    public func cancelUpload(fileId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[FileUpload] cancelUpload: fileId=${fileId}")
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                activeTasks[fileId].setStatus(UploadStatus.CANCELLED)
            }
        }
        var task: Option<UploadTask> = None
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                task = Some(activeTasks[fileId])
            }
        }
        match (task) {
            case Some(t) => t.waitUntilNotRunning()
            case None => ()
        }
    }

    /**
     * Get status of a running or recently completed upload.
     */
    public func getUploadStatus(fileId: Int64): Int32 {
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                return activeTasks[fileId].getStatus()
            }
        }
        return UploadStatus.COMPLETED
    }

    /**
     * Pre-upload file data in background（对应 iOS TelegramEngine.Resources.preUpload(id:encrypt:tag:source:onComplete:)）
     *
     * 在后台 spawn 启动 uploadFile()，完成后调用 onComplete 回调。
     * iOS preUpload 使用 Signal<EngineMediaResource.ResourceData> 作为 source；
     * Cangjie 无 Signal，改为直接接收 data: Array<Byte> + fileName + 完成回调。
     *
     * Signal-async 取舍说明：
     *   iOS preUpload 接受 Signal<ResourceData> 作为异步数据源，本地数据流式传入。
     *   Cangjie 版本接受已备好的 data: Array<Byte>（调用方负责准备好数据），
     *   在 spawn 后台上传，完成后 onComplete 被调用（非 UI 线程，调用方需 spawn(UIThread) 更新 @State）。
     *
     * @param preUploadId   关联 ID（对应 iOS id: Int64，用于注册结果回调 / 日志跟踪）
     * @param data          要上传的文件字节数据
     * @param fileName      文件名（发送给 Telegram）
     * @param onProgress    上传进度回调 (bytesUploaded, total)；注意非 UI 线程，需 spawn(UIThread) 更新 @State
     * @param onComplete    上传完成回调 (Option<TLObject>)；None 表示失败
     */
    public func preUpload(
        preUploadId: Int64,
        data: Array<Byte>,
        fileName: String,
        onProgress!: (Int64, Int64) -> Unit = { _, _ => },
        onComplete!: (Option<TLObject>) -> Unit = { _ => }
    ): Unit {
        Hilog.info(0, "CjTelegram", "[FileUpload] preUpload: id=${preUploadId}, name=${fileName}, size=${data.size}")
        let svc = this
        let capturedData = data
        let capturedName = fileName
        let capturedProgress = onProgress
        let capturedComplete = onComplete
        let _ = spawn {
            =>
            let result = svc.uploadFile(
                capturedData,
                capturedName,
                onProgress: capturedProgress
            )
            capturedComplete(result)
        }
    }

    // ================================================================
    // PRIVATE: parallel chunked upload (Gap 2 + 3 + 4)
    // ================================================================

    private func runParallelChunkedUpload(
        task: UploadTask,
        data: Array<Byte>,
        fileId: Int64,
        totalParts: Int32,
        isBigFile: Bool,
        chunkSize: Int64,
        useCompression: Bool,
        onProgress: (Int64, Int64) -> Unit
    ): Bool {
        let state = ChunkUploadState(totalParts)
        let totalBytes = Int64(data.size)

        // Capture shared references for spawned workers.
        let sharedState = state
        let sharedTask = task
        let sharedSlots = slotManager
        let sharedData = data
        let sharedFileId = fileId
        let sharedTotalParts = totalParts
        let sharedIsBig = isBigFile
        let sharedChunkSize = chunkSize
        let sharedUseCompression = useCompression
        let sharedTotalBytes = totalBytes
        let sharedOnProgress = onProgress
        // 本文件的 3 个分片全走同一条上传专用连接（iOS：一个文件占一个 worker）
        let sharedClient = getUploadMTProtoClient()

        // Spawn UPLOAD_PARALLEL_SLOTS workers. Each worker loops claiming chunk
        // indices and sending them, retrying on failure up to CHUNK_MAX_RETRIES.
        var futures: ArrayList<Future<Unit>> = ArrayList<Future<Unit>>()
        var slotIdx: Int64 = 0
        while (slotIdx < UPLOAD_PARALLEL_PARTS) {
            let fut = spawn {
                =>
                while (true) {
                    // Check cancel before each chunk
                    let taskStatus = sharedTask.getStatus()
                    if (taskStatus == UploadStatus.CANCELLED) {
                        break
                    }

                    // Check if upload was aborted by a peer worker
                    if (sharedState.isAborted()) {
                        break
                    }

                    // Claim next part
                    let partIdx = sharedState.claimNextPart()
                    if (partIdx < 0) {
                        break
                    }

                    // Extract chunk (IO not under any lock)
                    let offset = Int64(partIdx) * sharedChunkSize
                    let end = if (offset + sharedChunkSize > sharedTotalBytes) { sharedTotalBytes } else { offset + sharedChunkSize }
                    let chunkLen = end - offset
                    let chunk = Array<Byte>(chunkLen, repeat: 0)
                    var ci: Int64 = 0
                    while (ci < chunkLen) {
                        chunk[ci] = sharedData[offset + ci]
                        ci += 1
                    }

                    // Per-chunk retry loop
                    var attempt: Int32 = 0
                    var chunkSuccess = false
                    while (attempt <= CHUNK_MAX_RETRIES) {
                        // Check cancel inside retry
                        if (sharedTask.getStatus() == UploadStatus.CANCELLED) {
                            break
                        }

                        // Exponential backoff on retry (not on first attempt)
                        if (attempt > 0) {
                            let backMs = retryBackoffMs(attempt - 1)
                            Hilog.info(0, "CjTelegram", "[FileUpload] Retry part=${partIdx}, attempt=${attempt}, backoff=${backMs}ms")
                            sleep(Duration.millisecond * backMs)
                        }

                        // Acquire concurrency slot (blocks if UPLOAD_PARALLEL_SLOTS saturated)
                        sharedSlots.acquire()

                        // Build and send request (IO outside of any data lock)
                        var sendOk = false
                        if (sharedIsBig) {
                            let req = UploadSaveBigFilePart()
                            req.fileId = sharedFileId
                            req.filePart = partIdx
                            req.fileTotalParts = sharedTotalParts
                            req.bytes = chunk
                            let reqBytes = if (sharedUseCompression) { wrapGzipIfBeneficial(req.toBytes()) } else { req.toBytes() }
                            let response = sharedClient.sendRequest(reqBytes)
                            sendOk = (response.size > 0)
                        } else {
                            let req = UploadSaveFilePart()
                            req.fileId = sharedFileId
                            req.filePart = partIdx
                            req.bytes = chunk
                            let reqBytes = if (sharedUseCompression) { wrapGzipIfBeneficial(req.toBytes()) } else { req.toBytes() }
                            let response = sharedClient.sendRequest(reqBytes)
                            sendOk = (response.size > 0)
                        }

                        sharedSlots.release()

                        if (sendOk) {
                            chunkSuccess = true
                            break
                        }

                        attempt += 1
                    }

                    if (chunkSuccess) {
                        sharedState.markPartDone(partIdx)
                        sharedTask.addBytesUploaded(chunkLen)
                        // Progress callback — never under a lock (S-001 safety: no @State here)
                        sharedOnProgress(sharedTask.getBytesUploaded(), sharedTotalBytes)
                        Hilog.info(0, "CjTelegram", "[FileUpload] Part ${partIdx}/${sharedTotalParts} done")
                    } else {
                        // All retries exhausted for this chunk — signal abort to all workers.
                        // setAborted() decrements pendingCount exactly once for this claimed slot.
                        Hilog.info(0, "CjTelegram", "[FileUpload] Part ${partIdx} failed after ${CHUNK_MAX_RETRIES} retries — aborting")
                        sharedState.setAborted()
                        break
                    }
                }
            }
            futures.add(fut)
            slotIdx += 1
        }

        // Wait for all workers
        for (fut in futures) {
            fut.get()
        }

        // Check final state
        let taskStatus = task.getStatus()
        if (taskStatus == UploadStatus.CANCELLED) {
            return false
        }
        return state.isAllDone()
    }

    // ================================================================
    // PRIVATE: helpers
    // ================================================================

    private func generateFileId(): Int64 {
        let high = Int64(FileUploadService._rand.nextUInt32() & 0x7FFFFFFF)
        let low = Int64(FileUploadService._rand.nextUInt32())
        return (high << 32) | (low & 0xFFFFFFFF)
    }
}
