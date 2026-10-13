// Badge capability — real @kit.NotificationKit notificationManager.setBadgeNumber impl (Phase 3 reversal, SSOT §5).
// ArkTS owns the system-module call; cangjie BadgeService calls via callArk(BADGE_SET, argJson).
// argJson schema (cangjie → ArkTS): {"count": number}  — app icon badge number (unread count).
// result schema (ArkTS → cangjie): {"ok": boolean}  — best-effort ack; badge failure is non-fatal.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { notificationManager } from '@kit.NotificationKit';

// argJson shape, typed (ArkTS strict: no untyped object literals).
interface BadgeArgs {
  count: number;
}

export function registerBadge(): void {
  registerArkFunc(InteropMethod.BADGE_SET, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const args: BadgeArgs = JSON.parse(argJson) as BadgeArgs;
      const count: number = (typeof args.count === 'number' && args.count > 0) ? Math.floor(args.count) : 0;

      notificationManager.setBadgeNumber(count).then((): void => {
        onResult(JSON.stringify({ ok: true }));
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false }));
      });
    } catch (e) {
      // Badge is best-effort: never throw across the boundary; ack failure.
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
