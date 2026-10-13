// Photo-album picker capability — real @kit.MediaLibraryKit PhotoViewPicker.
// Presents the system album selector (permission-free) so the user can pick any
// photo to send from the chat attachment menu. Mirrors ScanDecodeImpl's
// SCAN_PICK_ALBUM PhotoViewPicker usage, but instead of decoding a QR it copies the
// picked media URI into the app sandbox and returns readable local paths.
//
// Method PICK_PHOTO_ALBUM = "photo.pickAlbum"
//   argJson (cangjie → ArkTS): {}   (no args)
//   result  (ArkTS → cangjie): {"ok": boolean, "status": string, "paths": string[]}
//       status: "picked" | "cancelled" | "error".
//       paths : sandbox file paths (plain paths, no file:// prefix) of the copied
//               images; empty for cancelled/error. sendPhoto needs a readable local
//               file, and a media-library URI cannot be handed straight to cangjie
//               fileIo, so each pick is copied into cacheDir first.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

// Copy a picked media URI into the app sandbox cache dir, return the sandbox path
// (empty string on failure). fileIo.copyFileSync accepts a source fd + dest path.
export function copyUriToSandbox(uri: string, index: number): string {
  return copyMediaUriToSandbox(uri, index, '.jpg');
}

// 按扩展名拷贝：附件面板网格里图片视频混排，视频要落 .mp4 才能走视频发送链路。
export function copyMediaUriToSandbox(uri: string, index: number, ext: string): string {
  let srcFile: fileIo.File | undefined = undefined;
  try {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    const destPath: string = context.cacheDir + '/album_' + Date.now().toString() + '_' + index.toString() + ext;
    srcFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    fileIo.copyFileSync(srcFile.fd, destPath);
    return destPath;
  } catch (e) {
    return '';
  } finally {
    if (srcFile !== undefined) {
      try {
        fileIo.closeSync(srcFile);
      } catch (e2) {
      }
    }
  }
}

interface PhotoPickArgs {
  mime?: string;          // "image" (default) | "video" | "imagevideo"
  maxSelectNumber?: number;
}

// 从 URI 取原始文件名（附件 sheet File 页签「Select from Gallery」按文件发送时要保留原名/后缀）
function displayNameOfUri(uri: string): string {
  try {
    const withoutQuery: string = uri.split('?')[0];
    const segments: string[] = withoutQuery.split('/');
    const last: string = segments.length > 0 ? segments[segments.length - 1] : '';
    return decodeURIComponent(last);
  } catch (e) {
    return '';
  }
}

function extOfName(name: string): string {
  const idx: number = name.lastIndexOf('.');
  if (idx < 0 || idx === name.length - 1) {
    return '.jpg';
  }
  return name.substring(idx).toLowerCase();
}

export function registerPhotoPicker(): void {
  registerArkFunc(InteropMethod.PICK_PHOTO_ALBUM, (argJson: string, onResult: (r: string) => void): void => {
    try {
      let args: PhotoPickArgs = {};
      try {
        args = JSON.parse(argJson) as PhotoPickArgs;
      } catch (_e) {
        args = {};
      }
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      const mime: string = args.mime ?? 'image';
      if (mime === 'imagevideo') {
        options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
      } else if (mime === 'video') {
        options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
      } else {
        options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      }
      options.maxSelectNumber = (typeof args.maxSelectNumber === 'number' && args.maxSelectNumber > 0)
        ? args.maxSelectNumber : 1;
      picker.select(options).then((sel: photoAccessHelper.PhotoSelectResult): void => {
        const uris: Array<string> = sel.photoUris;
        if (uris.length === 0) {
          onResult(JSON.stringify({ ok: true, status: 'cancelled', paths: [] as string[] }));
          return;
        }
        const paths: string[] = [];
        const names: string[] = [];
        for (let i: number = 0; i < uris.length; i++) {
          const uri: string = uris[i];
          if (uri.length === 0) {
            continue;
          }
          const name: string = displayNameOfUri(uri);
          const p: string = copyMediaUriToSandbox(uri, i, extOfName(name));
          if (p.length > 0) {
            paths.push(p);
            names.push(name);
          }
        }
        if (paths.length === 0) {
          onResult(JSON.stringify({ ok: false, status: 'error', paths: [] as string[], names: [] as string[] }));
        } else {
          onResult(JSON.stringify({ ok: true, status: 'picked', paths: paths, names: names }));
        }
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false, status: 'error', paths: [] as string[] }));
      });
    } catch (e) {
      onResult(JSON.stringify({ ok: false, status: 'error', paths: [] as string[] }));
    }
  });
}
