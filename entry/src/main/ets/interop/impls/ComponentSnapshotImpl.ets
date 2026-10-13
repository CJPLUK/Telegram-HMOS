// Exact visual handoff for the iOS-style message context menu.
// Cangjie owns the overlay state, while ArkTS captures the already-rendered
// message node without constructing a second media component.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import componentSnapshot from '@ohos.arkui.componentSnapshot';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

interface SnapshotCaptureArgs {
  componentId: string;
  token: string;
}

interface SnapshotReleaseArgs {
  path: string;
}

interface SnapshotResult {
  ok: boolean;
  path: string;
  width: number;
  height: number;
  error: string;
}

function result(ok: boolean, path: string, width: number, height: number, error: string): string {
  const value: SnapshotResult = { ok: ok, path: path, width: width, height: height, error: error };
  return JSON.stringify(value);
}

async function captureToPng(componentId: string, token: string): Promise<SnapshotResult> {
  let pixelMap: image.PixelMap | undefined = undefined;
  let packer: image.ImagePacker | undefined = undefined;
  let output: fileIo.File | undefined = undefined;
  let path: string = '';
  try {
    pixelMap = await componentSnapshot.get(componentId);
    const info: image.ImageInfo = await pixelMap.getImageInfo();
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    const safeToken: string = token.replace(/[^a-zA-Z0-9_-]/g, '_');
    path = context.cacheDir + '/message_context_' + safeToken + '_' + Date.now().toString() + '.png';
    output = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    packer = image.createImagePacker();
    const options: image.PackingOption = { format: 'image/png', quality: 100 };
    await packer.packToFile(pixelMap, output.fd, options);
    return { ok: true, path: path, width: info.size.width, height: info.size.height, error: '' };
  } catch (e) {
    if (path.length > 0) {
      try { fileIo.unlinkSync(path); } catch (_cleanupError) {}
    }
    return { ok: false, path: '', width: 0, height: 0, error: 'snapshot_failed' };
  } finally {
    if (output !== undefined) {
      try { fileIo.closeSync(output); } catch (_closeError) {}
    }
    if (packer !== undefined) {
      try { packer.release(); } catch (_packerError) {}
    }
    if (pixelMap !== undefined) {
      try { pixelMap.release(); } catch (_pixelError) {}
    }
  }
}

export function registerComponentSnapshot(): void {
  registerArkFunc(InteropMethod.COMPONENT_SNAPSHOT_CAPTURE,
    (argJson: string, onResult: (r: string) => void): void => {
      try {
        const args: SnapshotCaptureArgs = JSON.parse(argJson) as SnapshotCaptureArgs;
        if (args.componentId.length === 0) {
          onResult(result(false, '', 0, 0, 'empty_component_id'));
          return;
        }
        captureToPng(args.componentId, args.token).then((captured: SnapshotResult): void => {
          onResult(JSON.stringify(captured));
        }).catch((): void => {
          onResult(result(false, '', 0, 0, 'snapshot_failed'));
        });
      } catch (_e) {
        onResult(result(false, '', 0, 0, 'invalid_arguments'));
      }
    });

  registerArkFunc(InteropMethod.COMPONENT_SNAPSHOT_RELEASE,
    (argJson: string, onResult: (r: string) => void): void => {
      try {
        const args: SnapshotReleaseArgs = JSON.parse(argJson) as SnapshotReleaseArgs;
        if (args.path.length > 0) {
          try { fileIo.unlinkSync(args.path); } catch (_unlinkError) {}
        }
        onResult(result(true, '', 0, 0, ''));
      } catch (_e) {
        onResult(result(false, '', 0, 0, 'invalid_arguments'));
      }
    });
}
