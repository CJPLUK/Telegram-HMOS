import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "DataUsagePage": 薄 ArkTS NavDestination 壳，内嵌仓颉页
// (diag-suite_settings_data_storage-TC-0429-round2.md 修法方向 §0/§1 grant). Shape copied
// verbatim from DataStorageSettingsPage.ets's NavDestination/Stack/CJHybridComponent +
// CustomTransition register/unregister three-piece (round2's explicit instruction), only
// `component:` and the struct/builder names changed. Not copied: DataStorageSettingsPage.
// ets's extra onShown/dispatchEvent wiring — that exists there to refresh stale root-page
// @State mirrors when a *child* screen changes something the root summarizes (TC-0420).
// This page has no such caller; its own state only changes via its own in-page Reset
// button, already reflected immediately — not a not-yet-wired gap.
@Builder
export function dataUsagePageBuilder() {
  DataUsagePageShell();
}

@Component
struct DataUsagePageShell {
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
        component: 'DataUsagePage'
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
