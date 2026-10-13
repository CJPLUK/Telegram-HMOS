package ohos_app_cangjie_entry.services

/**
 * ArkAudioPlayerBridge — 系统 AVPlayer（ArkTS 反转，ets/interop/impls/AudioPlayerImpl.ets）
 *
 * 用途：播放 Telegram 语音 audio/ogg（Opus）。仓颉侧 AudioPlaybackService 只会裸播 PCM/WAV，
 * 此前把 OGG 压缩字节当 PCM 放出来是噪音（2026-09-11 真机复现）。iOS 走 FFmpeg 解 Opus；
 * 鸿蒙 AVPlayer 原生支持 OGG，OGG 与历史 WAV 都交给同一播放器状态机。
 */

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.interop.callArkOnJSTask

public class ArkAudioState {
    public var state: String = "idle"
    public var positionMs: Int64 = 0
    public var durationMs: Int64 = 0
    public init() {}
}

public class ArkAudioPlayerBridge {
    public static func preload(path: String): Unit {
        callArkOnJSTask("audio.preload", "{\"path\":\"" + path + "\"}", { _r: String => })
    }
    public static func play(path: String): Unit {
        callArkOnJSTask("audio.play", "{\"path\":\"" + path + "\"}", { _r: String => })
    }
    public static func pause(): Unit { callArkOnJSTask("audio.pause", "{}", { _r: String => }) }
    public static func resume(): Unit { callArkOnJSTask("audio.resume", "{}", { _r: String => }) }
    public static func stop(): Unit { callArkOnJSTask("audio.stop", "{}", { _r: String => }) }
    public static func seek(ms: Int64): Unit { callArkOnJSTask("audio.seek", "{\"ms\":${ms}}", { _r: String => }) }

    /** 同步查询播放状态（仅限非 UI 线程） */
    public static func state(): ArkAudioState {
        let st = ArkAudioState()
        let res = arkCallSync("audio.state", "{}", 400)
        if (res.size == 0) { return st }
        try {
            let obj = JsonParser.parseObject(res)
            st.state = obj.getString("state")
            st.positionMs = obj.getInt("positionMs")
            st.durationMs = obj.getInt("durationMs")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ArkAudio] state parse failed: ${e}")
        }
        return st
    }
}
