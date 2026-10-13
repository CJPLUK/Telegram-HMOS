// VoIP 来电上报到系统通话界面（Call Service Kit voipCall）—— iOS CallKit 的鸿蒙等价物。
//
// iOS 对照：CallKitIntegration.swift:247-273 reportIncomingCall → CXProvider.reportNewIncomingCall，
// 由系统弹出可接听/拒绝的来电界面；用户在系统界面上的接听/挂断经 CXProviderDelegate 回到应用
// （answerCall / endCall）；通话结束 reportCall(with:endedAt:reason:)（:199）。
//
// 鸿蒙：voipCall.reportIncomingCall 让系统显示来电横幅（锁屏时全屏）并带接听/拒绝按钮；
// 用户操作经 voipCall.on('voipCallUiEvent') 回调；应用侧状态变化用 reportCallStateChange 同步。
//
// Methods（仓颉 → ArkTS）:
//   VOIP_REPORT_INCOMING = "voip.reportIncoming"
//     argJson: {"callId": string, "name": string, "isVideo": boolean, "avatarPath": string}
//     result : {"ok": boolean, "reason": number, "err": string}
//              ok=true 仅当系统接受了来电（ErrorReason.ERROR_NONE）。
//   VOIP_REPORT_STATE = "voip.reportState"
//     argJson: {"callId": string, "state": 2(ACTIVE)|4(DISCONNECTED), "isVideo": boolean}
//     result : {"ok": boolean}
// Event（ArkTS → 仓颉 dispatchEvent）:
//   EVT_VOIP_UI_EVENT = "voip.uiEvent"   payload: {"callId": string, "event": number(VoipCallUiEvent)}
import { registerArkFunc, dispatchEvent } from 'libohos_app_cangjie_entry.so';
import { InteropMethod, InteropEvent } from '../InteropContract';
import { voipCall } from '@kit.CallServiceKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface VoipReportIncomingArgs {
  callId: string;
  name: string;
  isVideo: boolean;
  avatarPath?: string;
}

interface VoipReportStateArgs {
  callId: string;
  state: number;
  isVideo: boolean;
}

interface VoipReportResult {
  ok: boolean;
  reason: number;
  err: string;
}

interface VoipUiEventPayload {
  callId: string;
  event: number;
}

const PROFILE_SIDE: number = 96;

// VoipCallAttribute.userProfile 为必填 PixelMap：优先用已下载的头像，没有就给一张纯色图
// （系统界面会裁成圆形头像位）。
function loadProfile(path: string): Promise<image.PixelMap> {
  if (path.length > 0) {
    try {
      const src: image.ImageSource = image.createImageSource(path);
      return src.createPixelMap({ desiredSize: { width: PROFILE_SIDE, height: PROFILE_SIDE } })
        .then((pm: image.PixelMap): image.PixelMap => {
          src.release();
          return pm;
        })
        .catch((): Promise<image.PixelMap> => {
          src.release();
          return solidProfile();
        });
    } catch (_e) {
      return solidProfile();
    }
  }
  return solidProfile();
}

function solidProfile(): Promise<image.PixelMap> {
  const buf: ArrayBuffer = new ArrayBuffer(PROFILE_SIDE * PROFILE_SIDE * 4);
  const bytes: Uint8Array = new Uint8Array(buf);
  // BGRA：Telegram 默认头像蓝 #5CAFFA
  for (let i: number = 0; i < bytes.length; i += 4) {
    bytes[i] = 0xFA;
    bytes[i + 1] = 0xAF;
    bytes[i + 2] = 0x5C;
    bytes[i + 3] = 0xFF;
  }
  return image.createPixelMap(buf, {
    size: { width: PROFILE_SIDE, height: PROFILE_SIDE },
    srcPixelFormat: image.PixelMapFormat.BGRA_8888,
    pixelFormat: image.PixelMapFormat.BGRA_8888,
    editable: false
  });
}

function callTypeOf(isVideo: boolean): voipCall.VoipCallType {
  return isVideo ? voipCall.VoipCallType.VOIP_CALL_VIDEO : voipCall.VoipCallType.VOIP_CALL_VOICE;
}

// 仓颉侧只上报这三种状态（见 CallService.voipStateWatcher）
function stateOf(v: number): voipCall.VoipCallState {
  if (v === 2) {
    return voipCall.VoipCallState.VOIP_CALL_STATE_ACTIVE;
  }
  if (v === 4) {
    return voipCall.VoipCallState.VOIP_CALL_STATE_DISCONNECTED;
  }
  return voipCall.VoipCallState.VOIP_CALL_STATE_RINGING;
}

let uiEventSubscribed: boolean = false;

function ensureUiEventSubscription(): void {
  if (uiEventSubscribed) {
    return;
  }
  try {
    voipCall.on('voipCallUiEvent', (info: voipCall.VoipCallUiEventInfo): void => {
      const payload: VoipUiEventPayload = { callId: info.callId, event: info.voipCallUiEvent };
      console.info(`[VoipCallImpl] ui event call=${info.callId} event=${info.voipCallUiEvent}`);
      dispatchEvent(InteropEvent.VOIP_UI_EVENT, JSON.stringify(payload));
    });
    uiEventSubscribed = true;
  } catch (e) {
    const be = e as BusinessError;
    console.error(`[VoipCallImpl] on(voipCallUiEvent) failed: ${be.code} ${be.message}`);
  }
}

export function registerVoipCall(): void {
  registerArkFunc(InteropMethod.VOIP_REPORT_INCOMING, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: VoipReportIncomingArgs = JSON.parse(argJson) as VoipReportIncomingArgs;
      ensureUiEventSubscription();
      loadProfile(a.avatarPath ?? '')
        .then((profile: image.PixelMap): Promise<voipCall.ErrorReason> => {
          const attr: voipCall.VoipCallAttribute = {
            callId: a.callId,
            voipCallType: callTypeOf(a.isVideo),
            userName: a.name,
            userProfile: profile,
            abilityName: 'EntryAbility',
            voipCallState: voipCall.VoipCallState.VOIP_CALL_STATE_RINGING,
            showBannerForIncomingCall: true
          };
          return voipCall.reportIncomingCall(attr);
        })
        .then((reason: voipCall.ErrorReason): void => {
          const r: VoipReportResult = { ok: reason === voipCall.ErrorReason.ERROR_NONE, reason: reason, err: '' };
          onResult(JSON.stringify(r));
        })
        .catch((e: BusinessError): void => {
          const r: VoipReportResult = { ok: false, reason: -1, err: `${e.code}: ${e.message}` };
          onResult(JSON.stringify(r));
        });
    } catch (e) {
      const be = e as BusinessError;
      const r: VoipReportResult = { ok: false, reason: -1, err: `exception ${be.code}: ${be.message}` };
      onResult(JSON.stringify(r));
    }
  });

  registerArkFunc(InteropMethod.VOIP_REPORT_STATE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: VoipReportStateArgs = JSON.parse(argJson) as VoipReportStateArgs;
      voipCall.reportCallStateChange(a.callId, stateOf(a.state), callTypeOf(a.isVideo))
        .then((): void => onResult('{"ok":true}'))
        .catch((e: BusinessError): void => {
          console.error(`[VoipCallImpl] reportCallStateChange(${a.state}) failed: ${e.code} ${e.message}`);
          onResult('{"ok":false}');
        });
    } catch (e) {
      onResult('{"ok":false}');
    }
  });
}
