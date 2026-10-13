// Camera AVRecorder capability — real @kit.MediaKit AVRecorder impl (Phase 3 reversal, SSOT §5).
//
// SCOPE (honest): CameraService's Camera Kit calls (preview/capture/session/zoom/flash/focus)
// are native Cangjie `kit.CameraKit.*` and are NOT reversed — they stay in the cangjie service.
// The ONLY arkinterop dependency in CameraService is the P2-074 real-mp4 video recorder, which
// used ohos.ark_interop JSRuntime → requireSystemNativeModule("multimedia.media") → AVRecorder.
// AVRecorder has only an ArkTS binding (no cangjie kit.MediaKit AVRecorder), so it is reversed here.
//
// The AVRecorder is a long-lived, stateful JS object (prepare → getInputSurface → start → pause/
// resume → stop → release across separate user actions). The stateless callArkAsync(name,arg,cb)
// contract can't hand a JS object back to cangjie, so this impl holds the recorder instance in a
// module-level variable and exposes DISCRETE request/response operations. getInputSurface returns
// the surfaceId string — exactly what the cangjie CameraService needs to bind a VideoOutput into
// the live camera session on its side (surface binding stays in cangjie via kit.CameraKit).
//
// Methods:
//   CAMERA_REC_PREPARE  — createAVRecorder + prepare(config) + getInputSurface()
//     argJson (cangjie → ArkTS): {"path": string}  (absolute mp4 output path; cangjie owns videosDir)
//     result  (ArkTS → cangjie): {"ok": boolean, "surfaceId": string}
//   CAMERA_REC_START    — avRecorder.start()   arg {} → {"ok": boolean}
//   CAMERA_REC_PAUSE    — avRecorder.pause()   arg {} → {"ok": boolean}
//   CAMERA_REC_RESUME   — avRecorder.resume()  arg {} → {"ok": boolean}
//   CAMERA_REC_STOP     — avRecorder.stop() + release() + close fd  arg {} → {"ok": boolean}
// On any failure: {"ok": false [, "surfaceId": ""]}.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';

interface PrepareArgs {
  path: string;
  preset?: string;    // '' | 'videomsg'（圆形视频消息：单声道 AAC 48k、1.2 Mbps、相机方向旋转）
  width?: number;     // 与所选 VideoProfile 一致
  height?: number;
  rotation?: number;  // 写进 mp4 旋转元数据（相机 sensor 方向）
}

interface PrepareResult {
  ok: boolean;
  surfaceId: string;
}

interface OkResult {
  ok: boolean;
}

// Module-level recorder state (single active recording session, matches CameraService semantics).
let gRecorder: media.AVRecorder | undefined = undefined;
let gFile: fileIo.File | undefined = undefined;

function closeFile(): void {
  if (gFile !== undefined) {
    try {
      fileIo.closeSync(gFile);
    } catch (e) {
      // ignore
    }
    gFile = undefined;
  }
}

function buildConfig(fdUrl: string, args: PrepareArgs): media.AVRecorderConfig {
  const videoMsg: boolean = args.preset === 'videomsg';
  const profile: media.AVRecorderProfile = {
    audioBitrate: videoMsg ? 64000 : 96000,
    audioChannels: videoMsg ? 1 : 2,
    audioCodec: media.CodecMimeType.AUDIO_AAC,
    audioSampleRate: videoMsg ? 48000 : 44100,
    fileFormat: media.ContainerFormatType.CFT_MPEG_4,
    videoBitrate: videoMsg ? 1200000 : 4000000,
    videoCodec: media.CodecMimeType.VIDEO_AVC,
    videoFrameWidth: (args.width ?? 0) > 0 ? (args.width as number) : 1280,
    videoFrameHeight: (args.height ?? 0) > 0 ? (args.height as number) : 720,
    videoFrameRate: 30
  };
  const config: media.AVRecorderConfig = {
    audioSourceType: 1, // AudioSourceType.AUDIO_SOURCE_TYPE_MIC
    videoSourceType: media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_YUV,
    profile: profile,
    url: fdUrl,
    rotation: args.rotation ?? 0
  };
  return config;
}

export function registerCamera(): void {
  // ---- prepare: create recorder, prepare config, return input surfaceId ----
  registerArkFunc(InteropMethod.CAMERA_REC_PREPARE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const args: PrepareArgs = JSON.parse(argJson) as PrepareArgs;
      const file: fileIo.File = fileIo.openSync(
        args.path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE
      );
      gFile = file;
      const fdUrl: string = 'fd://' + file.fd.toString();
      media.createAVRecorder()
        .then((recorder: media.AVRecorder): void => {
          gRecorder = recorder;
          recorder.prepare(buildConfig(fdUrl, args))
            .then((): void => {
              recorder.getInputSurface()
                .then((surfaceId: string): void => {
                  const ok: PrepareResult = { ok: (surfaceId.length > 0), surfaceId: surfaceId };
                  onResult(JSON.stringify(ok));
                })
                .catch((): void => {
                  const r: PrepareResult = { ok: false, surfaceId: '' };
                  onResult(JSON.stringify(r));
                });
            })
            .catch((): void => {
              const r: PrepareResult = { ok: false, surfaceId: '' };
              onResult(JSON.stringify(r));
            });
        })
        .catch((): void => {
          closeFile();
          const r: PrepareResult = { ok: false, surfaceId: '' };
          onResult(JSON.stringify(r));
        });
    } catch (e) {
      closeFile();
      const r: PrepareResult = { ok: false, surfaceId: '' };
      onResult(JSON.stringify(r));
    }
  });

  // ---- start ----
  registerArkFunc(InteropMethod.CAMERA_REC_START, (argJson: string, onResult: (r: string) => void): void => {
    const rec: media.AVRecorder | undefined = gRecorder;
    if (rec === undefined) {
      onResult(JSON.stringify({ ok: false } as OkResult));
      return;
    }
    try {
      rec.start()
        .then((): void => { onResult(JSON.stringify({ ok: true } as OkResult)); })
        .catch((): void => { onResult(JSON.stringify({ ok: false } as OkResult)); });
    } catch (e) {
      onResult(JSON.stringify({ ok: false } as OkResult));
    }
  });

  // ---- pause ----
  registerArkFunc(InteropMethod.CAMERA_REC_PAUSE, (argJson: string, onResult: (r: string) => void): void => {
    const rec: media.AVRecorder | undefined = gRecorder;
    if (rec === undefined) {
      onResult(JSON.stringify({ ok: false } as OkResult));
      return;
    }
    try {
      rec.pause()
        .then((): void => { onResult(JSON.stringify({ ok: true } as OkResult)); })
        .catch((): void => { onResult(JSON.stringify({ ok: false } as OkResult)); });
    } catch (e) {
      onResult(JSON.stringify({ ok: false } as OkResult));
    }
  });

  // ---- resume ----
  registerArkFunc(InteropMethod.CAMERA_REC_RESUME, (argJson: string, onResult: (r: string) => void): void => {
    const rec: media.AVRecorder | undefined = gRecorder;
    if (rec === undefined) {
      onResult(JSON.stringify({ ok: false } as OkResult));
      return;
    }
    try {
      rec.resume()
        .then((): void => { onResult(JSON.stringify({ ok: true } as OkResult)); })
        .catch((): void => { onResult(JSON.stringify({ ok: false } as OkResult)); });
    } catch (e) {
      onResult(JSON.stringify({ ok: false } as OkResult));
    }
  });

  // ---- stop + release + close fd ----
  registerArkFunc(InteropMethod.CAMERA_REC_STOP, (argJson: string, onResult: (r: string) => void): void => {
    const rec: media.AVRecorder | undefined = gRecorder;
    gRecorder = undefined;
    if (rec === undefined) {
      closeFile();
      onResult(JSON.stringify({ ok: false } as OkResult));
      return;
    }
    try {
      rec.stop()
        .then((): void => {
          rec.release()
            .then((): void => {
              closeFile();
              onResult(JSON.stringify({ ok: true } as OkResult));
            })
            .catch((): void => {
              closeFile();
              onResult(JSON.stringify({ ok: false } as OkResult));
            });
        })
        .catch((): void => {
          closeFile();
          onResult(JSON.stringify({ ok: false } as OkResult));
        });
    } catch (e) {
      closeFile();
      onResult(JSON.stringify({ ok: false } as OkResult));
    }
  });
}
