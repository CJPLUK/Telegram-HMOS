export interface VoiceEncodeResult {
  ok: boolean;
  bytes: number;
  durationMs: number;
  waveformHex: string;   // 100 采样 5bit 打包（63 B）的 hex，对位 documentAttributeAudio.waveform
  error: string;
}
export const encodeVoice: (pcmPath: string, oggPath: string, sampleRate?: number, bitrate?: number) => Promise<VoiceEncodeResult>;

export interface SquareVideoResult {
  ok: boolean;
  width: number;
  height: number;
  durationMs: number;
  frames: number;
  error: string;
}
// 中心裁方 + 缩放到 side×side + H.264 重编码（音频直通）；rotation 仅在容器无旋转元数据时使用
// mode 0：中心裁方 side×side；mode 1：等比缩放到长边 ≤ side（fit）。bitrate 0 = 默认（square 1.2 Mbps / fit 2.2 Mbps）
export const squareVideo: (inPath: string, outPath: string, side?: number, rotation?: number, mode?: number, bitrate?: number) => Promise<SquareVideoResult>;
