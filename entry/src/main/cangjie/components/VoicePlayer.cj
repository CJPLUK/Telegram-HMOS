package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.time.DateTime
import ohos_app_cangjie_entry.services.ArkAudioPlayerBridge

/** UI progress tick (~30fps) and how many ticks pass between AVPlayer samples. */
private let VOICE_PROGRESS_TICK_MS: Int64 = 33
private let VOICE_PROGRESS_SAMPLE_EVERY: Int64 = 6

public enum PlaybackState {
    Idle | Loading | Playing | Paused
}

private var _voicePlayerInstance: Option<VoicePlayerManager> = None

public func getVoicePlayerManager(): VoicePlayerManager {
    match (_voicePlayerInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = VoicePlayerManager()
            _voicePlayerInstance = Some(inst)
            return inst
    }
}

public class VoicePlayerManager {
    public var currentMessageId: Int64 = -1
    public var playbackState: PlaybackState = PlaybackState.Idle
    public var currentProgress: Int32 = 0
    public var totalDuration: Int32 = 0
    
    private var _playbackActive: Bool = false
    private var _progressMs: Int32 = 0
    // Last AVPlayer position sample and when it was taken. Between samples the
    // position is extrapolated on a ~30fps UI tick, the same way iOS
    // ChatMessageInteractiveFileNode derives playerPosition from
    // status.timestamp + (CACurrentMediaTime() - generationTimestamp).
    private var _sampleMs: Int64 = 0
    private var _sampleAtMs: Int64 = 0
    private var _durationMs: Int64 = 0
    // No extrapolation until AVPlayer has reported a position for this playback,
    // otherwise prepare latency would make the fill run ahead and jump back.
    private var _hasLiveSample: Bool = false
    private var _currentFilePath: String = ""
    private var _preloadedFilePath: String = ""
    private var _playbackGeneration: Int64 = 0
    
    private var _onProgressUpdate: Option<() -> Unit> = None
    
    public func setOnProgressUpdate(callback: () -> Unit): Unit {
        this._onProgressUpdate = Some(callback)
    }
    
    public func clearOnProgressUpdate(): Unit {
        this._onProgressUpdate = None
    }

    /**
     * 将本地语音送入 AVPlayer 的 prepared 状态。这里只预备空闲播放器，
     * 不抢占正在播放或暂停的共享语音会话。
     */
    public func preload(messageId: Int64, fileUri: String): Unit {
        if (fileUri.size == 0 || this.currentMessageId != -1) { return }
        var preloadPath = fileUri
        if (preloadPath.startsWith("file://")) {
            preloadPath = preloadPath[7..]
        }
        if (preloadPath == this._preloadedFilePath) { return }
        this._preloadedFilePath = preloadPath
        ArkAudioPlayerBridge.preload(preloadPath)
        Hilog.info(0, "CjTelegram", "[VoicePlayer] Preloading msgId=${messageId}")
    }

    // 自然播完（非 stop()）回调，带刚播完的 messageId；用于连续播放下一条
    private var _onFinished: Option<(Int64) -> Unit> = None

    public func setOnFinished(callback: (Int64) -> Unit): Unit {
        this._onFinished = Some(callback)
    }
    
    /**
     * 播放语音消息 — 使用系统 AVPlayer 解码并播放音频
     */
    public func play(messageId: Int64, fileUri: String, duration: Int32) {
        if (this.currentMessageId != -1 && this.currentMessageId != messageId) {
            this.stop()
        }
        
        if (this.currentMessageId == messageId) {
            match (this.playbackState) {
                case Loading =>
                    this.pause()
                    return
                case Playing =>
                    this.pause()
                    return
                case Paused =>
                    this.resume()
                    return
                case _ => ()
            }
        }
        
        this.currentMessageId = messageId
        this.totalDuration = if (duration > 0) { duration } else { 1 }
        this.currentProgress = 0
        this._progressMs = 0
        this._durationMs = Int64(this.totalDuration) * 1000
        this.resetSample(0, live: false)
        // 与 iOS 的按钮反馈一致：本地文件点击后立即进入播放视觉态。
        // AVPlayer 已由会话首帧/按下事件预备；即使预备尚在收尾，ArkTS 的
        // playing intent 也会在 prepared 回调中自动启动。
        this.playbackState = PlaybackState.Playing
        this._playbackActive = true
        this._playbackGeneration += 1
        let generation = this._playbackGeneration
        
        var playPath = fileUri
        if (playPath.startsWith("file://")) {
            playPath = playPath[7..]
        }
        this._currentFilePath = playPath
        this._preloadedFilePath = playPath
        
        Hilog.info(0, "CjTelegram", "[VoicePlayer] Playing msgId=${messageId}, path=${playPath}, duration=${duration}s")
        
        // iOS 对 OGG/Opus 与历史 WAV 使用同一套 MediaPlayer 状态机。鸿蒙也统一交给
        // AVPlayer，避免 WAV 分支 stop 后无法从暂停位置恢复。
        ArkAudioPlayerBridge.play(playPath)

        this.startProgressPolling(generation, messageId)
    }

    private func startProgressPolling(generation: Int64, messageId: Int64): Unit {
        // arkCallSync 要等待 ArkTS 回调，不能放到 UI task，否则回调无 JS scope 并把
        // 主线程堵到 THREAD_BLOCK_6S。后台只更新播放器模型，页面回调再用 launch 重绘。
        // AVPlayer is sampled every 6th tick (~200ms) to keep bridge traffic low;
        // the ticks in between extrapolate the position so the waveform fill and
        // the time label advance continuously instead of once per whole second.
        spawn {
            var tick: Int64 = 0
            while (this._playbackActive && generation == this._playbackGeneration) {
                sleep(Duration.millisecond * VOICE_PROGRESS_TICK_MS)
                if (!this._playbackActive || generation != this._playbackGeneration) { break }
                let sampleNow = tick % VOICE_PROGRESS_SAMPLE_EVERY == 0
                tick += 1
                match (this.playbackState) {
                    case Loading =>
                        if (!sampleNow) { continue }
                        let st = ArkAudioPlayerBridge.state()
                        if (st.state == "completed") {
                            this.onPlaybackComplete(generation, messageId)
                            break
                        }
                        if (st.state == "error") {
                            this.onPlaybackError(generation, messageId)
                            break
                        }
                        if (st.state == "playing") {
                            this.playbackState = PlaybackState.Playing
                        }
                        if (st.state == "paused") {
                            this.playbackState = PlaybackState.Paused
                        }
                        this.updateArkProgress(st.positionMs, st.durationMs)
                    case Playing =>
                        if (!sampleNow) {
                            this.extrapolateProgress()
                            continue
                        }
                        let st = ArkAudioPlayerBridge.state()
                        if (st.state == "completed") {
                            this.onPlaybackComplete(generation, messageId)
                            break
                        }
                        if (st.state == "error") {
                            this.onPlaybackError(generation, messageId)
                            break
                        }
                        if (st.state == "paused") {
                            this.playbackState = PlaybackState.Paused
                        }
                        this.updateArkProgress(st.positionMs, st.durationMs)
                    case Paused => ()
                    case _ => ()
                }
            }
        }
    }

    private func nowMs(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    private func resetSample(positionMs: Int64, live!: Bool = true): Unit {
        this._sampleMs = positionMs
        this._sampleAtMs = this.nowMs()
        this._hasLiveSample = live
    }

    private func extrapolateProgress(): Unit {
        if (!this._hasLiveSample) { return }
        var position = this._sampleMs + (this.nowMs() - this._sampleAtMs)
        if (this._durationMs > 0 && position > this._durationMs) { position = this._durationMs }
        if (position < 0) { position = 0 }
        this._progressMs = Int32(position)
        this.currentProgress = this._progressMs / 1000
        this.notifyProgressUpdate()
    }

    public func pause() {
        match (this.playbackState) {
            case Loading =>
                this.playbackState = PlaybackState.Paused
                ArkAudioPlayerBridge.pause()
                Hilog.info(0, "CjTelegram", "[VoicePlayer] Pause requested while loading")
                this.notifyProgressUpdate()
            case Playing =>
                this.playbackState = PlaybackState.Paused
                ArkAudioPlayerBridge.pause()
                Hilog.info(0, "CjTelegram", "[VoicePlayer] Paused at ${this.currentProgress}s")
                this.notifyProgressUpdate()
            case _ => ()
        }
    }
    
    public func resume() {
        match (this.playbackState) {
            case Paused =>
                this.playbackState = PlaybackState.Playing
                this.resetSample(Int64(this._progressMs))
                if (!this._playbackActive) {
                    this._playbackActive = true
                    this._playbackGeneration += 1
                    this.startProgressPolling(this._playbackGeneration, this.currentMessageId)
                }
                ArkAudioPlayerBridge.resume()
                Hilog.info(0, "CjTelegram", "[VoicePlayer] Resumed from ${this.currentProgress}s")
                this.notifyProgressUpdate()
            case _ => ()
        }
    }
    
    public func stop() {
        this._playbackActive = false
        this._playbackGeneration += 1
        this.playbackState = PlaybackState.Idle
        this.currentMessageId = -1
        this.currentProgress = 0
        this._progressMs = 0
        this.totalDuration = 0
        this._durationMs = 0
        this.resetSample(0, live: false)
        this._preloadedFilePath = ""
        ArkAudioPlayerBridge.stop()
        Hilog.info(0, "CjTelegram", "[VoicePlayer] Stopped")
        this.notifyProgressUpdate()
    }
    
    public func seek(seconds: Int32): Unit {
        if (this.currentMessageId == -1) { return }
        var clampedSec = seconds
        if (clampedSec < 0) { clampedSec = 0 }
        if (clampedSec >= this.totalDuration) { clampedSec = this.totalDuration - 1 }
        this._progressMs = clampedSec * 1000
        this.resetSample(Int64(clampedSec) * 1000)
        ArkAudioPlayerBridge.seek(Int64(clampedSec) * 1000)
        this.currentProgress = clampedSec
        Hilog.info(0, "CjTelegram", "[VoicePlayer] Seek")
        this.notifyProgressUpdate()
    }
    
    private func updateArkProgress(positionMs: Int64, durationMs: Int64): Unit {
        if (durationMs > 0) {
            this._durationMs = durationMs
            let d = Int32(durationMs / 1000)
            if (d > 0) { this.totalDuration = d }
        }
        this.resetSample(positionMs, live: positionMs > 0 || this._hasLiveSample)
        this._progressMs = Int32(positionMs)
        this.currentProgress = this._progressMs / 1000
        this.notifyProgressUpdate()
    }

    private func onPlaybackComplete(generation: Int64, messageId: Int64) {
        if (generation != this._playbackGeneration || messageId != this.currentMessageId) { return }
        this._playbackActive = false
        this._playbackGeneration += 1
        // 保留已完成的 AVPlayer 和当前消息，重播时直接 seek(0)+play，避免再次
        // release/create/prepare 带来的明显延迟。若要连续播放下一条，play(next) 会先 stop。
        this.playbackState = PlaybackState.Paused
        this.currentProgress = 0
        this._progressMs = 0
        Hilog.info(0, "CjTelegram", "[VoicePlayer] Playback complete for msgId=${this.currentMessageId}")
        let finishedId = this.currentMessageId
        this.notifyProgressUpdate()
        match (this._onFinished) {
            case Some(cb) => cb(finishedId)
            case None => ()
        }
    }

    private func onPlaybackError(generation: Int64, messageId: Int64): Unit {
        if (generation != this._playbackGeneration || messageId != this.currentMessageId) { return }
        this._playbackActive = false
        this._playbackGeneration += 1
        this.playbackState = PlaybackState.Idle
        this.currentProgress = 0
        this._progressMs = 0
        this.currentMessageId = -1
        this._preloadedFilePath = ""
        ArkAudioPlayerBridge.stop()
        Hilog.info(0, "CjTelegram", "[VoicePlayer] Playback failed for msgId=${messageId}")
        this.notifyProgressUpdate()
    }
    
    private func notifyProgressUpdate(): Unit {
        match (this._onProgressUpdate) {
            case Some(cb) => cb()
            case None => ()
        }
    }
    
    public func getStateForMessage(messageId: Int64): PlaybackState {
        if (this.currentMessageId != messageId) {
            return PlaybackState.Idle
        }
        return this.playbackState
    }
    
    public func getProgressForMessage(messageId: Int64): Int32 {
        if (this.currentMessageId != messageId) {
            return 0
        }
        return this.currentProgress
    }
    
    /** Playback position in ms for the given message (0 when it is not current). */
    public func getProgressMsForMessage(messageId: Int64): Int64 {
        if (this.currentMessageId != messageId) { return 0 }
        return Int64(this._progressMs)
    }

    /** Player-reported duration in ms for the current message, else `fallbackSeconds`. */
    public func getDurationMsForMessage(messageId: Int64, fallbackSeconds: Int32): Int64 {
        if (this.currentMessageId == messageId && this._durationMs > 0) { return this._durationMs }
        return Int64(fallbackSeconds) * 1000
    }

    public func isPlaying(messageId: Int64): Bool {
        if (this.currentMessageId != messageId) { return false }
        match (this.playbackState) {
            case Playing => return true
            case _ => return false
        }
    }
}
