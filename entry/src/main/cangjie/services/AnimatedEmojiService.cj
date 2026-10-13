package ohos_app_cangjie_entry.services

import kit.ImageKit.{createPixelMap, InitializationOptions, Size, PixelMap, PixelMapFormat, AlphaType}
import kit.CoreFileKit.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.{ArrayList, HashMap, HashSet}
import std.sort.*
import std.sync.*
import std.time.*
import std.io.ByteBuffer
import stdx.compress.zlib.*
import std.random.Random
import std.convert.*
import ohos_app_cangjie_entry.bindings.{
    getTelegramLottieNative, TelegramLottieFrames, TelegramLottieSession,
    openTelegramVideoSticker, TelegramVideoStickerSession, nativeEncodeDeltaRuns
}

// iOS ChatMessageAnimatedStickerItemNode rasterizes standard animated emoji
// into a 384x384 backing surface, independently of its point-size layout.
// 112px was then stretched over a 112vp box on a high-density device.
private let ANIMATED_EMOJI_SIZE: Int32 = 384
// iOS passes the animation node's 384px backing size to the additional effect
// renderer and multiplies that by 1.6 (ChatMessageAnimatedStickerItemNode.swift
// playEffectAnimation), while layout independently expands the presentation
// frame. The previous 180px surface confused 112 layout points with the 384px
// backing surface and was then enlarged to 336vp, making interaction effects
// visibly soft on a real device.
private let ANIMATED_EMOJI_EFFECT_SIZE: Int32 = 614
// iOS ChatMessageAnimatedStickerItemNode keeps a 384px backing surface even
// when the sticker is laid out at 160pt. Match that source resolution and let
// ArkUI downsample once at presentation instead of stretching a 160px raster.
private let ANIMATED_STICKER_SIZE: Int32 = 384
// iOS ChatMessageAnimatedStickerItemNode decodes WebM stickers into a
// 384px backing surface, independent of their point-size layout.
private let VIDEO_STICKER_SIZE: Int32 = 384
// Visible messages can contain the same WebM document more than once. iOS's
// animation cache lets those nodes reuse decoded frames; without it two 30fps
// decoders compete for the same CPU and both miss their 33ms deadline.
private let videoStickerFrameCacheMonitor = Monitor()
private let videoStickerFrameCacheLimit: Int64 = 32
private var videoStickerFrameCache = HashMap<String, PixelMap>()
private var videoStickerFrameCacheOrder = ArrayList<String>()
private let animatedEmojiMonitor = Monitor()
private let animatedEmojiRenderMonitor = Monitor()
private let animatedEmojiSetMonitor = Monitor()
private var animatedEmojiFrames = HashMap<String, ArrayList<PixelMap>>()
private var animatedEmojiDurations = HashMap<String, Int32>()
private var animatedEmojiLoading = HashMap<String, Bool>()
private var animatedEmojiFailures = HashMap<String, Bool>()
// A frame entry may be a first-frame preview. Keep completion separate so the
// UI can become visible immediately while a later worker upgrades the same key
// to the complete source-rate animation.
private var animatedEmojiComplete = HashMap<String, Bool>()
private var animatedEmojiSetCache: Option<StickerPackDetail> = None
private var animatedEmojiEffectsSetCache: Option<StickerPackDetail> = None
private var animatedEmojiSetLoadedFromDisk: Bool = false
private var animatedEmojiEffectsSetLoadedFromDisk: Bool = false
private let animatedEmojiEffectsSetMonitor = Monitor()
private let animatedEmojiEffectRandom = Random()

public class AnimatedEmojiEffectSelection {
    public var index: Int64 = -1
    public var documentId: Int64 = 0
    public var loaded: Bool = false
    public init() {}
}

private let animatedEmojiEffectPrefetchMonitor = Monitor()
private var animatedEmojiEffectPrefetched = HashMap<String, AnimatedEmojiEffectSelection>()
private var animatedEmojiEffectPrefetching = HashMap<String, Bool>()
private let animatedEmojiEffectBytesMonitor = Monitor()
private var animatedEmojiEffectBytes = HashMap<Int64, Array<UInt8>>()
private var animatedEmojiEffectBytesLoading = HashMap<Int64, Bool>()
// iOS fetches every additional animation attached to a visible emoji and keeps
// the direct renderer's short-lived cache warm. Keep one parsed, first-frame
// ready stream per effect so the tap path does not pay gzip + JSON parsing.
private let animatedEmojiEffectStreamMonitor = Monitor()
private var animatedEmojiEffectStreams = HashMap<Int64, StreamingLottiePlayer>()
private var animatedEmojiEffectStreamPreparing = HashMap<Int64, Bool>()
private let animatedEmojiStreamMonitor = Monitor()
private var animatedEmojiStreams = HashMap<String, StreamingLottiePlayer>()
private var animatedEmojiStreamPreparing = HashMap<String, Bool>()
// Network push, polling and visible List nodes can resolve the same animated
// emoji simultaneously. Keep the compressed TGS resource single-flight in
// memory; renderer ownership remains per visible component.
private let animatedEmojiBytesMonitor = Monitor()
private var animatedEmojiBytes = HashMap<String, Array<UInt8>>()
private var animatedEmojiBytesLoading = HashMap<String, Bool>()
// iOS DirectAnimatedStickerNode submits work to one user-interactive queue.
// Keep two native raster jobs active (rlottie itself is threaded), while new
// first frames jump ahead of speculative successor frames. This preserves the
// source frame rate without letting many visible nodes saturate every core.
private let streamingLottieScheduleMonitor = Monitor()
private var streamingLottieActiveRenders: Int64 = 0
private var streamingLottieFirstFrameWaiters: Int64 = 0
// 4：面板放开到 48 格全动后，2 槽渲染闸是全局瓶颈（~600 帧/s，摊到 48 格
// 只剩 12fps）。105px 的 rlottie 单帧 ~2-4ms，4 槽 ≈ 1200-2000 帧/s，
// 8 核机型占用可控；不够时帧钟跳帧兜底。
private let streamingLottieRenderSlots: Int64 = 4

// 键盘帧钟上的活跃流数（components 层的钟在 register/unregister 时推送）。
// 预取的首帧预渲用它判断前台是否空闲 —— services 不能反向依赖 components，
// 所以计数落在这里。
private let frameClockStreamCountMonitor = Monitor()
private var frameClockStreamCountValue: Int64 = 0

public func setKeyboardFrameClockStreamCount(count: Int64): Unit {
    synchronized(frameClockStreamCountMonitor) { frameClockStreamCountValue = count }
}

public func getKeyboardFrameClockStreamCount(): Int64 {
    synchronized(frameClockStreamCountMonitor) { return frameClockStreamCountValue }
}

// 键盘网格滚动闸：滚动进行中一律不允许格子起播。
// 暴力滚动时 settle(260ms) 会在行存活的 1-2 秒窗口内到期 → 起播 → 行被
// LazyForEach 无回调拆毁 → 僵尸流（真机取证：停稳后 streams=53 全部在向
// 已销毁组件送帧，可见格子反被占满的槽饿死，整屏不动）。
// 停稳（onScrollStop）后由格子的 1.5s 看门狗自动补拉，僵尸从源头断绝。
// 时间戳闸而非布尔闸：onScrollStop 在快速 fling 场景不可靠（真机实测布尔闸
// 一旦卡 true，全网格永久无法起播）。onDidScroll 滚动期间持续触发 → 时间戳
// 持续刷新；停止触发 400ms 后闸自动放行 —— 不依赖任何「结束」回调。
private let keyboardGridScrollMonitor = Monitor()
private var keyboardGridLastScrollMs: Int64 = 0

public func setKeyboardGridScrolling(scrolling: Bool): Unit {
    synchronized(keyboardGridScrollMonitor) {
        if (scrolling) {
            keyboardGridLastScrollMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        } else {
            keyboardGridLastScrollMs = 0
        }
    }
}

public func isKeyboardGridScrolling(): Bool {
    synchronized(keyboardGridScrollMonitor) {
        if (keyboardGridLastScrollMs == 0) { return false }
        let now = DateTime.now().toUnixTimeStamp().toMilliseconds()
        return now - keyboardGridLastScrollMs < 400
    }
}

private func acquireStreamingLottieRender(firstFrame: Bool): Unit {
    synchronized(streamingLottieScheduleMonitor) {
        if (firstFrame) { streamingLottieFirstFrameWaiters += 1 }
        while (streamingLottieActiveRenders >= streamingLottieRenderSlots ||
            (!firstFrame && streamingLottieFirstFrameWaiters > 0)) {
            streamingLottieScheduleMonitor.wait(timeout: Duration.millisecond * 4)
        }
        if (firstFrame && streamingLottieFirstFrameWaiters > 0) {
            streamingLottieFirstFrameWaiters -= 1
        }
        streamingLottieActiveRenders += 1
    }
}

private func releaseStreamingLottieRender(): Unit {
    synchronized(streamingLottieScheduleMonitor) {
        if (streamingLottieActiveRenders > 0) { streamingLottieActiveRenders -= 1 }
        streamingLottieScheduleMonitor.notifyAll()
    }
}

/**
 * iOS-style rolling frame window for a single visible Lottie node.
 *
 * Only the displayed frame and its successor are retained. A player serializes
 * its own persistent Animation session, while the native target's
 * LOTTIE_THREAD_SAFE raster state lets independent visible nodes render in
 * parallel. Components apply iOS-style visibility gating, so offscreen List
 * cache nodes never consume render work.
 */
public class StreamingLottiePlayer {
    private let monitor = Monitor()
    private let session: TelegramLottieSession
    private let rasterSize: Int32
    private let key: String
    private var currentIndex: Int64 = -1
    private var currentFrame: Option<PixelMap> = None<PixelMap>
    private var nextIndex: Int64 = -1
    private var nextFrame: Option<PixelMap> = None<PixelMap>
    private var closed: Bool = false

    public init(session: TelegramLottieSession, rasterSize: Int32, key: String) {
        this.session = session
        this.rasterSize = rasterSize
        this.key = key
    }

    public func getFrameCount(): Int64 { return this.session.frameCount }

    public func getFrameDurationMs(): Int32 { return this.session.frameDurationMs }

    private func renderPixelMap(index: Int64, firstFrame!: Bool = false): Option<PixelMap> {
        acquireStreamingLottieRender(firstFrame)
        // finally 保证归还：native renderFrame 一抛异常，渲染闸就永久漏一个槽，
        // 漏满 4 个后**所有**解码卡死 —— 真机日志铁证：全局 delivered 冻结、
        // 僵尸流 miss 无限增长、整个面板"又不动了"。
        var pixels = Option<Array<UInt8>>.None
        try {
            pixels = this.session.renderFrame(index)
        } finally {
            releaseStreamingLottieRender()
        }
        match (pixels) {
            case Some(bytes) =>
                // rlottie 空帧防护：非首帧渲染出全透明按解码 miss 处理，
                // 帧钟保持上一帧（见 animFrameLooksEmpty 注释）。
                if (!firstFrame && this.currentIndex >= 0 && animFrameLooksEmpty(bytes)) {
                    return None<PixelMap>
                }
                let options = InitializationOptions(
                    Size(this.rasterSize, this.rasterSize),
                    srcPixelFormat: PixelMapFormat.Bgra8888,
                    pixelFormat: PixelMapFormat.Bgra8888,
                    alphaType: AlphaType.Premul
                )
                return Some(createPixelMap(bytes, options))
            case None => return None<PixelMap>
        }
    }

    public func prepareFirstFrame(): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            match (this.renderPixelMap(0, firstFrame: true)) {
                case Some(frame) =>
                    this.currentIndex = 0
                    this.currentFrame = Some(frame)
                    Hilog.info(0, "CjTelegram", "[StreamingLottie] first frame ready key=${this.key}")
                    return true
                case None => return false
            }
        }
    }

    public func prepareNextFrame(index: Int64): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            if (this.currentIndex == index || this.nextIndex == index) { return true }
            match (this.renderPixelMap(index, firstFrame: index == 0)) {
                case Some(frame) =>
                    this.nextIndex = index
                    this.nextFrame = Some(frame)
                    return true
                case None => return false
            }
        }
    }

    public func advanceTo(index: Int64): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            if (this.currentIndex == index) { return true }
            if (this.nextIndex != index) { return false }
            match (this.nextFrame) {
                case Some(frame) =>
                    this.currentIndex = index
                    this.currentFrame = Some(frame)
                    this.nextIndex = -1
                    this.nextFrame = None<PixelMap>
                    return true
                case None => return false
            }
        }
    }

    /** Render and present an arbitrary frame, used when a tapped emoji restarts. */
    public func seekTo(index: Int64): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            if (this.currentIndex == index) { return true }
            if (this.nextIndex == index) {
                match (this.nextFrame) {
                    case Some(frame) =>
                        this.currentIndex = index
                        this.currentFrame = Some(frame)
                        this.nextIndex = -1
                        this.nextFrame = None<PixelMap>
                        return true
                    case None => ()
                }
            }
            match (this.renderPixelMap(index, firstFrame: index == 0)) {
                case Some(frame) =>
                    this.currentIndex = index
                    this.currentFrame = Some(frame)
                    this.nextIndex = -1
                    this.nextFrame = None<PixelMap>
                    return true
                case None => return false
            }
        }
    }

    public func getCurrentFrame(): Option<PixelMap> {
        synchronized(this.monitor) { return this.currentFrame }
    }

    public func close(): Unit {
        synchronized(this.monitor) {
            if (this.closed) { return }
            this.closed = true
            this.currentFrame = None<PixelMap>
            this.nextFrame = None<PixelMap>
            this.currentIndex = -1
            this.nextIndex = -1
            this.session.close()
        }
    }
}

/** iOS-style current/next-frame window backed by one persistent VP9 decoder. */
public class StreamingVideoStickerPlayer {
    private let monitor = Monitor()
    private let documentId: Int64
    private let session: TelegramVideoStickerSession
    private let rasterSize: Int32
    private var currentIndex: Int64 = -1
    private var currentFrame: Option<PixelMap> = None<PixelMap>
    private var nextIndex: Int64 = -1
    private var nextFrame: Option<PixelMap> = None<PixelMap>
    private var closed: Bool = false
    private var slowRenderLogs: Int32 = 0

    public init(documentId: Int64, session: TelegramVideoStickerSession, rasterSize: Int32) {
        this.documentId = documentId
        this.session = session
        this.rasterSize = rasterSize
    }

    public func getFrameCount(): Int64 { return this.session.frameCount }
    public func getFrameDurationMs(): Int32 { return this.session.frameDurationMs }

    private func renderPixelMap(index: Int64): Option<PixelMap> {
        let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let cacheKey = "${this.documentId}:${index}"
        // Only the immediate presentation window is shared. A cache hit does
        // not advance a decoder session; caching later frames caused the first
        // miss after the cache window to synchronously decode a long backlog.
        // iOS similarly shares its start image/current-next window, then keeps
        // each visible FFMpeg source sequential.
        if (index <= 1) {
            synchronized(videoStickerFrameCacheMonitor) {
                if (videoStickerFrameCache.contains(cacheKey)) {
                    return Some(videoStickerFrameCache[cacheKey])
                }
            }
        }
        // Never hold the global cache monitor while VP9 decoding. The previous
        // implementation serialized unrelated stickers behind the slowest
        // frame and made a newly received sticker wait several frame budgets.
        match (this.session.renderFrame(index)) {
            case Some(bytes) =>
                // 空帧防护（同 StreamingLottiePlayer）
                if (index > 0 && this.currentIndex >= 0 && animFrameLooksEmpty(bytes)) {
                    return None<PixelMap>
                }
                let options = InitializationOptions(
                    Size(this.rasterSize, this.rasterSize),
                    srcPixelFormat: PixelMapFormat.Bgra8888,
                    pixelFormat: PixelMapFormat.Bgra8888,
                    alphaType: AlphaType.Premul
                )
                let frame = createPixelMap(bytes, options)
                if (index <= 1) {
                    synchronized(videoStickerFrameCacheMonitor) {
                        if (!videoStickerFrameCache.contains(cacheKey)) {
                            videoStickerFrameCache[cacheKey] = frame
                            videoStickerFrameCacheOrder.add(cacheKey)
                        }
                        while (videoStickerFrameCacheOrder.size > videoStickerFrameCacheLimit) {
                            let oldest = videoStickerFrameCacheOrder[0]
                            videoStickerFrameCacheOrder.remove(0..1)
                            let _ = videoStickerFrameCache.remove(oldest)
                        }
                    }
                }
                let elapsedMs = DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt
                if (elapsedMs > Int64(this.session.frameDurationMs) && this.slowRenderLogs < 3) {
                    this.slowRenderLogs = this.slowRenderLogs + 1
                    Hilog.info(0, "CjTelegram",
                        "[VideoStickerPerf] slow frame index=${index} elapsedMs=${elapsedMs} budgetMs=${this.session.frameDurationMs}")
                }
                return Some(frame)
            case None => return None<PixelMap>
        }
    }

    public func prepareFirstFrame(): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            match (this.renderPixelMap(0)) {
                case Some(frame) =>
                    this.currentIndex = 0
                    this.currentFrame = Some(frame)
                    return true
                case None => return false
            }
        }
    }

    public func prepareNextFrame(index: Int64): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            if (this.currentIndex == index || this.nextIndex == index) { return true }
            match (this.renderPixelMap(index)) {
                case Some(frame) =>
                    this.nextIndex = index
                    this.nextFrame = Some(frame)
                    return true
                case None => return false
            }
        }
    }

    public func advanceTo(index: Int64): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            if (this.currentIndex == index) { return true }
            if (this.nextIndex != index) { return false }
            match (this.nextFrame) {
                case Some(frame) =>
                    this.currentIndex = index
                    this.currentFrame = Some(frame)
                    this.nextIndex = -1
                    this.nextFrame = None<PixelMap>
                    return true
                case None => return false
            }
        }
    }

    public func getCurrentFrame(): Option<PixelMap> {
        synchronized(this.monitor) { return this.currentFrame }
    }

    public func close(): Unit {
        synchronized(this.monitor) {
            if (this.closed) { return }
            this.closed = true
            this.currentFrame = None<PixelMap>
            this.nextFrame = None<PixelMap>
            this.session.close()
        }
    }
}

// Incoming media resolves on a worker before Message.documentLocalPath is
// published. Keep that worker's first-frame-ready session for the first visible
// component, exactly like iOS MediaBox's short-lived resource representation.
// Entries are single-consumer and bounded so an offscreen burst cannot retain
// native decoders indefinitely.
private let preparedStickerStreamMonitor = Monitor()
private let preparedStickerStreamLimit: Int64 = 8
private var preparedLottieStickerStreams = HashMap<Int64, StreamingLottiePlayer>()
private var preparedVideoStickerStreams = HashMap<Int64, StreamingVideoStickerPlayer>()
private var preparedLottieStickerOrder = ArrayList<Int64>()
private var preparedVideoStickerOrder = ArrayList<Int64>()

private func preparedOrderWithout(
    order: ArrayList<Int64>, documentId: Int64
): ArrayList<Int64> {
    let result = ArrayList<Int64>()
    for (value in order) {
        if (value != documentId) { result.add(value) }
    }
    return result
}

private func takePreparedLottieStickerStream(
    documentId: Int64
): Option<StreamingLottiePlayer> {
    synchronized(preparedStickerStreamMonitor) {
        if (preparedLottieStickerStreams.contains(documentId)) {
            let player = preparedLottieStickerStreams[documentId]
            let _ = preparedLottieStickerStreams.remove(documentId)
            preparedLottieStickerOrder = preparedOrderWithout(
                preparedLottieStickerOrder, documentId)
            return Some(player)
        }
    }
    return None<StreamingLottiePlayer>
}

private func takePreparedVideoStickerStream(
    documentId: Int64
): Option<StreamingVideoStickerPlayer> {
    synchronized(preparedStickerStreamMonitor) {
        if (preparedVideoStickerStreams.contains(documentId)) {
            let player = preparedVideoStickerStreams[documentId]
            let _ = preparedVideoStickerStreams.remove(documentId)
            preparedVideoStickerOrder = preparedOrderWithout(
                preparedVideoStickerOrder, documentId)
            return Some(player)
        }
    }
    return None<StreamingVideoStickerPlayer>
}

/**
 * Wait for the owner of an in-flight render to publish its frames.
 *
 * Optimistic outgoing messages are replaced when the server confirms them,
 * which can create a second animation component for the same emoji while the
 * first component is still rendering. Returning false for that second caller
 * leaves it permanently on the static fallback until the chat is reopened.
 */
private func awaitAnimatedLoad(key: String, requireComplete!: Bool = true): Bool {
    var attempt: Int64 = 0
    while (attempt < 600) {
        var stillLoading = false
        synchronized(animatedEmojiMonitor) {
            if (requireComplete) {
                if (animatedEmojiComplete.contains(key)) { return true }
            } else if (animatedEmojiFrames.contains(key)) { return true }
            if (animatedEmojiFailures.contains(key)) { return false }
            stillLoading = animatedEmojiLoading.contains(key)
        }
        if (!stillLoading) { return false }
        sleep(Duration.millisecond * 25)
        attempt = attempt + 1
    }
    synchronized(animatedEmojiMonitor) {
        return if (requireComplete) {
            animatedEmojiComplete.contains(key)
        } else {
            animatedEmojiFrames.contains(key)
        }
    }
}

/**
 * Render only frame zero and publish it as soon as possible.  iOS keeps an
 * animation item/renderer and requests frames on demand; pre-rasterizing 60–90
 * PixelMaps before exposing any image inverted that priority.  This preview
 * path gives ArkUI stable artwork first, then the existing full loader upgrades
 * the cache in the background.
 */
private func loadAnimatedPreview(
    key: String,
    rasterSize: Int32,
    bytesProvider: () -> Array<UInt8>
): Bool {
    var joinExistingLoad = false
    synchronized(animatedEmojiMonitor) {
        if (animatedEmojiFrames.contains(key)) { return true }
        if (animatedEmojiFailures.contains(key)) { return false }
        if (animatedEmojiLoading.contains(key)) {
            joinExistingLoad = true
        } else {
            animatedEmojiLoading[key] = true
        }
    }
    if (joinExistingLoad) { return awaitAnimatedLoad(key, requireComplete: false) }

    var loaded = false
    try {
        let bytes = bytesProvider()
        if (bytes.size > 0) {
            var nativeFrames = TelegramLottieFrames()
            synchronized(animatedEmojiRenderMonitor) {
                nativeFrames = getTelegramLottieNative().renderTgs(
                    bytes, key + "_preview", rasterSize, maxFrames: 1)
            }
            if (nativeFrames.success && !nativeFrames.frames.isEmpty()) {
                let options = InitializationOptions(
                    Size(rasterSize, rasterSize),
                    srcPixelFormat: PixelMapFormat.Bgra8888,
                    pixelFormat: PixelMapFormat.Bgra8888,
                    alphaType: AlphaType.Premul
                )
                let pixelMaps = ArrayList<PixelMap>()
                pixelMaps.add(createPixelMap(nativeFrames.frames[0], options))
                synchronized(animatedEmojiMonitor) {
                    animatedEmojiFrames[key] = pixelMaps
                    animatedEmojiDurations[key] = nativeFrames.frameDurationMs
                }
                loaded = true
                Hilog.info(0, "CjTelegram", "[AnimatedEmojiService] preview ready key=${key}")
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[AnimatedEmojiService] preview failed key=${key}: ${e}")
    }
    synchronized(animatedEmojiMonitor) {
        let _ = animatedEmojiLoading.remove(key)
        if (!loaded) { animatedEmojiFailures[key] = true }
    }
    return loaded
}

private func normalizeAnimatedEmoji(value: String): String {
    var result = ""
    for (rune in value.toRuneArray()) {
        let codePoint = UInt32(rune)
        if (codePoint != 0xFE0F && codePoint != 0xFE0E) {
            result = result + rune.toString()
        }
    }
    return result
}

private func animatedEmojiDiskPath(value: String): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    let dir = filesDir + "/animated_emoji_tgs"
    try { FileIo.mkdir(dir) } catch (_e: Exception) {}
    var key = ""
    for (rune in normalizeAnimatedEmoji(value).toRuneArray()) {
        if (!key.isEmpty()) { key = key + "_" }
        key = key + UInt32(rune).toString()
    }
    return if (key.isEmpty()) { "" } else { dir + "/" + key + ".tgs" }
}

private func persistAnimatedEmojiBytes(value: String, bytes: Array<UInt8>): Unit {
    if (bytes.isEmpty()) { return }
    let path = animatedEmojiDiskPath(value)
    if (path.isEmpty()) { return }
    try {
        let file = FileIo.open(path, mode: 0o1101)
        FileIo.write(file.fd, bytes)
        FileIo.close(file)
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[AnimatedEmojiService] disk cache write failed: ${e}")
    }
}

private func findStickerByDocumentId(documentId: Int64, stickers: ArrayList<StickerItem>): Option<StickerItem> {
    for (sticker in stickers) {
        if (sticker.documentId == documentId) { return Some(sticker) }
    }
    return None
}

private func findAnimatedEmojiSticker(emoji: String, pack: StickerPackDetail): Option<StickerItem> {
    let normalized = normalizeAnimatedEmoji(emoji)
    for (emojiPack in pack.emojiPacks) {
        if (normalizeAnimatedEmoji(emojiPack.emoticon) == normalized) {
            for (documentId in emojiPack.documentIds) {
                match (findStickerByDocumentId(documentId, pack.stickers)) {
                    case Some(sticker) => return Some(sticker)
                    case None => ()
                }
            }
        }
    }
    // Older sets expose the mapping directly through DocumentAttributeSticker.alt.
    for (sticker in pack.stickers) {
        if (normalizeAnimatedEmoji(sticker.altEmoji) == normalized) {
            return Some(sticker)
        }
    }
    return None
}

private func getAnimatedEmojiSetCached(): StickerPackDetail {
    // Metadata can require an MTProto round-trip. Never hold the frame-cache
    // monitor across network I/O: UI frame reads also use that monitor.
    synchronized(animatedEmojiSetMonitor) {
        match (animatedEmojiSetCache) {
            case Some(pack) => return pack
            case None => ()
        }
        let diskPack = getStickersService().getCachedAnimatedEmojiSet()
        if (diskPack.success && !diskPack.stickers.isEmpty()) {
            animatedEmojiSetCache = Some(diskPack)
            animatedEmojiSetLoadedFromDisk = true
            return diskPack
        }
        // Keep the metadata request single-flight. It is small compared with frame
        // rendering and avoids one full getStickerSet call per newly visible emoji.
        let pack = getStickersService().getAnimatedEmojiSet()
        if (pack.success) {
            animatedEmojiSetCache = Some(pack)
            animatedEmojiSetLoadedFromDisk = false
        }
        return pack
    }
}

/**
 * Start the animatedEmoji sticker-set round trip after account connection,
 * while the Chats screen is visible. The first message component then reads
 * memory metadata instead of paying this multi-second request on chat entry.
 */
public func preloadAnimatedEmojiMetadata(): Unit {
    let _ = getAnimatedEmojiSetCached()
    var shouldRefresh = false
    synchronized(animatedEmojiSetMonitor) {
        shouldRefresh = animatedEmojiSetLoadedFromDisk
        animatedEmojiSetLoadedFromDisk = false
    }
    if (shouldRefresh) {
        let fresh = getStickersService().getAnimatedEmojiSet()
        if (fresh.success && !fresh.stickers.isEmpty()) {
            synchronized(animatedEmojiSetMonitor) { animatedEmojiSetCache = Some(fresh) }
        }
    }
}

private func getAnimatedEmojiEffectsSetCached(): StickerPackDetail {
    synchronized(animatedEmojiEffectsSetMonitor) {
        match (animatedEmojiEffectsSetCache) {
            case Some(pack) => return pack
            case None => ()
        }
        let diskPack = getStickersService().getCachedAnimatedEmojiAnimationsSet()
        if (diskPack.success && !diskPack.stickers.isEmpty()) {
            animatedEmojiEffectsSetCache = Some(diskPack)
            animatedEmojiEffectsSetLoadedFromDisk = true
            return diskPack
        }
        let pack = getStickersService().getAnimatedEmojiAnimationsSet()
        if (pack.success) {
            animatedEmojiEffectsSetCache = Some(pack)
            animatedEmojiEffectsSetLoadedFromDisk = false
        }
        return pack
    }
}

/** Warm the small effect index set before the first interaction. */
public func preloadAnimatedEmojiEffectsMetadata(): Unit {
    let _ = getAnimatedEmojiEffectsSetCached()
    var shouldRefresh = false
    synchronized(animatedEmojiEffectsSetMonitor) {
        shouldRefresh = animatedEmojiEffectsSetLoadedFromDisk
        animatedEmojiEffectsSetLoadedFromDisk = false
    }
    if (shouldRefresh) {
        let fresh = getStickersService().getAnimatedEmojiAnimationsSet()
        if (fresh.success && !fresh.stickers.isEmpty()) {
            synchronized(animatedEmojiEffectsSetMonitor) {
                animatedEmojiEffectsSetCache = Some(fresh)
            }
        }
    }
}

private func effectIndex(value: String): Int64 {
    var index: Int64 = -1
    var otherCodePoint = false
    for (rune in normalizeAnimatedEmoji(value).toRuneArray()) {
        let cp = UInt32(rune)
        if (cp >= 0x30 && cp <= 0x39 && index < 0) {
            index = Int64(cp - 0x30)
        } else if (cp != 0x20E3) {
            otherCodePoint = true
        }
    }
    return if (!otherCodePoint) { index } else { -1 }
}

private func effectStickerForDocument(documentId: Int64, pack: StickerPackDetail): Option<StickerItem> {
    return findStickerByDocumentId(documentId, pack.stickers)
}

private func loadAnimatedEmojiEffectBytes(sticker: StickerItem): Array<UInt8> {
    var joinExistingLoad = false
    synchronized(animatedEmojiEffectBytesMonitor) {
        if (animatedEmojiEffectBytes.contains(sticker.documentId)) {
            return animatedEmojiEffectBytes[sticker.documentId]
        }
        if (animatedEmojiEffectBytesLoading.contains(sticker.documentId)) {
            joinExistingLoad = true
        } else {
            animatedEmojiEffectBytesLoading[sticker.documentId] = true
        }
    }
    if (joinExistingLoad) {
        var attempt: Int64 = 0
        while (attempt < 600) {
            synchronized(animatedEmojiEffectBytesMonitor) {
                if (animatedEmojiEffectBytes.contains(sticker.documentId)) {
                    return animatedEmojiEffectBytes[sticker.documentId]
                }
                if (!animatedEmojiEffectBytesLoading.contains(sticker.documentId)) {
                    return Array<UInt8>(0, repeat: 0)
                }
            }
            sleep(Duration.millisecond * 25)
            attempt = attempt + 1
        }
        return Array<UInt8>(0, repeat: 0)
    }
    let bytes = getFileDownloadService().downloadDocument(
        sticker.documentId, sticker.accessHash, sticker.fileReference,
        sticker.dcId, fileSize: sticker.size, priority: 55)
    synchronized(animatedEmojiEffectBytesMonitor) {
        let _ = animatedEmojiEffectBytesLoading.remove(sticker.documentId)
        if (!bytes.isEmpty()) {
            animatedEmojiEffectBytes[sticker.documentId] = bytes
        }
    }
    return bytes
}

private func takePreparedAnimatedEmojiEffectStream(
    documentId: Int64
): Option<StreamingLottiePlayer> {
    synchronized(animatedEmojiEffectStreamMonitor) {
        if (animatedEmojiEffectStreams.contains(documentId)) {
            let player = animatedEmojiEffectStreams[documentId]
            let _ = animatedEmojiEffectStreams.remove(documentId)
            return Some(player)
        }
    }
    return None<StreamingLottiePlayer>
}

/** Download, parse and rasterize the first two frames before interaction. */
private func prepareAnimatedEmojiEffectStream(sticker: StickerItem): Unit {
    synchronized(animatedEmojiEffectStreamMonitor) {
        if (animatedEmojiEffectStreams.contains(sticker.documentId) ||
            animatedEmojiEffectStreamPreparing.contains(sticker.documentId)) { return }
        animatedEmojiEffectStreamPreparing[sticker.documentId] = true
    }
    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    var prepared = None<StreamingLottiePlayer>
    let bytes = loadAnimatedEmojiEffectBytes(sticker)
    if (!bytes.isEmpty()) {
        prepared = openStreamingLottie(
            bytes, "effect_stream_${sticker.documentId}", ANIMATED_EMOJI_EFFECT_SIZE)
        match (prepared) {
            case Some(player) =>
                if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
            case None => ()
        }
    }
    var closeDuplicate = None<StreamingLottiePlayer>
    synchronized(animatedEmojiEffectStreamMonitor) {
        let _ = animatedEmojiEffectStreamPreparing.remove(sticker.documentId)
        match (prepared) {
            case Some(player) =>
                if (animatedEmojiEffectStreams.contains(sticker.documentId)) {
                    closeDuplicate = Some(player)
                } else {
                    animatedEmojiEffectStreams[sticker.documentId] = player
                }
            case None => ()
        }
    }
    match (closeDuplicate) {
        case Some(player) => player.close()
        case None => ()
    }
    Hilog.info(0, "CjTelegram",
        "[EmojiInteractionPerf] prepared document=${sticker.documentId} raster=${ANIMATED_EMOJI_EFFECT_SIZE} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
}

/** Open the selected interaction effect without pre-rasterizing its timeline. */
public func openAnimatedEmojiEffectStream(
    documentId: Int64
): Option<StreamingLottiePlayer> {
    match (takePreparedAnimatedEmojiEffectStream(documentId)) {
        case Some(player) =>
            Hilog.info(0, "CjTelegram", "[EmojiInteractionPerf] prepared stream hit document=${documentId}")
            return Some(player)
        case None => ()
    }
    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let pack = getAnimatedEmojiEffectsSetCached()
    if (!pack.success) { return None<StreamingLottiePlayer> }
    match (effectStickerForDocument(documentId, pack)) {
        case Some(sticker) =>
            let result = openStreamingLottie(
                loadAnimatedEmojiEffectBytes(sticker),
                "effect_stream_${documentId}",
                ANIMATED_EMOJI_EFFECT_SIZE)
            Hilog.info(0, "CjTelegram",
                "[EmojiInteractionPerf] cold stream document=${documentId} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
            return result
        case None => return None<StreamingLottiePlayer>
    }
}

private func animatedEmojiEffectLookup(value: String): String {
    let normalized = normalizeAnimatedEmoji(value)
    return if (normalized == "💛" || normalized == "💙" || normalized == "💚" ||
        normalized == "💜" || normalized == "🧡" || normalized == "🖤" ||
        normalized == "🤎" || normalized == "🤍") { "❤" } else { normalized }
}

private func animatedEmojiEffectCandidates(
    emoji: String,
    pack: StickerPackDetail
): ArrayList<Array<Int64>> {
    let lookup = animatedEmojiEffectLookup(emoji)
    let candidates = ArrayList<Array<Int64>>()
    for (sticker in pack.stickers) {
        var animationIndex: Int64 = -1
        var matchesEmoji = false
        for (emojiPack in pack.emojiPacks) {
            var containsDocument = false
            for (documentId in emojiPack.documentIds) {
                if (documentId == sticker.documentId) {
                    containsDocument = true
                    break
                }
            }
            if (containsDocument) {
                let packIndex = effectIndex(emojiPack.emoticon)
                if (packIndex >= 0) {
                    animationIndex = packIndex
                } else if (normalizeAnimatedEmoji(emojiPack.emoticon) == lookup) {
                    matchesEmoji = true
                }
            }
        }
        if (animationIndex >= 0 && matchesEmoji) {
            candidates.add([animationIndex, sticker.documentId])
        }
    }
    return candidates
}

private func prepareAnimatedEmojiEffectInternal(
    emoji: String,
    previousIndex: Int64,
    requestedIndex: Int64
): AnimatedEmojiEffectSelection {
    let result = AnimatedEmojiEffectSelection()
    let lookup = animatedEmojiEffectLookup(emoji)
    let pack = getAnimatedEmojiEffectsSetCached()
    if (!pack.success) { return result }

    // Telegram stores the animation index and the target emoji as separate
    // StickerPack index keys for the same document. This mirrors iOS'
    // getStringRepresentationsOfIndexKeys(): one key is 0️⃣...9️⃣, the other
    // is the emoji itself.
    let candidates = animatedEmojiEffectCandidates(lookup, pack)
    if (candidates.size == 0) {
        Hilog.info(0, "CjTelegram", "[EmojiInteraction] no effects for emoji=${emoji}")
        return result
    }

    var usable = ArrayList<Array<Int64>>()
    for (candidate in candidates) {
        if (requestedIndex >= 0) {
            if (candidate[0] == requestedIndex) { usable.add(candidate) }
        } else if (candidate[0] != previousIndex || candidates.size == 1) {
            usable.add(candidate)
        }
    }
    if (usable.size == 0 && requestedIndex < 0) { usable = candidates }
    if (usable.size == 0) {
        Hilog.info(0, "CjTelegram", "[EmojiInteraction] requested effect missing emoji=${emoji} index=${requestedIndex}")
        return result
    }
    let chosen = usable[Int64(animatedEmojiEffectRandom.nextUInt32()) % usable.size]
    match (effectStickerForDocument(chosen[1], pack)) {
        case Some(sticker) =>
            result.index = chosen[0]
            result.documentId = chosen[1]
            // Download/cache only. The overlay owns a persistent rlottie
            // session and begins after frame zero instead of waiting for all
            // 180 frames to be rasterized here.
            result.loaded = !loadAnimatedEmojiEffectBytes(sticker).isEmpty()
        case None => ()
    }
    Hilog.info(0, "CjTelegram", "[EmojiInteraction] prepared emoji=${emoji} index=${result.index} document=${result.documentId} loaded=${result.loaded}")
    return result
}

/** Select and synchronously prepare one iOS-compatible indexed emoji effect. */
public func prepareAnimatedEmojiEffect(emoji: String, previousIndex: Int64): AnimatedEmojiEffectSelection {
    let lookup = animatedEmojiEffectLookup(emoji)
    synchronized(animatedEmojiEffectPrefetchMonitor) {
        if (animatedEmojiEffectPrefetched.contains(lookup)) {
            let prefetched = animatedEmojiEffectPrefetched[lookup]
            let _ = animatedEmojiEffectPrefetched.remove(lookup)
            if (prefetched.index != previousIndex || previousIndex < 0) {
                Hilog.info(0, "CjTelegram", "[EmojiInteraction] use prefetched emoji=${emoji} index=${prefetched.index}")
                return prefetched
            }
        }
    }
    return prepareAnimatedEmojiEffectInternal(emoji, previousIndex, -1)
}

/** Preload one likely first-tap effect for a visible animated emoji. */
public func preloadAnimatedEmojiEffect(emoji: String): Unit {
    let lookup = animatedEmojiEffectLookup(emoji)
    synchronized(animatedEmojiEffectPrefetchMonitor) {
        if (animatedEmojiEffectPrefetched.contains(lookup) ||
            animatedEmojiEffectPrefetching.contains(lookup)) { return }
        animatedEmojiEffectPrefetching[lookup] = true
    }
    let selection = prepareAnimatedEmojiEffectInternal(emoji, -1, -1)
    let pack = getAnimatedEmojiEffectsSetCached()
    if (pack.success) {
        // iOS starts freeMediaFileInteractiveFetched for every indexed effect
        // associated with the visible emoji. Only the likely first choice gets
        // parsed/rasterized eagerly; parsing ten effects at once would compete
        // with the visible message animation and cause the very hitch we avoid.
        let candidates = animatedEmojiEffectCandidates(emoji, pack)
        for (candidate in candidates) {
            match (effectStickerForDocument(candidate[1], pack)) {
                case Some(sticker) =>
                    if (sticker.documentId == selection.documentId) {
                        prepareAnimatedEmojiEffectStream(sticker)
                    } else {
                        let _ = spawn { let _ = loadAnimatedEmojiEffectBytes(sticker) }
                    }
                case None => ()
            }
        }
    }
    synchronized(animatedEmojiEffectPrefetchMonitor) {
        let _ = animatedEmojiEffectPrefetching.remove(lookup)
        if (selection.loaded) { animatedEmojiEffectPrefetched[lookup] = selection }
    }
}

/** Prepare the exact effect index received from another Telegram client. */
public func prepareAnimatedEmojiEffectAtIndex(emoji: String, index: Int64): AnimatedEmojiEffectSelection {
    return prepareAnimatedEmojiEffectInternal(emoji, -1, index)
}

private func animatedDocumentKey(documentId: Int64): String {
    return "document_${documentId}"
}

private func loadAnimatedStickerDocument(
    key: String,
    sticker: StickerItem,
    rasterSize!: Int32 = ANIMATED_EMOJI_SIZE,
    maxFrames!: Int32 = 180
): Bool {
    var joinExistingLoad = false
    synchronized(animatedEmojiMonitor) {
        if (animatedEmojiComplete.contains(key)) { return true }
        if (animatedEmojiFailures.contains(key)) { return false }
        if (animatedEmojiLoading.contains(key)) {
            joinExistingLoad = true
        } else {
            animatedEmojiLoading[key] = true
        }
    }
    if (joinExistingLoad) { return awaitAnimatedLoad(key) }

    var loaded = false
    try {
        if (!sticker.isEmpty && sticker.documentId != 0) {
            let bytes = getFileDownloadService().downloadDocument(
                sticker.documentId,
                sticker.accessHash,
                sticker.fileReference,
                sticker.dcId,
                fileSize: sticker.size,
                priority: 40
            )
            if (bytes.size > 0) {
                var nativeFrames = TelegramLottieFrames()
                synchronized(animatedEmojiRenderMonitor) {
                    nativeFrames = getTelegramLottieNative().renderTgs(
                        bytes,
                        key,
                        rasterSize,
                        maxFrames: maxFrames
                    )
                }
                if (nativeFrames.success) {
                    let pixelMaps = ArrayList<PixelMap>()
                    let options = InitializationOptions(
                        Size(rasterSize, rasterSize),
                        srcPixelFormat: PixelMapFormat.Bgra8888,
                        pixelFormat: PixelMapFormat.Bgra8888,
                        alphaType: AlphaType.Premul
                    )
                    for (frame in nativeFrames.frames) {
                        pixelMaps.add(createPixelMap(frame, options))
                    }
                    synchronized(animatedEmojiMonitor) {
                        animatedEmojiFrames[key] = pixelMaps
                        animatedEmojiDurations[key] = nativeFrames.frameDurationMs
                        animatedEmojiComplete[key] = true
                    }
                    loaded = true
                }
            }
        }
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[AnimatedEmojiService] document load failed: ${e}")
    }

    synchronized(animatedEmojiMonitor) {
        let _ = animatedEmojiLoading.remove(key)
        if (!loaded) { animatedEmojiFailures[key] = true }
    }
    return loaded
}

/** Load a reaction/custom-emoji Document through the same TGS renderer used by animated emoji. */
public func ensureAnimatedStickerDocumentLoaded(sticker: StickerItem): Bool {
    return loadAnimatedStickerDocument(animatedDocumentKey(sticker.documentId), sticker)
}

public func ensureAnimatedStickerDocumentPreviewLoaded(sticker: StickerItem): Bool {
    let key = animatedDocumentKey(sticker.documentId)
    return loadAnimatedPreview(key, ANIMATED_EMOJI_SIZE, { =>
        if (sticker.isEmpty || sticker.documentId == 0) {
            return Array<UInt8>(0, repeat: 0)
        }
        return getFileDownloadService().downloadDocument(
            sticker.documentId, sticker.accessHash, sticker.fileReference,
            sticker.dcId, fileSize: sticker.size, priority: 45)
    })
}

public func getAnimatedStickerDocumentFrameCount(documentId: Int64): Int64 {
    return getAnimatedEmojiFrameCount(animatedDocumentKey(documentId))
}

public func getAnimatedStickerDocumentFrameDuration(documentId: Int64): Int32 {
    return getAnimatedEmojiFrameDuration(animatedDocumentKey(documentId))
}

public func getAnimatedStickerDocumentFrame(documentId: Int64, index: Int64): Option<PixelMap> {
    return getAnimatedEmojiFrame(animatedDocumentKey(documentId), index)
}

private func loadAnimatedEmojiBytes(
    emoji: String,
    priority!: Int32 = 80
): Array<UInt8> {
    let key = normalizeAnimatedEmoji(emoji)
    var ownsLoad = false
    synchronized(animatedEmojiBytesMonitor) {
        if (animatedEmojiBytes.contains(key)) {
            return animatedEmojiBytes[key]
        }
        if (animatedEmojiBytesLoading.contains(key)) {
            while (animatedEmojiBytesLoading.contains(key)) {
                animatedEmojiBytesMonitor.wait(timeout: Duration.millisecond * 50)
            }
            if (animatedEmojiBytes.contains(key)) {
                return animatedEmojiBytes[key]
            }
            return Array<UInt8>(0, repeat: 0)
        }
        animatedEmojiBytesLoading[key] = true
        ownsLoad = true
    }
    if (!ownsLoad) { return Array<UInt8>(0, repeat: 0) }

    var resolved = Array<UInt8>(0, repeat: 0)
    // FileDownloadService persists by document id, but resolving that id still
    // requires the animatedEmoji sticker set after a process restart. Keep the
    // explicit per-emoji TGS cache used by the preview path.
    let diskPath = animatedEmojiDiskPath(key)
    if (!diskPath.isEmpty()) {
        let diskBytes = readLocalFileBytes(diskPath)
        if (!diskBytes.isEmpty()) {
            Hilog.info(0, "CjTelegram", "[AnimatedEmojiService] emoji TGS disk hit key=${key}")
            resolved = diskBytes
        }
    }
    if (resolved.isEmpty()) {
        let pack = getAnimatedEmojiSetCached()
        if (pack.success) {
            match (findAnimatedEmojiSticker(key, pack)) {
                case Some(sticker) =>
                    resolved = getFileDownloadService().downloadDocument(
                        sticker.documentId, sticker.accessHash, sticker.fileReference,
                        sticker.dcId, fileSize: sticker.size, priority: priority)
                    persistAnimatedEmojiBytes(key, resolved)
                case None => ()
            }
        }
    }
    synchronized(animatedEmojiBytesMonitor) {
        let _ = animatedEmojiBytesLoading.remove(key)
        if (!resolved.isEmpty()) { animatedEmojiBytes[key] = resolved }
        animatedEmojiBytesMonitor.notifyAll()
    }
    return resolved
}

/** Resolve only the compressed resource; visible nodes still own rendering. */
public func prefetchAnimatedEmojiResource(emoji: String): Bool {
    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let bytes = loadAnimatedEmojiBytes(emoji)
    Hilog.info(0, "CjTelegram",
        "[AnimatedEmojiPerf] resource prefetch emoji=${normalizeAnimatedEmoji(emoji)} bytes=${bytes.size} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
    return !bytes.isEmpty()
}

/**
 * Mirror iOS PrefetchManager's small popular-emoji warm set. This runs
 * sequentially at background priority: one speculative resource can occupy at
 * most one download slot, while a newly visible emoji (priority 80) can jump
 * ahead immediately.
 */
public func preloadPopularAnimatedEmojiResources(): Unit {
    let popular = ArrayList<String>()
    popular.add("❤")
    popular.add("👍")
    popular.add("👎")
    popular.add("😳")
    popular.add("😒")
    popular.add("🥳")
    popular.add("😡")
    popular.add("😮")
    popular.add("😂")
    popular.add("😘")
    popular.add("😍")
    popular.add("🙄")
    popular.add("😎")
    for (emoji in popular) {
        let _ = loadAnimatedEmojiBytes(emoji, priority: 5)
    }
}

private func animatedEmojiModelKey(key: String): String {
    return "animated_emoji_model_${key}"
}

private func openStreamingLottie(
    bytes: Array<UInt8>, key: String, rasterSize: Int32
): Option<StreamingLottiePlayer> {
    if (bytes.isEmpty()) { return None<StreamingLottiePlayer> }
    match (getTelegramLottieNative().openTgs(bytes, key, rasterSize)) {
        case Some(session) =>
            let player = StreamingLottiePlayer(session, rasterSize, key)
            if (player.prepareFirstFrame()) { return Some(player) }
            player.close()
            return None<StreamingLottiePlayer>
        case None => return None<StreamingLottiePlayer>
    }
}

// ---- 大表情消息的静帧 ----
//
// 2 个及以上 emoji 的消息，iOS 画的是一行不动的大号 Apple 字形（见
// ChatMessageAnimatedStickerItemNode.swift:503-523 把 emojiFile 置空只留 emojiString）。
// 鸿蒙没有那套字形，改用表情包素材逐个渲染，但这类消息可以有几十个 emoji ——
// 给每个都开一条常驻 Lottie 流既慢又吃内存。这里只渲染第 0 帧、渲完立刻关掉会话
// （PixelMap 是 createPixelMap 出来的独立缓冲，不随会话释放），再按
// (emoji, 光栅尺寸) 缓存复用，重复表情与重复消息都只渲染一次。
private let animatedEmojiStaticFrameMonitor = Monitor()
private var animatedEmojiStaticFrames = HashMap<String, PixelMap>()
private var animatedEmojiStaticFrameOrder = ArrayList<String>()
private let animatedEmojiStaticFrameLimit: Int64 = 96

private func cacheStaticFrame(cacheKey: String, pixelMap: PixelMap): Unit {
    synchronized(animatedEmojiStaticFrameMonitor) {
        if (animatedEmojiStaticFrames.contains(cacheKey)) { return }
        animatedEmojiStaticFrames[cacheKey] = pixelMap
        animatedEmojiStaticFrameOrder.add(cacheKey)
        if (animatedEmojiStaticFrameOrder.size > animatedEmojiStaticFrameLimit) {
            let oldest = animatedEmojiStaticFrameOrder[0]
            animatedEmojiStaticFrameOrder.remove(0..1)
            let _ = animatedEmojiStaticFrames.remove(oldest)
        }
    }
}

/**
 * 贴纸键盘用的静帧：按 documentId 取第 0 帧。
 *
 * 键盘一屏几十个格子，不能像聊天气泡那样每个都挂一条常驻 Lottie/VP9 流
 * （全局渲染槽只有 2 个，会直接卡死）。这里只渲染第 0 帧、渲完立刻关会话，
 * 位图本身是独立缓冲，再按 (documentId, 光栅尺寸) 复用同一份缓存。
 */
// ============================================================================
// AnimationCache —— iOS 全帧压缩缓存的完整对位（AnimationCacheItemWriter/Item）
// ============================================================================
//
// iOS 之所以能让整屏表情 30~60fps 全动不卡：播放读的是**预渲染并压缩落盘的帧**
//（~0.5ms/帧），不是 rlottie 实时渲染（~3ms/帧）。48 格 × 30fps 的实时渲染
// ≈ 4 核·秒/秒，任何调度都救不回来 —— 真机实测就是解码队列谁抢到谁动、
// 其余全冻。这里落地同一方案：
//
// 文件 anim_cache/doc{id}@{raster}.acv1：
//   [u32 magic 'ACV1'][i32 raster][i32 frameCount][i32 frameDurationMs]
//   然后 frameCount × ([i32 len][deflate(BGRA raster×raster×4)])
// 存帧按 stride 归到 ~30fps（iOS 键盘网格同帧率），光栅 = 格子尺寸 × 3
//（iOS 的 3x layer scale，清晰度一致）。BGRA 大片透明区 deflate 压得极狠，
// 单帧 ~2-8KB。读取端把整文件驻内存，inflate 即帧 —— 不经过 rlottie 渲染闸。

private let ANIMATION_CACHE_MAGIC_B0: Byte = 0x41  // 'A'
private let ANIMATION_CACHE_MAGIC_B1: Byte = 0x43  // 'C'
private let ANIMATION_CACHE_MAGIC_B2: Byte = 0x56  // 'V'
private let ANIMATION_CACHE_MAGIC_B3: Byte = 0x31  // '1'

private func animCacheDir(): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    let dir = filesDir + "/anim_cache"
    try { FileIo.mkdir(dir) } catch (_: Exception) {}
    return dir
}

private func animCachePath(documentId: Int64, rasterSize: Int32): String {
    let dir = animCacheDir()
    if (dir.isEmpty()) { return "" }
    // v2：存帧步长从 ~30fps 改为对齐 16ms（60fps，用户要求与 iOS 同帧率）。
    // 旧 v1 文件自然作废（不再被打开），留在盘上无害。
    // v3：deflate → 帧间 delta + 双游程（skip/literal）。zlib 每帧要新建一套
    // 解压流对象（1440 帧/s × ~15KB ≈ 20MB/s 的 GC churn，重 GC 单轮回收
    // ~200MB、停顿 400-650ms —— 「卡」与随后的进程死亡都源于此）。v3 解码是
    // 纯仓颉紧循环写复用缓冲，**每帧零分配**；动画帧间差异小，压缩率更优。
    return dir + "/doc${documentId}@${rasterSize}.acv3"
}

private func writeI32(buf: ArrayList<Byte>, value: Int64): Unit {
    buf.add(UInt8(value & 0xFF))
    buf.add(UInt8((value >> 8) & 0xFF))
    buf.add(UInt8((value >> 16) & 0xFF))
    buf.add(UInt8((value >> 24) & 0xFF))
}

private func readI32(bytes: Array<Byte>, pos: Int64): Int64 {
    return Int64(bytes[pos]) | (Int64(bytes[pos + 1]) << 8) |
        (Int64(bytes[pos + 2]) << 16) | (Int64(bytes[pos + 3]) << 24)
}

private func deflateBytes(data: Array<Byte>): Array<Byte> {
    let srcBuf = ByteBuffer(data)
    // BestSpeed：构建是后台一次性的，但 90 帧 × 44KB 也别拖太久；
    // BGRA 透明区主导，速度档压缩率损失很小。
    let stream = CompressInputStream(srcBuf, wrap: DeflateFormat, compressLevel: BestSpeed)
    let out = ArrayList<Byte>()
    let chunk = Array<Byte>(8192, repeat: 0)
    var n = stream.read(chunk)
    while (n > 0) {
        var i = 0
        while (i < n) { out.add(chunk[i]); i = i + 1 }
        n = stream.read(chunk)
    }
    stream.close()
    let result = Array<Byte>(out.size, repeat: 0)
    var j = 0
    while (j < out.size) { result[j] = out[j]; j = j + 1 }
    return result
}

/** 解压进调用方提供的复用缓冲；成功返回 true。 */
private func inflateInto(data: Array<Byte>, dest: Array<Byte>): Bool {
    let srcBuf = ByteBuffer(data)
    let stream = DecompressInputStream(srcBuf, wrap: DeflateFormat, bufLen: 8192)
    var filled: Int64 = 0
    let chunk = Array<Byte>(8192, repeat: 0)
    var n = stream.read(chunk)
    while (n > 0 && filled < Int64(dest.size)) {
        var i = 0
        while (i < n && filled < Int64(dest.size)) {
            dest[filled] = chunk[i]
            filled = filled + 1
            i = i + 1
        }
        n = stream.read(chunk)
    }
    stream.close()
    return filled == Int64(dest.size)
}

private func inflateBytes(data: Array<Byte>, expectedSize: Int64): Array<Byte> {
    let srcBuf = ByteBuffer(data)
    let stream = DecompressInputStream(srcBuf, wrap: DeflateFormat, bufLen: 8192)
    let result = Array<Byte>(expectedSize, repeat: 0)
    var filled: Int64 = 0
    let chunk = Array<Byte>(8192, repeat: 0)
    var n = stream.read(chunk)
    while (n > 0 && filled < expectedSize) {
        var i = 0
        while (i < n && filled < expectedSize) {
            result[filled] = chunk[i]
            filled = filled + 1
            i = i + 1
        }
        n = stream.read(chunk)
    }
    stream.close()
    if (filled != expectedSize) { return Array<Byte>(0, repeat: 0) }
    return result
}

// ---- v3 帧编码：delta + 双游程 ----
//
// 令牌流：[u32 skip][u32 lit][lit 字节] 反复，直到覆盖整帧。
// 首帧的 "skip" 语义 = 保持零（透明）；后续帧 = 保持上一帧字节。
private func encodeRunsInto(prev: Array<Byte>, cur: Array<Byte>, out: ArrayList<Byte>): Unit {
    let n = Int64(cur.size)
    var pos: Int64 = 0
    while (pos < n) {
        var skip: Int64 = 0
        while (pos + skip < n && cur[pos + skip] == prev[pos + skip]) { skip = skip + 1 }
        var lit: Int64 = 0
        while (pos + skip + lit < n && (
            cur[pos + skip + lit] != prev[pos + skip + lit] ||
            // 小于 9 字节的"相同段"并进字面段：省下一对 8 字节的令牌头
            (pos + skip + lit + 9 < n && !runsAheadEqual(prev, cur, pos + skip + lit)))) {
            lit = lit + 1
        }
        writeI32(out, skip)
        writeI32(out, lit)
        var i: Int64 = 0
        while (i < lit) { out.add(cur[pos + skip + i]); i = i + 1 }
        pos = pos + skip + lit
    }
}

/** 从 at 起是否有连续 ≥9 字节相同（值得切回 skip 段）。 */
private func runsAheadEqual(prev: Array<Byte>, cur: Array<Byte>, at: Int64): Bool {
    var i: Int64 = 0
    while (i < 9) {
        if (at + i >= Int64(cur.size) || cur[at + i] != prev[at + i]) { return false }
        i = i + 1
    }
    return true
}

/** 把一帧 delta 应用到 dest（dest 当前内容 = 上一帧）。返回是否成功。 */
private func applyRuns(bytes: Array<Byte>, offset: Int64, length: Int64,
                       dest: Array<Byte>): Bool {
    var pos = offset
    let end = offset + length
    var cursor: Int64 = 0
    let n = Int64(dest.size)
    while (pos < end && cursor < n) {
        if (pos + 8 > end) { return false }
        let skip = readI32(bytes, pos)
        let lit = readI32(bytes, pos + 4)
        pos = pos + 8
        if (skip < 0 || lit < 0 || cursor + skip + lit > n || pos + lit > end) { return false }
        cursor = cursor + skip
        var i: Int64 = 0
        while (i < lit) {
            dest[cursor + i] = bytes[pos + i]
            i = i + 1
        }
        cursor = cursor + lit
        pos = pos + lit
    }
    return cursor == n && pos == end
}

// ---- 缓存文件字节的全局 LRU ----
//
// 崩溃取证（2026-08-24 17:58）：滚动 churn 下每个格子反复 open/close 播放器，
// 每次 open 都把 0.5~1.5MB 的缓存文件重新读进堆 —— Cangjie GC 单轮回收 228MB、
// 累计停顿 655ms（就是「卡」），随后进程被压死（就是「闪退」）。iOS 用 mmap
// 共享页面天然免疫。这里用 LRU 共享字节：同一文件在滚动往返中只读一次。
private let animCacheLruMonitor = Monitor()
private let animCacheLruBytes = HashMap<String, Array<Byte>>()
private let animCacheLruOrder = ArrayList<String>()
private let ANIM_CACHE_LRU_LIMIT: Int64 = 32   // ~56 × ~1MB，覆盖一屏半的格子

private func animCacheBytesFor(path: String, key: String): Array<Byte> {
    synchronized(animCacheLruMonitor) {
        if (animCacheLruBytes.contains(key)) {
            animCacheLruOrder.removeIf({ existing: String => existing == key })
            animCacheLruOrder.add(key)
            return animCacheLruBytes[key]
        }
    }
    let bytes = readLocalFileBytes(path)
    if (bytes.size == 0) { return bytes }
    synchronized(animCacheLruMonitor) {
        if (!animCacheLruBytes.contains(key)) {
            animCacheLruBytes[key] = bytes
            animCacheLruOrder.add(key)
            while (Int64(animCacheLruOrder.size) > ANIM_CACHE_LRU_LIMIT) {
                let oldest = animCacheLruOrder.remove(at: 0)
                let _ = animCacheLruBytes.remove(oldest)
            }
        }
    }
    return bytes
}

// ---- 全局帧位图 LRU ----
//
// cached 播放的最后一块高频分配：每帧 createPixelMap（native 20KB + 带
// finalizer 的包装对象，1200 次/秒的 finalizer 压力正是「重 GC 后进程死亡」
// 的余党）。动画是循环的：把 (doc@raster#帧号) → PixelMap 缓存起来，第一圈
// 建满、之后每圈全命中 —— **稳态零分配**；帧对象不可变，ArkUI 的按对象
// 纹理缓存从「显示不更新的坑」反转为「纹理直接复用的优化」。iOS 对位物：
// MultiAnimationRenderer 的帧位图缓存。上限 3000 帧 ≈ 62MB@72px。
private let animFramePixelMonitor = Monitor()
private let animFramePixelCache = HashMap<String, PixelMap>()
private let animFramePixelOrder = ArrayList<String>()
// 预算按**像素总量**而非帧数计：贴纸池化后 84px 表情帧与 160px+ 贴纸帧
// 混住同一缓存，按帧数封顶时内存上界随光栅平方漂移。
// 大小必须容纳**全部在播流的整圈帧**（~80 流 × ~30 距离帧 × 84² ≈ 17M 像素）：
// 低于工作集就是 100% 抖动 —— 真机实锤 puts=18000/run、每秒 ~2700 次
// 重解码+createPixelMap，GC 风暴把帧钟冻成 4fps（导航 9→4 全局掉速根因）。
// 20M 像素 ≈ 80MB native，稳态时整圈命中、零分配。
private let ANIM_FRAME_PIXEL_BUDGET: Int64 = 20_000_000
private let animFramePixelWeights = HashMap<String, Int64>()
private var animFramePixelUsed: Int64 = 0

private func animFramePixelGet(key: String): Option<PixelMap> {
    synchronized(animFramePixelMonitor) {
        if (animFramePixelCache.contains(key)) {
            return Some(animFramePixelCache[key])
        }
        return Option<PixelMap>.None
    }
}

private var animFramePixelPuts: Int64 = 0

private func animFramePixelPut(key: String, frame: PixelMap, pixels: Int64): Unit {
    synchronized(animFramePixelMonitor) {
        animFramePixelPuts = animFramePixelPuts + 1
        if (animFramePixelPuts % 300 == 0) {
            Hilog.info(0, "CjTelegram",
                "[FrameLRU] puts=${animFramePixelPuts} size=${animFramePixelOrder.size} used=${animFramePixelUsed}")
        }
        if (animFramePixelCache.contains(key)) { return }
        animFramePixelCache[key] = frame
        animFramePixelOrder.add(key)
        animFramePixelWeights[key] = pixels
        animFramePixelUsed = animFramePixelUsed + pixels
        while (animFramePixelUsed > ANIM_FRAME_PIXEL_BUDGET && animFramePixelOrder.size > 1) {
            let oldest = animFramePixelOrder.remove(at: 0)
            let _ = animFramePixelCache.remove(oldest)
            match (animFramePixelWeights.get(oldest)) {
                case Some(weight) =>
                    animFramePixelUsed = animFramePixelUsed - weight
                    let _ = animFramePixelWeights.remove(oldest)
                case None => ()
            }
        }
    }
}

/**
 * 读取端：文件字节经全局 LRU 共享；帧按 delta 顺序解到**复用**的状态缓冲，
 * 再写进三缓冲复用的 PixelMap —— 每帧零堆分配（唯一例外：帧尺寸变化时重建
 * 缓冲，一次性）。回绕/后退按「归零 + 顺序重放」处理（v3 是帧间 delta，
 * 没有随机访问；播放本来就是顺序 + 步进跳帧，回绕只发生在循环点）。
 */
/** 全透明帧判定（素数步长采样 alpha）：vendored rlottie 对预合成负 ip/
 *  时间重映射等特性在衔接帧渲染失败输出全透明（真机实锤：🤑 duck 180 帧
 *  3s 循环、每圈整帧消失一次；iOS 自家渲染器支持这些特性故无感）。
 *  防护策略：空帧不上屏不入缓存，保持上一帧 —— iOS 的暂停语义。 */
func animFrameLooksEmpty(bytes: Array<UInt8>): Bool {
    let n = Int64(bytes.size)
    var i: Int64 = 3
    while (i < n) {
        if (bytes[i] > 8) { return false }
        i = i + 257 * 4
    }
    return true
}

public class CachedAnimationPlayer {
    private let monitor = Monitor()
    private let bytes: Array<Byte>
    private let offsets: Array<Int64>
    private let lengths: Array<Int64>
    private let raster: Int32
    private let frameCount: Int64
    private let frameDurationMs: Int32
    private var currentIndex: Int64 = -1
    private var currentFrame: Option<PixelMap> = None<PixelMap>
    private var nextIndex: Int64 = -1
    private var nextFrame: Option<PixelMap> = None<PixelMap>
    private var closed: Bool = false
    /** delta 重放的状态缓冲：内容恒等于 decodedIndex 那一帧的原始像素。 */
    private var frameBuf: Array<Byte>
    private var decodedIndex: Int64 = -1

    init(bytes: Array<Byte>, offsets: Array<Int64>, lengths: Array<Int64>,
         raster: Int32, frameCount: Int64, frameDurationMs: Int32) {
        this.bytes = bytes
        this.offsets = offsets
        this.lengths = lengths
        this.raster = raster
        this.frameCount = frameCount
        this.frameDurationMs = frameDurationMs
        this.frameBuf = Array<Byte>(Int64(raster) * Int64(raster) * 4, repeat: 0)
    }

    public func getFrameCount(): Int64 { return this.frameCount }
    public func getFrameDurationMs(): Int32 { return this.frameDurationMs }

    public func setFrameKeyPrefix(prefix: String): Unit {
        this.frameKeyPrefix = prefix
    }

    /** 把状态缓冲推进到 index（必要时归零重放）。 */
    private func decodeTo(index: Int64): Bool {
        if (index < 0 || index >= this.frameCount) { return false }
        if (index < this.decodedIndex) {
            var i: Int64 = 0
            let n = Int64(this.frameBuf.size)
            while (i < n) { this.frameBuf[i] = 0; i = i + 1 }
            this.decodedIndex = -1
        }
        while (this.decodedIndex < index) {
            let next = this.decodedIndex + 1
            if (!applyRuns(this.bytes, this.offsets[next], this.lengths[next], this.frameBuf)) {
                return false
            }
            this.decodedIndex = next
        }
        return true
    }

    /** (doc@raster#帧号) 的缓存键前缀，构造一次。 */
    private var frameKeyPrefix: String = ""

    private func renderFrame(index: Int64): Option<PixelMap> {
        let key = "${this.frameKeyPrefix}#${index}"
        match (animFramePixelGet(key)) {
            case Some(cached) => return Some(cached)
            case None => ()
        }
        if (!this.decodeTo(index)) { return None<PixelMap> }
        // 历史 .acv3 里可能已存入 rlottie 空帧：跳过不上屏（构建端已同步防护）
        if (index > 0 && animFrameLooksEmpty(this.frameBuf)) { return None<PixelMap> }
        try {
            let created = createPixelMap(this.frameBuf, InitializationOptions(
                Size(this.raster, this.raster),
                srcPixelFormat: PixelMapFormat.Bgra8888,
                pixelFormat: PixelMapFormat.Bgra8888,
                alphaType: AlphaType.Premul
            ))
            animFramePixelPut(key, created, Int64(this.raster) * Int64(this.raster))
            return Some(created)
        } catch (_: Exception) {
            return None<PixelMap>
        }
    }

    public func prepareFirstFrame(): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            match (this.renderFrame(0)) {
                case Some(frame) =>
                    this.currentIndex = 0
                    this.currentFrame = Some(frame)
                    return true
                case None => return false
            }
        }
    }

    public func prepareNextFrame(index: Int64): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            if (this.currentIndex == index || this.nextIndex == index) { return true }
            match (this.renderFrame(index)) {
                case Some(frame) =>
                    this.nextIndex = index
                    this.nextFrame = Some(frame)
                    return true
                case None => return false
            }
        }
    }

    public func advanceTo(index: Int64): Bool {
        synchronized(this.monitor) {
            if (this.closed) { return false }
            if (this.currentIndex == index) { return true }
            if (this.nextIndex != index) { return false }
            match (this.nextFrame) {
                case Some(frame) =>
                    this.currentIndex = index
                    this.currentFrame = Some(frame)
                    this.nextIndex = -1
                    this.nextFrame = None<PixelMap>
                    return true
                case None => return false
            }
        }
    }

    public func getCurrentFrame(): Option<PixelMap> {
        synchronized(this.monitor) { return this.currentFrame }
    }

    public func close(): Unit {
        synchronized(this.monitor) {
            this.closed = true
            this.currentFrame = None<PixelMap>
            this.nextFrame = None<PixelMap>
        }
    }
}

public func openCachedAnimationPlayer(
    documentId: Int64, rasterSize: Int32
): Option<CachedAnimationPlayer> {
    let path = animCachePath(documentId, rasterSize)
    if (path.isEmpty()) { return None<CachedAnimationPlayer> }
    let bytes = animCacheBytesFor(path, "doc${documentId}@${rasterSize}")
    if (bytes.size < 16) { return None<CachedAnimationPlayer> }
    if (bytes[0] != ANIMATION_CACHE_MAGIC_B0 || bytes[1] != ANIMATION_CACHE_MAGIC_B1 ||
        bytes[2] != ANIMATION_CACHE_MAGIC_B2 || bytes[3] != ANIMATION_CACHE_MAGIC_B3) {
        return None<CachedAnimationPlayer>
    }
    let raster = readI32(bytes, 4)
    let frameCount = readI32(bytes, 8)
    let durationMs = readI32(bytes, 12)
    if (raster != Int64(rasterSize)) {
        // 光栅不符的旧文件删掉重建。
        try { FileIo.unlink(path) } catch (_: Exception) {}
        return None<CachedAnimationPlayer>
    }
    if (frameCount <= 1 || durationMs <= 0) {
        // 单帧 .acv3 = root op=1 时代的毒丸（native 已修 root out-point，
        // 重建会得到完整多帧）。删除让紧急构建重来；真静态素材经构建器
        // ≤1 帧不落盘的守卫，不会再产生这种文件。
        try { FileIo.unlink(path) } catch (_: Exception) {}
        return None<CachedAnimationPlayer>
    }
    let offsets = Array<Int64>(frameCount, repeat: 0)
    let lengths = Array<Int64>(frameCount, repeat: 0)
    var pos: Int64 = 16
    var index: Int64 = 0
    while (index < frameCount) {
        if (pos + 4 > Int64(bytes.size)) { return None<CachedAnimationPlayer> }
        let len = readI32(bytes, pos)
        pos = pos + 4
        if (len <= 0 || pos + len > Int64(bytes.size)) { return None<CachedAnimationPlayer> }
        offsets[index] = pos
        lengths[index] = len
        pos = pos + len
        index = index + 1
    }
    let player = CachedAnimationPlayer(bytes, offsets, lengths,
        rasterSize, frameCount, Int32(durationMs))
    player.setFrameKeyPrefix("doc${documentId}@${rasterSize}")
    if (!player.prepareFirstFrame()) { return None<CachedAnimationPlayer> }
    return Some(player)
}

/**
 * 构建端：把一支动画全帧渲出、压缩、落盘。后台一次性工作；每帧渲染前
 * 让路给前台（活跃流 > 0 时等待），与 iOS 低优先级 cache 写入队列同构。
 * 顺带把代表帧写进静态帧缓存（首屏直出用）。
 */
// ============================================================================
// anim_cache 磁盘治理（iOS AnimationCache 尺寸管理的对位）
// ============================================================================
private var animCacheMaintenanceDone: Bool = false
private var emojiCacheMaintenanceDone: Bool = false
private let animCacheMaintenanceMonitor = Monitor()
/** 贴纸级缓存（@136）的磁盘预算；超限先删不在保留集里的，再删任意。 */
/** 渐进可播（iOS AnimationCacheItemWriter 对位）：编码到第 24 帧先原子落
 *  一个短版 .acv3，格子几百毫秒内即开播短循环；全量建完原子替换，
 *  播放端探测到帧数变多后升格。短动画（≲2×快段）不值得两次写盘。 */
let ANIM_QUICK_SEGMENT_FRAMES: Int64 = 24
/** .acv3 存储帧数封顶：300 帧 webm 单文件 4-8MB(实测均值 2.6MB、一轮浏览落盘
 *  1.75GB)，400MB 预算只装得下 ~150 个 → 预算删/重建死循环。90 帧等距抽帧 +
 *  时长同步放大(观感=低帧率循环，与 ImageAnimator 读端 maxFrames=90 同款、
 *  iOS 网格同样降档)，文件体积与构建时长同步 ÷(total/90)。 */
let ANIM_STORE_MAX_FRAMES: Int64 = 90
/** 全链路诊断日志（[ChainTrace] 逐 need 明细）总开关：默认关。 */
public let CHAIN_TRACE_LOGS: Bool = false
/** 冷(全量)队列深度上限：超出砍最旧 —— 滚走的页面再可见时 need 会重发。 */
let ANIM_COLD_QUEUE_CAP: Int64 = 48
/** 在建目标集（"doc@raster"）：快段(紧急道)与全量(冷道)对同一目标并发执行时
 *  会交错写同一个 .tmp，rename 后成为带坏帧的正式文件（真机「聊天气泡贴纸
 *  空白帧」根因）。同目标只允许一个构建在写，后到者直接让行。 */
private let animCacheBuildingMonitor = Monitor()
private let animCacheBuilding = HashSet<String>()

private let STICKER_ANIM_CACHE_BUDGET_BYTES: Int64 = 500 * 1024 * 1024
private let STICKER_ANIM_CACHE_TRIM_TARGET: Int64 = 400 * 1024 * 1024
/** emoji @84 缓存的独立预算：单文件 ~1.5MB 但 doc 基数无界（聊天里刷到的
 *  custom emoji 都会建），真机实锤堆到 2665 个/3.85GB —— 必须设限。 */
private let EMOJI_ANIM_CACHE_BUDGET_BYTES: Int64 = 800 * 1024 * 1024
private let EMOJI_ANIM_CACHE_TRIM_TARGET: Int64 = 600 * 1024 * 1024

/** 贴纸档光栅（与 StickerKeyboardPanel.probeAnimCache 的探测序一致，
 *  去重时保留序里靠前的那个 —— 即探测实际会命中的文件）。
 *  @84 是 emoji 面板专属（路径硬编码），永不参与去重/淘汰。 */
private let STICKER_ANIM_RASTER_ORDER: Array<Int64> = [136, 142, 126, 116, 174]

/**
 * 每会话一次的 anim_cache 清理：
 *   1) 无条件删除遗留 @204 文件（旧光栅，openCached 永远打不开，纯死重 —
 *      历史事故 3.5GB 的主力）；
 *   2) 按 doc 去重：同一 doc 的多个贴纸档光栅只留探测序首选（历史上
 *      驱动管线按格子尺寸建、RN 管线按 @136 建，同 doc 堆出 2-4 份 ——
 *      真机实锤 5.5GB/3421 文件的主力）；
 *   3) 贴纸档全光栅总量超 500MB 时，先删 keepDocs 之外的，仍超再删任意，
 *      直到降回 400MB。（旧版只统计 @136，@116 等存量在预算视野外失控。）
 * 调用方给 keepDocs = 当前贴纸行表宇宙（已装/精选/最近），后台线程执行。
 */
public func maintainStickerAnimCacheBudget(keepDocs: HashSet<Int64>): Unit {
    synchronized(animCacheMaintenanceMonitor) {
        if (animCacheMaintenanceDone) { return }
        animCacheMaintenanceDone = true
    }
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return }
    let dir = filesDir + "/anim_cache"
    var names = Array<String>(0, repeat: "")
    try { names = FileIo.listFile(dir) } catch (_: Exception) { return }
    // 名字形如 doc{id}@{raster}.acv3：扫出 doc 与 raster
    var legacyRemoved: Int64 = 0
    let parsed = ArrayList<(String, Int64, Int64)>() // name, docId, raster
    for (name in names) {
        if (name.contains("@204")) {
            try { FileIo.unlink(dir + "/" + name); legacyRemoved = legacyRemoved + 1 } catch (_: Exception) {}
            continue
        }
        if (name.endsWith(".tmp")) {
            try { FileIo.unlink(dir + "/" + name); legacyRemoved = legacyRemoved + 1 } catch (_: Exception) {}
            continue
        }
        if (!name.startsWith("doc") || !name.endsWith(".acv3")) { continue }
        var idText = ""
        var rasterText = ""
        var seenPrefix: Int64 = 0
        var afterAt = false
        for (rune in name.toRuneArray()) {
            if (seenPrefix < 3) { seenPrefix = seenPrefix + 1; continue }
            if (rune == r'@') { afterAt = true; continue }
            if (rune == r'.') { break }
            if (afterAt) { rasterText = rasterText + "${rune}" }
            else { idText = idText + "${rune}" }
        }
        let docId = (try { Int64.parse(idText) } catch (_: Exception) { 0 })
        let raster = (try { Int64.parse(rasterText) } catch (_: Exception) { 0 })
        if (docId == 0 || raster == 0) { continue }
        parsed.add((name, docId, raster))
    }
    // 第 2 步：按 doc 去重贴纸档光栅（@84 是 emoji 专属，不参与）
    let bestRaster = HashMap<Int64, Int64>() // docId -> 探测序最优 raster
    for (entry in parsed) {
        var pri: Int64 = -1
        var i: Int64 = 0
        while (i < Int64(STICKER_ANIM_RASTER_ORDER.size)) {
            if (STICKER_ANIM_RASTER_ORDER[i] == entry[2]) { pri = i; break }
            i = i + 1
        }
        if (pri < 0) { continue }
        var keep = true
        if (bestRaster.contains(entry[1])) {
            let cur = bestRaster[entry[1]]
            var curPri: Int64 = 0
            i = 0
            while (i < Int64(STICKER_ANIM_RASTER_ORDER.size)) {
                if (STICKER_ANIM_RASTER_ORDER[i] == cur) { curPri = i; break }
                i = i + 1
            }
            keep = pri < curPri
        }
        if (keep) { bestRaster[entry[1]] = entry[2] }
    }
    var dupRemoved: Int64 = 0
    var total: Int64 = 0
    let candidates = ArrayList<(String, Int64, Int64)>() // path, size, docId
    for (entry in parsed) {
        var inOrder = false
        for (r in STICKER_ANIM_RASTER_ORDER) {
            if (r == entry[2]) { inOrder = true; break }
        }
        if (!inOrder) { continue } // @84 等：不删、不计预算
        let path = dir + "/" + entry[0]
        if (bestRaster.contains(entry[1]) && bestRaster[entry[1]] != entry[2]) {
            try { FileIo.unlink(path); dupRemoved = dupRemoved + 1 } catch (_: Exception) {}
            continue
        }
        var size: Int64 = 0
        try { size = FileIo.stat(path).size } catch (_: Exception) { continue }
        total = total + size
        candidates.add((path, size, entry[1]))
    }
    Hilog.info(0, "CjTelegram",
        "[AnimCacheGC] files=${candidates.size} total=${total / 1048576}MB legacy204=${legacyRemoved} dupRemoved=${dupRemoved}")
    if (total <= STICKER_ANIM_CACHE_BUDGET_BYTES) { return }
    var freed: Int64 = 0
    // 第一轮：删不在保留集里的
    for (entry in candidates) {
        if (total - freed <= STICKER_ANIM_CACHE_TRIM_TARGET) { break }
        if (keepDocs.contains(entry[2])) { continue }
        try { FileIo.unlink(entry[0]); freed = freed + entry[1] } catch (_: Exception) {}
    }
    // 第二轮：仍超预算就删任意（下次可见时会重建）
    if (total - freed > STICKER_ANIM_CACHE_BUDGET_BYTES) {
        for (entry in candidates) {
            if (total - freed <= STICKER_ANIM_CACHE_TRIM_TARGET) { break }
            try { FileIo.unlink(entry[0]); freed = freed + entry[1] } catch (_: Exception) {}
        }
    }
    Hilog.info(0, "CjTelegram", "[AnimCacheGC] freed=${freed / 1048576}MB")
}

/**
 * emoji @84 缓存预算（贴纸预算的姊妹段，同样每会话一次、后台线程）。
 * 无 keep 集：mtime 即构建时间，最近构建 ≈ 最近被需要，超预算删最旧的；
 * 被删的 doc 下次可见时 ETS 发 need 重建，自愈。
 */
public func maintainEmojiAnimCacheBudget(): Unit {
    synchronized(animCacheMaintenanceMonitor) {
        if (emojiCacheMaintenanceDone) { return }
        emojiCacheMaintenanceDone = true
    }
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return }
    let dir = filesDir + "/anim_cache"
    var names = Array<String>(0, repeat: "")
    try { names = FileIo.listFile(dir) } catch (_: Exception) { return }
    let files = ArrayList<(String, Int64, Int64)>() // path, size, mtime
    var total: Int64 = 0
    for (name in names) {
        if (!name.startsWith("doc") || !name.endsWith("@84.acv3")) { continue }
        let path = dir + "/" + name
        var size: Int64 = 0
        var mtime: Int64 = 0
        try {
            let st = FileIo.stat(path)
            size = st.size
            mtime = st.mtime
        } catch (_: Exception) { continue }
        total = total + size
        files.add((path, size, mtime))
    }
    if (total <= EMOJI_ANIM_CACHE_BUDGET_BYTES) { return }
    sort<(String, Int64, Int64), Int64>(
        files, key: {e: (String, Int64, Int64) => e[2]}, stable: true)
    var freed: Int64 = 0
    for (entry in files) {
        if (total - freed <= EMOJI_ANIM_CACHE_TRIM_TARGET) { break }
        try { FileIo.unlink(entry[0]); freed = freed + entry[1] } catch (_: Exception) {}
    }
    Hilog.info(0, "CjTelegram",
        "[AnimCacheGC] emoji84 files=${files.size} total=${total / 1048576}MB freed=${freed / 1048576}MB")
}

/** 构建缓冲容量保障：不足按 2 倍增长（单次整段拷贝，无 ArrayList 逐次扩容）。 */
private func ensureCacheBuf(buf: Array<Byte>, need: Int64): Array<Byte> {
    if (need <= Int64(buf.size)) { return buf }
    var cap = Int64(buf.size) * 2
    if (cap < need) { cap = need }
    let grown = Array<Byte>(cap, repeat: 0)
    var i: Int64 = 0
    while (i < Int64(buf.size)) { grown[i] = buf[i]; i = i + 1 }
    return grown
}

/** 小端 i32 写入缓冲，返回新尾指针。 */
private func writeI32Buf(buf: Array<Byte>, at: Int64, value: Int64): Int64 {
    buf[at] = UInt8(value & 0xFF)
    buf[at + 1] = UInt8((value >> 8) & 0xFF)
    buf[at + 2] = UInt8((value >> 16) & 0xFF)
    buf[at + 3] = UInt8((value >> 24) & 0xFF)
    return at + 4
}

public func buildAnimationCacheFile(
    documentId: Int64, localPath: String, isVideo: Bool, rasterSize: Int32,
    quickOnly!: Bool = false
): Bool {
    if (documentId == 0 || localPath.size == 0) { return false }
    // 快段文件（≤24 帧）只是渐进首段：继续建全量替换；帧数更多才算已完成
    let framesOnDisk = animCacheFrameCount(documentId, rasterSize)
    if (framesOnDisk > ANIM_QUICK_SEGMENT_FRAMES) { return true }
    // 快段任务：盘上已有快段就不重建（全量升级归冷队列）
    if (quickOnly && framesOnDisk >= ANIM_QUICK_SEGMENT_FRAMES) { return true }
    let buildKey = "${documentId}@${rasterSize}"
    synchronized(animCacheBuildingMonitor) {
        if (animCacheBuilding.contains(buildKey)) {
            // 同目标已有构建在写（快段/全量并发是常态设计）：让行。
            // 对快段任务而言，另一条全量构建到第 24 帧同样会落快段文件。
            return true
        }
        let _ = animCacheBuilding.add(buildKey)
    }
    try {
        return buildAnimationCacheFileLocked(
            documentId, localPath, isVideo, rasterSize, quickOnly)
    } finally {
        synchronized(animCacheBuildingMonitor) {
            animCacheBuilding.remove(buildKey)
        }
    }
}

private func buildAnimationCacheFileLocked(
    documentId: Int64, localPath: String, isVideo: Bool, rasterSize: Int32,
    quickOnly: Bool
): Bool {
    var stopEarly = false
    // 输出缓冲预分配 + 尾指针：ArrayList 逐字节 add 的反复扩容拷贝是
    // 构建期堆分配大户（真机 trace：20s 内 GC 5.5s 的成因之一）。
    var outBuf = Array<Byte>(4 * 1024 * 1024, repeat: 0)
    var outLen: Int64 = 0
    var storedCount: Int64 = 0
    var storedDuration: Int64 = 33
    let expected = Int64(rasterSize) * Int64(rasterSize) * 4
    let buffer = Array<Byte>(expected, repeat: 0)
    // delta 编码的参照帧：首帧相对全零（透明）。
    let prevBuffer = Array<Byte>(expected, repeat: 0)
    // native 编码输出区：最坏 = 整帧全字面（8 + expected），留余量
    let encodeScratch = Array<Byte>(expected + 4096, repeat: 0)
    let frameTokens = ArrayList<Byte>()
    var representativeStored = false

    if (isVideo) {
        match (openTelegramVideoSticker(localPath, rasterSize)) {
            case Some(session) =>
                let player = StreamingVideoStickerPlayer(documentId, session, rasterSize)
                let total = player.getFrameCount()
                var raw = Int64(player.getFrameDurationMs())
                if (raw < 1) { raw = 33 }
                var stride = (16 + raw / 2) / raw
                if (stride < 1) { stride = 1 }
                // 存储帧数封顶（磁盘/构建时长的硬约束，见 ANIM_STORE_MAX_FRAMES）
                let capStride = (total + ANIM_STORE_MAX_FRAMES - 1) / ANIM_STORE_MAX_FRAMES
                if (capStride > stride) { stride = capStride }
                storedDuration = raw * stride
                if (!player.prepareFirstFrame()) { player.close(); return false }
                var index: Int64 = 0
                while (index < total && !stopEarly) {
                    // 快段（前 24 帧）零等待零节流 —— 可见格子 ≤2s 起播的预算；
                    // 全量阶段：live 流让路 + 紧急队列让路 + 2ms/帧压平尖峰。
                    if (storedCount >= ANIM_QUICK_SEGMENT_FRAMES) {
                        while (getKeyboardFrameClockStreamCount() > 96) {
                            sleep(Duration.millisecond * 300)
                        }
                        while (!quickOnly && animUrgentDepth() > 0) {
                            sleep(Duration.millisecond * 50)
                        }
                        sleep(Duration.millisecond * 2)
                    }
                    // VP9 只能顺序解码：逐帧推进，按 stride 存
                    if (index > 0) {
                        let _ = player.prepareNextFrame(index)
                        if (!player.advanceTo(index)) { break }
                    }
                    if (index % stride == 0) {
                        match (player.getCurrentFrame()) {
                            case Some(frame) =>
                                frame.readPixelsToBuffer(buffer)
                                if (storedCount > 0 && animFrameLooksEmpty(buffer)) {
                                    // rlottie 空帧不入库（见 animFrameLooksEmpty）
                                    index = index + 1
                                    continue
                                }
                                // 编码下沉 native（2-3×）；失败回退仓颉实现
                                var written = nativeEncodeDeltaRuns(prevBuffer, buffer, encodeScratch)
                                if (written < 0) {
                                    frameTokens.clear()
                                    encodeRunsInto(prevBuffer, buffer, frameTokens)
                                    outBuf = ensureCacheBuf(outBuf, outLen + 4 + Int64(frameTokens.size))
                                    outLen = writeI32Buf(outBuf, outLen, Int64(frameTokens.size))
                                    for (byteValue in frameTokens) { outBuf[outLen] = byteValue; outLen = outLen + 1 }
                                } else {
                                    outBuf = ensureCacheBuf(outBuf, outLen + 4 + written)
                                    outLen = writeI32Buf(outBuf, outLen, written)
                                    var wi: Int64 = 0
                                    while (wi < written) { outBuf[outLen] = encodeScratch[wi]; outLen = outLen + 1; wi = wi + 1 }
                                }
                                var ci: Int64 = 0
                                while (ci < expected) { prevBuffer[ci] = buffer[ci]; ci = ci + 1 }
                                storedCount = storedCount + 1
                                if (storedCount == ANIM_QUICK_SEGMENT_FRAMES &&
                                    total / stride >= ANIM_QUICK_SEGMENT_FRAMES * 2) {
                                    let _ = writeAnimCacheFileAtomic(documentId, rasterSize,
                                        storedCount, storedDuration, outBuf, outLen, quick: true)
                                    if (quickOnly) { stopEarly = true }
                                }
                                if (!representativeStored && storedCount >= 2) {
                                    representativeStored = true
                                    storeStickerStaticFrame(documentId, rasterSize, frame,
                                        representative: true)
                                }
                            case None => break
                        }
                    }
                    index = index + 1
                }
                player.close()
            case None => return false
        }
    } else {
        let fileBytes = readLocalFileBytes(localPath)
        match (openStreamingLottie(fileBytes, "acache_${documentId}_${rasterSize}", rasterSize)) {
            case Some(player) =>
                let total = player.getFrameCount()
                var raw = Int64(player.getFrameDurationMs())
                if (raw < 1) { raw = 16 }
                var stride = (16 + raw / 2) / raw
                if (stride < 1) { stride = 1 }
                let capStride = (total + ANIM_STORE_MAX_FRAMES - 1) / ANIM_STORE_MAX_FRAMES
                if (capStride > stride) { stride = capStride }
                storedDuration = raw * stride
                Hilog.info(0, "CjTelegram",
                    "[AnimCache] building doc=${documentId} total=${total} stride=${stride} streams=${getKeyboardFrameClockStreamCount()}")
                var index: Int64 = 0
                while (index < total && !stopEarly) {
                    if (storedCount >= ANIM_QUICK_SEGMENT_FRAMES) {
                        while (getKeyboardFrameClockStreamCount() > 96) {
                            sleep(Duration.millisecond * 300)
                        }
                        while (!quickOnly && animUrgentDepth() > 0) {
                            sleep(Duration.millisecond * 50)
                        }
                        sleep(Duration.millisecond * 2)
                    }
                    if (!player.seekTo(index)) { break }
                    match (player.getCurrentFrame()) {
                        case Some(frame) =>
                            frame.readPixelsToBuffer(buffer)
                            if (storedCount > 0 && animFrameLooksEmpty(buffer)) {
                                index = index + stride
                                continue
                            }
                            var written = nativeEncodeDeltaRuns(prevBuffer, buffer, encodeScratch)
                            if (written < 0) {
                                frameTokens.clear()
                                encodeRunsInto(prevBuffer, buffer, frameTokens)
                                outBuf = ensureCacheBuf(outBuf, outLen + 4 + Int64(frameTokens.size))
                                outLen = writeI32Buf(outBuf, outLen, Int64(frameTokens.size))
                                for (byteValue in frameTokens) { outBuf[outLen] = byteValue; outLen = outLen + 1 }
                            } else {
                                outBuf = ensureCacheBuf(outBuf, outLen + 4 + written)
                                outLen = writeI32Buf(outBuf, outLen, written)
                                var wi: Int64 = 0
                                while (wi < written) { outBuf[outLen] = encodeScratch[wi]; outLen = outLen + 1; wi = wi + 1 }
                            }
                            var ci: Int64 = 0
                            while (ci < expected) { prevBuffer[ci] = buffer[ci]; ci = ci + 1 }
                            storedCount = storedCount + 1
                            if (storedCount == ANIM_QUICK_SEGMENT_FRAMES &&
                                total / stride >= ANIM_QUICK_SEGMENT_FRAMES * 2) {
                                let _ = writeAnimCacheFileAtomic(documentId, rasterSize,
                                    storedCount, storedDuration, outBuf, outLen, quick: true)
                                if (quickOnly) { stopEarly = true }
                            }
                            if (!representativeStored && index >= total / 3) {
                                representativeStored = true
                                storeStickerStaticFrame(documentId, rasterSize, frame,
                                    representative: true)
                            }
                        case None => break
                    }
                    index = index + stride
                }
                player.close()
            case None => return false
        }
    }
    if (storedCount <= 1) { return false }
    if (stopEarly) { return true } // 快段任务：快段已原子落盘，全量归冷队列
    return writeAnimCacheFileAtomic(
        documentId, rasterSize, storedCount, storedDuration, outBuf, outLen, quick: false)
}

/** 读 .acv3 头部的帧数字段；文件缺失/损坏返回 0。 */
private func animCacheFrameCount(documentId: Int64, rasterSize: Int32): Int64 {
    let path = animCachePath(documentId, rasterSize)
    if (path.isEmpty()) { return 0 }
    try {
        if (!FileIo.access(path)) { return 0 }
        let file = FileIo.open(path, mode: 0o0)
        let head = Array<Byte>(16, repeat: 0)
        let n = FileIo.read(file.fd, head)
        FileIo.close(file)
        if (n < 16) { return 0 }
        if (head[0] != ANIMATION_CACHE_MAGIC_B0 || head[1] != ANIMATION_CACHE_MAGIC_B1 ||
            head[2] != ANIMATION_CACHE_MAGIC_B2 || head[3] != ANIMATION_CACHE_MAGIC_B3) { return 0 }
        return readI32(head, 8)
    } catch (_: Exception) { return 0 }
}

/** .acv3 原子落盘：写 .tmp 再 rename —— ETS 侧（格子 1.5s 轮询 / RN 90 拍
 *  重试）在构建期间反复尝试打开最终路径，直接写会被读到半截文件，且会话
 *  在 open 时固化帧表，从此循环播放坏尾帧（真机「空白帧」实锤）。 */
private func writeAnimCacheFileAtomic(
    documentId: Int64, rasterSize: Int32, storedCount: Int64, storedDuration: Int64,
    outBuf: Array<Byte>, outLen: Int64, quick!: Bool
): Bool {
    let header = ArrayList<Byte>()
    header.add(ANIMATION_CACHE_MAGIC_B0)
    header.add(ANIMATION_CACHE_MAGIC_B1)
    header.add(ANIMATION_CACHE_MAGIC_B2)
    header.add(ANIMATION_CACHE_MAGIC_B3)
    writeI32(header, Int64(rasterSize))
    writeI32(header, storedCount)
    writeI32(header, storedDuration)
    let path = animCachePath(documentId, rasterSize)
    if (path.isEmpty()) { return false }
    let tmpPath = path + ".tmp"
    try {
        let file = FileIo.open(tmpPath, mode: 0o1101)
        let headBytes = Array<Byte>(header.size, repeat: 0)
        var hi = 0
        while (hi < header.size) { headBytes[hi] = header[hi]; hi = hi + 1 }
        FileIo.write(file.fd, headBytes)
        let body = Array<Byte>(outLen, repeat: 0)
        var bi: Int64 = 0
        while (bi < outLen) { body[bi] = outBuf[bi]; bi = bi + 1 }
        FileIo.write(file.fd, body)
        FileIo.close(file)
        try {
            FileIo.rename(tmpPath, path)
        } catch (_: Exception) {
            // 目标已存在（快段升级全量）时部分实现不覆盖：先删再挪
            try { FileIo.unlink(path) } catch (_: Exception) {}
            FileIo.rename(tmpPath, path)
        }
        if (quick) {
            Hilog.info(0, "CjTelegram",
                "[AnimCache] quick doc=${documentId} frames=${storedCount}")
        } else {
            Hilog.info(0, "CjTelegram",
                "[AnimCache] built doc=${documentId} frames=${storedCount} bytes=${16 + outLen}")
        }
        return true
    } catch (e: Exception) {
        try { FileIo.unlink(tmpPath) } catch (_: Exception) {}
        Hilog.info(0, "CjTelegram", "[AnimCache] write failed doc=${documentId}: ${e}")
        return false
    }
}

// ---- 后台构建队列：单 worker，去重，构建内部自带前台让路 ----
private let animCacheBuildMonitor = Monitor()
/** 冷队列：全量构建（预取补债 + 快段后的升级）。 */
private let animCacheBuildQueue = ArrayList<(Int64, String, Bool, Int32, Int64)>()
/** 紧急队列：可见格子的快段（24 帧）构建，专用 worker、免节流，
 *  绝不被冷构建阻塞 —— 「所有表情 ≤2s 起播」的关键通道。 */
private let animCacheUrgentQueue = ArrayList<(Int64, String, Bool, Int32, Int64)>()
private let animCacheBuildSeen = HashSet<Int64>()
private var animCacheWorkerStarted = false

/** 紧急（快段）队列当前深度 —— 冷构建让路判据。 */
private func animUrgentDepth(): Int64 {
    synchronized(animCacheBuildMonitor) {
        return animCacheUrgentQueue.size
    }
}

private func animQueueContains(
    queue: ArrayList<(Int64, String, Bool, Int32, Int64)>, docId: Int64): Int64 {
    var qi: Int64 = 0
    while (qi < queue.size) {
        if (queue[qi][0] == docId) { return qi }
        qi = qi + 1
    }
    return -1
}

public func requestAnimationCacheBuild(
    documentId: Int64, localPath: String, isVideo: Bool, rasterSize: Int32,
    urgent!: Bool = false
): Unit {
    if (documentId == 0 || localPath.size == 0 || rasterSize <= 0) { return }
    // 已建成的直接跳过：seen 集是进程级的，重启后会把上千个已建项
    // 重新排队。快段文件（≤24 帧）不算建成：放行完成全量升级。
    let framesOnDisk = animCacheFrameCount(documentId, rasterSize)
    if (framesOnDisk > ANIM_QUICK_SEGMENT_FRAMES) { return }
    var startWorker = false
    synchronized(animCacheBuildMonitor) {
        if (urgent) {
            // 可见格子：快段进紧急队列（已有快段文件就不用再快建），
            // 全量挪到冷队列队首（排在预取补债之前）。
            if (framesOnDisk < ANIM_QUICK_SEGMENT_FRAMES &&
                animQueueContains(animCacheUrgentQueue, documentId) < 0) {
                animCacheUrgentQueue.add((documentId, localPath, isVideo, rasterSize,
                    DateTime.now().toUnixTimeStamp().toMilliseconds()))
            }
            let coldIdx = animQueueContains(animCacheBuildQueue, documentId)
            if (coldIdx > 0) {
                let task = animCacheBuildQueue.remove(at: coldIdx)
                animCacheBuildQueue.add(task, at: 0)
            } else if (coldIdx < 0) {
                // 深度上限：砍队尾（最旧）—— 全量积压曾到 154 深/等待 283s，
                // 2 条冷 worker 连烧数分钟 CPU（驻留态 ~4 核的主源）。
                while (animCacheBuildQueue.size >= ANIM_COLD_QUEUE_CAP) {
                    let _ = animCacheBuildQueue.remove(at: animCacheBuildQueue.size - 1)
                }
                animCacheBuildQueue.add((documentId, localPath, isVideo, rasterSize,
                    DateTime.now().toUnixTimeStamp().toMilliseconds()), at: 0)
            }
            let _ = animCacheBuildSeen.add(documentId)
        } else {
            // 非紧急（预取）：本会话试过一次就不再排 —— 失败重试交给可见 need。
            if (!animCacheBuildSeen.contains(documentId)) {
                let _ = animCacheBuildSeen.add(documentId)
                animCacheBuildQueue.add((documentId, localPath, isVideo, rasterSize,
                    DateTime.now().toUnixTimeStamp().toMilliseconds()))
            }
        }
        animCacheBuildMonitor.notifyAll()
        if (!animCacheWorkerStarted) {
            animCacheWorkerStarted = true
            startWorker = true
        }
    }
    if (startWorker) {
        // 紧急 worker ×6：只做快段（~0.5s/个，免节流）——一屏 40 个冷格子
        // 6 路并行 ~2s 内全部起播。冷 worker ×2：全量构建（2ms/帧节流），
        // 上限收窄防止和紧急道抢 CPU。
        var ui = 0
        while (ui < 6) {
            ui = ui + 1
            let _ = spawn {
                while (true) {
                    var task = Option<(Int64, String, Bool, Int32, Int64)>.None
                    synchronized(animCacheBuildMonitor) {
                        while (animCacheUrgentQueue.size == 0) {
                            let _ = animCacheBuildMonitor.wait(timeout: Duration.millisecond * 500)
                        }
                        // LIFO：最新的可见请求最先（用户正看着的页面永远优先），
                        // 且丢弃排队超 60s 的陈旧任务 —— 滚走的页面再可见时
                        // need 会重发（needSent 30s 重置 + 20s 限频兜底）。
                        // FIFO 曾让当前页排在几百个陈旧任务后面等 34~40s。
                        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                        while (animCacheUrgentQueue.size > 0) {
                            let cand = animCacheUrgentQueue.remove(at: animCacheUrgentQueue.size - 1)
                            if (nowMs - cand[4] <= 60_000) {
                                task = Some(cand)
                                break
                            }
                            Hilog.info(0, "CjTelegram",
                                "[ChainTrace] quick-drop-stale doc=${cand[0]} ageMs=${nowMs - cand[4]}")
                        }
                    }
                    match (task) {
                        case Some((docId, path, video, raster, enqMs)) =>
                            try {
                                let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                                let ok = buildAnimationCacheFile(docId, path, video, raster,
                                    quickOnly: true)
                                let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                                Hilog.info(0, "CjTelegram",
                                    "[ChainTrace] quick-built doc=${docId} ok=${ok} waitMs=${t0 - enqMs} ms=${t1 - t0}")
                            } catch (e: Exception) {
                                Hilog.info(0, "CjTelegram", "[AnimCache] quick failed ${docId}: ${e}")
                            }
                        case None => ()
                    }
                }
            }
        }
        var ci = 0
        while (ci < 2) {
            ci = ci + 1
            let _ = spawn {
                while (true) {
                    // 紧急队列有活先让路：冷全量与快段抢核会把可见格子的
                    // ≤2s 起播预算吃掉（真机：快段被拖到 1.2~3.2s）。
                    while (animUrgentDepth() > 0) {
                        sleep(Duration.millisecond * 100)
                    }
                    var task = Option<(Int64, String, Bool, Int32, Int64)>.None
                    var depth: Int64 = 0
                    synchronized(animCacheBuildMonitor) {
                        while (animCacheBuildQueue.size == 0) {
                            let _ = animCacheBuildMonitor.wait(timeout: Duration.millisecond * 500)
                        }
                        // 丢弃排队超 120s 的陈旧全量任务（页面早滚走了）
                        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
                        while (animCacheBuildQueue.size > 0) {
                            let cand = animCacheBuildQueue.remove(at: 0)
                            if (nowMs - cand[4] <= 120_000) {
                                task = Some(cand)
                                break
                            }
                        }
                        depth = animCacheBuildQueue.size
                    }
                    match (task) {
                        case Some((docId, path, video, raster, enqMs)) =>
                            try {
                                let t0 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                                Hilog.info(0, "CjTelegram",
                                    "[ChainTrace] build-start doc=${docId} waitMs=${t0 - enqMs} depth=${depth}")
                                let ok = buildAnimationCacheFile(docId, path, video, raster)
                                let t1 = DateTime.now().toUnixTimeStamp().toMilliseconds()
                                Hilog.info(0, "CjTelegram",
                                    "[ChainTrace] build-end doc=${docId} ok=${ok} ms=${t1 - t0}")
                            } catch (e: Exception) {
                                Hilog.info(0, "CjTelegram", "[AnimCache] build failed ${docId}: ${e}")
                            }
                        case None => ()
                    }
                }
            }
        }
    }
}

// ============================================================================
// 静态帧磁盘缓存 —— iOS AnimationCache 的对位
// ============================================================================
//
// 内存帧缓存（animatedEmojiStaticFrames）进程一死就没了：面板每次冷启动都要
// 对每个格子重开一次 lottie 会话（gunzip + JSON 解析 + 渲一帧），且渲染闸只有
// 2 槽 —— 格子肉眼可见地挨个蹦出来。iOS 的帧是磁盘 AnimationCache 预渲的，
// 打开面板就是读文件贴图，看不出加载。这里存 BGRA 裸位图（raster² × 4 字节，
// 120px ≈ 57KB），读回来一次 createPixelMap 就能上屏，不再碰解码器。
private func staticFrameDiskDir(): String {
    let filesDir = getAppFilesDir()
    if (filesDir.isEmpty()) { return "" }
    let dir = filesDir + "/static_frames"
    try { FileIo.mkdir(dir) } catch (_: Exception) {}
    return dir
}

private func loadStaticFrameFromDisk(cacheKey: String, rasterSize: Int32): Option<PixelMap> {
    let dir = staticFrameDiskDir()
    if (dir.isEmpty()) { return None<PixelMap> }
    let bytes = readLocalFileBytes(dir + "/" + cacheKey + ".bgra")
    let expected = Int64(rasterSize) * Int64(rasterSize) * 4
    if (Int64(bytes.size) != expected) { return None<PixelMap> }
    return Some(createPixelMap(bytes, InitializationOptions(
        Size(rasterSize, rasterSize),
        srcPixelFormat: PixelMapFormat.Bgra8888,
        pixelFormat: PixelMapFormat.Bgra8888,
        alphaType: AlphaType.Premul
    )))
}

private func storeStaticFrameToDisk(cacheKey: String, frame: PixelMap, rasterSize: Int32): Unit {
    let _ = spawn {
        try {
            let dir = staticFrameDiskDir()
            if (dir.isEmpty()) { return }
            let expected = Int64(rasterSize) * Int64(rasterSize) * 4
            let buffer = Array<UInt8>(expected, repeat: 0)
            frame.readPixelsToBuffer(buffer)
            let f = FileIo.open(dir + "/" + cacheKey + ".bgra", mode: 0o1101)
            FileIo.write(f.fd, buffer)
            FileIo.close(f)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[StaticFrameCache] write failed ${cacheKey}: ${e}")
        }
    }
}

/**
 * 只查缓存（内存 → 磁盘），**不开解码会话**。
 * 面板格子的首帧快路径：命中直接上屏（几毫秒），播放流在背后接管 ——
 * gunzip + 解析的开销藏在已经画出来的帧后面，对位 iOS 打开面板时
 * AnimationCache 直出、看不见加载的行为。
 */
public func loadStickerStaticFrameCached(
    documentId: Int64,
    rasterSize: Int32,
    representative!: Bool = false
): Option<PixelMap> {
    if (documentId == 0) { return None<PixelMap> }
    let cacheKey = "doc${documentId}@${rasterSize}" +
        if (representative) { "#representative" } else { "#first" }
    synchronized(animatedEmojiStaticFrameMonitor) {
        if (animatedEmojiStaticFrames.contains(cacheKey)) {
            return Some(animatedEmojiStaticFrames[cacheKey])
        }
    }
    match (loadStaticFrameFromDisk(cacheKey, rasterSize)) {
        case Some(cached) =>
            cacheStaticFrame(cacheKey, cached)
            return Some(cached)
        case None => return None<PixelMap>
    }
}

/**
 * 播放流送来的首帧回存缓存。播放中的格子从不走 loadStickerStaticFrame
 *（那条路会白开一次会话），不回存的话它们的磁盘缓存永远是空的，
 * 下次冷启动照样要等会话打开才有画面。
 */
public func storeStickerStaticFrame(
    documentId: Int64,
    rasterSize: Int32,
    frame: PixelMap,
    representative!: Bool = false
): Unit {
    if (documentId == 0) { return }
    let cacheKey = "doc${documentId}@${rasterSize}" +
        if (representative) { "#representative" } else { "#first" }
    cacheStaticFrame(cacheKey, frame)
    storeStaticFrameToDisk(cacheKey, frame, rasterSize)
}

public func loadStickerStaticFrame(
    documentId: Int64,
    localPath: String,
    isVideo: Bool,
    rasterSize: Int32,
    representative!: Bool = false
): Option<PixelMap> {
    if (documentId == 0 || localPath.size == 0) { return None<PixelMap> }
    let cacheKey = "doc${documentId}@${rasterSize}" +
        if (representative) { "#representative" } else { "#first" }
    synchronized(animatedEmojiStaticFrameMonitor) {
        if (animatedEmojiStaticFrames.contains(cacheKey)) {
            return Some(animatedEmojiStaticFrames[cacheKey])
        }
    }
    // 磁盘帧缓存：命中就完全绕开解码器（会话开销与 2 槽渲染闸都省了）。
    match (loadStaticFrameFromDisk(cacheKey, rasterSize)) {
        case Some(cached) =>
            cacheStaticFrame(cacheKey, cached)
            return Some(cached)
        case None => ()
    }

    var frame = None<PixelMap>
    if (isVideo) {
        match (openTelegramVideoSticker(localPath, rasterSize)) {
            case Some(session) =>
                let player = StreamingVideoStickerPlayer(documentId, session, rasterSize)
                if (player.prepareFirstFrame()) {
                    frame = player.getCurrentFrame()
                }
                player.close()
            case None => ()
        }
    } else {
        let bytes = readLocalFileBytes(localPath)
        match (openStreamingLottie(bytes, "stickerstatic_${documentId}_${rasterSize}", rasterSize)) {
            case Some(player) =>
                // combinedChatStickers 的 category icon 使用入场动画，第 0 帧通常全透明。
                // iOS 挂常驻动画节点；静态轻量预览取约 1/3 处的代表帧才有可见内容。
                if (representative && player.getFrameCount() > 2) {
                    let _ = player.seekTo(player.getFrameCount() / 3)
                }
                frame = player.getCurrentFrame()
                player.close()
            case None => ()
        }
    }

    match (frame) {
        case Some(pixelMap) =>
            cacheStaticFrame(cacheKey, pixelMap)
            storeStaticFrameToDisk(cacheKey, pixelMap, rasterSize)
            return Some(pixelMap)
        case None => return None<PixelMap>
    }
}

public func loadAnimatedEmojiStaticFrame(emoji: String, rasterSize: Int32): Option<PixelMap> {
    let key = normalizeAnimatedEmoji(emoji)
    let cacheKey = "${key}@${rasterSize}"
    synchronized(animatedEmojiStaticFrameMonitor) {
        if (animatedEmojiStaticFrames.contains(cacheKey)) {
            return Some(animatedEmojiStaticFrames[cacheKey])
        }
    }
    let bytes = loadAnimatedEmojiBytes(key)
    if (bytes.isEmpty()) { return None<PixelMap> }
    let sessionKey = "${animatedEmojiModelKey(key)}#static${rasterSize}"
    match (openStreamingLottie(bytes, sessionKey, rasterSize)) {
        case Some(player) =>
            let frame = player.getCurrentFrame()
            player.close()
            match (frame) {
                case Some(pixelMap) =>
                    cacheStaticFrame(cacheKey, pixelMap)
                    return Some(pixelMap)
                case None => return None<PixelMap>
            }
        case None => return None<PixelMap>
    }
}

private func takePreparedAnimatedEmojiStream(key: String): Option<StreamingLottiePlayer> {
    synchronized(animatedEmojiStreamMonitor) {
        if (animatedEmojiStreams.contains(key)) {
            let player = animatedEmojiStreams[key]
            let _ = animatedEmojiStreams.remove(key)
            return Some(player)
        }
    }
    return None<StreamingLottiePlayer>
}

/**
 * Resolve bytes, parse once and rasterize only frame 0/1. The outgoing-message
 * path calls this before publishing its sent-state bubble, so the mounted view
 * consumes the exact prepared session instead of repeating the work.
 */
public func preloadAnimatedEmojiStream(emoji: String): Bool {
    let key = normalizeAnimatedEmoji(emoji)
    var joinExisting = false
    synchronized(animatedEmojiStreamMonitor) {
        if (animatedEmojiStreams.contains(key)) { return true }
        if (animatedEmojiStreamPreparing.contains(key)) {
            joinExisting = true
        } else {
            animatedEmojiStreamPreparing[key] = true
        }
    }
    if (joinExisting) {
        var attempt: Int64 = 0
        while (attempt < 600) {
            synchronized(animatedEmojiStreamMonitor) {
                if (animatedEmojiStreams.contains(key)) { return true }
                if (!animatedEmojiStreamPreparing.contains(key)) { return false }
            }
            sleep(Duration.millisecond * 10)
            attempt = attempt + 1
        }
        return false
    }

    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    var prepared = None<StreamingLottiePlayer>
    prepared = openStreamingLottie(
        loadAnimatedEmojiBytes(key), animatedEmojiModelKey(key), ANIMATED_EMOJI_SIZE)
    match (prepared) {
        case Some(player) =>
            if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
        case None => ()
    }
    synchronized(animatedEmojiStreamMonitor) {
        let _ = animatedEmojiStreamPreparing.remove(key)
        match (prepared) {
            case Some(player) => animatedEmojiStreams[key] = player
            case None => ()
        }
    }
    let ready = synchronized(animatedEmojiStreamMonitor) { animatedEmojiStreams.contains(key) }
    Hilog.info(0, "CjTelegram",
        "[AnimatedEmojiPerf] preload key=${key} ready=${ready} raster=${ANIMATED_EMOJI_SIZE} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
    return ready
}

/**
 * Open a persistent two-frame session for one visible large animated emoji.
 *
 * The prepared map is intentionally single-consumer: it transfers ownership of
 * an outgoing-message warm session to the first mounted node. A visible node
 * that misses that slot must create its own renderer from the shared TGS bytes.
 * Waiting on preloadAnimatedEmojiStream() here used to make every concurrent
 * node compete for the same single player; an offscreen List cache node could
 * win and leave the actually visible message transparent until a later reuse.
 */
public func openAnimatedEmojiStream(emoji: String): Option<StreamingLottiePlayer> {
    let key = normalizeAnimatedEmoji(emoji)
    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    match (takePreparedAnimatedEmojiStream(key)) {
        case Some(player) =>
            Hilog.info(0, "CjTelegram",
                "[AnimatedEmojiPerf] prepared stream hit key=${key} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
            return Some(player)
        case None => ()
    }
    let sessionKey = animatedEmojiModelKey(key)
    match (openStreamingLottie(loadAnimatedEmojiBytes(key), sessionKey, ANIMATED_EMOJI_SIZE)) {
        case Some(player) =>
            Hilog.info(0, "CjTelegram",
                "[AnimatedEmojiPerf] stream ready key=${key} raster=${ANIMATED_EMOJI_SIZE} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
            return Some(player)
        case None =>
            Hilog.info(0, "CjTelegram",
                "[AnimatedEmojiService] independent stream open failed key=${key}, session=${sessionKey}")
            return None<StreamingLottiePlayer>
    }
}

public func getAnimatedEmojiFrameCount(emoji: String): Int64 {
    let key = normalizeAnimatedEmoji(emoji)
    synchronized(animatedEmojiMonitor) {
        match (animatedEmojiFrames.get(key)) {
            case Some(frames) => return Int64(frames.size)
            case None => return 0
        }
    }
}

public func getAnimatedEmojiFrameDuration(emoji: String): Int32 {
    let key = normalizeAnimatedEmoji(emoji)
    synchronized(animatedEmojiMonitor) {
        match (animatedEmojiDurations.get(key)) {
            case Some(duration) => return duration
            case None => return 33
        }
    }
}

public func getAnimatedEmojiFrame(emoji: String, index: Int64): Option<PixelMap> {
    let key = normalizeAnimatedEmoji(emoji)
    synchronized(animatedEmojiMonitor) {
        match (animatedEmojiFrames.get(key)) {
            case Some(frames) =>
                if (index >= 0 && index < Int64(frames.size)) {
                    return frames.get(index)
                }
            case None => ()
        }
    }
    return None
}

/** Read a downloaded local file to bytes. Accepts a plain path or a file:// URI. */
private func readLocalFileBytes(path: String): Array<UInt8> {
    var realPath = path
    if (realPath.startsWith("file://")) {
        realPath = realPath[7..]
    }
    if (realPath.size == 0) { return Array<UInt8>(0, repeat: 0) }
    try {
        let f = FileIo.open(realPath, mode: 0o0)
        let stat = FileIo.stat(f.fd)
        if (stat.size <= 0) {
            FileIo.close(f)
            return Array<UInt8>(0, repeat: 0)
        }
        let buf = Array<UInt8>(stat.size, repeat: 0)
        let _ = FileIo.read(f.fd, buf)
        FileIo.close(f)
        return buf
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[AnimatedStickerService] read failed ${path}: ${e}")
        return Array<UInt8>(0, repeat: 0)
    }
}

private func createAnimatedStickerFileStream(
    documentId: Int64, localPath: String, rasterSize: Int32
): Option<StreamingLottiePlayer> {
    if (documentId == 0 || localPath.size == 0) { return None<StreamingLottiePlayer> }
    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let bytes = readLocalFileBytes(localPath)
    let result = openStreamingLottie(
        bytes, "stickerfile_stream_${documentId}_${rasterSize}", rasterSize)
    Hilog.info(0, "CjTelegram",
        "[AnimatedStickerPerf] first frame id=${documentId} bytes=${bytes.size} raster=${rasterSize} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
    return result
}

private func createVideoStickerFileStream(
    documentId: Int64, localPath: String,
    rasterSize!: Int32 = VIDEO_STICKER_SIZE
): Option<StreamingVideoStickerPlayer> {
    if (documentId == 0 || localPath.size == 0) {
        return None<StreamingVideoStickerPlayer>
    }
    let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
    match (openTelegramVideoSticker(localPath, rasterSize)) {
        case Some(session) =>
            let player = StreamingVideoStickerPlayer(documentId, session, rasterSize)
            if (player.prepareFirstFrame()) {
                Hilog.info(0, "CjTelegram",
                    "[VideoStickerPerf] first frame id=${documentId} raster=${VIDEO_STICKER_SIZE} elapsedMs=${DateTime.now().toUnixTimeStamp().toMilliseconds() - startedAt}")
                return Some(player)
            }
            player.close()
            return None<StreamingVideoStickerPlayer>
        case None => return None<StreamingVideoStickerPlayer>
    }
}

/** Prepare an incoming sticker before publishing its local path to the UI. */
public func preloadAnimatedStickerFileStream(
    documentId: Int64, localPath: String, isVideo: Bool
): Bool {
    if (documentId == 0 || localPath.isEmpty()) { return false }
    if (isVideo) {
        synchronized(preparedStickerStreamMonitor) {
            if (preparedVideoStickerStreams.contains(documentId)) { return true }
        }
        match (createVideoStickerFileStream(documentId, localPath)) {
            case Some(player) =>
                if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
                var duplicate = false
                var evicted = None<StreamingVideoStickerPlayer>
                synchronized(preparedStickerStreamMonitor) {
                    if (preparedVideoStickerStreams.contains(documentId)) {
                        duplicate = true
                    } else {
                        preparedVideoStickerStreams[documentId] = player
                        preparedVideoStickerOrder.add(documentId)
                        if (preparedVideoStickerOrder.size > preparedStickerStreamLimit) {
                            let oldest = preparedVideoStickerOrder[0]
                            preparedVideoStickerOrder.remove(0..1)
                            if (preparedVideoStickerStreams.contains(oldest)) {
                                evicted = Some(preparedVideoStickerStreams[oldest])
                                let _ = preparedVideoStickerStreams.remove(oldest)
                            }
                        }
                    }
                }
                if (duplicate) { player.close() }
                match (evicted) {
                    case Some(oldPlayer) => oldPlayer.close()
                    case None => ()
                }
                return true
            case None => return false
        }
    }

    synchronized(preparedStickerStreamMonitor) {
        if (preparedLottieStickerStreams.contains(documentId)) { return true }
    }
    match (createAnimatedStickerFileStream(documentId, localPath, ANIMATED_STICKER_SIZE)) {
        case Some(player) =>
            if (player.getFrameCount() > 1) { let _ = player.prepareNextFrame(1) }
            var duplicate = false
            var evicted = None<StreamingLottiePlayer>
            synchronized(preparedStickerStreamMonitor) {
                if (preparedLottieStickerStreams.contains(documentId)) {
                    duplicate = true
                } else {
                    preparedLottieStickerStreams[documentId] = player
                    preparedLottieStickerOrder.add(documentId)
                    if (preparedLottieStickerOrder.size > preparedStickerStreamLimit) {
                        let oldest = preparedLottieStickerOrder[0]
                        preparedLottieStickerOrder.remove(0..1)
                        if (preparedLottieStickerStreams.contains(oldest)) {
                            evicted = Some(preparedLottieStickerStreams[oldest])
                            let _ = preparedLottieStickerStreams.remove(oldest)
                        }
                    }
                }
            }
            if (duplicate) { player.close() }
            match (evicted) {
                case Some(oldPlayer) => oldPlayer.close()
                case None => ()
            }
            return true
        case None => return false
    }
}

/** Open a persistent two-frame session for a visible TGS sticker message. */
public func openAnimatedStickerFileStream(
    documentId: Int64, localPath: String,
    rasterSize!: Int32 = ANIMATED_STICKER_SIZE
): Option<StreamingLottiePlayer> {
    // 光栅跟随调用方。此前一律 384px：72px 的键盘格子每帧付 28 倍像素的
    // 渲染/拷贝/GC 代价（真机 hilog 抓到 84px 缓冲读 384px 帧的报错，顺藤摸瓜）。
    // prepared-stream 缓存只存默认光栅的会话，非默认光栅直接新建。
    if (rasterSize == ANIMATED_STICKER_SIZE) {
        match (takePreparedLottieStickerStream(documentId)) {
            case Some(player) =>
                Hilog.info(0, "CjTelegram",
                    "[AnimatedStickerPerf] prepared stream hit id=${documentId}")
                return Some(player)
            case None => ()
        }
    }
    return createAnimatedStickerFileStream(documentId, localPath, rasterSize)
}

/** Parse packet metadata, decode frame zero, then retain the VP9 session. */
public func openVideoStickerFileStream(
    documentId: Int64, localPath: String,
    rasterSize!: Int32 = VIDEO_STICKER_SIZE
): Option<StreamingVideoStickerPlayer> {
    if (rasterSize == VIDEO_STICKER_SIZE) {
        match (takePreparedVideoStickerStream(documentId)) {
            case Some(player) =>
                Hilog.info(0, "CjTelegram",
                    "[VideoStickerPerf] prepared stream hit id=${documentId}")
                return Some(player)
            case None => ()
        }
    }
    return createVideoStickerFileStream(documentId, localPath, rasterSize: rasterSize)
}
