// 群 Video Chat 页（对位 iOS VideoChatScreenV2Impl）的通道。
//   groupCall.update  仓颉 → ArkTS：状态 JSON（state / title / 自己的静音态 / members…）
//   groupCall.action  ArkTS → 仓颉 dispatchEvent：{action, peerId?, text?}
import { registerArkFunc, dispatchEvent } from 'libohos_app_cangjie_entry.so';

export interface GroupCallMemberState {
  peerId: number;
  name: string;
  avatar: string;
  isSelf: boolean;
  isMuted: boolean;
  canSelfUnmute: boolean;
  mutedByYou: boolean;
  raiseHand: boolean;
  isSpeaking: boolean;
  level: string;
  volume: number;
  about: string;
  videoEndpoint: string;   // 非空 = 该成员正在发视频（自己恒为空，走本地预览）
  presentationEndpoint: string;   // 非空 = 该成员正在共享屏幕（第二路视频）
  presentationPaused: boolean;
  videoPaused: boolean;
}

export interface GroupCallMessageState {
  id: string;
  peerId: number;
  name: string;
  avatar: string;
  text: string;
  isSelf: boolean;
}

export interface GroupCallState {
  state: string;          // idle / connecting / connected / failed
  error: string;
  title: string;
  isMuted: boolean;
  canUnmute: boolean;
  raisedHand: boolean;
  canManage: boolean;
  speakerOn: boolean;
  isRecording: boolean;
  selfLevel: string;
  cameraOn: boolean;
  screenSharing: boolean;   // 自己在共享屏幕（含等待系统同意框）
  screenConnected: boolean;
  cameraFront: boolean;
  members: GroupCallMemberState[];
  messages: GroupCallMessageState[];
  messagesEnabled: boolean;
  canChangeMessages: boolean;
  joinMuted: boolean;
  displayAs: GroupCallDisplayAsState[];
  canChangeJoinMuted: boolean;
  inviteList: GroupCallInviteState[];
  inviteLoading: boolean;
  selfFirstName: string;
  selfLastName: string;
  selfIsUser: boolean;    // false = 以群/频道身份入会，没有 bio / 名字可改
  strings: Record<string, string>;   // 源英文 → 当前语言（只含有翻译的条目）
  mode: string;           // call | new | setup | scheduled
  scheduleDate: number;   // unix 秒
  reminderSet: boolean;
  routeCanManage: boolean;
  toast: string;      // "<seq>|<text>"：seq 变了才弹，避免每次推状态都重复弹
}

// "Display Me As" 的一个可选身份
export interface GroupCallDisplayAsState {
  peerId: number;
  name: string;
  avatar: string;
  current: boolean;
}

// 邀请面板的一行：本群成员（isMember）点了直接邀请，联系人先确认拉进群。
export interface GroupCallInviteState {
  peerId: number;
  name: string;
  avatar: string;
  isMember: boolean;
  invited: boolean;
}

type GroupCallListener = (raw: string) => void;
let gListener: GroupCallListener | null = null;
let gLast: string = '';

export function setGroupCallUpdateListener(l: GroupCallListener | null): void {
  gListener = l;
  if (l !== null && gLast.length > 0) {
    l(gLast);
  }
  if (l === null) {
    gLast = '';
  }
}

interface GroupCallActionPayload {
  action: string;
  peerId: number;
  text: string;
}

export function sendGroupCallAction(action: string, peerId: number = 0, text: string = ''): void {
  const payload: GroupCallActionPayload = { action: action, peerId: peerId, text: text };
  try {
    dispatchEvent('groupCall.action', JSON.stringify(payload));
  } catch (e) {
    console.error(`[GroupCall] dispatch failed: ${JSON.stringify(e)}`);
  }
}

export function registerGroupCall(): void {
  registerArkFunc('groupCall.update', (arg: string, onResult: (r: string) => void): void => {
    gLast = arg;
    if (gListener !== null) {
      gListener(arg);
    }
    onResult('{}');
  });
}
