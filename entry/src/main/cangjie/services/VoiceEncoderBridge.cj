package ohos_app_cangjie_entry.services

/**
 * VoiceEncoderBridge — 语音消息 PCM/WAV → Opus/OGG（ArkTS 反转 voice.encodeOgg →
 * cpp/opus_ogg_encoder.cpp）。对位 iOS ManagedAudioRecorder + opusenc：48 kHz、30 kbps、
 * audio/ogg，波形 100 采样 5bit（63 B）由编码器按 iOS 同一算法算好返回。仅限非 UI 线程。
 */

import kit.PerformanceAnalysisKit.Hilog

public class VoiceEncodeResult {
    public var ok: Bool = false
    public var bytes: Int64 = 0
    public var durationMs: Int64 = 0
    public var waveform: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var error: String = ""
    public init() {}
}

public class VoiceEncoderBridge {
    public static func encodeToOgg(pcmPath: String, oggPath: String, sampleRate: Int32): VoiceEncodeResult {
        let r = VoiceEncodeResult()
        let arg = "{\"pcmPath\":\"" + pcmPath + "\",\"oggPath\":\"" + oggPath +
            "\",\"sampleRate\":${sampleRate},\"bitrate\":30720}"
        let res = arkCallSync("voice.encodeOgg", arg, 20000)
        if (res.size == 0) {
            r.error = "timeout"
            return r
        }
        try {
            let obj = JsonParser.parseObject(res)
            r.ok = obj.getBool("ok")
            r.bytes = obj.getInt("bytes")
            r.durationMs = obj.getInt("durationMs")
            r.error = obj.getString("error")
            r.waveform = hexToBytes(obj.getString("waveformHex"))
        } catch (e: Exception) {
            r.ok = false
            r.error = "parse: ${e}"
        }
        if (!r.ok) {
            Hilog.info(0, "CjTelegram", "[VoiceEncoder] failed: ${r.error}")
        }
        return r
    }

    private static func nibble(c: UInt8): Int64 {
        if (c >= 48 && c <= 57) { return Int64(c) - 48 }
        if (c >= 97 && c <= 102) { return Int64(c) - 87 }
        if (c >= 65 && c <= 70) { return Int64(c) - 55 }
        return 0
    }

    static func hexToBytes(hex: String): Array<Byte> {
        let cs = hex.toArray()
        let n = cs.size / 2
        let out = Array<Byte>(n, repeat: 0)
        var i: Int64 = 0
        while (i < n) {
            out[i] = UInt8((nibble(cs[i * 2]) << 4) | nibble(cs[i * 2 + 1]))
            i += 1
        }
        return out
    }
}
