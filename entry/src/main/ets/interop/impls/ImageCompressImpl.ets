// 发图压缩：photo.compress {path, maxSide, quality} → {ok, path, width, height, bytes}
// 对位 iOS 发图默认按 1280 px 长边缩放为 JPEG（TransformOutgoingMessageMedia / 媒体选择器），
// 此前把相册原图（2–3 MB）直接上传。按 EXIF 方向摆正后再编码，成片 rotation=0。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface CompressArgs {
  path: string;
  maxSide?: number;
  quality?: number;
}

function exifRotation(v: string): number {
  const s: string = v.toLowerCase();
  if (s.indexOf('right-top') >= 0 || s === '6') return 90;
  if (s.indexOf('bottom-right') >= 0 || s === '3') return 180;
  if (s.indexOf('left-bottom') >= 0 || s === '8') return 270;
  return 0;
}

async function compress(a: CompressArgs): Promise<string> {
  const fail: string = JSON.stringify({ ok: false, path: '', width: 0, height: 0, bytes: 0 });
  let src: image.ImageSource | undefined = undefined;
  let pm: image.PixelMap | undefined = undefined;
  let packer: image.ImagePacker | undefined = undefined;
  let out: fileIo.File | undefined = undefined;
  let outPath: string = '';
  try {
    const maxSide: number = Math.max(256, Math.floor(a.maxSide ?? 1280));
    const quality: number = Math.min(100, Math.max(30, Math.floor(a.quality ?? 80)));
    src = image.createImageSource(a.path);
    const info: image.ImageInfo = await src.getImageInfo();
    let rot: number = 0;
    try {
      const o: string = await src.getImageProperty(image.PropertyKey.ORIENTATION);
      rot = exifRotation(o);
    } catch (_e) {}
    const w: number = info.size.width;
    const h: number = info.size.height;
    const scale: number = Math.min(1, maxSide / Math.max(w, h));
    const tw: number = Math.max(1, Math.round(w * scale));
    const th: number = Math.max(1, Math.round(h * scale));
    const opts: image.DecodingOptions = {
      desiredSize: { width: tw, height: th },
      rotate: rot,
      editable: false
    };
    pm = await src.createPixelMap(opts);
    const outInfo: image.ImageInfo = await pm.getImageInfo();
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    outPath = context.cacheDir + '/send_' + Date.now().toString() + '.jpg';
    out = fileIo.openSync(outPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    packer = image.createImagePacker();
    await packer.packToFile(pm, out.fd, { format: 'image/jpeg', quality: quality });
    const st: fileIo.Stat = fileIo.statSync(outPath);
    return JSON.stringify({ ok: true, path: outPath, width: outInfo.size.width, height: outInfo.size.height, bytes: st.size });
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    console.error(`[ImageCompress] failed ${err.code} ${err.message}`);
    if (outPath.length > 0) { try { fileIo.unlinkSync(outPath); } catch (_e0) {} }
    return fail;
  } finally {
    if (out !== undefined) { try { fileIo.closeSync(out); } catch (_e1) {} }
    if (packer !== undefined) { try { packer.release(); } catch (_e2) {} }
    if (pm !== undefined) { try { pm.release(); } catch (_e3) {} }
    if (src !== undefined) { try { src.release(); } catch (_e4) {} }
  }
}

export function registerImageCompress(): void {
  registerArkFunc('photo.compress', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: CompressArgs = JSON.parse(argJson) as CompressArgs;
      compress(a).then((r: string): void => { onResult(r); }).catch((): void => {
        onResult(JSON.stringify({ ok: false, path: '', width: 0, height: 0, bytes: 0 }));
      });
    } catch (_e) {
      onResult(JSON.stringify({ ok: false, path: '', width: 0, height: 0, bytes: 0 }));
    }
  });
}
