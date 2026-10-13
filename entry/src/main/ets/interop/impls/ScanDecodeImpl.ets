// Scan-decode capability — real @kit.ScanKit detectBarcode + @kit.MediaLibraryKit
// photoAccessHelper impl (Phase 3 reversal, SSOT §5).
// OHOS has no C QR NDK; QR decode lives in ArkTS ScanKit. ArkTS owns detectBarcode.decode
// and the album PhotoViewPicker; cangjie QrScannerPage calls via callArkAsync.
//
// Method SCAN_DECODE_FILE = "scan.decodeFile"
//   Decode a QR/barcode from a sandbox image file the camera frame was written to.
//   argJson (cangjie → ArkTS): {"uri": string}   file:// uri of the JPEG frame.
//   result (ArkTS → cangjie): {"ok": boolean, "code": string}
//       ok=true  → code = first barcode originalValue (empty if none found but decode ran).
//       ok=false → decode threw. code omitted.
//
// Method SCAN_PICK_ALBUM = "scan.pickAlbum"
//   Present the system photo picker, then decode the picked image.
//   argJson (cangjie → ArkTS): {}   (no args)
//   result (ArkTS → cangjie): {"ok": boolean, "code": string, "status": string}
//       status: "decoded" | "empty" (picked but no QR) | "cancelled" (no selection) | "error".
//       code   : QR text when status="decoded", else "".
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { detectBarcode, scanBarcode } from '@kit.ScanKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

interface ScanDecodeFileArgs {
  uri: string;
}

function decodeUri(uri: string, onCode: (ok: boolean, code: string) => void): void {
  try {
    const input: detectBarcode.InputImage = { uri: uri };
    detectBarcode.decode(input).then((results: Array<scanBarcode.ScanResult>): void => {
      let code: string = '';
      if (results.length > 0 && typeof results[0].originalValue === 'string') {
        code = results[0].originalValue;
      }
      onCode(true, code);
    }).catch((): void => {
      onCode(false, '');
    });
  } catch (e) {
    onCode(false, '');
  }
}

export function registerScanDecode(): void {
  registerArkFunc(InteropMethod.SCAN_DECODE_FILE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: ScanDecodeFileArgs = JSON.parse(argJson) as ScanDecodeFileArgs;
      const uri: string = (typeof a.uri === 'string') ? a.uri : '';
      if (uri.length === 0) {
        onResult(JSON.stringify({ ok: false }));
        return;
      }
      decodeUri(uri, (ok: boolean, code: string): void => {
        onResult(JSON.stringify({ ok: ok, code: code }));
      });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });

  registerArkFunc(InteropMethod.SCAN_PICK_ALBUM, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      picker.select(options).then((sel: photoAccessHelper.PhotoSelectResult): void => {
        const uris: Array<string> = sel.photoUris;
        if (uris.length === 0 || uris[0].length === 0) {
          onResult(JSON.stringify({ ok: true, code: '', status: 'cancelled' }));
          return;
        }
        decodeUri(uris[0], (ok: boolean, code: string): void => {
          if (!ok) {
            onResult(JSON.stringify({ ok: false, code: '', status: 'error' }));
          } else if (code.length > 0) {
            onResult(JSON.stringify({ ok: true, code: code, status: 'decoded' }));
          } else {
            onResult(JSON.stringify({ ok: true, code: '', status: 'empty' }));
          }
        });
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false, code: '', status: 'error' }));
      });
    } catch (e) {
      onResult(JSON.stringify({ ok: false, code: '', status: 'error' }));
    }
  });
}
