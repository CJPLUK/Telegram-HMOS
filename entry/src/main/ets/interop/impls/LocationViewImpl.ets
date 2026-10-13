// 应用内位置 / 实时位置查看页（对位 iOS LocationViewController）的通道。
//   locationView.update  仓颉 → ArkTS：状态 JSON（subject / user / own / participants）
//   locationView.action  ArkTS → 仓颉 dispatchEvent：{action, seconds?, lat?, lng?, title?}
import { registerArkFunc, dispatchEvent } from 'libohos_app_cangjie_entry.so';

export interface LocationViewSubject {
  msgId: number;
  lat: string;
  lng: string;
  isLive: boolean;
  period: number;
  timestamp: number;
  editDate: number;
  isSent: boolean;
  senderId: number;
  senderName: string;
  title: string;
  venueTitle: string;
  venueAddress: string;
}

export interface LocationViewUser {
  ok: boolean;
  lat: string;
  lng: string;
}

export interface LocationViewOwn {
  active: boolean;
  msgId: number;
  begin: number;
  period: number;
}

export interface LocationViewParticipant {
  msgId: number;
  peerId: number;
  isSelf: boolean;
  name: string;
  avatar: string;
  lat: string;
  lng: string;
  heading: number;
  updated: number;
  begin: number;
  period: number;
}

export interface LocationViewState {
  peerType: string;
  peerId: number;
  subject: LocationViewSubject;
  user: LocationViewUser;
  own: LocationViewOwn;
  participants: LocationViewParticipant[];
  now: number;
}

type LocationViewListener = (raw: string) => void;
let gListener: LocationViewListener | null = null;

export function setLocationViewUpdateListener(l: LocationViewListener | null): void {
  gListener = l;
}

interface LocationViewActionPayload {
  action: string;
  seconds: number;
  lat: string;
  lng: string;
  title: string;
}

export function sendLocationViewAction(action: string, seconds: number, lat: string, lng: string, title: string): void {
  const payload: LocationViewActionPayload = { action: action, seconds: seconds, lat: lat, lng: lng, title: title };
  try {
    dispatchEvent('locationView.action', JSON.stringify(payload));
  } catch (e) {
    console.error(`[LocationView] dispatch failed: ${JSON.stringify(e)}`);
  }
}

export function registerLocationView(): void {
  registerArkFunc('locationView.update', (arg: string, onResult: (r: string) => void): void => {
    if (gListener != null) {
      gListener(arg);
    }
    onResult('{}');
  });
}
