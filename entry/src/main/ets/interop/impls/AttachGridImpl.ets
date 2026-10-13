// 聊天附件面板内嵌图库网格（对位 iOS AttachmentController 的 MediaPickerScreen 区域）。
//
// 为什么走 ArkTS 覆盖层：读系统图库需要 ohos.permission.READ_IMAGEVIDEO，该权限是
// 受限权限，本仓签名 profile 的 allowed-acls 为空，声明后直接装不上（实测
// install failed ... PermissionName: ohos.permission.READ_IMAGEVIDEO）。
// PhotoPickerComponent 是免权限的系统选择器组件，但只能在 ArkTS 侧渲染，
// 因此复用表情网格已验证的「仓颉推几何 → ArkTS 覆盖层按几何绘制」通道
// （EmojiGridImpl.ets / ChatRoomPage.ets 同构）。
//
// 通道：
//   attachGrid.update  仓颉 → ArkTS：{visible,x,y,w,h}（px），控制覆盖层显隐与几何。
//                      visible=false 时同时取消挂起的 pick（避免 onResult 泄漏）。
//   attachGrid.pick    仓颉 → ArkTS：挂起式请求，用户在网格里选中一张后才回调
//                      {"ok":true,"status":"picked","paths":[沙箱路径]}；
//                      面板关闭时回 {"ok":true,"status":"cancelled","paths":[]}。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';

export interface AttachGridUpdate {
  visible: boolean;
  x: number;
  y: number;
  w: number;
  h: number;
}

type AttachUpdateListener = (u: AttachGridUpdate) => void;

let gListener: AttachUpdateListener | null = null;

export function setAttachGridUpdateListener(l: AttachUpdateListener | null): void {
  gListener = l;
}

// 挂起中的 pick 回调（同 PhotoPickerImpl：onResult 跨异步持有）
let gPick: ((r: string) => void) | null = null;

/** 网格里确认一批选择 → 回调仓颉发送；kinds 与 paths 按下标一一对应。 */
export function resolveAttachPick(paths: string[], kinds: string[]): void {
  const cb: ((r: string) => void) | null = gPick;
  gPick = null;
  if (cb !== null) {
    cb(JSON.stringify({ ok: true, status: 'picked', kinds: kinds, paths: paths }));
  }
}

/** 面板关闭 / 覆盖层隐藏 → 取消挂起请求 */
export function cancelAttachPick(): void {
  const cb: ((r: string) => void) | null = gPick;
  gPick = null;
  if (cb !== null) {
    cb(JSON.stringify({ ok: true, status: 'cancelled', kinds: [] as string[], paths: [] as string[] }));
  }
}

export function registerAttachGrid(): void {
  registerArkFunc('attachGrid.update', (arg: string, onResult: (r: string) => void): void => {
    try {
      const u: AttachGridUpdate = JSON.parse(arg) as AttachGridUpdate;
      if (!u.visible) {
        cancelAttachPick();
      }
      if (gListener != null) {
        gListener(u);
      }
    } catch (_e) {
      // 畸形 payload 忽略
    }
    onResult('{}');
  });

  registerArkFunc('attachGrid.pick', (_arg: string, onResult: (r: string) => void): void => {
    // 前一个请求还挂着（面板反复开合）：先取消，避免两个 onResult 同时在手
    cancelAttachPick();
    gPick = onResult;
  });
}
