// BackgroundPrivacy capability — real @kit.ArkUI window privacy mode (Phase 3 reversal, SSOT §5).
// ArkTS owns window.setWindowPrivacyMode on the app's last (top) window; cangjie
// BackgroundPrivacyService calls via callArk(BGPRIVACY_SET, argJson).
//
// argJson (cangjie → ArkTS): {"on": boolean}
//     on=true  → privacy mode ON  (task-switcher snapshot + screenshots output black).
//     on=false → privacy mode OFF (normal display).
// result (ArkTS → cangjie): {"ok": boolean}  — best-effort ack.
//
// Note: the previous pure-cangjie design injected a Window handle via setMainWindow();
// under the reversed model ArkTS resolves the top window itself through
// window.getLastWindow(context), so cangjie no longer needs a Window reference.
// Permission: ohos.permission.PRIVACY_WINDOW.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { window } from '@kit.ArkUI';

interface BgPrivacyArgs {
  on: boolean;
}

export function registerBackgroundPrivacy(): void {
  registerArkFunc(InteropMethod.BGPRIVACY_SET, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: BgPrivacyArgs = JSON.parse(argJson) as BgPrivacyArgs;
      const isPrivacy: boolean = a.on === true;
      window.getLastWindow(getContext()).then((win: window.Window): void => {
        win.setWindowPrivacyMode(isPrivacy).then((): void => {
          onResult(JSON.stringify({ ok: true }));
        }).catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false }));
      });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
