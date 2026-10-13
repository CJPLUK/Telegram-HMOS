// Phase1：仓颉 → ArkTS 表情网格覆盖层的几何/可见性/数据代际通道。
// 仓颉侧 callArk('emojiGrid.update', json)；壳（ChatRoomPage.ets）注册监听。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';

export interface EmojiGridUpdate {
  visible: boolean;
  x: number;
  y: number;
  w: number;
  h: number;
  gen: number;
  sr?: number; // 导航跳转目标行（-1 = 无）
  ss?: number; // 跳转序号（变化才执行）
}

type UpdateListener = (u: EmojiGridUpdate) => void;

let gListener: UpdateListener | null = null;

export function setEmojiGridUpdateListener(l: UpdateListener | null): void {
  gListener = l;
}

let gStickerListener: UpdateListener | null = null;

export function setStickerGridUpdateListener(l: UpdateListener | null): void {
  gStickerListener = l;
}

export function registerEmojiGrid(): void {
  registerArkFunc('emojiGrid.update', (arg: string, onResult: (r: string) => void): void => {
    console.info(`[ArkGrid] recv ${arg}`);
    try {
      const u: EmojiGridUpdate = JSON.parse(arg) as EmojiGridUpdate;
      if (gListener != null) {
        gListener(u);
      }
    } catch (_e) {
      // ignore malformed
    }
    onResult('{}');
  });
  // 贴纸 Phase1：同构的第二通道
  registerArkFunc('stickerGrid.update', (arg: string, onResult: (r: string) => void): void => {
    console.info(`[ArkStk] recv ${arg}`);
    try {
      const u: EmojiGridUpdate = JSON.parse(arg) as EmojiGridUpdate;
      if (gStickerListener != null) {
        gStickerListener(u);
      }
    } catch (_e) {
      // ignore malformed
    }
    onResult('{}');
  });
}
