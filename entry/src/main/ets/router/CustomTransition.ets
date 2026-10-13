// CTL-SHARED-003: iOS push 转场(0.5s spring 右侧滑入 + 底层 30% 视差 + dim 0.15)。
// 每个 NavDestination 壳在 onReady 注册自己的 setter;Home 的 customNavContentTransition
// 在 push/pop 时通过本单例驱动两侧页面的 translate/dim。
// 参照 OpenHarmony Navigation 自定义转场官方样例的 registry 模式。

// xPct/yPct: 页面位移,百分比(100 = 整屏宽/高);dim: 遮罩不透明度(0~0.25);
// scale: 下层页整体缩放系数(modal 呈现时 (W-32)/W,非 modal 场景恒为 1.0)。
// TS 回调形参可少于类型声明,已注册的既有 3 参 setter 无需改动即可继续编译通过。
export type PageTransformSetter = (xPct: number, yPct: number, dim: number, scale: number, opacity: number) => void;

// CTL-SETTINGS-001 等: iOS navigationPresentation=.modal/.flatModal 的路由——
// push 用底部上滑 sheet 样式(竖直),底层不视差只 dim。
export const MODAL_ROUTES: Set<string> = new Set<string>(['QrLoginPage', 'ArchiveInfoPage', 'LogoutOptionsPage', 'UsernameSettingsPage', 'ProxySettingsPage', 'ChatQrCodeSharePage', 'DeleteAccountOptionsScreen', 'PassportPage', 'ChatFolderEditorPage', 'ChatFolderPeerSelectionPage', 'ChatFolderInviteLinkPage', 'PremiumDemoPage', 'PremiumPage', 'ThemeAccentColorPickerPage', 'AutosaveExceptionPeerSelectionPage', 'AutosaveExceptionConfigPage', 'ComposePage']);
export const FADE_ROUTES: Set<string> = new Set<string>(['AvatarGalleryPage']);
// AuthorizationSequenceController.animateIn/animateOut: 多账号认证流是白色全屏
// 从底部进入/退出，不使用 sheet 的底页缩放、黑色遮罩或白色状态栏前景。
export const FULLSCREEN_VERTICAL_ROUTES: Set<string> = new Set<string>(['PhoneInputPage']);

class CustomTransitionClass {
  private setters: Map<string, PageTransformSetter> = new Map();

  register(id: string, setter: PageTransformSetter): void {
    this.setters.set(id, setter);
  }

  unregister(id: string): void {
    this.setters.delete(id);
  }

  apply(id: string | undefined, xPct: number, yPct: number, dim: number, scale: number = 1.0, opacity: number = 1.0): void {
    if (id === undefined) {
      return;
    }
    const s = this.setters.get(id);
    if (s !== undefined) {
      s(xPct, yPct, dim, scale, opacity);
    }
  }
}

export const CustomTransition = new CustomTransitionClass();
