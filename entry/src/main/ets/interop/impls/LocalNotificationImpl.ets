// LocalNotification capability — real @kit.NotificationKit impl (Phase 3 reversal, SSOT §5).
// ArkTS owns notificationManager.publish / getActiveNotifications / cancel;
// cangjie LocalNotificationDisplayService calls via callArk / callArkAsync.
//
// Methods:
//   NOTIF_PUBLISH = "notif.publish"
//     argJson (cangjie → ArkTS): {"id": number, "title": string, "text": string, "groupName": string}
//         groupName "" means "no group".
//     result (ArkTS → cangjie): {"ok": boolean}   — best-effort ack.
//   NOTIF_CANCEL_GROUP = "notif.cancelGroup"
//     argJson (cangjie → ArkTS): {"peerId": string}
//         cancels every delivered notification whose groupName == peerId or starts "<peerId>_".
//     result (ArkTS → cangjie): {"ok": boolean, "cancelled": number}
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';

// 点击通知拉起主 Ability（来电时全屏来电页已在栈顶，回前台即见）。
// 无 wantAgent 的通知点按无任何动作（实测「收到了通知但点不进去」）。
let cachedAgent: WantAgent | null = null;
function getLaunchAgent(): Promise<WantAgent> {
  if (cachedAgent !== null) {
    return Promise.resolve(cachedAgent);
  }
  const info: wantAgent.WantAgentInfo = {
    wants: [
      {
        bundleName: 'com.hmcangjie.telegram',
        abilityName: 'EntryAbility'
      }
    ],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  return wantAgent.getWantAgent(info).then((a: WantAgent): WantAgent => {
    cachedAgent = a;
    return a;
  });
}

// 消息通知点击 → 打开对应会话（iOS AppDelegate.userNotificationCenter(_:didReceive:)
// → peerIdFromNotification → openChatWhenReady）。peer 信息放进 want.parameters，
// EntryAbility.onCreate / onNewWant 读出后交给仓颉 NotificationClickRouter。
// 每个 peer 用独立 requestCode：同 requestCode + UPDATE_PRESENT_FLAG 会把旧通知的
// parameters 覆盖成最新一条，点旧通知就会进错会话。
function peerRequestCode(peerId: string, peerType: string): number {
  let h: number = 7;
  const key: string = peerType + ':' + peerId;
  for (let i: number = 0; i < key.length; i++) {
    h = (h * 31 + key.charCodeAt(i)) % 1000000007;
  }
  return 1 + (h % 2000000000);
}

function getPeerAgent(a: NotifPublishArgs): Promise<WantAgent> {
  const peerId: string = a.navPeerId ?? '';
  if (peerId === '' || peerId === '0') {
    return getLaunchAgent();
  }
  const peerType: string = a.navPeerType ?? '';
  const info: wantAgent.WantAgentInfo = {
    wants: [
      {
        bundleName: 'com.hmcangjie.telegram',
        abilityName: 'EntryAbility',
        parameters: {
          'notif_peer_id': peerId,
          'notif_peer_type': peerType,
          'notif_peer_name': a.navPeerName ?? '',
          'notif_msg_id': a.navMsgId ?? ''
        }
      }
    ],
    actionType: wantAgent.OperationType.START_ABILITY,
    requestCode: peerRequestCode(peerId, peerType),
    actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  return wantAgent.getWantAgent(info);
}

interface NotifPublishArgs {
  id: number;
  title: string;
  text: string;
  groupName: string;
  category?: string;
  navPeerId?: string;
  navPeerType?: string;
  navPeerName?: string;
  navMsgId?: string;
}

interface NotifCancelGroupArgs {
  peerId: string;
}

// groupName matches peer when exactly peerId, or "<peerId>_<topicId>".
function groupMatchesPeer(groupName: string, peerId: string): boolean {
  if (groupName === peerId) {
    return true;
  }
  return groupName.length > peerId.length + 1 && groupName.startsWith(peerId + '_');
}

// 来电横幅前置：确保 SOCIAL_COMMUNICATION 渠道存在（系统按该类型默认策略创建，
// 社交通讯类默认横幅+提示音）。对象版 addSlot(NotificationSlot 指定 level) 是
// systemapi，第三方不可用；横幅最终还受 设置→通知→本应用 的横幅开关控制。
function ensureSocialSlotHigh(): void {
  notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION)
    .then((): void => console.info('[LocalNotificationImpl] SOCIAL_COMMUNICATION slot ready'))
    .catch((e: Object): void => {
      try { console.error(`[LocalNotificationImpl] addSlot failed: ${JSON.stringify(e)}`); } catch (_) {}
    });
}

export function registerLocalNotification(): void {
  ensureSocialSlotHigh();
  registerArkFunc(InteropMethod.NOTIF_PUBLISH, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: NotifPublishArgs = JSON.parse(argJson) as NotifPublishArgs;
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: a.title,
          text: a.text
        }
      };
      const request: notificationManager.NotificationRequest = {
        id: a.id,
        content: content
      };
      if (a.groupName !== '') {
        request.groupName = a.groupName;
      }
      // 来电与消息都走社交通讯渠道：默认渠道（OTHER_TYPES）无横幅无铃声，
      // 消息通知还会被系统折叠进「更多通知」（R1 I1 实测）。
      if (a.category === 'incomingCall' || a.category === 'message') {
        request.notificationSlotType = notificationManager.SlotType.SOCIAL_COMMUNICATION;
      }
      getPeerAgent(a)
        .then((agent: WantAgent): Promise<void> => {
          request.wantAgent = agent;
          return notificationManager.publish(request);
        })
        .catch((): Promise<void> => notificationManager.publish(request))
        .then((): void => {
          onResult(JSON.stringify({ ok: true }));
        })
        .catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });

  registerArkFunc(InteropMethod.NOTIF_CANCEL_GROUP, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: NotifCancelGroupArgs = JSON.parse(argJson) as NotifCancelGroupArgs;
      const peerId: string = a.peerId;
      if (peerId === '') {
        onResult(JSON.stringify({ ok: true, cancelled: 0 }));
        return;
      }
      notificationManager.getActiveNotifications().then((list: Array<notificationManager.NotificationRequest>): void => {
        let cancelled: number = 0;
        for (let i: number = 0; i < list.length; i++) {
          const req: notificationManager.NotificationRequest = list[i];
          const gn: string = (typeof req.groupName === 'string') ? req.groupName : '';
          const id: number = (typeof req.id === 'number') ? req.id : -1;
          if (id >= 0 && groupMatchesPeer(gn, peerId)) {
            cancelled = cancelled + 1;
            notificationManager.cancel(id).catch((): void => {});
          }
        }
        onResult(JSON.stringify({ ok: true, cancelled: cancelled }));
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false, cancelled: 0 }));
      });
    } catch (e) {
      onResult(JSON.stringify({ ok: false, cancelled: 0 }));
    }
  });

  registerArkFunc(InteropMethod.NOTIF_ENABLED, (argJson: string, onResult: (r: string) => void): void => {
    try {
      notificationManager.isNotificationEnabled()
        .then((enabled: boolean): void => {
          onResult(JSON.stringify({ enabled: enabled }));
        })
        .catch((): void => {
          onResult(JSON.stringify({ error: 'unavailable' }));
        });
    } catch (e) {
      onResult(JSON.stringify({ error: 'unavailable' }));
    }
  });

  registerArkFunc(InteropMethod.NOTIF_REQUEST_ENABLE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const context: common.UIAbilityContext =
        (getContext() ?? globalThis.abilityContext) as common.UIAbilityContext;
      notificationManager.requestEnableNotification(context, (err: Object): void => {
        onResult(JSON.stringify({ granted: err === undefined || err === null }));
      });
    } catch (e) {
      onResult(JSON.stringify({ granted: false }));
    }
  });
}
