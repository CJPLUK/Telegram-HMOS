import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "RecentSessionScreen": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// diag-suite_settings_privacy-TC-0135.md §8 M1：对位源 RecentSessionScreen.swift:1215
// navigationPresentation = .flatModal + ResizableSheetComponent，压暗设备屏 + 底部面板。
// 需登记进 ets/router/CustomTransition.ets 的 MODAL_ROUTES（跨 allowlist，已按
// emitted_integration_contracts[] 上报，owner shell_settings_misc）。
@Builder
export function recentSessionScreenBuilder() {
  RecentSessionScreenShell();
}

@Component
struct RecentSessionScreenShell {
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
        component: 'RecentSessionScreen'
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
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]);
    }
    .hideTitleBar(true)
    .mode(NavDestinationMode.DIALOG)
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
