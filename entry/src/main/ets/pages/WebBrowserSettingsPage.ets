import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "WebBrowserSettingsPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// 形态照抄 AutoNightSettingsPage.ets（diag-suite_settings_data_storage-TC-0435.md §6.7 指定）。
//
// 非模态（源侧 webBrowserSettingsController 走普通 pushControllerImpl，
// PrivacyAndSecurityController.swift:1459-1462，没有 navigationPresentation = .modal）：
// 因此**不**加进 ../router/CustomTransition 的 MODAL_ROUTES，也**不**加进
// entry/src/main/cangjie/router/router.cj 的 isModalRoute()（D-166 的两处登记点，本路由两处都不登记）。
@Builder
export function webBrowserSettingsPageBuilder() {
  WebBrowserSettingsPageShell();
}

@Component
struct WebBrowserSettingsPageShell {
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
        component: 'WebBrowserSettingsPage'
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
