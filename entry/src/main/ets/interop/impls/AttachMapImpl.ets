// 附件面板 Location 页签内嵌系统地图（HMS Map Kit MapComponent，对位 iOS LocationPicker 顶部真实地图）。
// MapComponent 只能在 ArkTS 侧渲染，复用表情/图库网格的「仓颉推几何 → ArkTS 覆盖层」通道。
//   attachMap.update  仓颉 → ArkTS：{visible,x,y,w,h,lat,lng}（px / 度）
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';

export interface AttachMapUpdate {
  visible: boolean;
  x: number;
  y: number;
  w: number;
  h: number;
  lat: number;
  lng: number;
}

type AttachMapListener = (u: AttachMapUpdate) => void;

let gListener: AttachMapListener | null = null;

export function setAttachMapUpdateListener(l: AttachMapListener | null): void {
  gListener = l;
}

export function registerAttachMap(): void {
  registerArkFunc('attachMap.update', (arg: string, onResult: (r: string) => void): void => {
    try {
      const u: AttachMapUpdate = JSON.parse(arg) as AttachMapUpdate;
      if (gListener != null) {
        gListener(u);
      }
    } catch (_e) {
      // 畸形 payload 忽略
    }
    onResult('{}');
  });
}
