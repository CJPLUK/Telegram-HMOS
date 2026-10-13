// Haptic capability — real @ohos.vibrator impl (Phase 3 reversal, SSOT §5).
// ArkTS owns the system-module call; cangjie HapticService calls via callArk(HAPTIC_VIBRATE, argJson).
// argJson schema (cangjie → ArkTS): {"ms": number}  — vibration duration in milliseconds.
// result schema (ArkTS → cangjie): {"ok": boolean}  — best-effort ack; vibrate failure is non-fatal.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { vibrator } from '@kit.SensorServiceKit';

// argJson shape, typed (ArkTS strict: no untyped object literals).
interface HapticArgs {
  ms: number;
}

export function registerHaptic(): void {
  registerArkFunc(InteropMethod.HAPTIC_VIBRATE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const args: HapticArgs = JSON.parse(argJson) as HapticArgs;
      const ms: number = (typeof args.ms === 'number' && args.ms > 0) ? args.ms : 15;

      const effect: vibrator.VibrateTime = { type: 'time', duration: ms };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'notification' };

      vibrator.startVibration(effect, attribute, (err: Error): void => {
        onResult(JSON.stringify({ ok: !err }));
      });
    } catch (e) {
      // Vibrate is best-effort: never throw across the boundary; ack failure.
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
