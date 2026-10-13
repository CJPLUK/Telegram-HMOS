package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*
import kit.ArkData.*
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.core.storage.getDownloadPolicy
import ohos_app_cangjie_entry.core.storage.canAutoDownload
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.*
import std.time.*
import std.convert.*

// ============================================================
// P2-249: Enhanced File Download Service
//
// Adds on top of the existing serial 512 KB chunked download:
//   Gap 1 — ranged / resume: persist completed-chunk offsets to
//            <filesDir>/downloads/<fileId>.resume; restart from
//            the highest acknowledged byte, not from 0.
//   Gap 2 — parallel chunks + bounded concurrency slots +
//            priority queue: up to PARALLEL_SLOTS concurrent
//            MTProto requests per file; multi-file queue ordered
//            by descending priority (higher int = higher prio).
//   Gap 3 — cancel / pause: per-task flags checked between chunks.
//   Gap 4 — FILE_MIGRATE redirect: when the server returns
//            FILE_MIGRATE_X, transparently switch to DC-X via
//            the existing getClientForDC() path.
//   Gap 5 — CDN download path: upload.getCdnFile + AES-256-CTR
//            decryption using the existing AesCtr; per-part hash
//            verification; reuploadCdnFile for missing segments.
//            CDN DC RSA public-key auth is emitted as IC
//            (ic_cdn_dc_auth) — see emitted_integration_contracts.
// ============================================================

// ---- concurrency constants ----
private let CHUNK_SIZE_BYTES: Int32 = 524288       // 512 KB
private let PARALLEL_SLOTS: Int64 = 4             // max concurrent chunk requests per download
private let MAX_ACTIVE_RESOURCES: Int64 = 3        // iOS-style resource-level fetch budget
private let MAX_CHUNKS_PER_RESOURCE: Int64 = 2     // leave capacity for newly visible media
private let DOWNLOAD_DIR_NAME: String = "downloads"

// iOS FetchManager keeps userInitiated / elevated entries ahead of every
// backgroundPrefetch entry (AccountContext/FetchManager.swift FetchManagerPriorityKey.<),
// and on-screen chat media (ChatMessageInteractiveMediaNode) is fetched on display, never
// behind keyboard/sticker prefetch. Here a single FIFO budget let a burst of sticker panel
// downloads hold every resource and chunk slot, so a photo arriving on screen right after
// (R3 D9) stayed on "Loading…" for 20s+. Resources at or above this priority are
// interactive (visible chat media, user taps): they may use capacity that background
// work can never occupy, so they start as soon as they reach the head of the queue.
public let DOWNLOAD_INTERACTIVE_PRIORITY: Int32 = 80
private let INTERACTIVE_RESERVED_RESOURCES: Int64 = 2 // extra resource budget only interactive may use
private let INTERACTIVE_RESERVED_SLOTS: Int64 = 2     // extra chunk slots only interactive may use

// ---- download task status enum ----
public class DownloadStatus {
    public static let QUEUED: Int32 = 0
    public static let RUNNING: Int32 = 1
    public static let PAUSED: Int32 = 2
    public static let CANCELLED: Int32 = 3
    public static let COMPLETED: Int32 = 4
    public static let FAILED: Int32 = 5
}

// ---- per-file download state (shared between scheduling and worker threads) ----
public class DownloadTask {
    public let fileId: Int64
    // higher = more urgent. Mutable only under PriorityDownloadQueue.queueMon so a
    // queued resource can be raised when it becomes visible (iOS FetchManager
    // re-sorts an entry when a userInitiated/elevated subscriber joins it).
    public var priority: Int32
    // guarded by taskMon
    private let taskMon: Monitor = Monitor()
    private var statusField: Int32 = DownloadStatus.QUEUED
    private var bytesDownloaded: Int64 = 0

    public init(fileId: Int64, priority: Int32) {
        this.fileId = fileId
        this.priority = priority
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

    public func getBytesDownloaded(): Int64 {
        synchronized(taskMon) {
            return bytesDownloaded
        }
    }

    public func addBytes(n: Int64): Unit {
        synchronized(taskMon) {
            bytesDownloaded += n
        }
    }

    // Block a duplicate resource subscriber until its owner publishes a terminal state.
    public func waitUntilTerminal(): Unit {
        synchronized(taskMon) {
            while (statusField == DownloadStatus.QUEUED || statusField == DownloadStatus.RUNNING) {
                taskMon.wait(timeout: Duration.millisecond * 100)
            }
        }
    }

    // Block caller until status transitions away from RUNNING (used by cancel/pause waiters).
    public func waitUntilNotRunning(): Unit {
        synchronized(taskMon) {
            while (statusField == DownloadStatus.RUNNING) {
                taskMon.wait(timeout: Duration.millisecond * 500)
            }
        }
    }
}

// ---- bounded concurrency slot manager ----
// Provides acquire/release semantics; blocks if all PARALLEL_SLOTS are taken.
private class SlotManager {
    private let mon: Monitor = Monitor()
    private let maxSlots: Int64
    private var usedSlots: Int64 = 0

    public init(maxSlots: Int64) {
        this.maxSlots = maxSlots
    }

    /**
     * Background chunks share `maxSlots`; interactive chunks may additionally use
     * INTERACTIVE_RESERVED_SLOTS that background chunks never take, so a visible
     * photo's upload.getFile is never queued behind prefetch chunks.
     */
    public func acquire(interactive!: Bool = false): Unit {
        let limit = if (interactive) { maxSlots + INTERACTIVE_RESERVED_SLOTS } else { maxSlots }
        synchronized(mon) {
            while (usedSlots >= limit) {
                mon.wait(timeout: Duration.millisecond * 100)
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

// ---- priority download queue ----
// Holds pending file-download jobs ordered by descending priority.
// Access always under queueMon.
private class PriorityDownloadQueue {
    private let queueMon: Monitor = Monitor()
    // sorted list of (priority, fileId, task) — maintained descending by priority
    private var entries: ArrayList<DownloadTask> = ArrayList<DownloadTask>()
    private var runningResources: Int64 = 0

    private func removeAt(index: Int64): Unit {
        let newList = ArrayList<DownloadTask>()
        var i: Int64 = 0
        while (i < entries.size) {
            if (i != index) { newList.add(entries[i]) }
            i += 1
        }
        entries = newList
    }

    public func enqueue(task: DownloadTask): Unit {
        synchronized(queueMon) {
            // insertion-sort by priority descending
            var inserted = false
            var i: Int64 = 0
            while (i < entries.size) {
                if (entries[i].priority < task.priority) {
                    entries.add(task)        // ArrayList has no insertAt; rebuild tail
                    // Shift: move to position i
                    var j: Int64 = entries.size - 1
                    while (j > i) {
                        let tmp = entries[j]
                        entries[j] = entries[j - 1]
                        entries[j - 1] = tmp
                        j -= 1
                    }
                    inserted = true
                    break
                }
                i += 1
            }
            if (!inserted) {
                entries.add(task)
            }
            queueMon.notify()
        }
    }

    /**
     * Enqueue one resource and block only its owner until it reaches the head of
     * the priority queue and a resource slot is available. The previous code
     * enqueued a task and immediately marked it RUNNING, so priority never
     * affected execution at all.
     */
    public func enqueueAndWait(task: DownloadTask): Bool {
        this.enqueue(task)
        synchronized(queueMon) {
            while (true) {
                if (task.getStatus() == DownloadStatus.CANCELLED) {
                    var cancelledIndex: Int64 = -1
                    var ci: Int64 = 0
                    while (ci < entries.size) {
                        if (entries[ci].fileId == task.fileId) {
                            cancelledIndex = ci
                            break
                        }
                        ci += 1
                    }
                    if (cancelledIndex >= 0) { this.removeAt(cancelledIndex) }
                    queueMon.notifyAll()
                    return false
                }
                // Background resources share MAX_ACTIVE_RESOURCES; interactive ones may also
                // use the reserved budget, so prefetch can never occupy every slot.
                let resourceLimit = if (task.priority >= DOWNLOAD_INTERACTIVE_PRIORITY) {
                    MAX_ACTIVE_RESOURCES + INTERACTIVE_RESERVED_RESOURCES
                } else {
                    MAX_ACTIVE_RESOURCES
                }
                if (runningResources < resourceLimit && entries.size > 0 &&
                    entries[0].fileId == task.fileId) {
                    this.removeAt(0)
                    runningResources += 1
                    task.setStatus(DownloadStatus.RUNNING)
                    return true
                }
                queueMon.wait(timeout: Duration.millisecond * 50)
            }
            return false
        }
    }

    public func finish(): Unit {
        synchronized(queueMon) {
            if (runningResources > 0) { runningResources -= 1 }
            queueMon.notifyAll()
        }
    }

    /**
     * Raise a still-queued resource. Duplicate subscribers of one resource only
     * wait on its owner; without this a photo first discovered by a background
     * history page (priority 10) stays behind every earlier page even after it
     * scrolls on screen and is requested interactively.
     * Mirrors iOS FetchManager: joining an entry with a higher priority moves it
     * forward in the same queue (FetchManager.swift FetchManagerLocationEntry).
     */
    public func raisePriority(task: DownloadTask, priority: Int32): Unit {
        synchronized(queueMon) {
            if (task.priority >= priority) { return }
            var index: Int64 = -1
            var i: Int64 = 0
            while (i < entries.size) {
                if (refEq(entries[i], task)) {
                    index = i
                    break
                }
                i += 1
            }
            task.priority = priority
            if (index < 0) { return }
            this.removeAt(index)
            var insertAt: Int64 = entries.size
            var j: Int64 = 0
            while (j < entries.size) {
                if (entries[j].priority < priority) {
                    insertAt = j
                    break
                }
                j += 1
            }
            entries.add(task)
            var k: Int64 = entries.size - 1
            while (k > insertAt) {
                let tmp = entries[k]
                entries[k] = entries[k - 1]
                entries[k - 1] = tmp
                k -= 1
            }
            queueMon.notifyAll()
        }
    }

    /**
     * Lower every still-queued resource whose priority lies in [minPriority, maxPriority]
     * to `priority`, keeping the queue sorted. Used when the surface that asked for a
     * batch of prefetches goes away (iOS drops the FetchManager references of nodes
     * that leave the screen, so their entries fall back behind visible media).
     * Running resources are not touched. Returns the number of demoted entries.
     */
    public func demoteQueued(minPriority: Int32, maxPriority: Int32, priority: Int32): Int64 {
        var demoted: Int64 = 0
        synchronized(queueMon) {
            let kept = ArrayList<DownloadTask>()
            let lowered = ArrayList<DownloadTask>()
            for (entry in entries) {
                if (entry.priority >= minPriority && entry.priority <= maxPriority && entry.priority > priority) {
                    entry.priority = priority
                    lowered.add(entry)
                } else {
                    kept.add(entry)
                }
            }
            if (lowered.isEmpty()) { return 0 }
            let rebuilt = ArrayList<DownloadTask>()
            var li: Int64 = 0
            for (entry in kept) {
                while (li < lowered.size && lowered[li].priority > entry.priority) {
                    rebuilt.add(lowered[li])
                    li += 1
                }
                rebuilt.add(entry)
            }
            while (li < lowered.size) {
                rebuilt.add(lowered[li])
                li += 1
            }
            entries = rebuilt
            demoted = lowered.size
            queueMon.notifyAll()
        }
        return demoted
    }
}

// ---- resume-state helpers ----
// Persist/restore completed chunk offsets for a given fileId.
// Format: comma-separated Int64 decimal values in plain text.

private func resumeFilePath(fileId: Int64): String {
    let dir = getAppFilesDir()
    if (dir.isEmpty()) {
        return ""
    }
    return dir + "/" + DOWNLOAD_DIR_NAME + "/" + fileId.toString() + ".resume"
}

private func loadCompletedOffsets(fileId: Int64): ArrayList<Int64> {
    let path = resumeFilePath(fileId)
    let result = ArrayList<Int64>()
    if (path.isEmpty()) {
        return result
    }
    let exists = FileIo.access(path)
    if (!exists) {
        return result
    }
    try {
        let file = FileIo.open(path, mode: 0o0)  // read-only
        let st = FileIo.stat(path)
        if (st.size <= 0) {
            FileIo.close(file)
            return result
        }
        let buf = Array<Byte>(Int64(st.size), repeat: 0)
        let readN = FileIo.read(file.fd, buf)
        FileIo.close(file)
        if (readN <= 0) {
            return result
        }
        let text = String.fromUtf8(Array<Byte>(readN, {i: Int64 => buf[i]}))
        let parts = text.split(",")
        for (part in parts) {
            let trimmed = part.trimAscii()
            if (!trimmed.isEmpty()) {
                try {
                    let off = Int64.parse(trimmed)
                    result.add(off)
                } catch (_: Exception) {}
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[FileDownload] loadCompletedOffsets error for ${fileId}: ${e}")
    }
    return result
}

private func saveCompletedOffsets(fileId: Int64, offsets: ArrayList<Int64>): Unit {
    let path = resumeFilePath(fileId)
    if (path.isEmpty()) {
        return
    }
    // Ensure download dir exists
    let dir = getAppFilesDir() + "/" + DOWNLOAD_DIR_NAME
    try { FileIo.mkdir(dir) } catch (_e: Exception) {}
    try {
        let parts = ArrayList<String>()
        for (off in offsets) {
            parts.add(off.toString())
        }
        var text = ""
        var pi: Int64 = 0
        while (pi < parts.size) {
            if (pi > 0) { text += "," }
            text += parts[pi]
            pi += 1
        }
        let bytes = text.toArray()
        let file = FileIo.open(path, mode: 0o1101)  // CREATE | WRITE_ONLY | TRUNC
        FileIo.write(file.fd, bytes)
        FileIo.close(file)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[FileDownload] saveCompletedOffsets error for ${fileId}: ${e}")
    }
}

private func deleteResumeFile(fileId: Int64): Unit {
    let path = resumeFilePath(fileId)
    if (path.isEmpty()) {
        return
    }
    try { FileIo.unlink(path) } catch (_e: Exception) {}
}

// Write chunk data at the given byte offset in the partial-download file.
// File path: <filesDir>/downloads/<fileId>.part
private func partFilePath(fileId: Int64): String {
    let dir = getAppFilesDir()
    if (dir.isEmpty()) {
        return ""
    }
    return dir + "/" + DOWNLOAD_DIR_NAME + "/" + fileId.toString() + ".part"
}

private func writeChunkAt(fileId: Int64, offset: Int64, data: Array<Byte>): Bool {
    let path = partFilePath(fileId)
    if (path.isEmpty()) {
        return false
    }
    let dir = getAppFilesDir() + "/" + DOWNLOAD_DIR_NAME
    try { FileIo.mkdir(dir) } catch (_e: Exception) {}
    try {
        // 0o1 = WRITE_ONLY, 0o100 = CREATE, mode: O_WRONLY|O_CREAT = 0o101; combined with no-truncate
        let file = FileIo.open(path, mode: 0o101)   // CREATE|WRITE_ONLY, no truncate for partial writes
        FileIo.lseek(file.fd, offset, whence: SeekSet)
        FileIo.write(file.fd, data)
        FileIo.close(file)
        return true
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[FileDownload] writeChunkAt error fileId=${fileId} offset=${offset}: ${e}")
        return false
    }
}

private func readEntirePartFile(fileId: Int64): Array<Byte> {
    let path = partFilePath(fileId)
    if (path.isEmpty()) {
        return Array<Byte>(0, repeat: 0)
    }
    let exists = FileIo.access(path)
    if (!exists) {
        return Array<Byte>(0, repeat: 0)
    }
    try {
        let st = FileIo.stat(path)
        if (st.size <= 0) {
            return Array<Byte>(0, repeat: 0)
        }
        let buf = Array<Byte>(Int64(st.size), repeat: 0)
        let file = FileIo.open(path, mode: 0o0)
        let readN = FileIo.read(file.fd, buf)
        FileIo.close(file)
        if (readN < Int64(st.size)) {
            return Array<Byte>(readN, {i: Int64 => buf[i]})
        }
        return buf
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[FileDownload] readEntirePartFile error for ${fileId}: ${e}")
        return Array<Byte>(0, repeat: 0)
    }
}

private func deletePartFile(fileId: Int64): Unit {
    let path = partFilePath(fileId)
    if (path.isEmpty()) { return }
    try { FileIo.unlink(path) } catch (_e: Exception) {}
}

// ---- completed-resource helpers ----
// A resource is fetched into <fileId>.part (the temp file). Only after every part
// has been written exactly once and the assembled size equals the document size
// (iOS MultipartFetch reports completeSize = offset + data.count of the short part,
// and the partial file is truncated to it) is it renamed to <fileId>.data.
// Readers never treat a .part as a finished resource unless its size matches exactly.

private func dataFilePath(fileId: Int64): String {
    let dir = getAppFilesDir()
    if (dir.isEmpty()) {
        return ""
    }
    return dir + "/" + DOWNLOAD_DIR_NAME + "/" + fileId.toString() + ".data"
}

private func localFileSize(path: String): Int64 {
    if (path.isEmpty()) { return -1 }
    try {
        if (!FileIo.access(path)) { return -1 }
        return Int64(FileIo.stat(path).size)
    } catch (_e: Exception) {
        return -1
    }
}

private func readWholeFile(path: String): Array<Byte> {
    let size = localFileSize(path)
    if (size <= 0) {
        return Array<Byte>(0, repeat: 0)
    }
    try {
        let buf = Array<Byte>(size, repeat: 0)
        let file = FileIo.open(path, mode: 0o0)
        let readN = FileIo.read(file.fd, buf)
        FileIo.close(file)
        if (readN != size) {
            return Array<Byte>(0, repeat: 0)
        }
        return buf
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[FileDownload] readWholeFile error ${path}: ${e}")
        return Array<Byte>(0, repeat: 0)
    }
}

/**
 * True when `path` exists and holds exactly `expectedSize` bytes
 * (any non-empty size when the document size is unknown).
 */
public func downloadedFileMatchesSize(path: String, expectedSize: Int64): Bool {
    let size = localFileSize(path)
    if (size <= 0) { return false }
    return expectedSize <= 0 || size == expectedSize
}

/**
 * Writes `bytes` to `<path>.tmp` and renames it over `path` once the temp file holds
 * exactly the expected number of bytes. A payload whose size differs from the
 * document size is rejected and nothing is left at `path`.
 */
public func writeDownloadedFileAtomically(path: String, bytes: Array<Byte>, expectedSize!: Int64 = 0): Bool {
    if (path.isEmpty() || bytes.size == 0) { return false }
    if (expectedSize > 0 && bytes.size != expectedSize) {
        Hilog.info(0, "CjTelegram",
            "[FileDownload] refusing to store ${path}: ${bytes.size} bytes, document size ${expectedSize}")
        return false
    }
    let tmpPath = path + ".tmp"
    try {
        let file = FileIo.open(tmpPath, mode: 0o1101)  // CREATE | WRITE_ONLY | TRUNC
        FileIo.write(file.fd, bytes)
        FileIo.close(file)
        if (localFileSize(tmpPath) != bytes.size) {
            Hilog.info(0, "CjTelegram", "[FileDownload] short write for ${tmpPath}")
            try { FileIo.unlink(tmpPath) } catch (_e: Exception) {}
            return false
        }
        try { FileIo.unlink(path) } catch (_e: Exception) {}
        FileIo.rename(tmpPath, path)
        return localFileSize(path) == bytes.size
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[FileDownload] writeDownloadedFileAtomically error ${path}: ${e}")
        try { FileIo.unlink(tmpPath) } catch (_e: Exception) {}
        return false
    }
}

private func deleteDataFile(fileId: Int64): Unit {
    let path = dataFilePath(fileId)
    if (path.isEmpty()) { return }
    try { FileIo.unlink(path) } catch (_e: Exception) {}
}

/**
 * Returns the finished resource for fileId, or empty when there is none whose size
 * matches `fileSize`. A leftover <fileId>.part without resume state is either a finished
 * download from before completed files were renamed (promoted when its size matches)
 * or stale bytes (deleted so the next fetch starts from a clean temp file).
 */
private func readCompletedResource(fileId: Int64, fileSize: Int64): Array<Byte> {
    let dataPath = dataFilePath(fileId)
    if (dataPath.isEmpty()) {
        return Array<Byte>(0, repeat: 0)
    }
    let dataSize = localFileSize(dataPath)
    if (dataSize > 0) {
        if (fileSize <= 0 || dataSize == fileSize) {
            return readWholeFile(dataPath)
        }
        Hilog.info(0, "CjTelegram",
            "[FileDownload] completed file size ${dataSize} != document size ${fileSize} for fileId=${fileId}, discarding")
        deleteDataFile(fileId)
    }
    if (loadCompletedOffsets(fileId).size > 0) {
        // In-progress download: the .part is resumed, not a finished resource.
        return Array<Byte>(0, repeat: 0)
    }
    let partPath = partFilePath(fileId)
    let partSize = localFileSize(partPath)
    if (partSize <= 0) {
        return Array<Byte>(0, repeat: 0)
    }
    if (fileSize > 0 && partSize != fileSize) {
        Hilog.info(0, "CjTelegram",
            "[FileDownload] stale part file size ${partSize} != document size ${fileSize} for fileId=${fileId}, discarding")
        deletePartFile(fileId)
        return Array<Byte>(0, repeat: 0)
    }
    let bytes = readWholeFile(partPath)
    if (bytes.size > 0) {
        try { FileIo.rename(partPath, dataPath) } catch (_e: Exception) {}
    }
    return bytes
}

/**
 * Seals a fully fetched <fileId>.part: trims any bytes past the resource end,
 * checks the size against the document size and renames it to <fileId>.data.
 * Returns the resource bytes, or empty when the assembled file is not complete.
 */
private func finalizePartFile(fileId: Int64, fileSize: Int64, completeSize: Int64): Array<Byte> {
    let expected = if (fileSize > 0) { fileSize } else { completeSize }
    let assembled = readEntirePartFile(fileId)
    if (expected <= 0 || assembled.size < expected) {
        Hilog.info(0, "CjTelegram",
            "[FileDownload] part file incomplete fileId=${fileId} bytes=${assembled.size} expected=${expected}")
        return Array<Byte>(0, repeat: 0)
    }
    let dataPath = dataFilePath(fileId)
    if (assembled.size == expected) {
        // The temp file is exactly the resource: rename it into place.
        try {
            try { FileIo.unlink(dataPath) } catch (_e: Exception) {}
            FileIo.rename(partFilePath(fileId), dataPath)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[FileDownload] could not seal completed file fileId=${fileId}: ${e}")
            deletePartFile(fileId)
        }
        return assembled
    }
    Hilog.info(0, "CjTelegram",
        "[FileDownload] part file has ${assembled.size - expected} bytes past the end fileId=${fileId}, trimming")
    let exact = Array<Byte>(expected, {i: Int64 => assembled[i]})
    if (!writeDownloadedFileAtomically(dataPath, exact, expectedSize: expected)) {
        Hilog.info(0, "CjTelegram", "[FileDownload] could not seal completed file fileId=${fileId}")
    }
    deletePartFile(fileId)
    return exact
}

// ---- CDN chunk result type ----
private class CdnChunkResult {
    public var data: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var isNotModified: Bool = false  // upload.cdnFileReuploadNeeded
    public var reuploadToken: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var error: String = ""
}

// ---- Shared mutable state for parallel chunk workers ----
// All fields accessed under chunkMon.
private class ChunkDownloadState {
    public let chunkMon: Monitor = Monitor()
    public var nextOffset: Int64 = 0
    public var limitOffsetExclusive: Int64 = -1
    public var done: Bool = false
    public var hasError: Bool = false
    public var cdnRedirect: Bool = false
    public var migrateDc: Int64 = 0
    public var pendingCount: Int64 = 0
    // Resource end learned from the short (last) part: offset + data.count
    // (iOS MultipartFetch completeSize). -1 while unknown.
    public var completeSize: Int64 = -1
    public let completedOffsets: ArrayList<Int64> = ArrayList<Int64>()
    public let completedSet: HashMap<Int64, Bool> = HashMap<Int64, Bool>()
    // CDN redirect fields — populated under chunkMon when cdnRedirect is set true
    public var cdnDcId: Int32 = 0
    public var cdnFileToken: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var cdnEncKey: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var cdnEncIv: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func claimOffset(): Int64 {
        synchronized(chunkMon) {
            if (done || hasError || cdnRedirect) {
                return Int64(-1)
            }
            if (limitOffsetExclusive >= 0 && nextOffset >= limitOffsetExclusive) {
                return Int64(-1)
            }
            while (completedSet.contains(nextOffset) &&
                (limitOffsetExclusive < 0 || nextOffset < limitOffsetExclusive)) {
                nextOffset += Int64(524288)
            }
            if (limitOffsetExclusive >= 0 && nextOffset >= limitOffsetExclusive) {
                return Int64(-1)
            }
            let off = nextOffset
            nextOffset += Int64(524288)   // CHUNK_SIZE_BYTES
            pendingCount += 1
            return off
        }
    }

    public func getCurrentDc(): Int64 {
        synchronized(chunkMon) {
            return migrateDc
        }
    }

    // Store parsed fileCdnRedirect fields and set cdnRedirect=true, decrement pendingCount.
    // Must be called from a spawn worker after parsing all four fields from the deserializer.
    public func storeCdnRedirectAndMark(dcId: Int32, token: Array<Byte>, key: Array<Byte>, iv: Array<Byte>): Unit {
        synchronized(chunkMon) {
            cdnDcId = dcId
            cdnFileToken = token
            cdnEncKey = key
            cdnEncIv = iv
            cdnRedirect = true
            pendingCount -= 1
            chunkMon.notifyAll()
        }
    }

    public func markDone(): Unit {
        synchronized(chunkMon) {
            done = true
            pendingCount -= 1
            chunkMon.notifyAll()
        }
    }

    // upload.file with no bytes: the resource ends at `offset`.
    public func markEndAt(offset: Int64): Unit {
        synchronized(chunkMon) {
            if (completeSize < 0 || offset < completeSize) {
                completeSize = offset
            }
            done = true
            pendingCount -= 1
            chunkMon.notifyAll()
        }
    }

    public func markError(): Unit {
        synchronized(chunkMon) {
            hasError = true
            pendingCount -= 1
            chunkMon.notifyAll()
        }
    }

    public func isChunkWritten(offset: Int64): Bool {
        synchronized(chunkMon) {
            return completedSet.contains(offset)
        }
    }

    public func markChunkWritten(offset: Int64, chunkSize: Int64, isLast: Bool, fileId: Int64): Unit {
        synchronized(chunkMon) {
            if (!completedSet.contains(offset)) {
                completedSet[offset] = true
                completedOffsets.add(offset)
                saveCompletedOffsets(fileId, completedOffsets)
            }
            if (isLast) {
                completeSize = offset + chunkSize
                done = true
            }
            pendingCount -= 1
            chunkMon.notifyAll()
        }
    }

    public func recvMigrateError(offset: Int64, newDc: Int64): Unit {
        synchronized(chunkMon) {
            migrateDc = newDc
            if (offset < nextOffset) {
                nextOffset = offset
            }
            pendingCount -= 1
            chunkMon.notifyAll()
        }
    }
}

// ---- CDN crypto ----
// AES-256-CTR with counter derived from file offset.
// Matches iOS MultipartFetch.swift L436-439:
//   copy encryption_iv (16 bytes) into counter;
//   overwrite last 4 bytes with Int32(chunkOffset / 16) big-endian.
// CHUNK_SIZE_BYTES (524288) is always a multiple of 16, so intraBlock is always 0.
private func cdnDecryptChunk(data: Array<Byte>, key: Array<Byte>, iv: Array<Byte>, chunkOffset: Int64): Array<Byte> {
    // Copy IV into counter (keeps first 12 bytes from CDN-provided encryption_iv)
    let counter = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        counter[i] = iv[i]
    }
    // Overwrite last 4 bytes with Int32(chunkOffset / 16) big-endian
    let bi: Int32 = Int32(chunkOffset / 16)
    counter[12] = UInt8((bi >> 24) & 0xFF)
    counter[13] = UInt8((bi >> 16) & 0xFF)
    counter[14] = UInt8((bi >> 8) & 0xFF)
    counter[15] = UInt8(bi & 0xFF)
    let ctr = AesCtr(key, counter)
    return ctr.process(data)
}

// ============================================================
// P2-321 / TC-0427 FIX-2: Per-network-type auto-download settings.
//
// Stored in a dedicated Preferences store "telegram_dl_network",
// separate from the main AuthStorage store. Source-shaped model
// (submodules/TelegramUIPreferences/Sources/MediaAutoDownloadSettings.swift):
// connection(cellular|wifi) -> { enabled, preset(low|medium|high|custom), custom }
// where `custom`, when present, is a full categories(photo|video|file|stories)
// matrix, each category { contacts, otherPrivate, groups, channels, sizeLimit,
// predownload }.
//
// Explicitly NOT migrated (diag-suite_settings_data_storage-TC-0427.md case §4
// server_side_effect hard ban + FIX-2 step 3's explicit exclusion): the server-side
// `AutodownloadSettings` preset override (`updatedWithAutodownloadSettings`) and the
// `didDisappear` upload (`account.saveAutoDownloadSettings`). `low`/`medium`/`high`
// below are therefore the fixed offline-fallback defaults
// (`MediaAutoDownloadSettings.defaultSettings`), never server-refreshed — this
// mirrors the source's own offline fallback path, not a reduced feature.
//
// Call site for download gate:
//   if getFileDownloadService().shouldAutoDownload(mediaType, fileSizeBytes,
//       ReachabilityService.getInstance().currentStatus()) { ... download ... }
// ============================================================

private let DL_NETWORK_STORE = "telegram_dl_network"
private let KEY_NET_CELLULAR_ENABLED = "cellular_enabled"
private let KEY_NET_WIFI_ENABLED = "wifi_enabled"
private let KEY_NET_VIDEO_SIZE_CELLULAR = "video_size_cellular"
private let KEY_NET_VIDEO_SIZE_WIFI = "video_size_wifi"
private let KEY_NET_FILE_SIZE_CELLULAR = "file_size_cellular"
private let KEY_NET_FILE_SIZE_WIFI = "file_size_wifi"
private let KEY_MIGRATED_V2 = "migrated_v2"

// Legacy (pre-FIX-2) flat-model defaults. Retained ONLY as the "was this key ever
// touched by the user" comparison baseline for the one-time migration below — they
// are never used as a live default again (the report's finding was precisely that
// DEFAULT_VIDEO_SIZE_CELLULAR=2097152 (2 MB) is wrong; the real source medium preset
// is 2.5 MB, see PRESET_MEDIUM below). Do not read these outside migrateLegacyIfNeeded.
private let LEGACY_DEFAULT_VIDEO_SIZE_CELLULAR: Int64 = 2097152    // 2 MB
private let LEGACY_DEFAULT_VIDEO_SIZE_WIFI: Int64 = 10485760       // 10 MB
private let LEGACY_DEFAULT_FILE_SIZE_CELLULAR: Int64 = 1048576     // 1 MB
private let LEGACY_DEFAULT_FILE_SIZE_WIFI: Int64 = 3145728         // 3 MB

private let MB: Int64 = 1048576

public enum AutoDownloadPresetKind {
    | PresetLow | PresetMedium | PresetHigh | PresetCustom
}

extend AutoDownloadPresetKind <: Equatable<AutoDownloadPresetKind> {
    public operator func ==(that: AutoDownloadPresetKind): Bool {
        match ((this, that)) {
            case (PresetLow, PresetLow) => true
            case (PresetMedium, PresetMedium) => true
            case (PresetHigh, PresetHigh) => true
            case (PresetCustom, PresetCustom) => true
            case _ => false
        }
    }
    public operator func !=(that: AutoDownloadPresetKind): Bool {
        return !(this == that)
    }
}

public enum AutoDownloadConnectionKind {
    | ConnCellular | ConnWifi
}

public enum AutoDownloadCategoryKind {
    | CategoryPhoto | CategoryVideo | CategoryFile | CategoryStories
}

public enum AutoDownloadPeerKind {
    | PeerContacts | PeerOtherPrivate | PeerGroups | PeerChannels
}

public class MediaAutoDownloadCategory {
    public var contacts: Bool
    public var otherPrivate: Bool
    public var groups: Bool
    public var channels: Bool
    public var sizeLimit: Int64
    public var predownload: Bool

    public init(contacts!: Bool, otherPrivate!: Bool, groups!: Bool, channels!: Bool, sizeLimit!: Int64, predownload!: Bool) {
        this.contacts = contacts
        this.otherPrivate = otherPrivate
        this.groups = groups
        this.channels = channels
        this.sizeLimit = sizeLimit
        this.predownload = predownload
    }

    public func clone(): MediaAutoDownloadCategory {
        return MediaAutoDownloadCategory(
            contacts: this.contacts, otherPrivate: this.otherPrivate, groups: this.groups,
            channels: this.channels, sizeLimit: this.sizeLimit, predownload: this.predownload
        )
    }
}

public class MediaAutoDownloadCategories {
    public var photo: MediaAutoDownloadCategory
    public var video: MediaAutoDownloadCategory
    public var file: MediaAutoDownloadCategory
    public var stories: MediaAutoDownloadCategory

    public init(photo!: MediaAutoDownloadCategory, video!: MediaAutoDownloadCategory, file!: MediaAutoDownloadCategory, stories!: MediaAutoDownloadCategory) {
        this.photo = photo
        this.video = video
        this.file = file
        this.stories = stories
    }

    public func clone(): MediaAutoDownloadCategories {
        return MediaAutoDownloadCategories(
            photo: this.photo.clone(), video: this.video.clone(),
            file: this.file.clone(), stories: this.stories.clone()
        )
    }

    public func categoryFor(kind: AutoDownloadCategoryKind): MediaAutoDownloadCategory {
        match (kind) {
            case CategoryPhoto => return this.photo
            case CategoryVideo => return this.video
            case CategoryFile => return this.file
            case CategoryStories => return this.stories
        }
    }
}

public class MediaAutoDownloadConnection {
    public var enabled: Bool
    public var preset: AutoDownloadPresetKind
    public var custom: Option<MediaAutoDownloadCategories>

    public init(enabled!: Bool, preset!: AutoDownloadPresetKind, custom!: Option<MediaAutoDownloadCategories>) {
        this.enabled = enabled
        this.preset = preset
        this.custom = custom
    }
}

// Bare `None` at a named-argument call site is ambiguous ("find multiple constructor
// 'None' of enum declaration" — kit.ArkData/kit.CoreFileKit also register an enum with
// a `None` constructor, and named-arg position doesn't propagate the expected
// `Option<MediaAutoDownloadCategories>` target type early enough for overload
// resolution). A pre-typed local sidesteps it the same way the pre-existing
// `_networkSettings: Option<AutoDownloadNetworkSettings> = None` field declaration does
// (LHS type annotation resolves `None` unambiguously; call-site inference does not).
private let NO_CUSTOM_CATEGORIES: Option<MediaAutoDownloadCategories> = None

// ---- fixed low/medium/high presets (source: MediaAutoDownloadSettings.defaultSettings :375-400) ----
private func presetLowCategories(): MediaAutoDownloadCategories {
    return MediaAutoDownloadCategories(
        photo: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 1 * MB, predownload: false),
        video: MediaAutoDownloadCategory(contacts: false, otherPrivate: false, groups: false, channels: false, sizeLimit: 1 * MB, predownload: false),
        file: MediaAutoDownloadCategory(contacts: false, otherPrivate: false, groups: false, channels: false, sizeLimit: 1 * MB, predownload: false),
        stories: MediaAutoDownloadCategory(contacts: false, otherPrivate: false, groups: false, channels: false, sizeLimit: 20 * MB, predownload: false)
    )
}

private func presetMediumCategories(): MediaAutoDownloadCategories {
    return MediaAutoDownloadCategories(
        photo: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 1 * MB, predownload: false),
        video: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 2621440, predownload: false), // Int64(2.5 * MB)
        file: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 1 * MB, predownload: false),
        stories: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 20 * MB, predownload: false)
    )
}

private func presetHighCategories(): MediaAutoDownloadCategories {
    return MediaAutoDownloadCategories(
        photo: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 1 * MB, predownload: false),
        video: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 10 * MB, predownload: true),
        file: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 3 * MB, predownload: false),
        stories: MediaAutoDownloadCategory(contacts: true, otherPrivate: true, groups: true, channels: true, sizeLimit: 20 * MB, predownload: false)
    )
}

public func categoriesForPreset(preset: AutoDownloadPresetKind): MediaAutoDownloadCategories {
    match (preset) {
        case PresetLow => return presetLowCategories()
        case PresetMedium => return presetMediumCategories()
        case PresetHigh => return presetHighCategories()
        // PresetCustom without a `.custom` payload should not occur (every writer that
        // sets preset=Custom also sets custom=Some(...)); medium is the least-surprising
        // fallback shape (same as the source's decode-time fallback in :349 `?? .medium`).
        case PresetCustom => return presetMediumCategories()
    }
}

// Source: effectiveAutodownloadCategories(settings:networkType:) — resolves the
// categories actually in effect for a connection (custom overrides the named preset).
public func effectiveCategories(connection: MediaAutoDownloadConnection): MediaAutoDownloadCategories {
    match (connection.custom) {
        case Some(c) => return c
        case None => return categoriesForPreset(connection.preset)
    }
}

private func defaultCellularConnection(): MediaAutoDownloadConnection {
    return MediaAutoDownloadConnection(enabled: true, preset: AutoDownloadPresetKind.PresetMedium, custom: NO_CUSTOM_CATEGORIES)
}

private func defaultWifiConnection(): MediaAutoDownloadConnection {
    return MediaAutoDownloadConnection(enabled: true, preset: AutoDownloadPresetKind.PresetHigh, custom: NO_CUSTOM_CATEGORIES)
}

/**
 * Container for the in-memory cache of network-specific auto-download policy.
 * `AutoDownloadNetworkSettings()` (no-arg) always yields the fresh factory defaults —
 * used both as the Reset target and as the "what does default look like" comparison
 * baseline by DataStorageSettingsPage.autoDownloadIsCustomized().
 */
public class AutoDownloadNetworkSettings {
    public var cellular: MediaAutoDownloadConnection
    public var wifi: MediaAutoDownloadConnection

    public init() {
        this.cellular = defaultCellularConnection()
        this.wifi = defaultWifiConnection()
    }
}

/**
 * Source: AutodownloadMediaCategoryController.swift:12-46 `autodownloadDataSizeString`
 * (this feature's `source_refs`). Ported verbatim (integer arithmetic, no rounding
 * beyond what Int64 division already does) — the one-decimal-below-10MB rule is the
 * exact fix for F1's "2.5 MB truncates to 2MB" finding, so this must not be
 * simplified back to whole-number MB.
 */
public func autodownloadDataSizeString(size: Int64): String {
    if (size >= 1024 * 1024 * 1024) {
        var remainder = (size % (1024 * 1024 * 1024)) / (1024 * 1024 * 102)
        if (remainder == 10) { remainder = 9 }
        while (remainder != 0 && remainder % 10 == 0) { remainder /= 10 }
        if (remainder != 0) {
            return "${size / (1024 * 1024 * 1024)}.${remainder} GB"
        } else {
            return "${size / (1024 * 1024 * 1024)} GB"
        }
    } else if (size >= 1024 * 1024) {
        var remainder = (size % (1024 * 1024)) / (1024 * 102)
        if (remainder == 10) { remainder = 9 }
        while (remainder != 0 && remainder % 10 == 0) { remainder /= 10 }
        if (size < 10 * 1024 * 1024) {
            return "${size / (1024 * 1024)}.${remainder} MB"
        } else {
            return "${size / (1024 * 1024)} MB"
        }
    } else if (size >= 1024) {
        return "${size / 1024} KB"
    } else {
        return "${size} B"
    }
}

private func connectionKeyPrefix(kind: AutoDownloadConnectionKind): String {
    match (kind) {
        case ConnCellular => return "cellular"
        case ConnWifi => return "wifi"
    }
}

private func categoryKeyPart(kind: AutoDownloadCategoryKind): String {
    match (kind) {
        case CategoryPhoto => return "photo"
        case CategoryVideo => return "video"
        case CategoryFile => return "file"
        case CategoryStories => return "stories"
    }
}

private func presetToInt(p: AutoDownloadPresetKind): Int64 {
    match (p) {
        case PresetLow => return 0
        case PresetMedium => return 1
        case PresetHigh => return 2
        case PresetCustom => return 3
    }
}

private func intToPreset(n: Int64): AutoDownloadPresetKind {
    match (n) {
        case 0 => return AutoDownloadPresetKind.PresetLow
        case 1 => return AutoDownloadPresetKind.PresetMedium
        case 2 => return AutoDownloadPresetKind.PresetHigh
        case _ => return AutoDownloadPresetKind.PresetCustom
    }
}

private func readNetworkBoolPref(key: String, def: Bool): Bool {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, DL_NETWORK_STORE)
                let defInt: Int64 = if (def) { 1 } else { 0 }
                match (prefs.get(key, PreferencesValueType.Integer(defInt))) {
                    case PreferencesValueType.Integer(n) => return n != 0
                    case _ => return def
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[FileDownload] readNetworkBoolPref ${key} failed: ${e}")
                return def
            }
        case None => return def
    }
}

private func readNetworkInt64Pref(key: String, def: Int64): Int64 {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, DL_NETWORK_STORE)
                match (prefs.get(key, PreferencesValueType.Integer(def))) {
                    case PreferencesValueType.Integer(n) => return n
                    case _ => return def
                }
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[FileDownload] readNetworkInt64Pref ${key} failed: ${e}")
                return def
            }
        case None => return def
    }
}

private func saveNetworkBoolPref(key: String, value: Bool): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, DL_NETWORK_STORE)
                prefs.put(key, PreferencesValueType.Integer(if (value) { Int64(1) } else { Int64(0) }))
                prefs.flush()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[FileDownload] saveNetworkBoolPref ${key} failed: ${e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[FileDownload] saveNetworkBoolPref: context not ready")
    }
}

private func saveNetworkInt64Pref(key: String, value: Int64): Unit {
    match (getGlobalAbilityContext()) {
        case Some(ctx) =>
            try {
                let prefs = Preferences.getPreferences(ctx, DL_NETWORK_STORE)
                prefs.put(key, PreferencesValueType.Integer(value))
                prefs.flush()
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[FileDownload] saveNetworkInt64Pref ${key} failed: ${e}")
            }
        case None =>
            Hilog.info(0, "CjTelegram", "[FileDownload] saveNetworkInt64Pref: context not ready")
    }
}

private func loadCategoryFromPrefs(prefix: String, cat: String, def: MediaAutoDownloadCategory): MediaAutoDownloadCategory {
    return MediaAutoDownloadCategory(
        contacts: readNetworkBoolPref("${prefix}_${cat}_contacts", def.contacts),
        otherPrivate: readNetworkBoolPref("${prefix}_${cat}_otherPrivate", def.otherPrivate),
        groups: readNetworkBoolPref("${prefix}_${cat}_groups", def.groups),
        channels: readNetworkBoolPref("${prefix}_${cat}_channels", def.channels),
        sizeLimit: readNetworkInt64Pref("${prefix}_${cat}_sizeLimit", def.sizeLimit),
        predownload: readNetworkBoolPref("${prefix}_${cat}_predownload", def.predownload)
    )
}

private func loadConnectionFromPrefs(kind: AutoDownloadConnectionKind, def: MediaAutoDownloadConnection): MediaAutoDownloadConnection {
    let prefix = connectionKeyPrefix(kind)
    let enabled = readNetworkBoolPref("${prefix}_enabled", def.enabled)
    let presetN = readNetworkInt64Pref("${prefix}_preset", presetToInt(def.preset))
    let preset = intToPreset(presetN)
    let hasCustom = readNetworkBoolPref("${prefix}_has_custom", false)
    var custom: Option<MediaAutoDownloadCategories> = None
    if (hasCustom) {
        let baseline = categoriesForPreset(preset)
        custom = Some(MediaAutoDownloadCategories(
            photo: loadCategoryFromPrefs(prefix, "photo", baseline.photo),
            video: loadCategoryFromPrefs(prefix, "video", baseline.video),
            file: loadCategoryFromPrefs(prefix, "file", baseline.file),
            stories: loadCategoryFromPrefs(prefix, "stories", baseline.stories)
        ))
    }
    return MediaAutoDownloadConnection(enabled: enabled, preset: preset, custom: custom)
}

private func persistCategory(prefix: String, cat: String, c: MediaAutoDownloadCategory): Unit {
    saveNetworkBoolPref("${prefix}_${cat}_contacts", c.contacts)
    saveNetworkBoolPref("${prefix}_${cat}_otherPrivate", c.otherPrivate)
    saveNetworkBoolPref("${prefix}_${cat}_groups", c.groups)
    saveNetworkBoolPref("${prefix}_${cat}_channels", c.channels)
    saveNetworkInt64Pref("${prefix}_${cat}_sizeLimit", c.sizeLimit)
    saveNetworkBoolPref("${prefix}_${cat}_predownload", c.predownload)
}

private func persistConnection(kind: AutoDownloadConnectionKind, conn: MediaAutoDownloadConnection): Unit {
    let prefix = connectionKeyPrefix(kind)
    saveNetworkBoolPref("${prefix}_enabled", conn.enabled)
    saveNetworkInt64Pref("${prefix}_preset", presetToInt(conn.preset))
    match (conn.custom) {
        case Some(cats) =>
            saveNetworkBoolPref("${prefix}_has_custom", true)
            persistCategory(prefix, "photo", cats.photo)
            persistCategory(prefix, "video", cats.video)
            persistCategory(prefix, "file", cats.file)
            persistCategory(prefix, "stories", cats.stories)
        case None =>
            saveNetworkBoolPref("${prefix}_has_custom", false)
    }
}

// One-time migration from the pre-FIX-2 flat 6-key model. Values equal to the legacy
// default are treated as "user never touched this" and get the corrected new default
// instead (this is precisely how the 2 MB->2.5 MB cellular-video baseline bug gets
// fixed for existing installs); values that differ are genuine user customization and
// are carried over as a `.custom` connection (source parity: any per-field edit forces
// preset=custom). Old keys are read here one last time and never written again.
private func migrateLegacyIfNeeded(): Unit {
    if (readNetworkBoolPref(KEY_MIGRATED_V2, false)) { return }

    let oldCellEnabled = readNetworkBoolPref(KEY_NET_CELLULAR_ENABLED, true)
    let oldWifiEnabled = readNetworkBoolPref(KEY_NET_WIFI_ENABLED, true)
    let oldVideoCell = readNetworkInt64Pref(KEY_NET_VIDEO_SIZE_CELLULAR, LEGACY_DEFAULT_VIDEO_SIZE_CELLULAR)
    let oldVideoWifi = readNetworkInt64Pref(KEY_NET_VIDEO_SIZE_WIFI, LEGACY_DEFAULT_VIDEO_SIZE_WIFI)
    let oldFileCell = readNetworkInt64Pref(KEY_NET_FILE_SIZE_CELLULAR, LEGACY_DEFAULT_FILE_SIZE_CELLULAR)
    let oldFileWifi = readNetworkInt64Pref(KEY_NET_FILE_SIZE_WIFI, LEGACY_DEFAULT_FILE_SIZE_WIFI)

    let mediumCats = presetMediumCategories()
    var cellular = MediaAutoDownloadConnection(enabled: oldCellEnabled, preset: AutoDownloadPresetKind.PresetMedium, custom: NO_CUSTOM_CATEGORIES)
    if (oldVideoCell != LEGACY_DEFAULT_VIDEO_SIZE_CELLULAR || oldFileCell != LEGACY_DEFAULT_FILE_SIZE_CELLULAR) {
        let video = mediumCats.video.clone()
        if (oldVideoCell != LEGACY_DEFAULT_VIDEO_SIZE_CELLULAR) { video.sizeLimit = oldVideoCell }
        let file = mediumCats.file.clone()
        if (oldFileCell != LEGACY_DEFAULT_FILE_SIZE_CELLULAR) { file.sizeLimit = oldFileCell }
        cellular = MediaAutoDownloadConnection(
            enabled: oldCellEnabled, preset: AutoDownloadPresetKind.PresetCustom,
            custom: Some(MediaAutoDownloadCategories(photo: mediumCats.photo.clone(), video: video, file: file, stories: mediumCats.stories.clone()))
        )
    }

    let highCats = presetHighCategories()
    var wifi = MediaAutoDownloadConnection(enabled: oldWifiEnabled, preset: AutoDownloadPresetKind.PresetHigh, custom: NO_CUSTOM_CATEGORIES)
    if (oldVideoWifi != LEGACY_DEFAULT_VIDEO_SIZE_WIFI || oldFileWifi != LEGACY_DEFAULT_FILE_SIZE_WIFI) {
        let video = highCats.video.clone()
        if (oldVideoWifi != LEGACY_DEFAULT_VIDEO_SIZE_WIFI) { video.sizeLimit = oldVideoWifi }
        let file = highCats.file.clone()
        if (oldFileWifi != LEGACY_DEFAULT_FILE_SIZE_WIFI) { file.sizeLimit = oldFileWifi }
        wifi = MediaAutoDownloadConnection(
            enabled: oldWifiEnabled, preset: AutoDownloadPresetKind.PresetCustom,
            custom: Some(MediaAutoDownloadCategories(photo: highCats.photo.clone(), video: video, file: file, stories: highCats.stories.clone()))
        )
    }

    persistConnection(AutoDownloadConnectionKind.ConnCellular, cellular)
    persistConnection(AutoDownloadConnectionKind.ConnWifi, wifi)
    saveNetworkBoolPref(KEY_MIGRATED_V2, true)
    Hilog.info(0, "CjTelegram", "[FileDownload] migrated legacy auto-download settings to FIX-2 model")
}

// In-memory singleton for network download settings (loaded lazily from Preferences).
private var _networkSettings: Option<AutoDownloadNetworkSettings> = None
private let _networkSettingsMon: Monitor = Monitor()

private func loadNetworkSettingsFromPrefs(): AutoDownloadNetworkSettings {
    migrateLegacyIfNeeded()
    let s = AutoDownloadNetworkSettings()
    s.cellular = loadConnectionFromPrefs(AutoDownloadConnectionKind.ConnCellular, s.cellular)
    s.wifi = loadConnectionFromPrefs(AutoDownloadConnectionKind.ConnWifi, s.wifi)
    return s
}

private func getNetworkSettingsSingleton(): AutoDownloadNetworkSettings {
    synchronized(_networkSettingsMon) {
        match (_networkSettings) {
            case Some(s) => return s
            case None =>
                let s = loadNetworkSettingsFromPrefs()
                _networkSettings = Some(s)
                return s
        }
    }
}

private func connectionFor(s: AutoDownloadNetworkSettings, kind: AutoDownloadConnectionKind): MediaAutoDownloadConnection {
    match (kind) {
        case ConnCellular => return s.cellular
        case ConnWifi => return s.wifi
    }
}

// ---- global singleton ----
private var _fileDownloadInstance: Option<FileDownloadService> = None
private let _fileDownloadInitMon: Monitor = Monitor()

public func getFileDownloadService(): FileDownloadService {
    synchronized(_fileDownloadInitMon) {
        match (_fileDownloadInstance) {
            case Some(inst) => return inst
            case None =>
                let inst = FileDownloadService()
                _fileDownloadInstance = Some(inst)
                return inst
        }
    }
}

// ---- main service class ----
public class FileDownloadService {
    // in-memory cache: fileId -> completed bytes (for small files / already cached)
    private let cacheMon: Monitor = Monitor()
    private var downloadCache: HashMap<Int64, Array<Byte>> = HashMap<Int64, Array<Byte>>()

    // active task registry: fileId -> DownloadTask
    private let taskMon: Monitor = Monitor()
    private var activeTasks: HashMap<Int64, DownloadTask> = HashMap<Int64, DownloadTask>()
    private let photoTaskMon: Monitor = Monitor()
    private var activePhotoTasks: HashMap<Int64, DownloadTask> = HashMap<Int64, DownloadTask>()
    // Photo ids whose last upload.getFile failed with FILE_REFERENCE_* / FILEREF_INVALID
    // (iOS MultipartFetch.swift:356 → revalidate the media reference and retry).
    private let fileRefMon: Monitor = Monitor()
    private var fileRefExpiredPhotos: HashMap<Int64, Bool> = HashMap<Int64, Bool>()

    // priority queue for queued tasks
    private let downloadQueue: PriorityDownloadQueue = PriorityDownloadQueue()

    // bounded concurrency slot manager
    private let slotManager: SlotManager = SlotManager(PARALLEL_SLOTS)

    // ================================================================
    // PUBLIC API — initiating a download
    // ================================================================

    /**
     * Download a document / media file with ranged resume + parallel chunks.
     * priority: higher integer = higher priority in the global queue.
     * Returns file bytes when complete, or empty array on error/cancel.
     */
    public func downloadDocument(
        fileId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        dcId: Int32,
        fileSize!: Int64 = 0,
        priority!: Int32 = 10,
        statsCategory!: TransportUsageCategory = TransportUsageCategory.File,
        contentType!: MediaUsageContentType = MediaUsageContentType.Other
    ): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[FileDownload] downloadDocument: fileId=${fileId}, size=${fileSize}, dc=${dcId}, prio=${priority}")

        // Check memory cache (only an entry of exactly the document size is this resource)
        synchronized(cacheMon) {
            if (downloadCache.contains(fileId)) {
                let cached = downloadCache[fileId]
                if (fileSize <= 0 || cached.size == fileSize) {
                    return cached
                }
                Hilog.info(0, "CjTelegram",
                    "[FileDownload] memory cache size ${cached.size} != document size ${fileSize} for fileId=${fileId}, dropping")
                let _ = downloadCache.remove(fileId)
            }
        }

        // Check if already complete on disk (sealed .data, or a legacy .part of exactly fileSize)
        let existing = readCompletedResource(fileId, fileSize)
        if (existing.size > 0) {
            Hilog.info(0, "CjTelegram", "[FileDownload] Cache hit on disk for fileId=${fileId} bytes=${existing.size}")
            synchronized(cacheMon) {
                downloadCache[fileId] = existing
            }
            return existing
        }

        // Single-flight by Telegram resource id. Local history, network refresh,
        // push and polling can all discover the same file concurrently; only
        // the first caller owns I/O, the rest subscribe to its terminal state.
        var task = DownloadTask(fileId, priority)
        var ownsTask = false
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                task = activeTasks[fileId]
            } else {
                activeTasks[fileId] = task
                ownsTask = true
            }
        }
        if (!ownsTask) {
            let joinStartedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
            downloadQueue.raisePriority(task, priority)
            task.waitUntilTerminal()
            synchronized(cacheMon) {
                if (downloadCache.contains(fileId) &&
                    (fileSize <= 0 || downloadCache[fileId].size == fileSize)) {
                    Hilog.info(0, "CjTelegram",
                        "[FileDownloadPerf] single-flight hit fileId=${fileId} waitMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - joinStartedAt}")
                    return downloadCache[fileId]
                }
            }
            return readCompletedResource(fileId, fileSize)
        }

        let queueStartedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        if (!downloadQueue.enqueueAndWait(task)) {
            synchronized(taskMon) { let _ = activeTasks.remove(fileId) }
            return Array<Byte>(0, repeat: 0)
        }
        Hilog.info(0, "CjTelegram",
            "[FileDownloadPerf] start fileId=${fileId} priority=${priority} queueMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - queueStartedAt}")

        let location = InputDocumentFileLocation()
        location.id = fileId
        location.accessHash = accessHash
        location.fileReference = fileReference
        location.thumbSize = ""

        let transferStartedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let result = this.runParallelChunkedDownload(
            task,
            fileId,
            location,
            Int64(dcId),
            fileSize,
            statsCategory,
            contentType
        )
        downloadQueue.finish()

        // Deregister task
        synchronized(taskMon) {
            let _ = activeTasks.remove(fileId)
        }

        if (result.size > 0) {
            synchronized(cacheMon) {
                downloadCache[fileId] = result
            }
        }
        Hilog.info(0, "CjTelegram",
            "[FileDownloadPerf] finish fileId=${fileId} bytes=${result.size} transferMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - transferStartedAt}")
        return result
    }

    /**
     * Download a photo (single-chunk; small enough not to need parallel).
     */
    // 下载单个文件分片（对齐 iOS MultipartFetch 的一片 = 一次 upload.getFile）。
    // 返回该片字节（空=错误/EOF）。并发安全：sendRequest 是 per-msgId 并发设计，
    // 多个本函数可同时在不同线程调用（location 只读共享）。
    private func downloadFilePart(location: InputPhotoFileLocation, offset: Int64, limit: Int32,
        interactive!: Bool = false): Array<UInt8> {
        // 双连接：文件分片走下载专用客户端（独立 TCP+会话），
        // 不再把主连接上的小 RPC 回复压在 512KB 分片响应后面。
        let client = getDownloadMTProtoClient()
        let req = UploadGetFile()
        req.precise = true
        req.location = location
        req.offset = offset
        req.limit = limit
        this.slotManager.acquire(interactive: interactive)
        var responseData = Array<Byte>(0, repeat: 0)
        try {
            responseData = client.sendMediaRequest(
                req.toBytes(),
                TransportUsageCategory.Image,
                MediaUsageContentType.Image
            )
        } catch (_e: Exception) {
            this.slotManager.release()
            return Array<UInt8>(0, repeat: 0)
        }
        this.slotManager.release()
        if (responseData.size < 8) { return Array<UInt8>(0, repeat: 0) }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            try {
                let errorCode = d.readInt32()
                let errorMessage = d.readString()
                Hilog.info(0, "CjTelegram", "[FileDownload] photo part RPC error id=${location.id}: ${errorCode} ${errorMessage}")
                if (errorMessage.startsWith("FILE_REFERENCE_") || errorMessage.startsWith("FILEREF_INVALID")) {
                    synchronized(this.fileRefMon) { this.fileRefExpiredPhotos[location.id] = true }
                }
            } catch (_e: Exception) {}
            return Array<UInt8>(0, repeat: 0)
        }
        if (constructor != 0x096a18d5) { return Array<UInt8>(0, repeat: 0) }  // 非 upload.file
        let _ = d.readUInt32()  // type
        let _ = d.readInt32()   // mtime
        let photoBytes = d.readBytes()
        let out = Array<UInt8>(photoBytes.size, repeat: 0)
        for (i in 0..photoBytes.size) { out[i] = photoBytes[i] }
        return out
    }

    /** True (once) when the last fetch of this photo failed because its file_reference expired. */
    public func takeFileReferenceExpired(photoId: Int64): Bool {
        synchronized(this.fileRefMon) {
            if (this.fileRefExpiredPhotos.contains(photoId)) {
                let _ = this.fileRefExpiredPhotos.remove(photoId)
                return true
            }
            return false
        }
    }

    public func downloadPhoto(
        photoId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        thumbSize!: String = "x",
        priority!: Int32 = 10
    ): Array<Byte> {
        let cacheKey = this.photoCacheKey(photoId, thumbSize)
        Hilog.info(0, "CjTelegram", "[FileDownload] downloadPhoto: photoId=${photoId}, thumb=${thumbSize}")
        synchronized(cacheMon) {
            if (downloadCache.contains(cacheKey)) {
                return downloadCache[cacheKey]
            }
        }

        // Photo representations use their own single-flight registry but share
        // the resource priority queue with documents. Negative queue ids keep
        // their identity disjoint from Telegram document ids.
        var photoTask = DownloadTask(-cacheKey, priority)
        var ownsPhotoTask = false
        synchronized(photoTaskMon) {
            if (activePhotoTasks.contains(cacheKey)) {
                photoTask = activePhotoTasks[cacheKey]
            } else {
                activePhotoTasks[cacheKey] = photoTask
                ownsPhotoTask = true
            }
        }
        if (!ownsPhotoTask) {
            downloadQueue.raisePriority(photoTask, priority)
            photoTask.waitUntilTerminal()
            synchronized(cacheMon) {
                if (downloadCache.contains(cacheKey)) { return downloadCache[cacheKey] }
            }
            return Array<Byte>(0, repeat: 0)
        }
        if (!downloadQueue.enqueueAndWait(photoTask)) {
            synchronized(photoTaskMon) { let _ = activePhotoTasks.remove(cacheKey) }
            return Array<Byte>(0, repeat: 0)
        }

        let location = InputPhotoFileLocation()
        location.id = photoId
        location.accessHash = accessHash
        location.fileReference = fileReference
        location.thumbSize = thumbSize

        // MTProto upload.getFile 单次 limit 上限 = 1MB(1048576)；整除 1MB 且 4096 倍数
        // （对齐 iOS MultipartFetch.swift:341-342 约束；此前对 "y" 用 2MB→LIMIT_INVALID）。
        // 首片串行：多数照片(气泡"y"≤~400KB)首片即短读→一次拉完、无浪费、无并发。
        // 首片满(大文件如"w"2560/长图)才对余下片 4 路并行下载（对齐 iOS 并行分片提速）。
        let limit: Int32 = 1048576
        let acc = ArrayList<UInt8>()
        // Priority may be raised while queued (a background history photo scrolling on screen).
        let interactivePhoto = photoTask.priority >= DOWNLOAD_INTERACTIVE_PRIORITY
        let first = this.downloadFilePart(location, 0, limit, interactive: interactivePhoto)
        for (b in first) { acc.add(b) }
        if (Int32(first.size) == limit) {
            // 大文件：并行拉余下片（sendRequest 是 per-msgId 并发安全）
            let parallelN: Int64 = MAX_CHUNKS_PER_RESOURCE
            var base: Int64 = Int64(limit)
            var stop = false
            var guardN: Int32 = 0
            while (!stop && guardN < 64) {  // 安全上限 ~256MB
                guardN = guardN + 1
                let futs = ArrayList<Future<Array<UInt8>>>()
                var k: Int64 = 0
                while (k < parallelN) {
                    let off = base + k * Int64(limit)
                    futs.add(spawn { this.downloadFilePart(location, off, limit, interactive: interactivePhoto) })
                    k = k + 1
                }
                var j: Int64 = 0
                while (j < parallelN) {
                    let part = futs[j].get()
                    for (b in part) { acc.add(b) }
                    if (Int32(part.size) < limit) { stop = true; break }  // 短片=EOF→停
                    j = j + 1
                }
                base = base + parallelN * Int64(limit)
            }
        }

        if (acc.size > 0) {
            let result = Array<Byte>(acc.size, repeat: 0)
            for (i in 0..acc.size) { result[i] = acc[i] }
            synchronized(cacheMon) {
                downloadCache[cacheKey] = result
            }
            photoTask.setStatus(DownloadStatus.COMPLETED)
            downloadQueue.finish()
            synchronized(photoTaskMon) { let _ = activePhotoTasks.remove(cacheKey) }
            return result
        }
        photoTask.setStatus(DownloadStatus.FAILED)
        downloadQueue.finish()
        synchronized(photoTaskMon) { let _ = activePhotoTasks.remove(cacheKey) }
        return Array<Byte>(0, repeat: 0)
    }

    /**
     * Download a document thumbnail.
     */
    public func downloadDocumentThumb(
        fileId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        thumbSize!: String = "m",
        dcId!: Int32 = 0
    ): Array<Byte> {
        let cacheKey = fileId ^ Int64(thumbSize.size)
        Hilog.info(0, "CjTelegram", "[FileDownload] downloadDocumentThumb: fileId=${fileId}, thumb=${thumbSize}")
        synchronized(cacheMon) {
            if (downloadCache.contains(cacheKey)) {
                return downloadCache[cacheKey]
            }
        }

        // 主 DC（或调用方未传 dcId）走下载专用客户端；跨 DC 走 per-DC 客户端（导出授权路径）。
        // 对位 downloadUserPhoto() :1378 的分流形状。
        let client = if (dcId <= 0 || Int64(dcId) == getMainClientDcId()) {
            getDownloadMTProtoClient()
        } else {
            getClientForDC(Int64(dcId))
        }
        let location = InputDocumentFileLocation()
        location.id = fileId
        location.accessHash = accessHash
        location.fileReference = fileReference
        location.thumbSize = thumbSize

        let req = UploadGetFile()
        req.precise = true
        req.location = location
        req.offset = 0
        req.limit = 1048576

        let responseData = client.sendMediaRequest(
            req.toBytes(),
            TransportUsageCategory.Image,
            MediaUsageContentType.Image
        )
        if (responseData.size < 8) {
            return Array<Byte>(0, repeat: 0)
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == 0x096a18d5) {
            let _ = d.readUInt32()
            let _ = d.readInt32()
            let thumbBytes = d.readBytes()
            let result = Array<Byte>(thumbBytes.size, repeat: 0)
            for (i in 0..thumbBytes.size) {
                result[i] = thumbBytes[i]
            }
            synchronized(cacheMon) {
                downloadCache[cacheKey] = result
            }
            return result
        }

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[FileDownload] Thumb RPC Error: ${errorCode} - ${errorMessage}")
        }
        return Array<Byte>(0, repeat: 0)
    }

    /**
     * Download user / group avatar with cross-DC support.
     */
    public func downloadUserPhoto(
        userId: Int64,
        accessHash: Int64,
        photoId: Int64,
        dcId: Int32,
        big!: Bool = false,
        peerType!: String = "user"
    ): Array<Byte> {
        let cacheKey = photoId ^ (if (big) { Int64(1) } else { Int64(0) })
        Hilog.info(0, "CjTelegram", "[FileDownload] downloadUserPhoto: userId=${userId}, photoId=${photoId}, dc=${dcId}, big=${big}")
        synchronized(cacheMon) {
            if (downloadCache.contains(cacheKey)) {
                return downloadCache[cacheKey]
            }
        }

        var peer: TLObject = InputPeerEmpty()
        if (peerType == "channel") {
            let channel = InputPeerChannel()
            channel.channelId = userId
            channel.accessHash = accessHash
            peer = channel
        } else if (peerType == "chat") {
            let chat = InputPeerChat()
            chat.chatId = userId
            peer = chat
        } else {
            let user = InputPeerUser()
            user.userId = userId
            user.accessHash = accessHash
            peer = user
        }

        let location = InputPeerPhotoFileLocation()
        location.big = big
        location.peer = peer
        location.photoId = photoId

        // 主 DC 走下载专用客户端；跨 DC 仍走 per-DC 客户端（导出授权路径）。
        let client = if (Int64(dcId) == getMainClientDcId()) {
            getDownloadMTProtoClient()
        } else {
            getClientForDC(Int64(dcId))
        }

        let req = UploadGetFile()
        req.precise = true
        req.location = location
        req.offset = 0
        req.limit = 1048576

        let responseData = client.sendMediaRequest(
            req.toBytes(),
            TransportUsageCategory.Image,
            MediaUsageContentType.Image
        )
        if (responseData.size < 8) {
            return Array<Byte>(0, repeat: 0)
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == 0x096a18d5) {
            let _ = d.readUInt32()
            let _ = d.readInt32()
            let photoBytes = d.readBytes()
            let result = Array<Byte>(photoBytes.size, repeat: 0)
            for (i in 0..photoBytes.size) {
                result[i] = photoBytes[i]
            }
            if (result.size > 0) {
                synchronized(cacheMon) {
                    downloadCache[cacheKey] = result
                }
            }
            return result
        }

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[FileDownload] Avatar RPC Error: ${errorCode} - ${errorMessage}")
        }
        if (big) {
            Hilog.info(0, "CjTelegram", "[FileDownload] Big avatar unavailable (constructor=${constructor}), falling back to standard avatar")
            return this.downloadUserPhoto(
                userId,
                accessHash,
                photoId,
                dcId,
                big: false,
                peerType: peerType
            )
        }
        return Array<Byte>(0, repeat: 0)
    }

    // ================================================================
    // Cancel / Pause API
    // ================================================================

    /**
     * Demote still-queued background prefetch in [minPriority, maxPriority] to `priority`
     * (see PriorityDownloadQueue.demoteQueued). Interactive priorities are never touched.
     */
    public func demoteQueuedPrefetch(minPriority: Int32, maxPriority: Int32, priority: Int32): Int64 {
        let upper = if (maxPriority >= DOWNLOAD_INTERACTIVE_PRIORITY) {
            DOWNLOAD_INTERACTIVE_PRIORITY - 1
        } else {
            maxPriority
        }
        let demoted = downloadQueue.demoteQueued(minPriority, upper, priority)
        if (demoted > 0) {
            Hilog.info(0, "CjTelegram",
                "[FileDownload] demoted ${demoted} queued prefetch (prio ${minPriority}..${upper}) to ${priority}")
        }
        return demoted
    }

    /**
     * Cancel a running download. Waits for the task to actually stop.
     * After cancel, the .resume file and .part file are deleted.
     */
    public func cancelDownload(fileId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[FileDownload] cancelDownload: fileId=${fileId}")
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                activeTasks[fileId].setStatus(DownloadStatus.CANCELLED)
            }
        }
        // Wait for task to exit running state
        var task: Option<DownloadTask> = None
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                task = Some(activeTasks[fileId])
            }
        }
        match (task) {
            case Some(t) => t.waitUntilNotRunning()
            case None => ()
        }
        // Clean up
        deleteResumeFile(fileId)
        deletePartFile(fileId)
    }

    /**
     * Pause a running download. The .resume and .part files are preserved
     * so the download can be resumed later.
     */
    public func pauseDownload(fileId: Int64): Unit {
        Hilog.info(0, "CjTelegram", "[FileDownload] pauseDownload: fileId=${fileId}")
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                activeTasks[fileId].setStatus(DownloadStatus.PAUSED)
            }
        }
    }

    /**
     * Resume a previously paused download.
     */
    public func resumeDownload(
        fileId: Int64,
        accessHash: Int64,
        fileReference: Array<Byte>,
        dcId: Int32,
        fileSize!: Int64 = 0
    ): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[FileDownload] resumeDownload: fileId=${fileId}")
        return this.downloadDocument(fileId, accessHash, fileReference, dcId, fileSize: fileSize, priority: 20)
    }

    // ================================================================
    // CDN download path
    // ================================================================

    /**
     * Download a file from a Telegram CDN DC.
     *
     * Called when upload.getFile returns upload.fileCdnRedirect.
     * Performs:
     *   1. upload.getCdnFile (repeated per 512 KB chunk)
     *   2. AES-256-CTR decryption of each chunk (key + iv from redirect)
     *   3. upload.getCdnFileHashes to verify per-part SHA256
     *   4. upload.reuploadCdnFile for segments reported missing by CDN
     *
     * CDN DC auth (RSA public-key encrypted file token) requires the
     * CDN RSA public key obtained from a prior auth handshake with the
     * CDN DC. This dependency is expressed as emitted_integration_contracts
     * (ic_cdn_dc_auth) and is NOT stubbed here: if cdnAuthKey is empty,
     * we fall back to master DC download and log a structured warning.
     */
    public func downloadFromCDN(
        masterDcId: Int64,
        cdnDcId: Int32,
        fileToken: Array<Byte>,
        encryptionKey: Array<Byte>,     // 32-byte AES-256 key from fileCdnRedirect
        encryptionIv: Array<Byte>,      // 16-byte IV from fileCdnRedirect
        fileId: Int64,
        fileSize!: Int64 = 0,
        priority!: Int32 = 10,
        cdnAuthKeyAvailable!: Bool = false
    ): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[FileDownload] downloadFromCDN: cdnDc=${cdnDcId}, fileId=${fileId}, cdnAuth=${cdnAuthKeyAvailable}")

        if (!cdnAuthKeyAvailable) {
            // CDN DC RSA auth not yet available: fall back to master DC.
            // The integration contract ic_cdn_dc_auth (emitted in emitted_integration_contracts)
            // must be resolved before CDN auth can work.
            Hilog.info(0, "CjTelegram", "[FileDownload] CDN auth unavailable (ic_cdn_dc_auth pending), falling back to master DC ${masterDcId}")
            return Array<Byte>(0, repeat: 0)
        }

        if (encryptionKey.size != 32 || encryptionIv.size != 16) {
            Hilog.info(0, "CjTelegram", "[FileDownload] CDN: invalid key/iv size, key=${encryptionKey.size} iv=${encryptionIv.size}")
            return Array<Byte>(0, repeat: 0)
        }

        // Fetch hash cluster from master DC (getCdnFileHashes verifies integrity)
        let masterClient = getClientForDC(masterDcId)
        let partHashes = this.fetchCdnPartHashes(masterClient, fileToken)

        // Download chunks from CDN DC
        let cdnClient = getClientForDC(Int64(cdnDcId))
        let task = DownloadTask(fileId, priority)
        task.setStatus(DownloadStatus.RUNNING)
        synchronized(taskMon) {
            activeTasks[fileId] = task
        }

        let completedOffsets = loadCompletedOffsets(fileId)
        var startOffset: Int64 = 0
        if (completedOffsets.size > 0) {
            // Find maximum acknowledged offset to resume from
            var maxOff: Int64 = 0
            for (off in completedOffsets) {
                if (off > maxOff) { maxOff = off }
            }
            startOffset = maxOff + Int64(CHUNK_SIZE_BYTES)
            Hilog.info(0, "CjTelegram", "[FileDownload] CDN resume from offset ${startOffset}")
        }

        var offset: Int64 = startOffset
        var done = false
        var cdnCompleteSize: Int64 = -1

        while (!done) {
            let status = task.getStatus()
            if (status == DownloadStatus.CANCELLED) {
                Hilog.info(0, "CjTelegram", "[FileDownload] CDN download cancelled at offset ${offset}")
                break
            }
            if (status == DownloadStatus.PAUSED) {
                Hilog.info(0, "CjTelegram", "[FileDownload] CDN download paused at offset ${offset}")
                break
            }

            let chunkResult = this.fetchCdnChunk(cdnClient, fileToken, offset, Int64(CHUNK_SIZE_BYTES))
            if (!chunkResult.error.isEmpty()) {
                Hilog.info(0, "CjTelegram", "[FileDownload] CDN chunk error at offset ${offset}: ${chunkResult.error}")
                break
            }

            if (chunkResult.isNotModified && chunkResult.reuploadToken.size > 0) {
                // CDN reports missing segment: request master DC to re-upload
                Hilog.info(0, "CjTelegram", "[FileDownload] CDN reupload needed at offset ${offset}")
                let reuploadOk = this.reuploadCdnChunk(masterClient, fileToken, chunkResult.reuploadToken)
                if (!reuploadOk) {
                    Hilog.info(0, "CjTelegram", "[FileDownload] CDN reupload failed, aborting")
                    break
                }
                // Retry same offset after reupload
                continue
            }

            let rawChunk = chunkResult.data
            if (rawChunk.size == 0) {
                cdnCompleteSize = offset
                done = true
                break
            }

            // Decrypt with AES-256-CTR
            let decrypted = cdnDecryptChunk(rawChunk, encryptionKey, encryptionIv, offset)

            // Verify hash — abort on mismatch to prevent writing corrupted data
            let hashOk = this.verifyCdnPartHash(partHashes, offset, decrypted)
            if (!hashOk) {
                Hilog.info(0, "CjTelegram", "[FileDownload] CDN download aborted due to hash mismatch at offset ${offset}")
                break
            }

            // Write to part file
            let wrote = writeChunkAt(fileId, offset, decrypted)
            if (wrote) {
                completedOffsets.add(offset)
                saveCompletedOffsets(fileId, completedOffsets)
            }
            task.addBytes(Int64(decrypted.size))

            if (!wrote) {
                break
            }
            if (rawChunk.size < Int64(CHUNK_SIZE_BYTES)) {
                cdnCompleteSize = offset + Int64(decrypted.size)
                done = true
            } else {
                offset += Int64(CHUNK_SIZE_BYTES)
            }
        }

        let result = if (done) {
            finalizePartFile(fileId, fileSize, cdnCompleteSize)
        } else {
            Array<Byte>(0, repeat: 0)
        }
        if (result.size > 0) {
            deleteResumeFile(fileId)
            task.setStatus(DownloadStatus.COMPLETED)
            synchronized(cacheMon) {
                downloadCache[fileId] = result
            }
        } else {
            task.setStatus(DownloadStatus.FAILED)
        }

        synchronized(taskMon) {
            let _ = activeTasks.remove(fileId)
        }
        return result
    }

    // ================================================================
    // Misc public API
    // ================================================================

    public func clearCache(): Unit {
        synchronized(cacheMon) {
            downloadCache = HashMap<Int64, Array<Byte>>()
        }
    }

    public func getTaskStatus(fileId: Int64): Int32 {
        synchronized(taskMon) {
            if (activeTasks.contains(fileId)) {
                return activeTasks[fileId].getStatus()
            }
        }
        return DownloadStatus.COMPLETED
    }

    // ================================================================
    // P2-321: shouldAutoDownload — network-aware auto-download gate
    // ================================================================

    /**
     * Determines whether a media item should be automatically downloaded,
     * mirroring iOS shouldDownloadMediaAutomatically() in MediaAutoDownloadSettings.swift.
     *
     * Decision tree (in order):
     *   1. dataSaving mode → false (global veto)
     *   2. networkStatus == NetUnavailable → false (no connection)
     *   3. cellular/wifi global enabled check (per current networkStatus)
     *   4. media-type toggle (autoPhotos / autoVideos / autoFiles)
     *   5. size threshold check (video and file types only; photos always pass if toggle is on)
     *
     * @param mediaType     "photo" | "video" | "document" | "sticker" | "voice" | "gif"
     * @param fileSizeBytes actual file size in bytes; pass 0 if unknown (treated as "pass")
     * @param networkStatus current network status from ReachabilityService.currentStatus()
     * @return true if auto-download should proceed
     */
    public func shouldAutoDownload(mediaType: String, fileSizeBytes: Int64, networkStatus: NetworkStatus,
        peerKind!: String = ""): Bool {
        // Step 1: Check basic media-type toggle + dataSaving via existing DownloadPolicy.
        // canAutoDownload handles: dataSaving veto + per-type on/off toggle.
        if (!canAutoDownload(mediaType)) {
            Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=${mediaType}: false (canAutoDownload=false)")
            return false
        }

        // Step 2: No network
        match (networkStatus) {
            case NetUnavailable =>
                Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=${mediaType}: false (no network)")
                return false
            case _ => ()
        }

        // Step 3: Per-network-type enabled check using P2-321 network settings store.
        let netSettings = getNetworkSettingsSingleton()
        let onCellular: Bool = match (networkStatus) {
            case NetCellular => true
            case _ => false
        }
        let onWifi: Bool = match (networkStatus) {
            case NetWifi => true
            case _ => false
        }
        if (onCellular && !netSettings.cellular.enabled) {
            Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=${mediaType}: false (cellular disabled)")
            return false
        }
        if (onWifi && !netSettings.wifi.enabled) {
            Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=${mediaType}: false (wifi disabled)")
            return false
        }

        // Step 3b (S7-93): per-network, per-category peer toggles. iOS
        // shouldDownloadMediaAutomatically (MediaAutoDownloadSettings.swift:567-600): stickers
        // always pass; otherwise the category chosen by categoryAndSizeForMedia (photo → photo,
        // video/gif → video, document → file) from effectiveAutodownloadCategories(networkType)
        // must be enabled for the chat's peer type (isAutodownloadEnabledForPeerType :550-561);
        // voice skips the peer check. `peerKind` is "contact" | "otherPrivate" | "group" |
        // "channel"; empty means the caller has no chat context → any peer type enabled.
        if (mediaType != "sticker" && mediaType != "voice") {
            let peerCats: MediaAutoDownloadCategories = if (onCellular) {
                effectiveCategories(netSettings.cellular)
            } else {
                effectiveCategories(netSettings.wifi)
            }
            let category: MediaAutoDownloadCategory = match (mediaType) {
                case "photo" => peerCats.photo
                case "video" | "gif" => peerCats.video
                case _ => peerCats.file
            }
            let peerEnabled: Bool = match (peerKind) {
                case "contact" => category.contacts
                case "otherPrivate" => category.otherPrivate
                case "group" => category.groups
                case "channel" => category.channels
                case _ => category.contacts || category.otherPrivate || category.groups || category.channels
            }
            if (!peerEnabled) {
                Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=${mediaType}: false (peer '${peerKind}' disabled for category, cellular=${onCellular})")
                return false
            }
        }

        // Step 4: Size-threshold check (videos/gifs and documents only; photos/stickers/voice skip).
        // GIFs follow the video size limit (iOS parity: animated media shares the video threshold).
        if (fileSizeBytes > 0) {
            let cats: MediaAutoDownloadCategories = if (onCellular) {
                effectiveCategories(netSettings.cellular)
            } else {
                effectiveCategories(netSettings.wifi)
            }
            match (mediaType) {
                case "video" | "gif" =>
                    let limit: Int64 = cats.video.sizeLimit
                    if (limit > 0 && fileSizeBytes > limit) {
                        Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=${mediaType}: false (size ${fileSizeBytes} > limit ${limit})")
                        return false
                    }
                case "document" =>
                    let limit: Int64 = cats.file.sizeLimit
                    if (limit > 0 && fileSizeBytes > limit) {
                        Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=document: false (size ${fileSizeBytes} > limit ${limit})")
                        return false
                    }
                case _ => ()
            }
        }

        Hilog.info(0, "CjTelegram", "[FileDownload] shouldAutoDownload=${mediaType}: true (size=${fileSizeBytes}, cellular=${onCellular}, wifi=${onWifi})")
        return true
    }

    // ================================================================
    // TC-0427 FIX-2: Network settings getters/setters (called by
    // DataStorageSettingsPage / AutodownloadConnectionTypePage /
    // AutodownloadMediaCategoryPage). Every mutator here matches a source write
    // path (AutodownloadConnectionTypeController.swift toggleMaster/changePreset,
    // AutodownloadMediaCategoryController.swift togglePeer/adjustSize/
    // toggleVideoPreload) — each mutates the in-memory singleton in place (its
    // fields are class-typed, so this mutates the same instance every reader
    // sees) and persists synchronously, mirroring this file's pre-existing
    // save-then-flush convention for every other setter.
    // ================================================================

    public func getAutoDownloadNetworkSettings(): AutoDownloadNetworkSettings {
        return getNetworkSettingsSingleton()
    }

    // Source: toggleMaster — connection.enabled = value.
    public func setConnectionEnabled(kind: AutoDownloadConnectionKind, enabled: Bool): Unit {
        let s = getNetworkSettingsSingleton()
        let conn = connectionFor(s, kind)
        conn.enabled = enabled
        persistConnection(kind, conn)
        Hilog.info(0, "CjTelegram", "[FileDownload] ${connectionKeyPrefix(kind)}.enabled=${enabled}")
    }

    // Source: changePreset — connection.preset = preset (custom cleared; picking a
    // named preset off the DATA USAGE control always means "no more per-category
    // overrides").
    public func setConnectionPreset(kind: AutoDownloadConnectionKind, preset: AutoDownloadPresetKind): Unit {
        let s = getNetworkSettingsSingleton()
        let conn = connectionFor(s, kind)
        conn.preset = preset
        conn.custom = None
        persistConnection(kind, conn)
        Hilog.info(0, "CjTelegram", "[FileDownload] ${connectionKeyPrefix(kind)}.preset=${presetToInt(preset)}")
    }

    // Source: togglePeer — any peer-type edit unconditionally forces
    // preset=.custom + custom=categories (source AutodownloadMediaCategoryController
    // .swift :370-377/:394-401/:418-425, all three mutators share this shape).
    public func setCategoryPeer(kind: AutoDownloadConnectionKind, category: AutoDownloadCategoryKind, peer: AutoDownloadPeerKind, value: Bool): Unit {
        let s = getNetworkSettingsSingleton()
        let conn = connectionFor(s, kind)
        let cats = effectiveCategories(conn).clone()
        let target = cats.categoryFor(category)
        match (peer) {
            case PeerContacts => target.contacts = value
            case PeerOtherPrivate => target.otherPrivate = value
            case PeerGroups => target.groups = value
            case PeerChannels => target.channels = value
        }
        conn.preset = AutoDownloadPresetKind.PresetCustom
        conn.custom = Some(cats)
        persistConnection(kind, conn)
        Hilog.info(0, "CjTelegram", "[FileDownload] ${connectionKeyPrefix(kind)}.${categoryKeyPart(category)} peer updated -> custom")
    }

    // Source: adjustSize.
    public func setCategorySizeLimit(kind: AutoDownloadConnectionKind, category: AutoDownloadCategoryKind, bytes: Int64): Unit {
        let s = getNetworkSettingsSingleton()
        let conn = connectionFor(s, kind)
        let cats = effectiveCategories(conn).clone()
        cats.categoryFor(category).sizeLimit = bytes
        conn.preset = AutoDownloadPresetKind.PresetCustom
        conn.custom = Some(cats)
        persistConnection(kind, conn)
        Hilog.info(0, "CjTelegram", "[FileDownload] ${connectionKeyPrefix(kind)}.${categoryKeyPart(category)}.sizeLimit=${bytes} -> custom")
    }

    // Source: toggleVideoPreload. Only ever called for .video by the category page
    // (source only surfaces the control there), but takes `category` generically —
    // matches the source mutator's own shape (it also switches on `category`).
    public func setCategoryPredownload(kind: AutoDownloadConnectionKind, category: AutoDownloadCategoryKind, value: Bool): Unit {
        let s = getNetworkSettingsSingleton()
        let conn = connectionFor(s, kind)
        let cats = effectiveCategories(conn).clone()
        cats.categoryFor(category).predownload = value
        conn.preset = AutoDownloadPresetKind.PresetCustom
        conn.custom = Some(cats)
        persistConnection(kind, conn)
        Hilog.info(0, "CjTelegram", "[FileDownload] ${connectionKeyPrefix(kind)}.${categoryKeyPart(category)}.predownload=${value} -> custom")
    }

    // Used by DataStorageSettingsPage's "Reset Auto-Download Settings" row
    // (TC-0420 R37 gate stays at the page call site; this only supplies the
    // now-corrected default values it resets into).
    public func resetAutoDownloadToDefaults(): Unit {
        let fresh = AutoDownloadNetworkSettings()
        persistConnection(AutoDownloadConnectionKind.ConnCellular, fresh.cellular)
        persistConnection(AutoDownloadConnectionKind.ConnWifi, fresh.wifi)
        synchronized(_networkSettingsMon) {
            _networkSettings = Some(fresh)
        }
        Hilog.info(0, "CjTelegram", "[FileDownload] auto-download network settings reset to defaults")
    }

    /**
     * 查询资源已下载的字节范围状态（对应 iOS TelegramEngine.Resources.resourceRangesStatus(resource:)）
     *
     * 从磁盘 .resume 文件读取已确认完成的块偏移列表，转换为 [(start, end)] 区间列表。
     * 每个区间为 [offset, offset+CHUNK_SIZE_BYTES)，对应 iOS RangeSet<Int64>。
     *
     * Signal-async deferred：iOS 返回 Signal<RangeSet<Int64>>；Cangjie 无 Signal/RangeSet，
     * 改为同步返回 ArrayList<(Int64, Int64)>（start inclusive, end exclusive）。
     * 调用方如需响应式，在 spawn{} 调用后通过 spawn(UIThread) 更新 @State。
     *
     * @param fileId  媒体文件 ID（TL file_id）
     * @return 已下载字节范围列表 [(start, end)]（end = start + CHUNK_SIZE_BYTES 或文件末尾）
     */
    public func resourceRangesStatus(fileId: Int64): ArrayList<(Int64, Int64)> {
        let result = ArrayList<(Int64, Int64)>()
        let completed = loadCompletedOffsets(fileId)
        for (off in completed) {
            result.add((off, off + Int64(CHUNK_SIZE_BYTES)))
        }
        return result
    }

    /**
     * 取消所有活跃下载任务（对应 iOS TelegramEngine.Resources.cancelAllFetches(id:)，批量版本）
     *
     * 从 activeTasks 注册表中取出全部 fileId，逐个调用 cancelDownload()。
     * cancelDownload() 会等待任务真正停止、删除 .resume 和 .part 文件。
     */
    public func cancelAllActiveDownloads(): Unit {
        let fileIds = ArrayList<Int64>()
        synchronized(taskMon) {
            for ((fid, _) in activeTasks) {
                fileIds.add(fid)
            }
        }
        for (fid in fileIds) {
            this.cancelDownload(fid)
            Hilog.info(0, "CjTelegram", "[FileDownload] cancelAllActiveDownloads: cancelled ${fid}")
        }
        Hilog.info(0, "CjTelegram", "[FileDownload] cancelAllActiveDownloads: total=${fileIds.size}")
    }

    // ================================================================
    // PRIVATE: parallel chunked download (Gap 1 + 2 + 3 + 4)
    // ================================================================

    private func runParallelChunkedDownload(
        task: DownloadTask,
        fileId: Int64,
        location: TLObject,
        dcId: Int64,
        fileSize: Int64,
        statsCategory: TransportUsageCategory,
        contentType: MediaUsageContentType
    ): Array<Byte> {
        // Determine how many total chunks we expect
        let totalChunks: Int64 = if (fileSize > 0) {
            (fileSize + Int64(CHUNK_SIZE_BYTES) - 1) / Int64(CHUNK_SIZE_BYTES)
        } else {
            Int64(-1)  // unknown: download until server returns empty
        }

        // Restore completed offsets from prior run (resume)
        let state = ChunkDownloadState()
        state.migrateDc = dcId
        var prior = loadCompletedOffsets(fileId)
        if (prior.size > 0 && localFileSize(partFilePath(fileId)) <= 0) {
            // Resume state without its temp file: nothing to resume into.
            deleteResumeFile(fileId)
            prior = ArrayList<Int64>()
        }
        if (prior.size == 0) {
            // Fresh fetch: start from an empty temp file so no stale bytes survive
            // past the resource end (the part file is opened without truncation).
            deletePartFile(fileId)
        }
        for (off in prior) {
            state.completedOffsets.add(off)
            state.completedSet[off] = true
        }

        // Find first uncompleted offset
        var startOffset: Int64 = 0
        var allKnownDone = false
        if (prior.size > 0 && totalChunks > 0) {
            var searchOff: Int64 = 0
            var found = false
            while (!found && (totalChunks < 0 || searchOff < totalChunks * Int64(CHUNK_SIZE_BYTES))) {
                if (!state.completedSet.contains(searchOff)) {
                    startOffset = searchOff
                    found = true
                } else {
                    searchOff += Int64(CHUNK_SIZE_BYTES)
                }
            }
            if (!found) {
                allKnownDone = true
            }
        }
        state.nextOffset = startOffset
        if (totalChunks > 0) {
            state.limitOffsetExclusive = totalChunks * Int64(CHUNK_SIZE_BYTES)
        }

        if (allKnownDone) {
            let existing = finalizePartFile(fileId, fileSize, -1)
            deleteResumeFile(fileId)
            if (existing.size > 0) {
                task.setStatus(DownloadStatus.COMPLETED)
                return existing
            }
            // Every part was recorded but the temp file does not add up: refetch from scratch.
            deletePartFile(fileId)
            state.completedOffsets.clear()
            state.completedSet.clear()
            state.nextOffset = 0
        }

        Hilog.info(0, "CjTelegram", "[FileDownload] Starting parallel download fileId=${fileId}, resumeFrom=${startOffset}, completed=${prior.size} chunks")

        // A known small Telegram sticker is usually < 512 KB and needs exactly
        // one upload.getFile request. The old fixed four-worker fan-out wasted
        // three RPCs at offsets beyond EOF and occupied every global slot.
        var workerCount: Int64 = 1
        if (totalChunks > 0) {
            var remainingChunks = totalChunks - prior.size
            if (remainingChunks < 1) { remainingChunks = 1 }
            workerCount = if (remainingChunks < MAX_CHUNKS_PER_RESOURCE) {
                remainingChunks
            } else {
                MAX_CHUNKS_PER_RESOURCE
            }
        }
        Hilog.info(0, "CjTelegram",
            "[FileDownloadPerf] workers fileId=${fileId} count=${workerCount} totalChunks=${totalChunks}")

        // Spawn a bounded per-resource worker set, passing state as an immutable reference.
        let sharedState = state
        let sharedTask = task
        let sharedLocation = location
        let sharedSlotMgr = slotManager
        let sharedFileId = fileId
        let sharedFileSize = fileSize
        let sharedStatsCategory = statsCategory
        let sharedContentType = contentType

        var futures: ArrayList<Future<Unit>> = ArrayList<Future<Unit>>()
        var slotIdx: Int64 = 0
        while (slotIdx < workerCount) {
            let fut = spawn {
                =>
                while (true) {
                    // Check cancel / pause before each chunk
                    let taskStatus = sharedTask.getStatus()
                    if (taskStatus == DownloadStatus.CANCELLED || taskStatus == DownloadStatus.PAUSED) {
                        break
                    }

                    // Claim next offset; returns -1 if stopped
                    let myOffset = sharedState.claimOffset()
                    if (myOffset < 0) {
                        break
                    }

                    // Read current DC (thread-safe via ChunkDownloadState.getCurrentDc)
                    let currentDc = sharedState.getCurrentDc()
                    // 双连接：主 DC 分片走下载专用客户端（独立 TCP+会话），
                    // RPC 不再被分片响应队头阻塞；跨 DC 保持 per-DC 客户端。
                    // 先拿客户端再占分片槽：跨 DC 首次建连/导出授权可能耗时数秒，
                    // 不能在这期间占着全局分片槽让可见媒体排队。
                    let activeClient = if (currentDc == getMainClientDcId()) {
                        getDownloadMTProtoClient()
                    } else {
                        getClientForDC(currentDc)
                    }

                    // Acquire concurrency slot (blocks if all occupied). Interactive
                    // resources (priority read per chunk: it may be raised mid-download)
                    // can use the reserved slots background chunks never take.
                    sharedSlotMgr.acquire(
                        interactive: sharedTask.priority >= DOWNLOAD_INTERACTIVE_PRIORITY)

                    // Build and send upload.getFile request
                    let req = UploadGetFile()
                    req.precise = true
                    req.location = sharedLocation
                    req.offset = myOffset
                    req.limit = CHUNK_SIZE_BYTES
                    req.cdnSupported = true

                    var responseData = Array<Byte>(0, repeat: 0)
                    try {
                        responseData = activeClient.sendMediaRequest(
                            req.toBytes(),
                            sharedStatsCategory,
                            sharedContentType
                        )
                    } catch (e: Exception) {
                        sharedSlotMgr.release()
                        Hilog.info(0, "CjTelegram",
                            "[FileDownload] transport failed fileId=${sharedFileId} offset=${myOffset}: ${e}")
                        sharedState.markError()
                        break
                    }
                    sharedSlotMgr.release()

                    if (responseData.size < 8) {
                        // No response (timeout / transport loss) is a failed part, not end of file:
                        // the file end is only known from a short upload.file part.
                        Hilog.info(0, "CjTelegram", "[FileDownload] Empty response at offset ${myOffset}")
                        sharedState.markError()
                        break
                    }

                    let d = TLDeserializer(responseData)
                    let constructor = d.readUInt32()

                    if (constructor == 0x096a18d5) {
                        // upload.file
                        let _ = d.readUInt32()   // storage.FileType
                        let _ = d.readInt32()    // mtime
                        let chunkBytes = d.readBytes()

                        // A precise upload.getFile part is exactly `limit` bytes except the last one,
                        // which ends the resource (iOS MultipartFetch: completeSize = offset + data.count).
                        // With the document size known the part length is fully determined; a part of
                        // any other length is not the answer to this request and is never written.
                        let expectedPartSize: Int64 = if (sharedFileSize > 0) {
                            let left = sharedFileSize - myOffset
                            if (left < Int64(CHUNK_SIZE_BYTES)) { left } else { Int64(CHUNK_SIZE_BYTES) }
                        } else {
                            -1
                        }
                        if (chunkBytes.size > Int64(CHUNK_SIZE_BYTES) ||
                            (expectedPartSize >= 0 && chunkBytes.size != expectedPartSize)) {
                            Hilog.info(0, "CjTelegram",
                                "[FileDownload] part size mismatch fileId=${sharedFileId} offset=${myOffset}: got ${chunkBytes.size}, expected ${expectedPartSize}")
                            sharedState.markError()
                            break
                        }
                        if (chunkBytes.size > 0) {
                            // Each part is written exactly once, at its own offset.
                            let writeOk = sharedState.isChunkWritten(myOffset) ||
                                writeChunkAt(sharedFileId, myOffset, chunkBytes)
                            if (writeOk) {
                                let isLastChunk = chunkBytes.size < Int64(CHUNK_SIZE_BYTES) ||
                                    (sharedFileSize > 0 && myOffset + chunkBytes.size >= sharedFileSize)
                                sharedTask.addBytes(Int64(chunkBytes.size))
                                sharedState.markChunkWritten(myOffset, Int64(chunkBytes.size), isLastChunk, sharedFileId)
                                if (isLastChunk) {
                                    break
                                }
                            } else {
                                sharedState.markError()
                                break
                            }
                        } else {
                            sharedState.markEndAt(myOffset)
                            break
                        }

                    } else if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
                        let errorCode = d.readInt32()
                        let errorMessage = d.readString()
                        Hilog.info(0, "CjTelegram", "[FileDownload] RPC Error at offset ${myOffset}: ${errorCode} ${errorMessage}")

                        if (errorMessage.contains("_MIGRATE_")) {
                            let newDc = parseMigrateTargetDc(errorMessage)
                            if (newDc > 0) {
                                Hilog.info(0, "CjTelegram", "[FileDownload] FILE_MIGRATE to DC${newDc}")
                                sharedState.recvMigrateError(myOffset, newDc)
                                let _ = getClientForDC(newDc)
                                continue
                            }
                        }
                        sharedState.markError()
                        break

                    } else if (constructor == 0xf18cda44) {
                        // upload.fileCdnRedirect#f18cda44 dc_id:int file_token:bytes
                        //   encryption_key:bytes encryption_iv:bytes file_hashes:Vector<FileHash>
                        // Read all four fields before handing off to downloadFromCDN.
                        let cdnDcIdParsed = d.readInt32()                 // dc_id:int
                        let cdnFileTokenParsed = d.readBytes()            // file_token:bytes
                        let cdnEncKeyParsed = d.readBytes()               // encryption_key:bytes (32 B AES-256)
                        let cdnEncIvParsed = d.readBytes()                // encryption_iv:bytes (16 B)
                        // file_hashes:Vector<FileHash> — skip: read vector header + all fileHash entries
                        // fileHash#f39b035c offset:long limit:int hash:bytes
                        let vecCtor = d.readUInt32()                      // 0x1cb5c415 vector tag
                        if (vecCtor == TLConstructors.VECTOR) {
                            let hashCount = d.readInt32()
                            var hIdx: Int32 = 0
                            while (hIdx < hashCount) {
                                let _ = d.readUInt32()   // fileHash constructor
                                let _ = d.readInt64()    // offset:long
                                let _ = d.readInt32()    // limit:int
                                let _ = d.readBytes()    // hash:bytes
                                hIdx += 1
                            }
                        }
                        // Copy parsed bytes into local arrays (defensive copy from deserializer slice)
                        let tokenCopy = Array<Byte>(cdnFileTokenParsed.size, repeat: 0)
                        for (i in 0..cdnFileTokenParsed.size) { tokenCopy[i] = cdnFileTokenParsed[i] }
                        let keyCopy = Array<Byte>(cdnEncKeyParsed.size, repeat: 0)
                        for (i in 0..cdnEncKeyParsed.size) { keyCopy[i] = cdnEncKeyParsed[i] }
                        let ivCopy = Array<Byte>(cdnEncIvParsed.size, repeat: 0)
                        for (i in 0..cdnEncIvParsed.size) { ivCopy[i] = cdnEncIvParsed[i] }
                        Hilog.info(0, "CjTelegram", "[FileDownload] CDN redirect: dcId=${cdnDcIdParsed}, tokenLen=${tokenCopy.size}, keyLen=${keyCopy.size}, ivLen=${ivCopy.size}")
                        sharedState.storeCdnRedirectAndMark(cdnDcIdParsed, tokenCopy, keyCopy, ivCopy)
                        break

                    } else {
                        Hilog.info(0, "CjTelegram", "[FileDownload] Unknown constructor 0x${constructor} at offset ${myOffset}")
                        sharedState.markError()
                        break
                    }
                }
            }
            futures.add(fut)
            slotIdx += 1
        }

        // Wait for all workers to finish
        for (fut in futures) {
            fut.get()
        }

        // ── CDN redirect path ──────────────────────────────────────────────
        // If any worker received upload.fileCdnRedirect, route to downloadFromCDN.
        // Read CDN params under chunkMon to avoid data races.
        var gotCdnRedirect: Bool = false
        var savedCdnDcId: Int32 = 0
        var savedCdnFileToken: Array<Byte> = Array<Byte>(0, repeat: 0)
        var savedCdnEncKey: Array<Byte> = Array<Byte>(0, repeat: 0)
        var savedCdnEncIv: Array<Byte> = Array<Byte>(0, repeat: 0)
        synchronized(sharedState.chunkMon) {
            gotCdnRedirect = sharedState.cdnRedirect
            savedCdnDcId = sharedState.cdnDcId
            savedCdnFileToken = sharedState.cdnFileToken
            savedCdnEncKey = sharedState.cdnEncKey
            savedCdnEncIv = sharedState.cdnEncIv
        }
        if (gotCdnRedirect) {
            Hilog.info(0, "CjTelegram", "[FileDownload] Routing fileId=${fileId} to CDN DC ${savedCdnDcId}")
            return this.downloadFromCDN(
                dcId,
                savedCdnDcId,
                savedCdnFileToken,
                savedCdnEncKey,
                savedCdnEncIv,
                fileId,
                fileSize: fileSize,
                priority: task.priority,
                cdnAuthKeyAvailable: false
            )
        }
        // ── end CDN redirect path ──────────────────────────────────────────

        // Assemble result
        let taskStatus = task.getStatus()
        if (taskStatus == DownloadStatus.CANCELLED) {
            deleteResumeFile(fileId)
            deletePartFile(fileId)
            task.setStatus(DownloadStatus.CANCELLED)
            return Array<Byte>(0, repeat: 0)
        }

        var hadError = false
        var learnedSize: Int64 = -1
        synchronized(sharedState.chunkMon) {
            hadError = sharedState.hasError
            learnedSize = sharedState.completeSize
        }
        if (taskStatus == DownloadStatus.PAUSED) {
            // A paused fetch is not a resource: never hand partial bytes to the caller.
            Hilog.info(0, "CjTelegram", "[FileDownload] Download paused, state preserved for fileId=${fileId}")
            return Array<Byte>(0, repeat: 0)
        }
        if (!hadError) {
            let result = finalizePartFile(fileId, fileSize, learnedSize)
            if (result.size > 0) {
                deleteResumeFile(fileId)
                task.setStatus(DownloadStatus.COMPLETED)
                return result
            }
        }
        task.setStatus(DownloadStatus.FAILED)
        Hilog.info(0, "CjTelegram",
            "[FileDownload] incomplete resource retained for resume fileId=${fileId} expected=${fileSize} learned=${learnedSize} error=${hadError}")
        return Array<Byte>(0, repeat: 0)
    }

    // ================================================================
    // PRIVATE: CDN helpers
    // ================================================================

    // Fetch part hashes from master DC (upload.getCdnFileHashes).
    // Returns map: offset -> SHA256 hash bytes.
    private func fetchCdnPartHashes(masterClient: MTProtoClient, fileToken: Array<Byte>): HashMap<Int64, Array<Byte>> {
        let result = HashMap<Int64, Array<Byte>>()
        let req = UploadGetCdnFileHashes()
        req.fileToken = fileToken
        req.offset = 0
        let responseData = masterClient.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return result
        }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        // Vector of fileHash#f39b035c (offset:long limit:int hash:bytes)
        // schema Layer 214: fileHash#f39b035c offset:long limit:int hash:bytes = FileHash
        if (constructor == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                let hashCtor = d.readUInt32()
                if (hashCtor == 0xf39b035c) {
                    let offset = d.readInt64()  // schema: offset:long (not int)
                    let _ = d.readInt32()        // limit:int
                    let hash = d.readBytes()
                    result[offset] = hash
                }
                i += 1
            }
        }
        return result
    }

    // Verify a decrypted CDN chunk against stored hash (SHA256).
    // Returns true if hash matches (or no hash available for this offset).
    // Returns false on mismatch — caller must abort the download (aligns with iOS .fail(.generic)).
    private func verifyCdnPartHash(partHashes: HashMap<Int64, Array<Byte>>, offset: Int64, data: Array<Byte>): Bool {
        if (!partHashes.contains(offset)) {
            return true
        }
        let expectedHash = partHashes[offset]
        let actualHash = SHA256.hash(data)
        if (actualHash.size != expectedHash.size) {
            Hilog.info(0, "CjTelegram", "[FileDownload] CDN hash size mismatch at offset ${offset} — aborting")
            return false
        }
        var hashMatch = true
        var i: Int64 = 0
        while (i < actualHash.size) {
            if (UInt8(actualHash[i]) != UInt8(expectedHash[i])) {
                hashMatch = false
                break
            }
            i += 1
        }
        if (!hashMatch) {
            Hilog.info(0, "CjTelegram", "[FileDownload] CDN hash MISMATCH at offset ${offset} — aborting download to prevent corrupted data")
            return false
        }
        return true
    }

    // Fetch one chunk from CDN DC (upload.getCdnFile).
    private func fetchCdnChunk(cdnClient: MTProtoClient, fileToken: Array<Byte>, offset: Int64, limit: Int64): CdnChunkResult {
        let result = CdnChunkResult()
        let req = UploadGetCdnFile()
        req.fileToken = fileToken
        req.offset = offset
        req.limit = Int32(limit)

        let responseData = cdnClient.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            result.error = "empty response"
            return result
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == 0xa99fca4f) {
            // upload.cdnFile#a99fca4f bytes:bytes
            let fileBytes = d.readBytes()
            let out = Array<Byte>(fileBytes.size, repeat: 0)
            for (i in 0..fileBytes.size) {
                out[i] = fileBytes[i]
            }
            result.data = out
        } else if (constructor == 0xeea8e46e) {
            // upload.cdnFileReuploadNeeded#eea8e46e request_token:bytes
            let requestToken = d.readBytes()
            let tokenBytes = Array<Byte>(requestToken.size, repeat: 0)
            for (i in 0..requestToken.size) {
                tokenBytes[i] = requestToken[i]
            }
            result.isNotModified = true
            result.reuploadToken = tokenBytes
        } else if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let errorCode = d.readInt32()
            let msg = d.readString()
            result.error = "RPC ${errorCode}: ${msg}"
        } else {
            result.error = "unknown ctor 0x${constructor}"
        }
        return result
    }

    // Request master DC to re-upload a missing CDN segment (upload.reuploadCdnFile).
    private func reuploadCdnChunk(masterClient: MTProtoClient, fileToken: Array<Byte>, requestToken: Array<Byte>): Bool {
        let req = UploadReuploadCdnFile()
        req.fileToken = fileToken
        req.requestToken = requestToken
        let responseData = masterClient.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            return false
        }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        // Returns Vector<FileHash> on success
        return (constructor == TLConstructors.VECTOR)
    }

    // ================================================================
    // PRIVATE: helpers
    // ================================================================

    private func photoCacheKey(photoId: Int64, thumbSize: String): Int64 {
        let sizeOffset: Int64 = if (thumbSize == "s" || thumbSize == "m") { 1 }
            else if (thumbSize == "y") { 3 }
            else { 2 }
        return photoId ^ sizeOffset
    }
}

// ---- TL methods for CDN (added here since they are only used in FileDownloadService) ----

/**
 * upload.getCdnFile#395f69da file_token:bytes offset:long limit:int = upload.CdnFile
 * (Layer 214; was 0x2000bcc3 in older layers — corrected via tl_codegen verify)
 */
public class UploadGetCdnFile <: TLObject {
    public var fileToken: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var offset: Int64 = 0     // schema: offset:long
    public var limit: Int32 = 524288 // schema: limit:int

    public func getConstructorId(): UInt32 { return 0x395f69da }

    public func serialize(serializer: TLSerializer) {
        serializer.writeBytes(this.fileToken)
        serializer.writeInt64(this.offset)
        serializer.writeInt32(this.limit)
    }
}

/**
 * upload.getCdnFileHashes#91dc3f31 file_token:bytes offset:long = Vector<FileHash>
 * (Layer 214; was 0x4da54231 in older layers — corrected via tl_codegen verify)
 */
public class UploadGetCdnFileHashes <: TLObject {
    public var fileToken: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var offset: Int64 = 0     // schema: offset:long

    public func getConstructorId(): UInt32 { return 0x91dc3f31 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeBytes(this.fileToken)
        serializer.writeInt64(this.offset)
    }
}

/**
 * upload.reuploadCdnFile#9b2754a8 file_token:bytes request_token:bytes = Vector<FileHash>
 */
public class UploadReuploadCdnFile <: TLObject {
    public var fileToken: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var requestToken: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0x9b2754a8 }

    public func serialize(serializer: TLSerializer) {
        serializer.writeBytes(this.fileToken)
        serializer.writeBytes(this.requestToken)
    }
}

// ---- Helper: parse DC id from MIGRATE error message ----
// e.g. "FILE_MIGRATE_2" -> 2, "NETWORK_MIGRATE_5" -> 5
// Delegates to the existing MTProtoClient.parseTrailingInt to avoid Char indexing.
private func parseMigrateTargetDc(errorMessage: String): Int64 {
    return MTProtoClient.parseTrailingInt(errorMessage, "_MIGRATE_")
}
