// ShareLink capability — real @kit.ShareKit systemShare.ShareController impl (Phase 3 reversal, SSOT §5).
// ArkTS owns the system share sheet; cangjie InviteMembersSheet.shareLink() calls via
// callArkAsync(SHARE_LINK, argJson).
//
// argJson (cangjie → ArkTS): {"url": string, "title": string} | {"text": string, "title": string}
//     url   — the invite link to share (goes into SharedRecord.content, HYPERLINK UTD).
//     text  — plain text to share (PLAIN_TEXT UTD); used when url is absent.
//     title — optional sheet/record title.
// Media-file extension (imgmenu batch, ImageViewer share button):
//   {"filePath": string, "title": string, "isVideo": boolean}
//     filePath — absolute sandbox path of a local media file; converted to a shareable
//                file:// URI via fileUri.getUriFromPath and shared with utd IMAGE/VIDEO
//                (SharedRecord.uri branch; ShareKit grants the receiver read access).
//     When filePath is present it takes precedence over url.
// result (ArkTS → cangjie): {"ok": boolean}
//     ok=true  → share sheet was presented successfully.
//     ok=false → share unavailable (no context / API error); caller degrades to clipboard-copy.
//
// The share sheet requires a UIAbilityContext; obtained via getContext() (same pattern as
// BackgroundPrivacyImpl). Text/URL sharing uses the general.plain-text UTD with content=url.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';

interface ShareLinkArgs {
  url?: string;
  text?: string;
  title?: string;
  filePath?: string;
  isVideo?: boolean;
}

export function registerShareLink(): void {
  registerArkFunc(InteropMethod.SHARE_LINK, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: ShareLinkArgs = JSON.parse(argJson) as ShareLinkArgs;
      const url: string = (typeof a.url === 'string') ? a.url : '';
      const text: string = (typeof a.text === 'string') ? a.text : '';
      const filePath: string = (typeof a.filePath === 'string') ? a.filePath : '';
      if (url.length === 0 && text.length === 0 && filePath.length === 0) {
        onResult(JSON.stringify({ ok: false }));
        return;
      }
      const title: string = (typeof a.title === 'string' && a.title.length > 0) ? a.title : 'Invite';

      let record: systemShare.SharedRecord;
      if (filePath.length > 0) {
        // Media-file branch: sandbox path → shareable file:// URI, IMAGE/VIDEO UTD.
        const isVideo: boolean = a.isVideo === true;
        const shareUri: string = filePath.startsWith('file://') ? filePath : fileUri.getUriFromPath(filePath);
        record = {
          utd: isVideo ? utd.UniformDataType.VIDEO : utd.UniformDataType.IMAGE,
          uri: shareUri,
          title: title
        };
      } else if (url.length > 0) {
        record = {
          utd: utd.UniformDataType.HYPERLINK,
          content: url,
          title: title
        };
      } else {
        // Plain-text branch (InviteContactsPage "Share Telegram": full invite sentence, not a bare URL).
        record = {
          utd: utd.UniformDataType.PLAIN_TEXT,
          content: text,
          title: title
        };
      }
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);

      const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
      controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      }).then((): void => {
        onResult(JSON.stringify({ ok: true }));
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false }));
      });
    } catch (e) {
      // Never throw across the boundary; on any failure caller falls back to clipboard.
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
