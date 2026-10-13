// 相机取景 XComponent（CameraPage.ets 壳，垫在仓颉页下方；仓颉预览区透明透出，同 VideoCallScreen）。
//   cameraPreview.surfaceId  仓颉 → ArkTS：{} → {surfaceId}（XComponent onLoad 后非空）
//   cameraPreview.layout     仓颉 → ArkTS：{round, square}  取景面布局（圆形/方形/16:9 竖屏）
// 此前预览走 ImageReceiver(JPEG) 100ms 轮询解码成 Image：视频场景会话下帧解不出（黑屏），
// 且拖慢录制帧率；相机预览本就该直渲到 surface。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';

export interface CameraPreviewLayout {
  round: boolean;
  square: boolean;
}

type LayoutListener = (l: CameraPreviewLayout) => void;

let gSurfaceId: string = '';
let gLayoutListener: LayoutListener | null = null;

export function publishCameraPreviewSurface(sid: string): void {
  gSurfaceId = sid;
}

export function clearCameraPreviewSurface(): void {
  gSurfaceId = '';
}

export function setCameraPreviewLayoutListener(l: LayoutListener | null): void {
  gLayoutListener = l;
}

export function registerCameraPreview(): void {
  registerArkFunc('cameraPreview.surfaceId', (_arg: string, onResult: (r: string) => void): void => {
    onResult(JSON.stringify({ surfaceId: gSurfaceId }));
  });
  registerArkFunc('cameraPreview.layout', (arg: string, onResult: (r: string) => void): void => {
    try {
      const l: CameraPreviewLayout = JSON.parse(arg) as CameraPreviewLayout;
      if (gLayoutListener !== null) {
        gLayoutListener(l);
      }
    } catch (_e) {
      // 畸形 payload 忽略
    }
    onResult('{}');
  });
}
