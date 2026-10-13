// 聊天附件面板 Location 页签（对位 iOS LocationPickerControllerNode）整块由 ArkTS 渲染。
//
// 为什么整块搬到 ArkTS：此前仓颉 LocationPicker 只留地图占位、由 ArkTS 覆盖层按占位块几何
// 贴一张 HMS 地图；列表上滑时占位块随内容滚动，每帧都要「仓颉状态 → onAreaChange →
// interop → ArkTS 重排 MapComponent」，地图逐帧被 resize，真机明显卡顿。改为地图与列表
// 同在 ArkTS 一层里（AttachLocationView.ets），滚动完全在本进程内完成；仓颉只在
// 定位/地点数据变化时推一次状态。
//
// 通道：
//   attachLocation.update  仓颉 → ArkTS：{visible,x,y,w,h(px), ready,loading,permission,error,
//                          name,accuracy,lat,lng(string),venuesLoading,query,venues[]}
//   attachLocation.action  ArkTS → 仓颉 dispatchEvent：{action:'sendCurrent'|'sendLive'|
//                          'sendVenue'|'search'|'retry', seconds?, id?, query?}
import { registerArkFunc, dispatchEvent } from 'libohos_app_cangjie_entry.so';

export interface AttachVenue {
  id: string;
  title: string;
  address: string;
  label: string;
  color: number;
}

export interface AttachLocationUpdate {
  visible: boolean;
  x: number;
  y: number;
  w: number;
  h: number;
  ready: boolean;
  loading: boolean;
  permission: boolean;
  error: string;
  name: string;
  accuracy: number;
  lat: string;
  lng: string;
  venuesLoading: boolean;
  query: string;
  venues: AttachVenue[];
}

type AttachLocationListener = (u: AttachLocationUpdate, raw: string) => void;

let gListener: AttachLocationListener | null = null;

export function setAttachLocationUpdateListener(l: AttachLocationListener | null): void {
  gListener = l;
}

interface LocationActionPayload {
  action: string;
  seconds: number;
  id: string;
  query: string;
}

/** 覆盖层里的用户动作 → 仓颉（LocationPicker.handleArkAction）。 */
export function sendAttachLocationAction(action: string, seconds: number, id: string, query: string): void {
  const payload: LocationActionPayload = { action: action, seconds: seconds, id: id, query: query };
  try {
    dispatchEvent('attachLocation.action', JSON.stringify(payload));
  } catch (e) {
    console.error(`[AttachLocation] dispatch failed: ${JSON.stringify(e)}`);
  }
}

export function registerAttachLocation(): void {
  registerArkFunc('attachLocation.update', (arg: string, onResult: (r: string) => void): void => {
    try {
      const u: AttachLocationUpdate = JSON.parse(arg) as AttachLocationUpdate;
      if (gListener != null) {
        gListener(u, arg);
      }
    } catch (_e) {
      // 畸形 payload 忽略
    }
    onResult('{}');
  });
}
