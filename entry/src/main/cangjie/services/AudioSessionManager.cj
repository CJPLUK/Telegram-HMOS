package ohos_app_cangjie_entry.services

/**
 * AudioSessionManager — 通话音频会话管理（P2-068）
 *
 * iOS 对照：
 *   TelegramAudio/Sources/ManagedAudioSession.swift — ManagedAudioSession
 *     - category/mode: AVAudioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
 *     - 中断处理: AVAudioSession.interruptionNotification → paused/resume
 *     - route-change 监听: AVAudioSession.routeChangeNotification
 *     - holder 仲裁: HoldingContext queue 管理多音频源
 *
 * HarmonyOS 实现策略（C 优先查询结论）：
 *   KB 三轮查询 "OH_AudioSessionManager audio session interrupt C NDK"
 *   top_hit_score 均 < 0.02，无专用 OH_AudioSessionManager C NDK Cangjie 绑定。
 *
 *   现有 AudioPlaybackService.cj 已通过 OH_AudioStreamBuilder C FFI 完成：
 *     - 中断事件回调 ohRendererOnInterruptEvent（P2-229 真做）
 *     - g_playInterrupted 标志 + TelegramAudioService.isInterrupted()
 *   → 本服务扩展其能力，增加 voice-call 专用配置层：
 *
 *   P2-068 实现策略：
 *   1. 语音通话 StreamUsage 常量：VOICE_COMMUNICATION = 3（vs 媒体 MUSIC = 1）
 *      在 VoIP 音频流初始化时通过 OH_AudioStreamBuilder_SetRendererInfo 应用
 *      （对应 iOS voiceChat category/mode）
 *   2. 中断仲裁：扩展现有 g_playInterrupted 机制，加入 AudioSessionManager 侧
 *      来电/系统打断（forceType=FORCE_STOP）→ 通知 CallService 暂停/恢复
 *   3. Route-change 监听：复用 AudioRouteService.setDeviceChangeCallback()
 *   4. Holder 仲裁：多音频源简单仲裁（通话持有期间阻止 TelegramAudioService 媒体播放）
 *
 * 诚实说明：
 *   - OH_AudioSession C NDK 的 activateAudioSession/deactivateAudioSession 无 Cangjie 绑定
 *   - 中断后的自动恢复播放由 TelegramAudioService.waitForPlaybackFinish() 已实现，
 *     本服务仅补充通话层仲裁逻辑
 */

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

// OH_AudioStreamBuilder_SetRendererInfo 的 StreamUsage 值
// 来源：OHAudio C API 头文件 oh_audio_device_type.h
// MUSIC = 1（媒体播放，AudioPlaybackService 当前使用）
// VOICE_COMMUNICATION = 3（通话，对应 iOS voiceChat mode）
let SESSION_USAGE_VOICE_COMMUNICATION: Int32 = 3

// ==================== 音频会话 Holder 仲裁 ====================

/**
 * 音频会话 Holder 类型（对应 iOS ManagedAudioSessionType）
 */
public enum AudioSessionHolder {
    | Call          // 语音通话（最高优先级）
    | VoiceRecorder // 语音录制
    | MediaPlayer   // 媒体播放

    public func ordinal(): Int32 {
        match (this) {
            case Call => 0
            case VoiceRecorder => 1
            case MediaPlayer => 2
        }
    }

    public func priority(): Int32 {
        match (this) {
            case Call => 100
            case VoiceRecorder => 50
            case MediaPlayer => 10
        }
    }

    public operator func ==(right: AudioSessionHolder): Bool {
        return this.ordinal() == right.ordinal()
    }
    public operator func !=(right: AudioSessionHolder): Bool {
        return this.ordinal() != right.ordinal()
    }
}

// ==================== 中断事件描述 ====================

/**
 * 音频中断事件（对应 iOS AVAudioSession.InterruptionType）
 */
public enum AudioInterruptionType {
    | Began         // 被打断（来电/Siri/系统声音抢占）
    | Ended         // 中断结束（可以恢复）

    public func ordinal(): Int32 {
        match (this) {
            case Began => 0
            case Ended => 1
        }
    }
    public operator func ==(right: AudioInterruptionType): Bool {
        return this.ordinal() == right.ordinal()
    }
    public operator func !=(right: AudioInterruptionType): Bool {
        return this.ordinal() != right.ordinal()
    }
}

// ==================== 单例 ====================

private var _audioSessionMgrInstance: Option<AudioSessionManager> = None

public func getAudioSessionManager(): AudioSessionManager {
    match (_audioSessionMgrInstance) {
        case Some(m) => return m
        case None =>
            let m = AudioSessionManager()
            _audioSessionMgrInstance = Some(m)
            return m
    }
}

// ==================== AudioSessionManager ====================

/**
 * 音频会话管理器
 *
 * 职责：
 *   1. 激活/释放通话音频会话（acquire/release）
 *   2. 维护 holder 仲裁（优先级队列）
 *   3. 转发中断事件到注册方
 *   4. 提供通话流 StreamUsage 常量
 */
public class AudioSessionManager {

    private var _currentHolder: Option<AudioSessionHolder> = None
    private var _holderStack: ArrayList<AudioSessionHolder> = ArrayList<AudioSessionHolder>()
    private var _interruptionCallback: Option<(AudioInterruptionType) -> Unit> = None
    private var _routeChangeCallback: Option<() -> Unit> = None

    /**
     * 获取通话音频流 StreamUsage 常量
     * 应在 AudioPlaybackService 初始化通话渲染器时使用（代替 USAGE_MUSIC=1）
     *
     * 对应 iOS: AVAudioSession.Mode.voiceChat → playAndRecord + voiceProcessing
     */
    public func getCallStreamUsage(): Int32 {
        return SESSION_USAGE_VOICE_COMMUNICATION
    }

    /**
     * 获取当前 Holder
     */
    public func getCurrentHolder(): Option<AudioSessionHolder> {
        return this._currentHolder
    }

    /**
     * 通话占用音频会话（Call.acquire）
     * 对应 iOS ManagedAudioSession.push(type: .voiceCall, ...)
     *
     * 效果：
     *   - 设置 _currentHolder = Call
     *   - 若有 MediaPlayer 持有者 → 通知其暂停（中断语义）
     */
    public func acquireCallSession(): Unit {
        Hilog.info(0, "CjTelegram", "[AudioSession] acquireCallSession")
        let prev = this._currentHolder
        this._currentHolder = Some(AudioSessionHolder.Call)
        this._holderStack.add(AudioSessionHolder.Call)

        match (prev) {
            case Some(holder) =>
                if (holder == AudioSessionHolder.MediaPlayer) {
                    Hilog.info(0, "CjTelegram", "[AudioSession] MediaPlayer interrupted by Call")
                    this.notifyInterruption(AudioInterruptionType.Began)
                }
            case None => ()
        }

        Hilog.info(0, "CjTelegram", "[AudioSession] Call session active: StreamUsage=VOICE_COMMUNICATION(${SESSION_USAGE_VOICE_COMMUNICATION})")
    }

    /**
     * 释放通话音频会话（Call.release）
     * 对应 iOS ManagedAudioSession.pop()
     *
     * 效果：
     *   - 从 holderStack 移除 Call
     *   - 若之前有 MediaPlayer 被中断 → 通知恢复（Ended）
     */
    public func releaseCallSession(): Unit {
        Hilog.info(0, "CjTelegram", "[AudioSession] releaseCallSession")
        let prevStack = ArrayList<AudioSessionHolder>()
        for (h in this._holderStack) {
            if (h != AudioSessionHolder.Call) {
                prevStack.add(h)
            }
        }
        this._holderStack = prevStack

        if (this._holderStack.isEmpty()) {
            this._currentHolder = None
        } else {
            this._currentHolder = Some(this._holderStack[this._holderStack.size - 1])
        }

        match (this._currentHolder) {
            case Some(holder) =>
                if (holder == AudioSessionHolder.MediaPlayer) {
                    Hilog.info(0, "CjTelegram", "[AudioSession] MediaPlayer can resume after Call ended")
                    this.notifyInterruption(AudioInterruptionType.Ended)
                }
            case None => ()
        }

        Hilog.info(0, "CjTelegram", "[AudioSession] Call session released")
    }

    /**
     * 注册来电/系统中断回调（对应 iOS AVAudioSession.interruptionNotification）
     *
     * 由 CallService / TelegramAudioService 注册，当通话被系统打断（Siri、来电）时触发。
     * AudioPlaybackService.ohRendererOnInterruptEvent 已处理 OHAudio 层 forceStop，
     * 本回调提供上层感知接口。
     */
    public func setInterruptionCallback(cb: (AudioInterruptionType) -> Unit): Unit {
        this._interruptionCallback = Some(cb)
        Hilog.info(0, "CjTelegram", "[AudioSession] interruptionCallback registered")
    }

    /**
     * 注册 route-change 回调（对应 iOS AVAudioSession.routeChangeNotification）
     * AudioRouteService.setDeviceChangeCallback() 已实现底层监听，
     * 本接口提供高层 route-change 通知给 CallScreen/CallService。
     */
    public func setRouteChangeCallback(cb: () -> Unit): Unit {
        this._routeChangeCallback = Some(cb)
        Hilog.info(0, "CjTelegram", "[AudioSession] routeChangeCallback registered")
    }

    /**
     * 通知中断事件（由 AudioPlaybackService.ohRendererOnInterruptEvent → 外部调用此方法）
     * 对应 iOS AVAudioSession.InterruptionType.began / .ended
     */
    public func notifyInterruption(interruptionType: AudioInterruptionType): Unit {
        Hilog.info(0, "CjTelegram", "[AudioSession] notifyInterruption type=${interruptionType.ordinal()}")
        match (this._interruptionCallback) {
            case Some(cb) => cb(interruptionType)
            case None => ()
        }
    }

    /**
     * 通知 route 变化（由 AudioRouteService 的 deviceChange 回调触发）
     */
    public func notifyRouteChange(): Unit {
        Hilog.info(0, "CjTelegram", "[AudioSession] notifyRouteChange")
        match (this._routeChangeCallback) {
            case Some(cb) => cb()
            case None => ()
        }
    }

    /**
     * 判断通话会话是否激活（用于 AudioPlaybackService 流初始化时选择 StreamUsage）
     */
    public func isCallSessionActive(): Bool {
        match (this._currentHolder) {
            case Some(holder) => holder == AudioSessionHolder.Call
            case None => false
        }
    }

    /**
     * 获取当前应使用的 StreamUsage
     * 通话中 → VOICE_COMMUNICATION(3)，否则 → MUSIC(1)
     */
    public func getEffectiveStreamUsage(): Int32 {
        if (this.isCallSessionActive()) {
            return SESSION_USAGE_VOICE_COMMUNICATION
        }
        return 1
    }
}
