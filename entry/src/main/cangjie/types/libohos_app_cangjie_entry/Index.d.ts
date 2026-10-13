export declare function testCJ(s: string): string
export declare function registerArkFunc(name: string, fn: (funcArg0: string, funcArg1: (funcArgfuncArg0: string) => void) => void): void

export declare function dispatchEvent(event: string, payloadJson: string): void

export declare function appStartup(context: Object): void

// 视频通话 XComponent surfaceId → 原生解码器 GPU 直渲。"0"/"" 清除。
export declare function setVideoCallSurface(surfaceId: string): void
export declare function setEmojiGridSurface(surfaceId: string, w?: string, h?: string): void
// sid 匹配清除：仅当该 sid 仍是当前绑定时才清（防旧 shell 迟到销毁误清新绑定）。
export declare function clearVideoCallSurface(surfaceId: string): void
export declare function getEmojiGridRows(): string
export declare function emojiGridEvent(json: string): void
export declare function getStickerGridRows(): string
export declare function stickerGridEvent(json: string): void
