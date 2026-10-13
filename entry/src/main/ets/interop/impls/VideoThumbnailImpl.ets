// 视频首帧缩略图：AVImageGenerator 取帧 → ImagePacker 存 JPEG → 返回沙箱路径。
//   video.thumbnail {path, maxSide} → {ok, path, w, h, vw, vh, durMs}（vw/vh 为套旋转后的显示尺寸）
// 供发送视频 / 圆形视频消息时上传 inputMediaUploadedDocument.thumb（对位 iOS previewRepresentations）。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface ThumbArgs {
  path: string;
  maxSide?: number;
}

interface VideoMeta {
  w: number;      // 编码宽（未套旋转）
  h: number;
  rot: number;    // 0/90/180/270
  durMs: number;
}

function toInt(v: string | undefined): number {
  const n: number = parseInt(v ?? '0', 10);
  return Number.isNaN(n) ? 0 : n;
}

// AVMetadataExtractor 读容器元数据：宽高/旋转/时长。手机竖拍 mp4 的 tkhd 是 1920x1080 + 90° 矩阵，
// 仓颉侧只读 tkhd 会把竖视频当横视频发（iOS 端气泡比例就错）。
async function probeMeta(fd: number): Promise<VideoMeta> {
  const m: VideoMeta = { w: 0, h: 0, rot: 0, durMs: 0 };
  let ex: media.AVMetadataExtractor | undefined = undefined;
  try {
    ex = await media.createAVMetadataExtractor();
    ex.fdSrc = { fd: fd };
    const md: media.AVMetadata = await ex.fetchMetadata();
    m.w = toInt(md.videoWidth);
    m.h = toInt(md.videoHeight);
    m.rot = toInt(md.videoOrientation) % 360;
    m.durMs = toInt(md.duration);
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    console.warn(`[VideoThumb] metadata failed ${err.code} ${err.message}`);
  } finally {
    if (ex !== undefined) { try { await ex.release(); } catch (_e) {} }
  }
  return m;
}

async function makeThumb(a: ThumbArgs): Promise<string> {
  let src: fileIo.File | undefined = undefined;
  let gen: media.AVImageGenerator | undefined = undefined;
  let pixelMap: image.PixelMap | undefined = undefined;
  let packer: image.ImagePacker | undefined = undefined;
  let out: fileIo.File | undefined = undefined;
  let outPath: string = '';
  const fail: string = JSON.stringify({ ok: false, path: '', w: 0, h: 0, vw: 0, vh: 0, durMs: 0 });
  try {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    src = fileIo.openSync(a.path, fileIo.OpenMode.READ_ONLY);
    const meta: VideoMeta = await probeMeta(src.fd);
    const swap: boolean = meta.rot === 90 || meta.rot === 270;
    // 显示尺寸（套旋转后），对位 iOS 发送时的 dimensions
    const vw: number = swap ? meta.h : meta.w;
    const vh: number = swap ? meta.w : meta.h;
    const side: number = Math.max(64, Math.floor(a.maxSide ?? 320));
    // 按编码宽高等比缩到 maxSide；元数据缺失时退回正方形
    let tw: number = side;
    let th: number = side;
    if (meta.w > 0 && meta.h > 0) {
      const scale: number = side / Math.max(meta.w, meta.h);
      tw = Math.max(16, Math.round(meta.w * scale));
      th = Math.max(16, Math.round(meta.h * scale));
    }
    gen = await media.createAVImageGenerator();
    gen.fdSrc = { fd: src.fd };
    const param: media.PixelMapParams = { width: tw, height: th };
    pixelMap = await gen.fetchFrameByTime(0, media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC, param);
    let info: image.ImageInfo = await pixelMap.getImageInfo();
    // 取帧器可能已按旋转矩阵出图，也可能没有：以期望的横竖向为准补一次旋转
    if (swap && vw > 0 && vh > 0) {
      const wantPortrait: boolean = vh > vw;
      const isPortrait: boolean = info.size.height > info.size.width;
      if (wantPortrait !== isPortrait) {
        await pixelMap.rotate(meta.rot);
        info = await pixelMap.getImageInfo();
      }
    }
    outPath = context.cacheDir + '/vthumb_' + Date.now().toString() + '.jpg';
    out = fileIo.openSync(outPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    packer = image.createImagePacker();
    const opts: image.PackingOption = { format: 'image/jpeg', quality: 70 };
    await packer.packToFile(pixelMap, out.fd, opts);
    return JSON.stringify({
      ok: true, path: outPath, w: info.size.width, h: info.size.height,
      vw: vw, vh: vh, durMs: meta.durMs
    });
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    console.error(`[VideoThumb] failed ${err.code} ${err.message}`);
    if (outPath.length > 0) {
      try { fileIo.unlinkSync(outPath); } catch (_e0) {}
    }
    return fail;
  } finally {
    if (out !== undefined) { try { fileIo.closeSync(out); } catch (_e1) {} }
    if (packer !== undefined) { try { packer.release(); } catch (_e2) {} }
    if (pixelMap !== undefined) { try { pixelMap.release(); } catch (_e3) {} }
    if (gen !== undefined) { try { await gen.release(); } catch (_e4) {} }
    if (src !== undefined) { try { fileIo.closeSync(src); } catch (_e5) {} }
  }
}

export function registerVideoThumbnail(): void {
  registerArkFunc('video.thumbnail', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: ThumbArgs = JSON.parse(argJson) as ThumbArgs;
      makeThumb(a).then((r: string): void => { onResult(r); }).catch((): void => {
        onResult(JSON.stringify({ ok: false, path: '', w: 0, h: 0, vw: 0, vh: 0, durMs: 0 }));
      });
    } catch (_e) {
      onResult(JSON.stringify({ ok: false, path: '', w: 0, h: 0, vw: 0, vh: 0, durMs: 0 }));
    }
  });
}
