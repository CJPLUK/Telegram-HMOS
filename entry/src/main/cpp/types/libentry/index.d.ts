export const add: (a: number, b: number) => number;
export interface EmojiCachedFrames {
  raster: number;
  frameDurationMs: number;
  frames: ArrayBuffer[];
}
export const emojiLoadCachedFrames: (path: string) => EmojiCachedFrames | null;
export const emojiLoadRawFrame: (path: string, raster: number) => ArrayBuffer | null;

declare const entryDefault: {
  add: (a: number, b: number) => number;
  emojiLoadCachedFrames: (path: string) => EmojiCachedFrames | null;
  emojiLoadRawFrame: (path: string, raster: number) => ArrayBuffer | null;
};
export default entryDefault;
