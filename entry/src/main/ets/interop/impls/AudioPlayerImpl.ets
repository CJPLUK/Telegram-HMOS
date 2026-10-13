// 语音消息播放（系统 AVPlayer）。仓颉侧只能裸播 PCM/WAV，Telegram 语音是 audio/ogg(Opus)，
// 交给 AVPlayer 解码（d.ts 声明支持 OGG）。单实例：同一时刻只播一条语音（iOS 同）。
//   audio.preload {path}  提前打开文件并 prepare，点击时直接 play
//   audio.play    {path}  播放；命中预备播放器时不再重新创建
//   audio.pause / audio.resume / audio.stop
//   audio.seek   {ms}
//   audio.state  → {state, positionMs, durationMs}
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface PlayArgs {
  path: string;
}

interface SeekArgs {
  ms: number;
}

let gPlayer: media.AVPlayer | undefined = undefined;
let gFile: fileIo.File | undefined = undefined;
let gState: string = 'idle';
let gEnded: boolean = false;
let gIntent: string = 'stopped';
let gGeneration: number = 0;
let gCommandChain: Promise<void> = Promise.resolve();
let gPath: string = '';
let gPlayRequestedAt: number = 0;
let gLoggedPlayRequestAt: number = 0;

function enqueueCommand(command: () => Promise<void>): Promise<void> {
  const result: Promise<void> = gCommandChain
    .catch((): void => {})
    .then(command);
  gCommandChain = result.catch((): void => {});
  return result;
}

async function releasePlayer(): Promise<void> {
  const p: media.AVPlayer | undefined = gPlayer;
  const f: fileIo.File | undefined = gFile;
  gPlayer = undefined;
  gFile = undefined;
  if (p !== undefined) {
    try { p.off('stateChange'); } catch (_e1) {}
    try { p.off('error'); } catch (_e2) {}
    try { await p.release(); } catch (_e3) {}
  }
  if (f !== undefined) {
    try { fileIo.closeSync(f); } catch (_e4) {}
  }
}

async function loadPath(path: string, generation: number): Promise<boolean> {
  await releasePlayer();
  if (generation !== gGeneration || gIntent === 'stopped') {
    return false;
  }
  gPath = path;
  gEnded = false;
  gState = 'loading';
  try {
    const p: media.AVPlayer = await media.createAVPlayer();
    if (generation !== gGeneration || gIntent === 'stopped') {
      try { await p.release(); } catch (_releaseError) {}
      return false;
    }
    gPlayer = p;
    p.on('stateChange', (state: string): void => {
      if (generation !== gGeneration || gPlayer !== p) {
        return;
      }
      gState = state;
      if (state === 'playing' && gPlayRequestedAt > 0 && gLoggedPlayRequestAt !== gPlayRequestedAt) {
        gLoggedPlayRequestAt = gPlayRequestedAt;
        console.info(`[AudioPlayerTiming] audible state after ${Date.now() - gPlayRequestedAt}ms path=${gPath}`);
      }
      if (state === 'initialized') {
        if (gIntent !== 'stopped') {
          p.prepare().catch((e: BusinessError): void => {
            if (generation === gGeneration) {
              gState = 'error';
              console.error(`[AudioPlayer] prepare failed ${e.code} ${e.message}`);
            }
          });
        }
      } else if (state === 'prepared') {
        if (gIntent === 'playing') {
          p.play().catch((e: BusinessError): void => {
            if (generation === gGeneration) {
              gState = 'error';
              console.error(`[AudioPlayer] play failed ${e.code} ${e.message}`);
            }
          });
        } else if (gIntent === 'paused') {
          // A pause can arrive while create/prepare is still in flight. Keep
          // the prepared player parked until a later resume command.
          gState = 'paused';
        }
      } else if (state === 'completed') {
        gEnded = true;
      }
    });
    p.on('error', (err: BusinessError): void => {
      if (generation === gGeneration && gPlayer === p) {
        console.error(`[AudioPlayer] error ${err.code} ${err.message}`);
        gState = 'error';
      }
    });
    gFile = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    p.url = 'fd://' + gFile.fd.toString();
    return true;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    console.error(`[AudioPlayer] open failed ${err.code} ${err.message}`);
    await releasePlayer();
    if (generation === gGeneration) {
      gState = 'error';
    }
    return false;
  }
}

export function registerAudioPlayer(): void {
  registerArkFunc('audio.preload', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: PlayArgs = JSON.parse(argJson) as PlayArgs;
      if (a.path.length === 0) {
        onResult(JSON.stringify({ ok: false }));
        return;
      }
      if (gPath === a.path && (gPlayer !== undefined || gState === 'loading') && gState !== 'error') {
        onResult(JSON.stringify({ ok: true, reused: true }));
        return;
      }
      // A visible bubble may ask to warm another file while the global voice
      // player is active. Keep the active item intact, matching iOS' shared
      // media player ownership.
      if (gPlayer !== undefined && (gIntent === 'playing' || gIntent === 'paused')) {
        onResult(JSON.stringify({ ok: false, busy: true }));
        return;
      }
      gIntent = 'preloaded';
      gState = 'loading';
      gGeneration += 1;
      const generation: number = gGeneration;
      // Publish the target before the asynchronous create/prepare chain runs.
      // A tap arriving during preload can then promote this same chain to play.
      gPath = a.path;
      enqueueCommand(async (): Promise<void> => {
        const ok: boolean = await loadPath(a.path, generation);
        onResult(JSON.stringify({ ok: ok }));
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false }));
      });
    } catch (_e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });
  registerArkFunc('audio.play', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: PlayArgs = JSON.parse(argJson) as PlayArgs;
      gIntent = 'playing';
      gPlayRequestedAt = Date.now();
      if (gPath === a.path && (gPlayer !== undefined || gState === 'loading') && gState !== 'error') {
        enqueueCommand(async (): Promise<void> => {
          const p: media.AVPlayer | undefined = gPlayer;
          if (p !== undefined && (gState === 'prepared' || gState === 'paused' || gState === 'completed')) {
            if (gState === 'completed') {
              p.seek(0);
            }
            gEnded = false;
            try { await p.play(); } catch (_e) { gState = 'error'; }
          }
          // loading/initialized needs no second action: its captured stateChange
          // callback sees the promoted playing intent after prepare completes.
          onResult(JSON.stringify({ ok: gState !== 'error', reused: true }));
        }).catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
      } else {
        gGeneration += 1;
        const generation: number = gGeneration;
        gPath = a.path;
        enqueueCommand(async (): Promise<void> => {
          const ok: boolean = await loadPath(a.path, generation);
          onResult(JSON.stringify({ ok: ok, reused: false }));
        }).catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
      }
    } catch (_e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });
  registerArkFunc('audio.pause', (_a: string, onResult: (r: string) => void): void => {
    gIntent = 'paused';
    enqueueCommand(async (): Promise<void> => {
      const p: media.AVPlayer | undefined = gPlayer;
      if (p !== undefined && gState === 'playing') {
        try { await p.pause(); } catch (_e) {}
      }
      onResult('{}');
    }).catch((): void => { onResult('{}'); });
  });
  registerArkFunc('audio.resume', (_a: string, onResult: (r: string) => void): void => {
    gIntent = 'playing';
    gPlayRequestedAt = Date.now();
    enqueueCommand(async (): Promise<void> => {
      const p: media.AVPlayer | undefined = gPlayer;
      if (p !== undefined && (gState === 'paused' || gState === 'prepared' || gState === 'completed')) {
        if (gState === 'completed') {
          p.seek(0);
        }
        gEnded = false;
        try { await p.play(); } catch (_e) { gState = 'error'; }
      }
      onResult('{}');
    }).catch((): void => { onResult('{}'); });
  });
  registerArkFunc('audio.stop', (_a: string, onResult: (r: string) => void): void => {
    gIntent = 'stopped';
    gGeneration += 1;
    const generation: number = gGeneration;
    enqueueCommand(async (): Promise<void> => {
      await releasePlayer();
      if (generation === gGeneration) {
        gPath = '';
        gState = 'idle';
        gEnded = false;
      }
      onResult('{}');
    }).catch((): void => { onResult('{}'); });
  });
  registerArkFunc('audio.seek', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: SeekArgs = JSON.parse(argJson) as SeekArgs;
      enqueueCommand(async (): Promise<void> => {
        if (gPlayer !== undefined) {
          gPlayer.seek(Math.max(0, Math.floor(a.ms)));
        }
        onResult('{}');
      }).catch((): void => { onResult('{}'); });
    } catch (_e) {
      onResult('{}');
    }
  });
  registerArkFunc('audio.state', (_a: string, onResult: (r: string) => void): void => {
    let pos: number = 0;
    let dur: number = 0;
    if (gPlayer !== undefined) {
      try { pos = gPlayer.currentTime; } catch (_e1) {}
      try { dur = gPlayer.duration; } catch (_e2) {}
    }
    onResult(JSON.stringify({
      state: gEnded ? 'completed' : gState,
      positionMs: Math.max(0, Math.floor(pos)),
      durationMs: Math.max(0, Math.floor(dur))
    }));
  });
}
