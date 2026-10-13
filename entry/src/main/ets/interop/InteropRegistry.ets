import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from './InteropContract';
import { AppRouter } from '../router/AppRouter';
import { registerHaptic } from './impls/HapticImpl';
import { registerBadge } from './impls/BadgeImpl';
import { registerGeocoding } from './impls/GeocodingImpl';
import { registerAudioRoute } from './impls/AudioRouteImpl';
import { registerLocalNotification } from './impls/LocalNotificationImpl';
import { registerBackgroundPrivacy } from './impls/BackgroundPrivacyImpl';
import { registerLocalAuth } from './impls/LocalAuthImpl';
import { registerPasskey } from './impls/PasskeyImpl';
import { registerContinuousTask } from './impls/ContinuousTaskImpl';
import { registerPushToken } from './impls/PushTokenImpl';
import { registerCamera } from './impls/CameraImpl';
import { registerShareLink } from './impls/ShareLinkImpl';
import { registerIapReceipt } from './impls/IapReceiptImpl';
import { registerScanDecode } from './impls/ScanDecodeImpl';
import { registerPhotoPicker } from './impls/PhotoPickerImpl';
import { registerContactPicker } from './impls/ContactPickerImpl';
import { registerComponentSnapshot } from './impls/ComponentSnapshotImpl';
import { registerDocumentPicker } from './impls/DocumentPickerImpl';
import { registerEmojiGrid } from './impls/EmojiGridImpl';
import { registerAttachGrid } from './impls/AttachGridImpl';
import { registerAttachMap } from './impls/AttachMapImpl';
import { registerAttachLocation } from './impls/AttachLocationImpl';
import { registerLocationView } from './impls/LocationViewImpl';
import { registerGroupCall } from './impls/GroupCallImpl';
import { registerMapKit } from './impls/MapKitImpl';
import { registerAudioPlayer } from './impls/AudioPlayerImpl';
import { registerVideoThumbnail } from './impls/VideoThumbnailImpl';
import { registerVoiceEncoder } from './impls/VoiceEncoderImpl';
import { registerRoundVideo } from './impls/RoundVideoImpl';
import { registerCameraPreview } from './impls/CameraPreviewImpl';
import { registerImageCompress } from './impls/ImageCompressImpl';
import { registerLanguageDisplayNames } from './impls/LanguageDisplayNamesImpl';
import { registerStorageStats } from './impls/StorageStatsImpl';
import { registerVoipCall } from './impls/VoipCallImpl';
import { registerInAppBanner } from './impls/InAppBannerImpl';
import { registerUndoToastOverlay } from './impls/UndoToastOverlayImpl';
import { window } from '@kit.ArkUI';

// 启动时把 ArkTS 侧能力/router 实现注册进 cangjie（反转模式，SSOT §5）。
// 所有契约方法在此登记；仓颉服务经 callArkAsync 调用。契约全异步(D1)：
// 每个 impl 形态 = (argJson, onResult) => void，异步完成后调 onResult(resJson)。
export function registerAllCapabilities(): void {
  // ---- router 操作（仓颉 router 经 interop 驱动 ArkTS NavPathStack）----
  registerArkFunc(InteropMethod.ROUTER_PUSH, (arg: string, onResult: (r: string) => void): void => {
    AppRouter.push(arg);
    onResult('{}');
  });
  registerArkFunc(InteropMethod.ROUTER_POP, (arg: string, onResult: (r: string) => void): void => {
    AppRouter.pop();
    onResult('{}');
  });
  registerArkFunc(InteropMethod.ROUTER_REPLACE, (arg: string, onResult: (r: string) => void): void => {
    AppRouter.replace(arg);
    onResult('{}');
  });
  // diag-suite_settings_root-TC-0083.md M-2-c：值须与 cangjie 侧 interop/interop.cj 的
  // ROUTER_REPLACE_TOP 一字不差（'router.replaceTop'）。InteropContract.ets 不在本 feature
  // allowlist 内，故不新增 InteropMethod.ROUTER_REPLACE_TOP 具名常量，直接内联同值字面量。
  registerArkFunc('router.replaceTop', (arg: string, onResult: (r: string) => void): void => {
    AppRouter.replaceTop(arg);
    onResult('{}');
  });
  registerArkFunc('appearance.systemBars', (arg: string, onResult: (r: string) => void): void => {
    try {
      const dark: boolean = (JSON.parse(arg) as Record<string, boolean>).dark === true;
      AppStorage.setOrCreate<boolean>('globalDarkMode', dark);
      window.getLastWindow(getContext()).then((mainWindow: window.Window): void => {
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: dark ? '#FF000000' : '#00000000',
          statusBarContentColor: dark ? '#FFFFFFFF' : '#FF000000',
          navigationBarColor: dark ? '#FF000000' : '#00000000',
          navigationBarContentColor: dark ? '#FFFFFFFF' : '#FF000000',
          enableStatusBarAnimation: true
        }).then((): void => onResult('{"ok":true}'))
          .catch((): void => onResult('{"ok":false}'));
      }).catch((): void => onResult('{"ok":false}'));
    } catch (_e) {
      onResult('{"ok":false}');
    }
  });

  // ---- Phase 3 能力（反转，真实 @kit.* 实现在 impls/<Cap>Impl.ets）----
  registerHaptic();
  registerBadge();
  registerGeocoding();
  registerAudioRoute();
  registerLocalNotification();
  registerBackgroundPrivacy();
  registerLocalAuth();
  registerPasskey();
  registerPushToken();
  registerContinuousTask();
  registerVoipCall();
  registerCamera();
  registerShareLink();
  registerLanguageDisplayNames();
  registerStorageStats();
  registerIapReceipt();
  registerScanDecode();
  registerPhotoPicker();
  registerEmojiGrid();
  registerAttachGrid();
  registerAttachMap();
  registerAttachLocation();
  registerLocationView();
  registerGroupCall();
  registerMapKit();
  registerAudioPlayer();
  registerVideoThumbnail();
  registerVoiceEncoder();
  registerRoundVideo();
  registerCameraPreview();
  registerImageCompress();
  registerContactPicker();
  registerComponentSnapshot();
  // diag-suite_settings_notifications-TC-0449-round5.md 改动2：document.pick 从未
  // 注册进 ARK_FUNCS，Upload Sound 静默无反应。'document.pick' 是内联字面量（见
  // impls/DocumentPickerImpl.ets 文件头注释），与 :41 的 'router.replaceTop' 同一
  // 既有做法。
  registerDocumentPicker();
  registerInAppBanner();
  registerUndoToastOverlay();
}
