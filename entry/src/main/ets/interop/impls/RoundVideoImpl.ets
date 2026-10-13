// 圆形视频消息转码反转能力：video.square {inPath, outPath, side?, rotation?}
//   → {ok, width, height, durationMs, frames, error}
// 实现在 cpp/round_video_transcoder.cpp（AVDemuxer → VideoDecoder → libyuv 裁方 → VideoEncoder → AVMuxer）。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { squareVideo, SquareVideoResult } from 'libtg_media.so';

interface SquareArgs {
  inPath: string;
  outPath: string;
  side?: number;      // square：边长；fit：长边上限
  rotation?: number;
  mode?: string;      // 'square'（默认）| 'fit'
  bitrate?: number;
}

export function registerRoundVideo(): void {
  registerArkFunc('video.square', (argJson: string, onResult: (r: string) => void): void => {
    const fail = (e: string): void => {
      onResult(JSON.stringify({ ok: false, width: 0, height: 0, durationMs: 0, frames: 0, error: e }));
    };
    try {
      const a: SquareArgs = JSON.parse(argJson) as SquareArgs;
      squareVideo(a.inPath, a.outPath, a.side ?? 400, a.rotation ?? 0, a.mode === 'fit' ? 1 : 0, a.bitrate ?? 0)
        .then((r: SquareVideoResult): void => { onResult(JSON.stringify(r)); })
        .catch((e: Error): void => { fail(String(e)); });
    } catch (_e) {
      fail('bad args');
    }
  });
}
