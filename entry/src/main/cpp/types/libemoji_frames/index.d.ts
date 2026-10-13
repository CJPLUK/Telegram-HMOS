export interface EmojiCachedFrames {
  raster: number;
  frameDurationMs: number;
  frames: ArrayBuffer[];
}
export const emojiLoadCachedFrames: (path: string, tint?: boolean) => EmojiCachedFrames | null;
export const emojiLoadRawFrame: (path: string, raster: number, tint?: boolean) => ArrayBuffer | null;

export interface EmojiAnimHandle {
  handle: number;
  raster: number;
  frameCount: number;
  frameDurationMs: number;
}
export const emojiAnimOpen: (path: string) => EmojiAnimHandle | null;
export const emojiAnimNextBatch: (handles: number[], outs: ArrayBuffer[]) => Promise<number[]>;
export const emojiAnimClose: (handle: number) => void;
