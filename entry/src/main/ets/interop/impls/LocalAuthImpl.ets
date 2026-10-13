// LocalAuth capability — real @kit.UserAuthenticationKit impl (Phase 3 reversal, SSOT §5).
// ArkTS owns userAuth.getAvailableStatus / getUserAuthInstance; cangjie LocalAuthManager
// calls via callArkAsync.
//
// Methods:
//   LOCALAUTH_AVAILABLE = "localauth.available"
//     argJson (cangjie → ArkTS): {}   (no args)
//     result (ArkTS → cangjie): {"available": boolean, "type": "face"|"fingerprint"|"none"}
//         Probes FACE first, then FINGERPRINT (matches original cangjie priority).
//   LOCALAUTH_AUTHENTICATE = "localauth.authenticate"
//     argJson (cangjie → ArkTS): {"type": "face"|"fingerprint", "reason": string}
//     result (ArkTS → cangjie): {"ok": boolean, "msg": string}
//         ok=true on SUCCESS (12500000); ok=false with msg on cancel/failure.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { userAuth } from '@kit.UserAuthenticationKit';

// AuthTrustLevel ATL1 — basic recognition threshold.
const ATL1: number = 10000;
const RESULT_SUCCESS: number = 12500000;
const RESULT_CANCELED: number = 12500001;

interface LocalAuthAuthArgs {
  type: string;
  reason: string;
}

function statusAvailable(authType: userAuth.UserAuthType): boolean {
  try {
    userAuth.getAvailableStatus(authType, userAuth.AuthTrustLevel.ATL1);
    return true;
  } catch (e) {
    return false;
  }
}

export function registerLocalAuth(): void {
  registerArkFunc(InteropMethod.LOCALAUTH_AVAILABLE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      let available: boolean = false;
      let typeStr: string = 'none';
      if (statusAvailable(userAuth.UserAuthType.FACE)) {
        available = true;
        typeStr = 'face';
      } else if (statusAvailable(userAuth.UserAuthType.FINGERPRINT)) {
        available = true;
        typeStr = 'fingerprint';
      }
      onResult(JSON.stringify({ available: available, type: typeStr }));
    } catch (e) {
      onResult(JSON.stringify({ available: false, type: 'none' }));
    }
  });

  registerArkFunc(InteropMethod.LOCALAUTH_AUTHENTICATE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: LocalAuthAuthArgs = JSON.parse(argJson) as LocalAuthAuthArgs;
      const authType: userAuth.UserAuthType =
        (a.type === 'fingerprint') ? userAuth.UserAuthType.FINGERPRINT : userAuth.UserAuthType.FACE;

      const challenge: Uint8Array = new Uint8Array(0);
      const authParam: userAuth.AuthParam = {
        challenge: challenge,
        authType: [authType],
        authTrustLevel: userAuth.AuthTrustLevel.ATL1
      };
      const widgetParam: userAuth.WidgetParam = {
        title: (typeof a.reason === 'string' && a.reason.length > 0) ? a.reason : 'Authenticate'
      };

      const instance: userAuth.UserAuthInstance = userAuth.getUserAuthInstance(authParam, widgetParam);
      instance.on('result', {
        onResult: (result: userAuth.UserAuthResult): void => {
          if (result.result === RESULT_SUCCESS) {
            onResult(JSON.stringify({ ok: true, msg: '' }));
          } else if (result.result === RESULT_CANCELED) {
            onResult(JSON.stringify({ ok: false, msg: 'Authentication canceled' }));
          } else {
            onResult(JSON.stringify({ ok: false, msg: 'Authentication failed (code=' + result.result + ')' }));
          }
        }
      });
      instance.start();
    } catch (e) {
      onResult(JSON.stringify({ ok: false, msg: 'Biometric system error' }));
    }
  });
}
