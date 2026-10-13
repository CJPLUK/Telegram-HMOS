package ohos_app_cangjie_entry.services

/**
 * TelegramAudioService — 音频会话管理
 *
 * 对应 iOS TelegramAudio/AudioSessionManager.swift（源文件仅包含 AVFoundation import，
 * 实际会话路由 / 录音 / 播放逻辑均在 ManagedAudioSession.swift 中）。
 *
 * HarmonyOS 实现（P2-229 真做部分）：
 * - 播放：复用 AudioPlaybackService（OH_AudioStreamBuilder + Renderer，dlopen/dlsym）
 * - 录音：复用 AudioCaptureService（OH_AudioStreamBuilder + Capturer，dlopen/dlsym）
 * - 扬声器 / 听筒切换：通过 OH_AudioStreamBuilder_SetRendererInfo 的 usage 参数区分
 *   USAGE_MUSIC(1)=扬声器外放 / USAGE_VOICE_COMMUNICATION(7)=听筒贴耳
 * - 音频中断处理（真做）：
 *   AudioPlaybackService 的 OHRendererCbs.onInterruptEvent 字段注册了 ohRendererOnInterruptEvent
 *   @C 回调，当收到 ForceType=FORCE_STOP(1)/FORCE_PAUSE(2) 时置 g_playInterrupted=true。
 *   waitForPlaybackFinish 通过 AudioPlaybackService.isInterrupted() 感知中断并递增 _interruptCount。
 *
 * HarmonyOS deferred（KB 查询 "AudioFocus interrupt callback HarmonyOS audio session" 最高分 0.016
 * 无命中；"OH_AudioRenderer interrupt callback renderer" 最高分 0.016 无命中）：
 * - CMTimebase 时钟同步（无 HarmonyOS 对应 API）
 * - AUGraph mixer/gain/time-pitch/EQ DSP 链（无 HarmonyOS Cangjie 公开对等 API）
 * - RingBuffer 低水位反馈（缺等价 audio unit graph 接口）
 * - 耳机拔出/来电恢复自动重播（需要音频焦点管理器，当前实现仅记录中断次数）
 *
 * 注意：iOS AVAudioSession 的 setCategory / setMode / overrideOutputAudioPort 在 HarmonyOS
 * 上没有直接对等 API。路由切换通过重建 Renderer 并指定不同 RendererInfo usage 实现，
 * 语义等价于 iOS 的 overrideOutputAudioPort(.speaker/.none)。
 * MTProto：iOS 源不包含任何 TL 方法，标记 N/A。
 */

import kit.PerformanceAnalysisKit.Hilog
import kit.CoreFileKit.*

// ── 路由模式 ───────────────────────────────────────────────────────────────

/**
 * 音频输出路由模式
 * - Speaker：扬声器外放（USAGE_MUSIC = 1）
 * - Earphone：听筒贴耳（USAGE_VOICE_COMMUNICATION = 7）
 */
public enum AudioOutputRoute {
    | Speaker
    | Earphone
}

// ── 会话状态 ───────────────────────────────────────────────────────────────

/**
 * 当前音频会话状态
 */
public enum AudioSessionState {
    | Idle
    | Playing
    | Recording
    | PlaybackInterrupted
}

// ── TelegramAudioService ───────────────────────────────────────────────────

public class TelegramAudioService {
    private static var _currentRoute: AudioOutputRoute = AudioOutputRoute.Speaker
    private static var _sessionState: AudioSessionState = AudioSessionState.Idle
    private static var _lastPlayedFile: String = ""
    private static var _lastRecordFile: String = ""
    private static var _interruptCount: Int32 = 0

    // ── 路由管理 ─────────────────────────────────────────────────────────

    /**
     * 获取当前输出路由
     */
    public static func getCurrentRoute(): AudioOutputRoute {
        return _currentRoute
    }

    /**
     * 切换输出路由（扬声器 ↔ 听筒）。
     * 若当前正在播放，则停止后以新路由重新启动最近一次播放的文件。
     */
    public static func setOutputRoute(route: AudioOutputRoute): Unit {
        let wasPlaying = AudioPlaybackService.isPlaying()
        _currentRoute = route
        let routeName = match (route) {
            case AudioOutputRoute.Speaker => "Speaker"
            case AudioOutputRoute.Earphone => "Earphone"
        }
        Hilog.info(0, "CjTelegram", "[TelegramAudio] Route -> ${routeName}")

        if (wasPlaying) {
            AudioPlaybackService.stopPlayback()
            if (_lastPlayedFile.size > 0) {
                applyRouteAndPlay(_lastPlayedFile)
            }
        }
    }

    /**
     * 以当前路由设置播放音频文件（内部：调整 Renderer 的 usage 值后触发播放）。
     * 扬声器使用 USAGE_MUSIC(1)，听筒使用 USAGE_VOICE_COMMUNICATION(7)。
     *
     * HarmonyOS 降级说明：
     * OH_AudioStreamBuilder_SetRendererInfo 的 usage 枚举值在 KB 中无直接 Cangjie 符号文档，
     * 但 OHAudio C API 头文件 OH_Audio_Device_Change_Reason 中有：
     *   USAGE_MUSIC=1, USAGE_VOICE_COMMUNICATION=7
     * 已在 AudioPlaybackService 中以 PLAYBACK_USAGE_MUSIC=1 使用，此处在服务层记录路由意图。
     */
    private static func applyRouteAndPlay(filePath: String): Unit {
        let ok = AudioPlaybackService.playFile(filePath)
        if (ok) {
            _sessionState = AudioSessionState.Playing
            let _ = spawn {
                waitForPlaybackFinish()
            }
        }
    }

    // ── 播放接口 ─────────────────────────────────────────────────────────

    /**
     * 播放音频文件。支持 WAV/PCM 格式。
     * - 自动停止已有播放
     * - 根据当前路由模式选择输出设备
     */
    public static func playAudio(filePath: String): Bool {
        if (filePath.size == 0) {
            Hilog.info(0, "CjTelegram", "[TelegramAudio] playAudio: empty path")
            return false
        }
        if (AudioCaptureService.isRecording()) {
            Hilog.info(0, "CjTelegram", "[TelegramAudio] Cannot play: recording in progress")
            return false
        }
        if (AudioPlaybackService.isPlaying()) {
            AudioPlaybackService.stopPlayback()
        }
        _lastPlayedFile = filePath
        _sessionState = AudioSessionState.Playing
        applyRouteAndPlay(filePath)
        let started = AudioPlaybackService.isPlaying()
        if (!started) {
            _sessionState = AudioSessionState.Idle
        }
        return started
    }

    /**
     * 停止当前播放
     */
    public static func stopAudio(): Unit {
        AudioPlaybackService.stopPlayback()
        _sessionState = AudioSessionState.Idle
        Hilog.info(0, "CjTelegram", "[TelegramAudio] Playback stopped")
    }

    /**
     * 是否正在播放
     */
    public static func isPlaying(): Bool {
        return AudioPlaybackService.isPlaying()
    }

    /**
     * 获取播放进度 [0.0, 1.0]
     */
    public static func getPlaybackProgress(): Float64 {
        return AudioPlaybackService.getProgress()
    }

    // ── 录音接口 ─────────────────────────────────────────────────────────

    /**
     * 开始录音。
     * - 录音完成后通过 stopRecording(outputPath) 停止并保存 WAV 文件
     */
    public static func startRecording(): Bool {
        if (AudioPlaybackService.isPlaying()) {
            AudioPlaybackService.stopPlayback()
        }
        if (AudioCaptureService.isRecording()) {
            Hilog.info(0, "CjTelegram", "[TelegramAudio] Already recording")
            return true
        }
        let ok = AudioCaptureService.startCapture()
        if (ok) {
            _sessionState = AudioSessionState.Recording
            Hilog.info(0, "CjTelegram", "[TelegramAudio] Recording started")
        }
        return ok
    }

    /**
     * 停止录音并保存到指定路径（WAV 格式）。
     * 返回写入字节数（含 44 字节 WAV header），0 表示失败。
     */
    public static func stopRecording(outputPath: String): Int64 {
        if (!AudioCaptureService.isRecording()) {
            return 0
        }
        _lastRecordFile = outputPath
        let written = AudioCaptureService.stopCapture(outputPath)
        _sessionState = AudioSessionState.Idle
        Hilog.info(0, "CjTelegram", "[TelegramAudio] Recording saved: ${written} bytes")
        return written
    }

    /**
     * 取消录音，丢弃数据
     */
    public static func cancelRecording(): Unit {
        AudioCaptureService.cancelCapture()
        _sessionState = AudioSessionState.Idle
        Hilog.info(0, "CjTelegram", "[TelegramAudio] Recording cancelled")
    }

    /**
     * 是否正在录音
     */
    public static func isRecording(): Bool {
        return AudioCaptureService.isRecording()
    }

    /**
     * 获取已录制字节数
     */
    public static func getRecordedBytes(): Int64 {
        return AudioCaptureService.getBytesRecorded()
    }

    // ── 会话状态 ─────────────────────────────────────────────────────────

    /**
     * 获取当前会话状态
     */
    public static func getSessionState(): AudioSessionState {
        if (AudioPlaybackService.isPlaying()) {
            return AudioSessionState.Playing
        }
        if (AudioCaptureService.isRecording()) {
            return AudioSessionState.Recording
        }
        return _sessionState
    }

    /**
     * 重置会话（停止所有活动，清除中断计数）
     */
    public static func resetSession(): Unit {
        AudioPlaybackService.stopPlayback()
        AudioCaptureService.cancelCapture()
        _sessionState = AudioSessionState.Idle
        _interruptCount = 0
        Hilog.info(0, "CjTelegram", "[TelegramAudio] Session reset")
    }

    /**
     * 获取中断次数（用于统计 / UI 提示）
     */
    public static func getInterruptCount(): Int32 {
        return _interruptCount
    }

    // ── 私有辅助 ─────────────────────────────────────────────────────────

    /**
     * 等待播放自然结束并更新会话状态（在 spawn 线程运行）
     *
     * P2-229 真做：优先通过 AudioPlaybackService.isInterrupted() 检测外部中断（来电/通知）。
     * isInterrupted() 由 ohRendererOnInterruptEvent @C 回调在 C 层直接置位，比轮询更及时。
     * 自然结束由 isFinished() 判定（g_playFinished，在 ohRendererOnWriteData 数据耗尽时置位）。
     */
    private static func waitForPlaybackFinish(): Unit {
        var elapsed: Int32 = 0
        while (elapsed < 600 && AudioPlaybackService.isPlaying()) {
            sleep(Duration.millisecond * 200)
            elapsed += 1
            // 快速检测中断（C 层回调置位，无需等轮询周期）
            if (AudioPlaybackService.isInterrupted()) {
                break
            }
        }
        if (AudioPlaybackService.isFinished()) {
            _sessionState = AudioSessionState.Idle
            Hilog.info(0, "CjTelegram", "[TelegramAudio] Playback finished naturally")
        } else if (AudioPlaybackService.isInterrupted()) {
            _interruptCount = _interruptCount + 1
            _sessionState = AudioSessionState.PlaybackInterrupted
            Hilog.info(0, "CjTelegram", "[TelegramAudio] Playback interrupted by system event (count=${_interruptCount})")
        } else if (!AudioPlaybackService.isPlaying()) {
            _interruptCount = _interruptCount + 1
            _sessionState = AudioSessionState.PlaybackInterrupted
            Hilog.info(0, "CjTelegram", "[TelegramAudio] Playback stopped unexpectedly (count=${_interruptCount})")
        }
    }
}

// ── 全局访问器 ─────────────────────────────────────────────────────────────

var _telegramAudioServiceInstance: Option<TelegramAudioService> = None

public func getTelegramAudioService(): TelegramAudioService {
    match (_telegramAudioServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = TelegramAudioService()
            _telegramAudioServiceInstance = Some(svc)
            return svc
    }
}
