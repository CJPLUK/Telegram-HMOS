// Continuous task (长时任务) — keep the MTProto connection alive in background so
// incoming calls are always receivable (CALL-BG).
//
// iOS 对照: Telegram-iOS 用 PushKit VoIP push 唤醒挂起的 app（无需保活）。
// HarmonyOS 第三方应用无系统 VoIP push 唤醒权益，等价方案是 voip/dataTransfer
// 长时任务：退后台后进程与 socket 保活，来电信令照常到达 → CallService 全局
// 弹全屏来电页。配套 module.json5: backgroundModes [voip,dataTransfer] +
// ohos.permission.KEEP_BACKGROUND_RUNNING。
//
// Methods:
//   BGTASK_START — startBackgroundRunning(context, VOIP; 失败回退 DATA_TRANSFER)
//     argJson: {}    result: {"ok": bool, "mode": "voip"|"dataTransfer"|"", "err": string}
//   BGTASK_STOP  — stopBackgroundRunning(context)
//     argJson: {}    result: {"ok": bool}
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface BgTaskResult {
  ok: boolean;
  mode: string;
  err: string;
}

function buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
  const wantAgentInfo: wantAgent.WantAgentInfo = {
    wants: [
      {
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'EntryAbility'
      }
    ],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  return wantAgent.getWantAgent(wantAgentInfo);
}

function startWithMode(
  context: common.UIAbilityContext,
  agent: WantAgent,
  mode: backgroundTaskManager.BackgroundMode
): Promise<void> {
  return backgroundTaskManager.startBackgroundRunning(context, mode, agent);
}

export function registerContinuousTask(): void {
  registerArkFunc(InteropMethod.BGTASK_START, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const context: common.UIAbilityContext =
        (getContext() ?? globalThis.abilityContext) as common.UIAbilityContext;
      buildWantAgent(context)
        .then((agent: WantAgent): void => {
          startWithMode(context, agent, backgroundTaskManager.BackgroundMode.VOIP)
            .then((): void => {
              const r: BgTaskResult = { ok: true, mode: 'voip', err: '' };
              onResult(JSON.stringify(r));
            })
            .catch((e1: BusinessError): void => {
              // voip 模式可能因未开通权益被拒 → 回退 dataTransfer
              startWithMode(context, agent, backgroundTaskManager.BackgroundMode.DATA_TRANSFER)
                .then((): void => {
                  const r: BgTaskResult = { ok: true, mode: 'dataTransfer', err: `voip rejected: ${e1.code}` };
                  onResult(JSON.stringify(r));
                })
                .catch((e2: BusinessError): void => {
                  const r: BgTaskResult = { ok: false, mode: '', err: `voip:${e1.code} dataTransfer:${e2.code}` };
                  onResult(JSON.stringify(r));
                });
            });
        })
        .catch((e: BusinessError): void => {
          const r: BgTaskResult = { ok: false, mode: '', err: `wantAgent:${e.code}` };
          onResult(JSON.stringify(r));
        });
    } catch (e) {
      const be = e as BusinessError;
      const r: BgTaskResult = { ok: false, mode: '', err: `exception ${be.code}: ${be.message}` };
      onResult(JSON.stringify(r));
    }
  });

  registerArkFunc(InteropMethod.BGTASK_STOP, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const context: common.UIAbilityContext =
        (getContext() ?? globalThis.abilityContext) as common.UIAbilityContext;
      backgroundTaskManager.stopBackgroundRunning(context)
        .then((): void => onResult('{"ok":true}'))
        .catch((): void => onResult('{"ok":false}'));
    } catch (e) {
      onResult('{"ok":false}');
    }
  });
}
