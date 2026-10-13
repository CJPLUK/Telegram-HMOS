// 语音消息编码反转能力：voice.encodeOgg {pcmPath, oggPath, sampleRate?, bitrate?}
//   → {ok, bytes, durationMs, waveformHex, error}
// 实现在 cpp/opus_ogg_encoder.cpp（libopus + 自写 Ogg 分页），这里只做 JSON 搬运。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { encodeVoice, VoiceEncodeResult } from 'libtg_media.so';

interface VoiceEncodeArgs {
  pcmPath: string;
  oggPath: string;
  sampleRate?: number;
  bitrate?: number;
}

export function registerVoiceEncoder(): void {
  registerArkFunc('voice.encodeOgg', (argJson: string, onResult: (r: string) => void): void => {
    const fail = (e: string): void => {
      onResult(JSON.stringify({ ok: false, bytes: 0, durationMs: 0, waveformHex: '', error: e }));
    };
    try {
      const a: VoiceEncodeArgs = JSON.parse(argJson) as VoiceEncodeArgs;
      encodeVoice(a.pcmPath, a.oggPath, a.sampleRate ?? 48000, a.bitrate ?? 30720)
        .then((r: VoiceEncodeResult): void => { onResult(JSON.stringify(r)); })
        .catch((e: Error): void => { fail(String(e)); });
    } catch (_e) {
      fail('bad args');
    }
  });
}
