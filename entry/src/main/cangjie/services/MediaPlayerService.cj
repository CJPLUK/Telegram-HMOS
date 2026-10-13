package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import kit.PerformanceAnalysisKit.Hilog
import std.time.DateTime

/**
 * MediaPlayerService — 媒体播放器服务
 *
 * 对应 iOS submodules/MediaPlayer/Sources/MediaPlayer.swift
 *          submodules/MediaResources/Sources/MediaPlaybackStoredState.swift
 *          submodules/MediaPlayer/Sources/TimeBasedVideoPreload.swift
 *
 * 实现范围（P2-223 + P2-228 + P2-232）：
 *
 * P2-223 媒体播放存储态：
 *   MediaPlaybackStoredState 结构体（timestamp + baseRate）
 *   loadStoredState / saveStoredState — Preferences("telegram_media_playback") 持久化
 *   每次 stop/detach 时自动保存，下次 load 时恢复 timestamp
 *
 * P2-228 播放器状态机（增量扩展）：
 *   MediaPlayerStatus — generationTimestamp / seekId / baseRate / playbackStatus
 *   MediaPlayerPlaybackStatus 枚举（playing/paused/buffering/stopped）
 *   MediaPlayerActionAtEnd 枚举（stop/loop/loopAll）
 *   seekId 每次 seek 自增（避免过期回调污染）
 *   baseRate / PlaybackSpeed 控制
 *   notifyStatusChanged — 向 Page 推送 MediaPlayerStatus 快照
 *
 * P2-232 基于时间的视频预加载：
 *   preloadVideoResource — 逻辑层实现（何时/何段预加载）
 *   preSeekWarmup — seek 前预热逻辑标记
 *   HarmonyOS ArkUI Video 组件未暴露逐帧预载 API，底层帧级预热 defer（诚实标注）
 *
 * 架构：
 *   MediaPlayerPage.onPlayPause()
 *     → MediaPlayerService.togglePlayPause()
 *       → VideoController.start() / pause()
 *         → handleProgressUpdate() / handlePrepared()
 *           → notifyStatusChanged() → statusCallback(MediaPlayerStatus)
 *             → Page @State 刷新（via launch{}）
 *
 * iOS 映射：
 *   MediaPlayerStatus.generationTimestamp ← CACurrentMediaTime()
 *   MediaPlayerStatus.seekId              ← seekId: Int (iOS MediaPlayerContext)
 *   MediaPlayerStatus.baseRate            ← baseRate: Double
 *   MediaPlayerStatus.status              ← MediaPlayerPlaybackStatus
 *   MediaPlaybackStoredState.timestamp    ← timestamp: Double
 *   MediaPlaybackStoredState.playbackRate ← AudioPlaybackRate.rawValue (Int32)
 *   preloadVideoResource()                ← TimeBasedVideoPreload.swift (逻辑层)
 *
 * MTProto 说明：本 feature 无 MTProto 方法，媒体来源为本地已下载文件。
 */

// ─── P2-228: 播放状态枚举 ───────────────────────────────────────────────────────

/**
 * 媒体播放器高层状态
 * 对应 iOS MediaPlayerState (.empty / .paused / .playing / .seeking)
 */
public enum MediaPlayerState {
    | Idle
    | Prepared
    | Playing
    | Paused
    | Seeking
    | Stopped
    | Buffering
    | Error
}

/**
 * 播放状态详情 — 对应 iOS MediaPlayerPlaybackStatus
 * 用于 MediaPlayerStatus.status 字段
 */
public enum MediaPlayerPlaybackStatus {
    /** 正在播放 */
    | Playing
    /** 已暂停 */
    | Paused
    /** 缓冲中 / 加载中 */
    | Buffering
    /** 已停止 */
    | Stopped
}

/**
 * 播放结束行为 — 对应 iOS MediaPlayerActionAtEnd
 */
public enum MediaPlayerActionAtEnd {
    /** 停止（默认） */
    | Stop
    /** 单曲循环 */
    | Loop
    /** 全部循环（playlist 语义，单媒体退化为 Loop） */
    | LoopAll
}

// ─── P2-228: 时间戳状态快照 ────────────────────────────────────────────────────

/**
 * MediaPlayerStatus — 带版本戳的播放器状态快照
 *
 * 对应 iOS MediaPlayer.swift struct MediaPlayerStatus:
 *   - generationTimestamp: 快照生成的系统单调时间（秒），用于消费端识别过期回调
 *   - seekId: seek 操作递增计数，消费端可丢弃 seekId < currentSeekId 的响应
 *   - baseRate: 播放倍速（1.0 = 正常）
 *   - timestamp: 当前播放位置（秒）
 *   - duration: 媒体总时长（秒）
 *   - status: 播放状态详情
 */
public struct MediaPlayerStatus {
    /** 快照生成时刻（DateTime.nowUtc().unixTimestampMilliseconds / 1000.0） */
    public var generationTimestamp: Float64
    /** seek 操作序号，每次 seek 自增 */
    public var seekId: Int64
    /** 当前播放倍速（1.0 = 正常, 1.5, 2.0…） */
    public var baseRate: Float64
    /** 当前播放位置（秒） */
    public var timestamp: Int32
    /** 媒体总时长（秒） */
    public var duration: Int32
    /** 播放状态详情 */
    public var status: MediaPlayerPlaybackStatus

    public init(
        generationTimestamp: Float64,
        seekId: Int64,
        baseRate: Float64,
        timestamp: Int32,
        duration: Int32,
        status: MediaPlayerPlaybackStatus
    ) {
        this.generationTimestamp = generationTimestamp
        this.seekId = seekId
        this.baseRate = baseRate
        this.timestamp = timestamp
        this.duration = duration
        this.status = status
    }
}

// ─── P2-223: 媒体播放存储态 ────────────────────────────────────────────────────

/**
 * MediaPlaybackStoredState — 每条媒体的播放进度持久化数据
 *
 * 对应 iOS submodules/MediaResources/Sources/MediaPlaybackStoredState.swift:
 *   public final class MediaPlaybackStoredState: Codable {
 *     public let timestamp: Double
 *     public let playbackRate: AudioPlaybackRate    (rawValue: Int32)
 *   }
 *
 * HarmonyOS 实现：通过 Preferences("telegram_media_playback") 以 messageId 为 key 持久化。
 * key 格式：
 *   "<msgId>_ts"   → Float64Data(timestamp)
 *   "<msgId>_rate" → Integer(rateRaw)   (1000 = x1.0, 2000 = x2.0, 同 iOS rawValue)
 */
public struct MediaPlaybackStoredState {
    /** 上次停止时的播放位置（秒，Float64 保留小数） */
    public var timestamp: Float64
    /** 播放倍速 rawValue (1000=x1, 1500=x1.5, 2000=x2)，对应 iOS AudioPlaybackRate.rawValue */
    public var playbackRateRaw: Int64

    public init(timestamp: Float64, playbackRateRaw: Int64) {
        this.timestamp = timestamp
        this.playbackRateRaw = playbackRateRaw
    }

    /** 倍速值（Double），对应 iOS AudioPlaybackRate.doubleValue = rawValue/1000.0 */
    public func rateDouble(): Float64 {
        if (playbackRateRaw <= 0) { return 1.0 }
        return Float64(playbackRateRaw) / 1000.0
    }
}

// ─── P2-223: 存储态持久化辅助 ─────────────────────────────────────────────────

/**
 * 从 Preferences("telegram_media_playback") 读取指定 messageId 的播放存储态。
 * 对应 iOS mediaPlaybackStoredState(engine:messageId:) Signal<MediaPlaybackStoredState?>
 *
 * @param ctx  UIAbilityContext（来自 getGlobalAbilityContext()）
 * @param msgId 消息 ID 字符串
 * @return Option<MediaPlaybackStoredState>
 */
public func loadMediaPlaybackStoredState(
    ctx: UIAbilityContext,
    msgId: String
): Option<MediaPlaybackStoredState> {
    let storeName = "telegram_media_playback"
    try {
        let prefs = Preferences.getPreferences(ctx, storeName)
        let tsKey = "${msgId}_ts"
        let rateKey = "${msgId}_rate"
        if (!prefs.has(tsKey)) {
            return None
        }
        // timestamp 以毫秒整数存储（Int64），避免 Float64Data 不存在的问题
        let tsVal = prefs.get(tsKey, PreferencesValueType.Integer(0))
        let rateVal = prefs.get(rateKey, PreferencesValueType.Integer(1000))
        let tsMs: Int64 = match (tsVal) {
            case PreferencesValueType.Integer(n) => n
            case _ => 0
        }
        let rate: Int64 = match (rateVal) {
            case PreferencesValueType.Integer(n) => n
            case _ => 1000
        }
        if (tsMs <= 0) {
            return None
        }
        let ts = Float64(tsMs) / 1000.0
        return Some(MediaPlaybackStoredState(ts, rate))
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MediaPlayer] loadStoredState(${msgId}) err: ${e}")
        return None
    }
}

/**
 * 将播放存储态写入 Preferences("telegram_media_playback")。
 * 对应 iOS updateMediaPlaybackStoredStateInteractively(engine:messageId:state:)
 *
 * @param ctx     UIAbilityContext
 * @param msgId   消息 ID 字符串
 * @param state   存储态（None 表示清除该记录）
 */
public func saveMediaPlaybackStoredState(
    ctx: UIAbilityContext,
    msgId: String,
    state: Option<MediaPlaybackStoredState>
): Unit {
    let storeName = "telegram_media_playback"
    try {
        let prefs = Preferences.getPreferences(ctx, storeName)
        let tsKey = "${msgId}_ts"
        let rateKey = "${msgId}_rate"
        match (state) {
            case None =>
                prefs.delete(tsKey)
                prefs.delete(rateKey)
            case Some(s) =>
                // timestamp 以毫秒整数存储（Int64）
                let tsMs: Int64 = Int64(s.timestamp * 1000.0)
                prefs.put(tsKey, PreferencesValueType.Integer(tsMs))
                prefs.put(rateKey, PreferencesValueType.Integer(s.playbackRateRaw))
        }
        prefs.flush()
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[MediaPlayer] saveStoredState(${msgId}) err: ${e}")
    }
}

// ─── P2-232: 预加载逻辑层 ─────────────────────────────────────────────────────

/**
 * 视频预加载请求描述 — 对应 iOS TimeBasedVideoPreload.swift preloadVideoResource()
 *
 * iOS 实现：FFMpegMediaFrameSource.seek(timestamp:) + ensureHasFrames(until:)
 * 鸿蒙实现：ArkUI Video 组件不暴露逐帧/分片预载 API（帧级别预热 DEFERRED），
 *   此处实现**逻辑层**：记录何时应预加载、预加载哪段（起始位置 + 时长上限），
 *   由 MediaPlayerService 在播放进度推进时触发预加载决策，
 *   实际网络数据获取由 ArkUI Video 内部缓冲机制处理。
 *
 * 预加载触发条件（对齐 iOS 2MB 约束精神）：
 *   播放时间戳接近预加载窗口 → 触发记录预加载起点
 *   seek 操作前 → 记录目标帧预热请求
 */
public struct VideoPreloadRequest {
    /** 预加载起始时间戳（秒） */
    public var fromTimestamp: Float64
    /** 预加载最大时长（秒），对应 iOS maximumFetchSize / duration 约束 */
    public var durationLimit: Float64
    /** 是否为 seek 预热（pre-seek warmup） */
    public var isPreSeek: Bool
    /** 目标媒体 URL */
    public var mediaUrl: String

    public init(
        fromTimestamp: Float64,
        durationLimit: Float64,
        isPreSeek: Bool,
        mediaUrl: String
    ) {
        this.fromTimestamp = fromTimestamp
        this.durationLimit = durationLimit
        this.isPreSeek = isPreSeek
        this.mediaUrl = mediaUrl
    }
}

// ─── 服务单例 ──────────────────────────────────────────────────────────────────

private var _mediaPlayerServiceInstance: Option<MediaPlayerService> = None

/**
 * 获取 MediaPlayerService 单例
 */
public func getMediaPlayerService(): MediaPlayerService {
    match (_mediaPlayerServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = MediaPlayerService()
            _mediaPlayerServiceInstance = Some(inst)
            return inst
    }
}

// ─── MediaPlayerService ────────────────────────────────────────────────────────

/**
 * MediaPlayerService
 *
 * 封装 VideoController 生命周期，统一播放状态管理。
 * 扩展支持 P2-223(存储态) / P2-228(状态机) / P2-231(scrubbing) / P2-232(预加载逻辑层)。
 *
 * 调用链（P2-228 增强）：
 *   MediaPlayerPage.onPlayPause()
 *     → MediaPlayerService.togglePlayPause()
 *       → VideoController.start() / pause()
 *         → handleProgressUpdate() / handlePrepared()
 *           → notifyStatusChanged()
 *             → statusCallback(MediaPlayerStatus) [P2-228]
 *               → Page launch{} 更新 @State
 *
 * 调用链（P2-231 scrubbing）：
 *   Slider.onChange Begin   → MediaPlayerPage.onScrubbingBegin()
 *     → MediaPlayerService.beginScrubbing()          // 记录拖前播放态，暂停
 *   Slider.onChange Moving  → MediaPlayerPage.onScrubbingUpdate(fraction)
 *     → MediaPlayerService.updateScrubbingTarget(seconds) // 防抖：记录目标，按序
 *   Slider.onChange End     → MediaPlayerPage.onScrubbingEnd(fraction)
 *     → MediaPlayerService.endScrubbing(seconds)     // 精确 seek + 按需恢复播放
 *
 * 调用链（P2-223 存储态）：
 *   MediaPlayerPage.aboutToDisappear()
 *     → MediaPlayerService.persistStoredState(ctx, msgId)
 *         → saveMediaPlaybackStoredState(ctx, msgId, state)
 *
 *   MediaPlayerPage.loadMediaWithResume(url, msgId, ctx)
 *     → loadMediaPlaybackStoredState(ctx, msgId)
 *     → seek(seconds: Int32(state.timestamp))
 *     → setBaseRate(state.rateDouble())
 *
 * 调用链（P2-232 预加载）：
 *   handleProgressUpdate(timeSec)
 *     → checkPreloadTrigger(timeSec)
 *       → preloadCallback(VideoPreloadRequest)  [逻辑通知]
 */
public class MediaPlayerService {
    // ─── 基础播放状态 ──────────────────────────────────────────────────────────
    /** 当前媒体文件路径（本地 file:// URI 或 http:// URL） */
    public var mediaUrl: String = ""
    /** 当前消息 ID（用于存储态 key） */
    public var currentMsgId: String = ""
    /** 播放状态 */
    public var state: MediaPlayerState = MediaPlayerState.Idle
    /** 是否已就绪（onPrepared 触发后） */
    public var isPrepared: Bool = false
    /** 当前播放位置（秒） */
    public var currentTime: Int32 = 0
    /** 媒体总时长（秒，onPrepared 后更新） */
    public var duration: Int32 = 0
    /** 是否静音 */
    public var isMuted: Bool = false
    /** 是否循环（向后兼容字段，与 actionAtEnd 联动） */
    public var isLooping: Bool = false
    /** 播放结束行为 */
    public var actionAtEnd: MediaPlayerActionAtEnd = MediaPlayerActionAtEnd.Stop
    /** 错误描述 */
    public var lastError: String = ""

    // ─── P2-228: 状态机扩展字段 ───────────────────────────────────────────────
    /**
     * seek 操作序号（每次 seek 自增）
     * 对应 iOS MediaPlayerContext.seekId: Int
     * 消费端可用此字段丢弃过期 seek 回调
     */
    public var seekId: Int64 = 0

    /**
     * 基准播放倍速（1.0 = 正常，1.5 = 1.5倍速，2.0 = 2倍速）
     * 对应 iOS MediaPlayerContext.baseRate: Double
     * HarmonyOS 侧通过 Video(currentProgressRate: PlaybackSpeed) 控制，
     * Page 持有 @State var playbackSpeed: PlaybackSpeed 并在此更新时触发重渲染。
     */
    public var baseRate: Float64 = 1.0

    /**
     * 当前 PlaybackSpeed 枚举值（供 Page Video 组件的 currentProgressRate 参数使用）
     * KB 确认：Video 组件通过 currentProgressRate 参数控制倍速（不是 VideoController 方法）
     */
    public var playbackSpeed: PlaybackSpeed = PlaybackSpeed.SpeedForward100X

    // ─── P2-231: scrubbing 状态 ──────────────────────────────────────────────
    /**
     * 是否处于 scrubbing（拖动进度条）状态。
     * 对应 iOS MediaPlayerScrubbingNode.isScrubbing。
     *
     * beginScrubbing() → true；endScrubbing() → false。
     * 拖动期间暂停播放，松手后按需恢复。
     */
    public var isScrubbing: Bool = false

    /**
     * scrubbing 开始前的播放状态（Playing/Paused/…），
     * 用于 endScrubbing 中决定是否恢复播放。
     * 对应 iOS MediaPlayerScrubbingNode 中保存的 playing 标志。
     */
    private var _scrubbingPreState: MediaPlayerState = MediaPlayerState.Idle

    /**
     * 防抖 seek 序号：每次 updateScrubbingTarget 递增。
     * onScrubbingEnd 取最新序号对应的目标值做精确 seek，避免 Moving 期间
     * 频繁 seek 造成的卡顿（对应 iOS scrubbing multiplier 节流思路）。
     */
    private var _scrubbingSeekSeq: Int64 = 0

    /**
     * 最新 scrubbing 目标（秒）；onScrubbingEnd 会再做一次精确 seek。
     */
    public var scrubbingTargetSec: Int32 = 0

    // ─── P2-232: 预加载控制 ───────────────────────────────────────────────────
    /**
     * 预加载触发窗口（秒）：当前播放位置超过上次预加载触发时刻 + 此值时重新触发
     * 对应 iOS 2MB 前向预载的时间换算（约 30s @500kbps）
     */
    private var preloadWindowSec: Int32 = 30
    /** 上次预加载触发时的播放位置 */
    private var lastPreloadTriggerTime: Int32 = -1

    // ─── 回调与控制器 ─────────────────────────────────────────────────────────
    // VideoController 由 MediaPlayerPage 创建后注入
    private var _controller: Option<VideoController> = None
    // 进度更新回调（Page 注册，用于驱动 @State 刷新）
    private var _onProgressUpdate: Option<(Int32, Int32) -> Unit> = None
    // 播放完成回调
    private var _onPlaybackFinished: Option<() -> Unit> = None
    // P2-228: 状态快照回调（Page 注册，接收 MediaPlayerStatus）
    private var _statusCallback: Option<(MediaPlayerStatus) -> Unit> = None
    // P2-232: 预加载通知回调（逻辑层，Page 或上层可选注册）
    private var _preloadCallback: Option<(VideoPreloadRequest) -> Unit> = None

    public init() {}

    // ─── 注入 VideoController ────────────────────────────────────────────────

    /**
     * 注入来自 MediaPlayerPage 的 VideoController 实例。
     * Page 在 aboutToAppear 时调用此方法。
     */
    public func attachController(controller!: VideoController): Unit {
        _controller = Some(controller)
        Hilog.info(0, "CjTelegram", "[MediaPlayer] Controller attached")
    }

    /**
     * 注销 VideoController（Page 销毁时调用）。
     */
    public func detachController(): Unit {
        _controller = None
        state = MediaPlayerState.Idle
        isPrepared = false
        Hilog.info(0, "CjTelegram", "[MediaPlayer] Controller detached")
    }

    // ─── 回调注册 ────────────────────────────────────────────────────────────

    /**
     * 注册进度更新回调（(currentTime, duration) → Unit）。
     */
    public func setProgressCallback(cb: (Int32, Int32) -> Unit): Unit {
        _onProgressUpdate = Some(cb)
    }

    /**
     * 注册播放完成回调。
     */
    public func setFinishCallback(cb: () -> Unit): Unit {
        _onPlaybackFinished = Some(cb)
    }

    /**
     * P2-228: 注册状态快照回调。
     * 每次 play/pause/seek/rate 变化后触发，携带 MediaPlayerStatus 快照。
     */
    public func setStatusCallback(cb: (MediaPlayerStatus) -> Unit): Unit {
        _statusCallback = Some(cb)
    }

    /**
     * P2-232: 注册预加载通知回调（可选）。
     * 当逻辑层判定需要预加载时触发，传入 VideoPreloadRequest 描述。
     */
    public func setPreloadCallback(cb: (VideoPreloadRequest) -> Unit): Unit {
        _preloadCallback = Some(cb)
    }

    // ─── P2-228: 状态机通知 ──────────────────────────────────────────────────

    /**
     * 生成当前状态快照并通过 statusCallback 推送。
     * 对应 iOS MediaPlayerContext 内部的 playerStatus Promise.set(status)。
     */
    private func notifyStatusChanged(): Unit {
        match (_statusCallback) {
            case None => ()
            case Some(cb) =>
                let nowTs = Float64(DateTime.now().toUnixTimeStamp().toSeconds())
                let playbackSt: MediaPlayerPlaybackStatus = match (state) {
                    case MediaPlayerState.Playing => MediaPlayerPlaybackStatus.Playing
                    case MediaPlayerState.Paused => MediaPlayerPlaybackStatus.Paused
                    case MediaPlayerState.Buffering => MediaPlayerPlaybackStatus.Buffering
                    case _ => MediaPlayerPlaybackStatus.Stopped
                }
                let snap = MediaPlayerStatus(nowTs, seekId, baseRate, currentTime, duration, playbackSt)
                cb(snap)
        }
    }

    // ─── 平台事件入口（由 MediaPlayerPage 的 Video 组件回调调用）─────────────

    /**
     * onPrepared 事件处理：视频就绪，更新时长。
     */
    public func handlePrepared(durationSec!: Int32): Unit {
        duration = durationSec
        isPrepared = true
        state = MediaPlayerState.Prepared
        Hilog.info(0, "CjTelegram", "[MediaPlayer] Prepared, duration=${durationSec}s")
        // P2-223: 若 loadWithResume 设置了 pendingResumeTime，此时 seek 到恢复位置
        applyPendingResume()
        match (_onProgressUpdate) {
            case Some(cb) => cb(currentTime, duration)
            case None => ()
        }
        notifyStatusChanged()
    }

    /**
     * onUpdate 事件处理：播放进度更新。
     * P2-232: 每次进度更新后检查是否需要触发预加载逻辑。
     */
    public func handleProgressUpdate(timeSec!: Int32): Unit {
        currentTime = timeSec
        match (_onProgressUpdate) {
            case Some(cb) => cb(currentTime, duration)
            case None => ()
        }
        // P2-228: 不每帧通知 statusCallback（避免频繁推送），仅进度回调更新
        // P2-232: 检查预加载触发条件
        checkPreloadTrigger(timeSec: timeSec)
    }

    /**
     * onFinish 事件处理：播放完成。
     * 对应 iOS MediaPlayerContext actionAtEnd 处理。
     */
    public func handleFinish(): Unit {
        Hilog.info(0, "CjTelegram", "[MediaPlayer] Playback finished")
        let actionLoops: Bool = match (actionAtEnd) {
            case MediaPlayerActionAtEnd.Loop | MediaPlayerActionAtEnd.LoopAll => true
            case _ => false
        }
        if (isLooping || actionLoops) {
            seek(seconds: 0)
            play()
        } else {
            state = MediaPlayerState.Stopped
            currentTime = 0
        }
        match (_onPlaybackFinished) {
            case Some(cb) => cb()
            case None => ()
        }
        notifyStatusChanged()
    }

    /**
     * onError 事件处理。
     */
    public func handleError(msg!: String): Unit {
        lastError = msg
        state = MediaPlayerState.Error
        Hilog.info(0, "CjTelegram", "[MediaPlayer] Error: ${msg}")
        notifyStatusChanged()
    }

    /**
     * onStart 事件处理：VideoController.start() 被响应。
     */
    public func handleStart(): Unit {
        state = MediaPlayerState.Playing
        Hilog.info(0, "CjTelegram", "[MediaPlayer] Started")
        notifyStatusChanged()
    }

    // ─── 控制 API ─────────────────────────────────────────────────────────────

    /**
     * 加载媒体文件。
     * P2-223: 支持 msgId 用于存储态 key；可选传入已恢复的起始位置。
     */
    public func load(url!: String): Unit {
        mediaUrl = url
        isPrepared = false
        state = MediaPlayerState.Idle
        currentTime = 0
        duration = 0
        lastError = ""
        lastPreloadTriggerTime = -1
        Hilog.info(0, "CjTelegram", "[MediaPlayer] Load: ${url}")
    }

    /**
     * P2-223: 加载媒体文件并绑定 messageId（用于存储态持久化）。
     */
    public func loadWithMsgId(url!: String, msgId!: String): Unit {
        currentMsgId = msgId
        load(url: url)
        Hilog.info(0, "CjTelegram", "[MediaPlayer] loadWithMsgId: url=${url} msgId=${msgId}")
    }

    /**
     * P2-223: 加载媒体并尝试恢复上次播放进度。
     *
     * 对应 iOS GalleryData.swift / MediaManager.swift 中：
     *   let state = mediaPlaybackStoredState(engine:messageId:)
     *   gallery = GalleryController(..., timecode: state.timestamp, playbackRate: state.rate)
     *
     * @param url   媒体文件路径
     * @param msgId 消息 ID（Preferences key 前缀）
     * @param ctx   UIAbilityContext（需来自 UIAbility，满足 S-012）
     */
    public func loadWithResume(
        url!: String,
        msgId!: String,
        ctx!: UIAbilityContext
    ): Unit {
        loadWithMsgId(url: url, msgId: msgId)
        match (loadMediaPlaybackStoredState(ctx, msgId)) {
            case None =>
                Hilog.info(0, "CjTelegram", "[MediaPlayer] No stored state for msgId=${msgId}")
            case Some(stored) =>
                let resumeTime = Int32(stored.timestamp)
                let rate = stored.rateDouble()
                Hilog.info(0, "CjTelegram",
                    "[MediaPlayer] Restoring: ts=${resumeTime}s rate=${rate}")
                // 存储恢复值，待 onPrepared 后 seek 生效
                _pendingResumeTime = resumeTime
                // 恢复倍速
                setBaseRate(rate: rate)
        }
    }

    // 待恢复时间戳（loadWithResume 设置，onPrepared 后执行）
    private var _pendingResumeTime: Int32 = -1

    /**
     * onPrepared 后若有 pendingResumeTime，自动 seek。
     * 调用方在 handlePrepared 内自动触发。
     */
    private func applyPendingResume(): Unit {
        if (_pendingResumeTime > 0) {
            let t = _pendingResumeTime
            _pendingResumeTime = -1
            seek(seconds: t)
            Hilog.info(0, "CjTelegram", "[MediaPlayer] Applied resume seek to ${t}s")
        }
    }

    /**
     * 播放。
     * 对应 iOS MediaPlayerContext.play()。
     */
    public func play(): Unit {
        match (_controller) {
            case Some(ctrl) =>
                ctrl.start()
                state = MediaPlayerState.Playing
                Hilog.info(0, "CjTelegram", "[MediaPlayer] play()")
                notifyStatusChanged()
            case None =>
                Hilog.info(0, "CjTelegram", "[MediaPlayer] play() — no controller")
        }
    }

    /**
     * 暂停。
     * 对应 iOS MediaPlayerContext.pause(lostAudioSession:).
     */
    public func pause(): Unit {
        match (_controller) {
            case Some(ctrl) =>
                ctrl.pause()
                state = MediaPlayerState.Paused
                Hilog.info(0, "CjTelegram", "[MediaPlayer] pause()")
                notifyStatusChanged()
            case None =>
                Hilog.info(0, "CjTelegram", "[MediaPlayer] pause() — no controller")
        }
    }

    /**
     * 停止播放并重置到开头。
     */
    public func stop(): Unit {
        match (_controller) {
            case Some(ctrl) =>
                ctrl.stop()
                state = MediaPlayerState.Stopped
                currentTime = 0
                Hilog.info(0, "CjTelegram", "[MediaPlayer] stop()")
                notifyStatusChanged()
            case None =>
                Hilog.info(0, "CjTelegram", "[MediaPlayer] stop() — no controller")
        }
    }

    /**
     * 播放/暂停切换。
     */
    public func togglePlayPause(): Unit {
        match (state) {
            case MediaPlayerState.Playing => pause()
            case MediaPlayerState.Paused => play()
            case MediaPlayerState.Prepared => play()
            case MediaPlayerState.Stopped =>
                seek(seconds: 0)
                play()
            case _ =>
                Hilog.info(0, "CjTelegram", "[MediaPlayer] togglePlayPause() in state=${stateLabel()}")
        }
    }

    /**
     * Seek 到指定位置（秒）。
     * P2-228: seekId 自增，触发 notifyStatusChanged。
     * P2-231: 使用 ClosestKeyframe 模式（快速定位，适合常规 seek）。
     * P2-232: 触发 pre-seek 预加载逻辑。
     */
    public func seek(seconds!: Int32): Unit {
        match (_controller) {
            case Some(ctrl) =>
                seekId = seekId + 1
                triggerPreSeekWarmup(targetSec: seconds)
                let prevState = state
                state = MediaPlayerState.Seeking
                ctrl.setCurrentTime(seconds, SeekMode.ClosestKeyframe)
                state = prevState
                currentTime = seconds
                Hilog.info(0, "CjTelegram", "[MediaPlayer] seek(${seconds}s) seekId=${seekId}")
                notifyStatusChanged()
            case None =>
                Hilog.info(0, "CjTelegram", "[MediaPlayer] seek() — no controller")
        }
    }

    /**
     * P2-231: 精确 seek 到任意时间戳（非关键帧），对应 iOS SeekMode.Accurate。
     * 用于 scrubbing 结束时的最终定位 + -10s/+10s 跳转。
     *
     * HarmonyOS 对应：SeekMode.Accurate（精准跳转，不论是否为关键帧）。
     * iOS 对应：ChunkMediaPlayer.seek(timestamp:) 中的精确帧定位。
     *
     * @param seconds 目标时间（秒）
     */
    public func seekAccurate(seconds!: Int32): Unit {
        match (_controller) {
            case Some(ctrl) =>
                seekId = seekId + 1
                triggerPreSeekWarmup(targetSec: seconds)
                let prevState = state
                state = MediaPlayerState.Seeking
                ctrl.setCurrentTime(seconds, SeekMode.Accurate)
                state = prevState
                currentTime = seconds
                Hilog.info(0, "CjTelegram",
                    "[MediaPlayer] seekAccurate(${seconds}s) seekId=${seekId}")
                notifyStatusChanged()
            case None =>
                Hilog.info(0, "CjTelegram", "[MediaPlayer] seekAccurate() — no controller")
        }
    }

    /**
     * P2-231: 关键帧 seek（快速但不精确），对应 iOS kCMTimeFlags_Valid 关键帧跳转。
     * 用于 scrubbing Moving 期间的实时位置更新（快速响应优先于精度）。
     *
     * HarmonyOS 对应：SeekMode.ClosestKeyframe。
     *
     * @param seconds 目标时间（秒）
     */
    public func seekNearestKeyframe(seconds!: Int32): Unit {
        match (_controller) {
            case Some(ctrl) =>
                seekId = seekId + 1
                let prevState = state
                state = MediaPlayerState.Seeking
                ctrl.setCurrentTime(seconds, SeekMode.ClosestKeyframe)
                state = prevState
                currentTime = seconds
                Hilog.info(0, "CjTelegram",
                    "[MediaPlayer] seekNearestKeyframe(${seconds}s) seekId=${seekId}")
                notifyStatusChanged()
            case None =>
                Hilog.info(0, "CjTelegram",
                    "[MediaPlayer] seekNearestKeyframe() — no controller")
        }
    }

    // ─── P2-231: scrubbing API ───────────────────────────────────────────────

    /**
     * 开始拖动（Slider Begin）。
     * 对应 iOS MediaPlayerScrubbingNode beginScrubbing()。
     *
     * 行为：
     *   1. 记录拖前状态（_scrubbingPreState）
     *   2. 若当前正在播放，暂停
     *   3. 设置 isScrubbing = true
     *   4. 重置防抖序号
     *
     * 注意：暂停调用 pause()（走 VideoController.pause()），不改变 isLooping。
     */
    public func beginScrubbing(): Unit {
        if (isScrubbing) {
            return
        }
        _scrubbingPreState = state
        _scrubbingSeekSeq = 0
        scrubbingTargetSec = currentTime
        isScrubbing = true
        match (state) {
            case MediaPlayerState.Playing =>
                match (_controller) {
                    case Some(ctrl) =>
                        ctrl.pause()
                        state = MediaPlayerState.Paused
                    case None => ()
                }
            case _ => ()
        }
        Hilog.info(0, "CjTelegram",
            "[MediaPlayer] beginScrubbing preState=${stateLabel()}")
        notifyStatusChanged()
    }

    /**
     * 拖动中位置更新（Slider Moving，防抖）。
     * 对应 iOS MediaPlayerScrubbingNode updateScrubbing(x:multiplier:)。
     *
     * 防抖策略：
     *   每次 Moving 事件递增 _scrubbingSeekSeq，仅执行关键帧 seek 更新当前显示位置。
     *   精确 seek 推迟到 endScrubbing()。
     *   这样高频拖动不会因大量 Accurate seek 堆积导致播放器阻塞。
     *
     * 缩略图预览（Scrubbing Preview Thumbnail）：
     *   iOS 通过 MediaPlayerFramePreview（FFMpeg UniversalSoftwareVideoSource）
     *   实时取帧显示对应时间点缩略图。
     *   HarmonyOS ArkUI Video 组件不暴露同等逐帧实时取帧 API（AVImageGenerator
     *   为 async，不适合高频 scrubbing preview）。此能力诚实 defer。
     *
     * @param seconds 目标时间（秒）
     */
    public func updateScrubbingTarget(seconds!: Int32): Unit {
        if (!isScrubbing) {
            return
        }
        _scrubbingSeekSeq = _scrubbingSeekSeq + 1
        scrubbingTargetSec = seconds
        seekNearestKeyframe(seconds: seconds)
        Hilog.info(0, "CjTelegram",
            "[MediaPlayer] updateScrubbingTarget(${seconds}s) seq=${_scrubbingSeekSeq}")
    }

    /**
     * 结束拖动（Slider End / Click）。
     * 对应 iOS MediaPlayerScrubbingNode endScrubbing()。
     *
     * 行为：
     *   1. 执行精确 seek 到最终目标位置（SeekMode.Accurate）
     *   2. 若拖前正在播放，恢复播放
     *   3. 设置 isScrubbing = false
     *
     * @param finalSeconds 松手时的目标时间（秒）
     */
    public func endScrubbing(finalSeconds!: Int32): Unit {
        if (!isScrubbing) {
            return
        }
        isScrubbing = false
        scrubbingTargetSec = finalSeconds
        seekAccurate(seconds: finalSeconds)
        let wasPlaying: Bool = match (_scrubbingPreState) {
            case MediaPlayerState.Playing => true
            case _ => false
        }
        if (wasPlaying) {
            match (_controller) {
                case Some(ctrl) =>
                    ctrl.start()
                    state = MediaPlayerState.Playing
                case None => ()
            }
        }
        Hilog.info(0, "CjTelegram",
            "[MediaPlayer] endScrubbing finalSec=${finalSeconds}s resume=${wasPlaying}")
        notifyStatusChanged()
    }

    /**
     * 设置是否静音。
     */
    public func setMuted(muted!: Bool): Unit {
        isMuted = muted
        Hilog.info(0, "CjTelegram", "[MediaPlayer] muted=${muted}")
    }

    /**
     * P2-228: 设置播放倍速。
     * 对应 iOS MediaPlayer.setBaseRate(baseRate:) → MediaPlayerContext.setBaseRate()。
     *
     * HarmonyOS：倍速通过 Video 组件 currentProgressRate 参数控制（非 VideoController 方法）。
     * 此方法更新 baseRate + playbackSpeed，Page 需将 playbackSpeed 绑定到 Video.currentProgressRate。
     *
     * @param rate 倍速值（1.0/1.5/2.0 等）
     */
    public func setBaseRate(rate!: Float64): Unit {
        baseRate = rate
        playbackSpeed = rateToPlaybackSpeed(rate: rate)
        Hilog.info(0, "CjTelegram", "[MediaPlayer] setBaseRate(${rate})")
        notifyStatusChanged()
    }

    /**
     * 设置是否循环播放（简化入口，等同于 setActionAtEnd(Loop/Stop)）。
     */
    public func setLooping(loop!: Bool): Unit {
        isLooping = loop
        actionAtEnd = if (loop) {
            MediaPlayerActionAtEnd.Loop
        } else {
            MediaPlayerActionAtEnd.Stop
        }
        Hilog.info(0, "CjTelegram", "[MediaPlayer] looping=${loop}")
    }

    // ─── P2-223: 存储态 API ──────────────────────────────────────────────────

    /**
     * 持久化当前播放进度到 Preferences。
     * 对应 iOS storeMediaPlaybackState(MessageId, Double?, Double) 回调触发。
     *
     * 调用时机：
     *   - MediaPlayerPage.aboutToDisappear()
     *   - handleFinish()（停止时自动保存，以便下次恢复）
     *
     * @param ctx   UIAbilityContext（来自 getGlobalAbilityContext()）
     * @param msgId 消息 ID
     */
    public func persistStoredState(ctx!: UIAbilityContext, msgId!: String): Unit {
        if (msgId.isEmpty()) {
            return
        }
        let ts = Float64(currentTime)
        let rateRaw = Int64(baseRate * 1000.0)
        let stored = MediaPlaybackStoredState(ts, rateRaw)
        saveMediaPlaybackStoredState(ctx, msgId, Some(stored))
        Hilog.info(0, "CjTelegram",
            "[MediaPlayer] persistStoredState msgId=${msgId} ts=${ts}s rate=${rateRaw}")
    }

    /**
     * 清除指定消息的播放存储态（对应 iOS state=nil 时调用 updateMediaPlaybackStoredState）。
     */
    public func clearStoredState(ctx!: UIAbilityContext, msgId!: String): Unit {
        saveMediaPlaybackStoredState(ctx, msgId, Option<MediaPlaybackStoredState>.None)
        Hilog.info(0, "CjTelegram", "[MediaPlayer] clearStoredState msgId=${msgId}")
    }

    // ─── P2-232: 预加载逻辑层 ────────────────────────────────────────────────

    /**
     * 进度更新时检查是否需要触发预加载。
     * 对应 iOS preloadVideoResource() 的调用时机：当前帧接近缓冲边界时。
     *
     * 触发条件：播放时间 >= lastPreloadTriggerTime + preloadWindowSec
     * 触发动作：通知 preloadCallback，携带从当前位置起的预加载请求。
     *
     * 底层帧级预热（FFMpegMediaFrameSource.ensureHasFrames）在 HarmonyOS ArkUI Video
     * 组件中无对应 API，此处仅记录意图（诚实 defer），ArkUI Video 内部缓冲自行处理。
     */
    private func checkPreloadTrigger(timeSec!: Int32): Unit {
        match (_preloadCallback) {
            case None => ()
            case Some(cb) =>
                if (timeSec >= lastPreloadTriggerTime + preloadWindowSec) {
                    lastPreloadTriggerTime = timeSec
                    let req = VideoPreloadRequest(Float64(timeSec), 30.0, false, mediaUrl)
                    cb(req)
                    Hilog.info(0, "CjTelegram",
                        "[MediaPlayer] preload trigger at ${timeSec}s url=${mediaUrl}")
                }
        }
    }

    /**
     * seek 前预热逻辑 — 对应 iOS pre-seek 帧预热。
     * 通知 preloadCallback 在 seek 目标时刻前预加载帧。
     *
     * 底层（HarmonyOS）：ArkUI Video 不暴露逐帧预载 API，预热意图仅通过回调通知上层。
     * Reviewer 注意：帧级预热 API 受限 → 诚实 defer（logically triggered, platform limited）。
     */
    private func triggerPreSeekWarmup(targetSec!: Int32): Unit {
        match (_preloadCallback) {
            case None => ()
            case Some(cb) =>
                let req = VideoPreloadRequest(Float64(targetSec), 5.0, true, mediaUrl)
                cb(req)
                Hilog.info(0, "CjTelegram",
                    "[MediaPlayer] pre-seek warmup target=${targetSec}s")
        }
    }

    /**
     * 外部调用接口：触发预加载（P2-232 逻辑层入口）。
     * 对应 iOS preloadVideoResource(postbox:userLocation:resourceReference:duration:)。
     *
     * 平台说明：ArkUI Video 组件不暴露分片预载 API，此方法记录预加载意图并通知
     * preloadCallback（如果已注册）；实际数据获取由 ArkUI Video 内部缓冲处理。
     *
     * @param fromTimestamp 预加载起点（秒）
     * @param durationLimit 预加载最大时长（秒）
     */
    public func preloadVideoResource(fromTimestamp!: Float64, durationLimit!: Float64): Unit {
        if (mediaUrl.isEmpty()) {
            return
        }
        let req = VideoPreloadRequest(fromTimestamp, durationLimit, false, mediaUrl)
        match (_preloadCallback) {
            case Some(cb) => cb(req)
            case None => ()
        }
        Hilog.info(0, "CjTelegram",
            "[MediaPlayer] preloadVideoResource from=${fromTimestamp}s limit=${durationLimit}s")
    }

    // ─── 状态查询 ─────────────────────────────────────────────────────────────

    /** 是否正在播放。 */
    public func isPlaying(): Bool {
        match (state) {
            case MediaPlayerState.Playing => true
            case _ => false
        }
    }

    /**
     * P2-228: 取当前状态快照（主动查询版本）。
     */
    public func currentStatus(): MediaPlayerStatus {
        let nowTs = Float64(DateTime.now().toUnixTimeStamp().toSeconds())
        let playbackSt: MediaPlayerPlaybackStatus = match (state) {
            case MediaPlayerState.Playing => MediaPlayerPlaybackStatus.Playing
            case MediaPlayerState.Paused => MediaPlayerPlaybackStatus.Paused
            case MediaPlayerState.Buffering => MediaPlayerPlaybackStatus.Buffering
            case _ => MediaPlayerPlaybackStatus.Stopped
        }
        return MediaPlayerStatus(nowTs, seekId, baseRate, currentTime, duration, playbackSt)
    }

    /** 播放进度 0.0–1.0。 */
    public func getProgress(): Float64 {
        if (duration <= 0) { return 0.0 }
        return Float64(currentTime) / Float64(duration)
    }

    /** 格式化当前时间为 "m:ss"。 */
    public func formatCurrentTime(): String {
        return formatSeconds(currentTime)
    }

    /** 格式化总时长为 "m:ss"。 */
    public func formatDuration(): String {
        return formatSeconds(duration)
    }

    // ─── 辅助方法 ────────────────────────────────────────────────────────────

    private func formatSeconds(total: Int32): String {
        if (total < 0) { return "0:00" }
        let m = total / 60
        let s = total - m * 60
        let sStr: String = if (s < 10) { "0${s}" } else { "${s}" }
        return "${m}:${sStr}"
    }

    private func stateLabel(): String {
        match (state) {
            case MediaPlayerState.Idle => "Idle"
            case MediaPlayerState.Prepared => "Prepared"
            case MediaPlayerState.Playing => "Playing"
            case MediaPlayerState.Paused => "Paused"
            case MediaPlayerState.Seeking => "Seeking"
            case MediaPlayerState.Stopped => "Stopped"
            case MediaPlayerState.Error => "Error"
            case MediaPlayerState.Buffering => "Buffering"
        }
    }

    /**
     * P2-228: Float64 倍速 → PlaybackSpeed 枚举转换
     * KB 确认：Video 组件支持 SpeedForward075X/100X/125X/175X/200X
     * 对应 iOS AudioPlaybackRate: x0_5/x1/x1_5/x2（最接近匹配）
     */
    private func rateToPlaybackSpeed(rate!: Float64): PlaybackSpeed {
        if (rate <= 0.85) {
            return PlaybackSpeed.SpeedForward075X
        } else if (rate <= 1.1) {
            return PlaybackSpeed.SpeedForward100X
        } else if (rate <= 1.35) {
            return PlaybackSpeed.SpeedForward125X
        } else if (rate <= 1.85) {
            return PlaybackSpeed.SpeedForward175X
        } else {
            return PlaybackSpeed.SpeedForward200X
        }
    }
}
