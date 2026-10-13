// Push token capability — real @kit.PushKit pushService impl (Phase 3 reversal, SSOT §5).
// ArkTS owns the HMS system-module call; cangjie PushTokenService calls via
// callArkAsync(PUSH_GET_TOKEN, "{}", cb) and delivers the token to its existing callback.
//
// Method:
//   PUSH_GET_TOKEN — pushService.getToken() (HMS Push Kit, returns Promise<string>)
//     argJson (cangjie → ArkTS): {} (no args)
//     result  (ArkTS → cangjie): {"ok": boolean, "token": string}
// On any failure: {"ok": false, "token": ""}. cangjie side maps ok=false → None.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { pushService } from '@kit.PushKit';

interface PushTokenResult {
  ok: boolean;
  token: string;
}

export function registerPushToken(): void {
  registerArkFunc(InteropMethod.PUSH_GET_TOKEN, (argJson: string, onResult: (r: string) => void): void => {
    try {
      pushService.getToken()
        .then((token: string): void => {
          const result: PushTokenResult = {
            ok: (typeof token === 'string' && token.length > 0),
            token: (typeof token === 'string') ? token : ''
          };
          onResult(JSON.stringify(result));
        })
        .catch((e: Object): void => {
          try {
            console.error(`[PushTokenImpl] getToken rejected: ${JSON.stringify(e)}`);
          } catch (_) {}
          const fail: PushTokenResult = { ok: false, token: '' };
          onResult(JSON.stringify(fail));
        });
    } catch (e) {
      const fail: PushTokenResult = { ok: false, token: '' };
      onResult(JSON.stringify(fail));
    }
  });
}
