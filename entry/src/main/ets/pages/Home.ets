import { AppRouter } from '../router/AppRouter';
import { CustomTransition, FADE_ROUTES, FULLSCREEN_VERTICAL_ROUTES, MODAL_ROUTES } from '../router/CustomTransition';
import { curves, display, window } from '@kit.ArkUI';
import { InAppNotificationBanner } from '../interop/impls/InAppBannerImpl';
import { UndoToastOverlayHost } from '../interop/impls/UndoToastOverlayImpl';

// ArkTS @Entry container — the single ArkTS entry. It holds the Navigation(AppRouter.stack)
// and routes into AppRoot (the cangjie login-gating root) which decides, based on
// getAuthViewModel().isLoggedIn, whether to routerReplace into MainTabPage (logged in) or
// SplashPage (login flow). All further navigation is cangjie routerPush/Replace → AppRouter stack.
//
// CTL-SHARED-003: customNavContentTransition 实现 iOS push/pop 转场——
// push: 新页自右整屏滑入(spring ~0.5s),旧页左移 30% 视差 + dim 0.15;pop 反向。
// 参数源: iOS ContainedViewLayoutTransition .spring(mass5/stiffness900/damping100≈0.5s),
// NavigationTransitionCoordinator 视差 0.3、dim 0.15。
@Entry
@Component
struct Home {
  // diag-suite_settings_root-TC-0081-round7.md §6.4: 模态呈现期,下层页四周由黑底承接
  // (对位源 NavigationModalFrame 的四条黑 shade)。模态在栈期间为 true,退出模态还原。
  @State ctModalActive: boolean = false;
  @StorageProp('globalDarkMode') globalDarkMode: boolean = false;

  // diag-suite_settings_root-TC-0081-round8.md §6: 状态栏前景色三件套的第三件,
  // 对位源 NavigationController.swift:1193-1194 (statusBarStyle = .White),
  // 与驱动黑底的 ctModalActive 同一判据、同址调用。写法逐字照抄仓内先例
  // PeerInfoPage.ets updateSystemBars()。false 分支取值须与
  // EntryAbility.ets 冷启动写死的 statusBarContentColor 逐字一致。
  private applyModalStatusBar(active: boolean): void {
    window.getLastWindow(getContext()).then((mainWindow: window.Window): void => {
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: active ? '#FFFFFFFF' : '#FF000000'
      });
    });
  }

  aboutToAppear(): void {
    AppRouter.push('AppRoot');
  }

  build() {
    // S7-59: the in-app message banner sits above the whole Navigation stack (iOS presents
    // ChatMessageNotificationItem in the window-level NotificationContainerController).
    Stack({ alignContent: Alignment.Top }) {
    Navigation(AppRouter.stack) {
    }
    .hideTitleBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(this.ctModalActive || this.globalDarkMode ? Color.Black : Color.White)
    .customNavContentTransition((from: NavContentInfo, to: NavContentInfo, operation: NavigationOperation) => {
      // 首页装载(index -1)与 replace 用默认(无)转场
      if (from.index === -1 || to.index === -1 || operation === NavigationOperation.REPLACE) {
        return undefined;
      }
      const trans: NavigationAnimatedTransition = {
        timeout: 700,
        transition: (proxy: NavigationTransitionProxy) => {
          const fromId = from.navDestinationId;
          const toId = to.navDestinationId;
          // 模态路由(iOS flatModal): 竖直上滑 sheet,底层不视差只 dim 0.25
          const pushName: string = operation === NavigationOperation.PUSH ? (to.name ?? '') : (from.name ?? '');
          const isModal: boolean = MODAL_ROUTES.has(pushName);
          const isFade: boolean = FADE_ROUTES.has(pushName);
          const isFullscreenVertical: boolean = FULLSCREEN_VERTICAL_ROUTES.has(pushName);
          // diag-suite_settings_root-TC-0081-round7.md §6.2-3: 下层页缩放系数,逐字对位
          // NavigationController.swift:1219 maxScale = (W - 32) / W(W 取视口 vp)。
          const winWidthVp = px2vp(display.getDefaultDisplaySync().width);
          const modalUnderlayScale = (winWidthVp - 32) / winWidthVp;
          if (operation === NavigationOperation.PUSH) {
            if (isFullscreenVertical) {
              // Telegram iOS AuthorizationSequenceController.swift:1405-1420：
              // 添加账号的认证容器从整屏底部以 0.5s spring 进入。
              CustomTransition.apply(toId, 0, 100, 0);
              CustomTransition.apply(fromId, 0, 0, 0);
              this.getUIContext().animateTo({
                duration: 500,
                curve: curves.interpolatingSpring(0, 1, 342, 30),
                onFinish: () => proxy.finishTransition()
              }, () => {
                CustomTransition.apply(toId, 0, 0, 0);
              });
            } else if (isFade) {
              CustomTransition.apply(toId, 0, 0, 0, 1.0, 0.0);
              CustomTransition.apply(fromId, 0, 0, 0, 1.0, 1.0);
              this.getUIContext().animateTo({
                duration: 180,
                curve: Curve.EaseOut,
                onFinish: () => proxy.finishTransition()
              }, () => {
                CustomTransition.apply(toId, 0, 0, 0, 1.0, 1.0);
              });
            } else if (isModal) {
              this.ctModalActive = true;
              this.applyModalStatusBar(true);
              CustomTransition.apply(toId, 0, 100, 0);
              CustomTransition.apply(fromId, 0, 0, 0);
              this.getUIContext().animateTo({
                duration: 400,
                curve: curves.interpolatingSpring(0, 1, 342, 30),
                onFinish: () => {
                  // diag-suite_settings_root-TC-0081-round2-dynamic.md §6-G3：模态呈现期下层
                  // 页遮罩是常驻状态(对位源 NavigationModalContainer.swift:386 的 dim 恒为
                  // 黑色 α0.25)，不是转场专属，push 动画结束后不得把它归零。
                  CustomTransition.apply(fromId, 0, 0, 0.25, modalUnderlayScale);
                  proxy.finishTransition();
                }
              }, () => {
                CustomTransition.apply(toId, 0, 0, 0);
                CustomTransition.apply(fromId, 0, 0, 0.25, modalUnderlayScale);
              });
            } else {
              CustomTransition.apply(toId, 100, 0, 0);
              CustomTransition.apply(fromId, 0, 0, 0);
              this.getUIContext().animateTo({
                duration: 500,
                curve: curves.interpolatingSpring(0, 1, 342, 30),
                onFinish: () => {
                  CustomTransition.apply(fromId, 0, 0, 0);
                  proxy.finishTransition();
                }
              }, () => {
                CustomTransition.apply(toId, 0, 0, 0);
                CustomTransition.apply(fromId, -30, 0, 0.15);
              });
            }
          } else {
            if (isFullscreenVertical) {
              // 同一源码 animateOut：0.2s easeInEaseOut 向屏幕底部退出。
              CustomTransition.apply(fromId, 0, 0, 0);
              CustomTransition.apply(toId, 0, 0, 0);
              this.getUIContext().animateTo({
                duration: 200,
                curve: Curve.EaseInOut,
                onFinish: () => proxy.finishTransition()
              }, () => {
                CustomTransition.apply(fromId, 0, 100, 0);
              });
            } else if (isFade) {
              CustomTransition.apply(fromId, 0, 0, 0, 1.0, 1.0);
              CustomTransition.apply(toId, 0, 0, 0, 1.0, 1.0);
              this.getUIContext().animateTo({
                duration: 180,
                curve: Curve.EaseOut,
                onFinish: () => proxy.finishTransition()
              }, () => {
                CustomTransition.apply(fromId, 0, 0, 0, 1.0, 0.0);
              });
            } else if (isModal) {
              CustomTransition.apply(fromId, 0, 0, 0);
              // toId(下层页)此刻仍处于 push 阶段留下的缩放态,pop 动画开始前先维持
              // modalUnderlayScale 不做无动画的瞬时归位,避免在动画开始前先跳变。
              CustomTransition.apply(toId, 0, 0, 0.25, modalUnderlayScale);
              // diag-suite_settings_root-TC-0081.md 归因:状态栏前景色须与几何动画
              // 同一时基,在关闭起点(而非 onFinish)写入,对位源侧 dismissWithAnimation()
              // 起点即置 dismissProgress=1.0 并立刻重算样式。ctModalActive(黑底)不随动,
              // 仍按进度收拢语义留在 onFinish 里。
              this.applyModalStatusBar(false);
              this.getUIContext().animateTo({
                duration: 350,
                curve: curves.interpolatingSpring(0, 1, 342, 34),
                onFinish: () => {
                  this.ctModalActive = false;
                  proxy.finishTransition();
                }
              }, () => {
                CustomTransition.apply(fromId, 0, 100, 0);
                // 对称还原:下层页缩放系数还原为 1.0(对位 round7 §6.2 修法方向)。
                CustomTransition.apply(toId, 0, 0, 0, 1.0);
              });
            } else {
              CustomTransition.apply(fromId, 0, 0, 0);
              CustomTransition.apply(toId, -30, 0, 0.15);
              this.getUIContext().animateTo({
                duration: 500,
                curve: curves.interpolatingSpring(0, 1, 342, 30),
                onFinish: () => {
                  proxy.finishTransition();
                }
              }, () => {
                CustomTransition.apply(fromId, 100, 0, 0);
                CustomTransition.apply(toId, 0, 0, 0);
              });
            }
          }
        }
      };
      return trans;
    });
      // Undo/轻提示浮条也挂在整个 Navigation 栈之上（iOS UndoOverlayController 挂在 window 级
      // 容器，不随页面栈切换），命中区只覆盖浮条本身，见 impls/UndoToastOverlayImpl.ets。
      UndoToastOverlayHost()
      InAppNotificationBanner()
    }
    .width('100%')
    .height('100%')
  }
}
