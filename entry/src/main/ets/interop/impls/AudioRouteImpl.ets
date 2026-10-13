// Audio-route capability — real @kit.AudioKit audio impl (Phase 3 reversal, SSOT §5).
// ArkTS owns the system-module calls; cangjie AudioRouteService calls via callArkAsync(AUDIO_*, argJson, cb).
//
// Two methods:
//   AUDIO_LIST_DEVICES — audio.getAudioManager().getRoutingManager().getDevices(OUTPUT_DEVICES_FLAG=2)
//     argJson (cangjie → ArkTS): {}  (ignored)
//     result  (ArkTS → cangjie): {"ok": boolean, "devices": [{"id": number, "type": number, "name": string}]}
//   AUDIO_SET_ROUTE  — programmatic output-device selection.
//     argJson (cangjie → ArkTS): {"deviceId": number}  — cangjie resolves route→deviceId from the list above
//     result  (ArkTS → cangjie): {"ok": boolean}
//     NOTE: this SDK's AudioRoutingManager exposes no output-device *setter*
//     (only getDevices/getDevicesSync/getPreferredOutputDeviceForRendererInfoSync are present;
//     selectOutputDevice was removed). Programmatic routing is not available, so SET_ROUTE is a
//     best-effort no-op that validates the target exists and acks ok — the OS/user drives the
//     actual output route, and cangjie keeps its optimistic route↔deviceType UI mapping.
// On any failure: {"ok": false}. Cangjie side keeps route↔deviceType mapping + optimistic UI update.
// NOTE: the passive OS deviceChange push listener is not bridged here (would need the separate
//   dispatchEvent channel / shared-file wiring); cangjie re-enumerates on demand via AUDIO_LIST_DEVICES.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { audio } from '@kit.AudioKit';

interface SetRouteArgs {
  deviceId: number;
}

interface DeviceEntry {
  id: number;
  type: number;
  name: string;
}

interface ListResult {
  ok: boolean;
  devices: Array<DeviceEntry>;
}

const OUTPUT_DEVICES_FLAG: number = 2;

export function registerAudioRoute(): void {
  // ---- enumerate output devices ----
  registerArkFunc(InteropMethod.AUDIO_LIST_DEVICES, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const routingManager: audio.AudioRoutingManager =
        audio.getAudioManager().getRoutingManager();
      routingManager.getDevices(OUTPUT_DEVICES_FLAG)
        .then((descriptors: audio.AudioDeviceDescriptors): void => {
          const devices: Array<DeviceEntry> = [];
          for (let i = 0; i < descriptors.length; i++) {
            const d: audio.AudioDeviceDescriptor = descriptors[i];
            const entry: DeviceEntry = {
              id: (typeof d.id === 'number') ? d.id : -1,
              type: (typeof d.deviceType === 'number') ? d.deviceType : -1,
              name: (typeof d.name === 'string') ? d.name : ''
            };
            devices.push(entry);
          }
          const result: ListResult = { ok: true, devices: devices };
          onResult(JSON.stringify(result));
        })
        .catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });

  // ---- select output device by id ----
  registerArkFunc(InteropMethod.AUDIO_SET_ROUTE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const args: SetRouteArgs = JSON.parse(argJson) as SetRouteArgs;
      const targetId: number = args.deviceId;
      const routingManager: audio.AudioRoutingManager =
        audio.getAudioManager().getRoutingManager();
      // TODO(P3-api): this SDK's audio.AudioRoutingManager has no programmatic output-device
      // setter (selectOutputDevice absent; only getters remain). Validate the target exists,
      // then best-effort no-op ack — actual routing is OS/user-driven.
      routingManager.getDevices(OUTPUT_DEVICES_FLAG)
        .then((descriptors: audio.AudioDeviceDescriptors): void => {
          let found: boolean = false;
          for (let i = 0; i < descriptors.length; i++) {
            if (descriptors[i].id === targetId) {
              found = true;
              break;
            }
          }
          onResult(JSON.stringify({ ok: found }));
        })
        .catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
