import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "ThemePreviewPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// 源侧 navigationPresentation = .modal（ThemePreviewController.swift:62-68）——目标侧 modal
// 两处登记点（router/router.cj#isModalRoute + 本目录 CustomTransition.ets#MODAL_ROUTES）
// 均不在 set_theme_editing 的 allowlist（owner shell_settings_misc，同型先例见
// pages/RecentSessionScreen.ets / pages/ProxySettingsPage.cj 的同款注释）。本轮先按普通 push
// 落地，两处登记留给该 owner 后续接线；接线前到达本屏退化成默认横向 push 转场。
@Builder
export function themePreviewPageBuilder() {
  ThemePreviewPageShell();
}

@Component
struct ThemePreviewPageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';
  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'ThemePreviewPage'
      })
        .width('100%')
        .height('100%');
        if (this.ctDim > 0.001) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Black)
            .opacity(this.ctDim);
        }
      }
      .width('100%')
      .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .hideTitleBar(true)
    .translate({ x: `${this.ctTransX}%`, y: `${this.ctTransY}%` })
    .onReady((ctx: NavDestinationContext) => {
      this.ctNavId = ctx.navDestinationId ?? '';
      CustomTransition.register(this.ctNavId, (x: number, y: number, d: number) => {
        this.ctTransX = x;
        this.ctTransY = y;
        this.ctDim = d;
      });
    })
    .onDisAppear(() => {
      CustomTransition.unregister(this.ctNavId);
    });
  }
}
