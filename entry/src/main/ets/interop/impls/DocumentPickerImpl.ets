// Document picker capability — real @kit.CoreFileKit DocumentViewPicker.
// Presents the system document selector (permission-free) so the user can pick a
// document (e.g. a notification sound .mp3) to upload. Mirrors PhotoPickerImpl's
// copy-into-sandbox pattern: picker.select() returns content:// URIs that cangjie's
// FileIo.open(path) cannot read directly, so each picked URI is copied into
// context.cacheDir and the sandbox path (not the URI) is returned.
//
// Method 'document.pick':
//   `InteropMethod`/`ets/interop/InteropContract.ets` is not in this feature's
//   allowlist, so this registration uses the same inline string-literal precedent
//   already established at `InteropRegistry.ets:41` for 'router.replaceTop': the
//   literal 'document.pick' must stay byte-for-byte identical to cangjie's
//   `interop/interop.cj` `PICK_DOCUMENT` and to
//   `services/NotificationSoundSelectionService.cj`'s private `NSND_PICK_DOCUMENT`
//   copy — both already use this exact string.
//   argJson (cangjie -> ArkTS): {"suffixes": string[], "maxSelectNumber": number}
//   result  (ArkTS -> cangjie): {"ok": boolean, "status": string, "paths": string[], "names": string[]}
//       status: "picked" | "cancelled" | "error".
//       paths : sandbox file paths (plain paths, no file:// prefix) of the copied
//               documents; empty for cancelled/error.
//       names : original user-facing file names (NOT derived from the sandbox
//               destPath, which is a synthetic name — see copyUriToSandbox),
//               parallel-indexed with paths.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

interface DocumentPickArgs {
  suffixes?: string[];
  maxSelectNumber?: number;
}

// Copy a picked document URI into the app sandbox cache dir, return the sandbox
// path (empty string on failure). Same pattern as PhotoPickerImpl.copyUriToSandbox.
function copyUriToSandbox(uri: string, index: number, displayName: string): string {
  let srcFile: fileIo.File | undefined = undefined;
  try {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    const dotIndex: number = displayName.lastIndexOf('.');
    const rawExtension: string = dotIndex >= 0 ? displayName.substring(dotIndex) : '';
    const extension: string = /^\.[A-Za-z0-9._-]{1,32}$/.test(rawExtension) ? rawExtension : '';
    const destPath: string = context.cacheDir + '/document_' + Date.now().toString() + '_' + index.toString() + extension;
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

// Original user-facing file name, read from the picker URI itself (not the sandbox
// destPath). `fileUri.FileUri(uri).name` is the SDK-provided accessor for this;
// fall back to a manual last-path-segment decode if it throws on an unexpected URI
// shape, so a naming edge case never turns into a dropped pick.
function extractDisplayName(uri: string): string {
  try {
    const name: string = new fileUri.FileUri(uri).name;
    if (name.length > 0) {
      return name;
    }
  } catch (e) {
  }
  try {
    const withoutQuery: string = uri.split('?')[0];
    const segments: string[] = withoutQuery.split('/');
    const last: string = segments.length > 0 ? segments[segments.length - 1] : '';
    return decodeURIComponent(last);
  } catch (e2) {
    return '';
  }
}

export function registerDocumentPicker(): void {
  registerArkFunc('document.pick', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const args: DocumentPickArgs = JSON.parse(argJson) as DocumentPickArgs;
      const suffixes: string[] = args.suffixes ?? [];
      const maxSelectNumber: number = (typeof args.maxSelectNumber === 'number' && args.maxSelectNumber > 0) ? args.maxSelectNumber : 1;

      const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = suffixes;
      options.maxSelectNumber = maxSelectNumber;

      documentPicker.select(options).then((uris: Array<string>): void => {
        if (uris.length === 0) {
          onResult(JSON.stringify({ ok: true, status: 'cancelled', paths: [] as string[], names: [] as string[] }));
          return;
        }
        const paths: string[] = [];
        const names: string[] = [];
        for (let i: number = 0; i < uris.length; i++) {
          const uri: string = uris[i];
          if (uri.length === 0) {
            continue;
          }
          const displayName: string = extractDisplayName(uri);
          const p: string = copyUriToSandbox(uri, i, displayName);
          if (p.length > 0) {
            paths.push(p);
            names.push(displayName);
          }
        }
        if (paths.length === 0) {
          onResult(JSON.stringify({ ok: false, status: 'error', paths: [] as string[], names: [] as string[] }));
        } else {
          onResult(JSON.stringify({ ok: true, status: 'picked', paths: paths, names: names }));
        }
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false, status: 'error', paths: [] as string[], names: [] as string[] }));
      });
    } catch (e) {
      onResult(JSON.stringify({ ok: false, status: 'error', paths: [] as string[], names: [] as string[] }));
    }
  });
}
