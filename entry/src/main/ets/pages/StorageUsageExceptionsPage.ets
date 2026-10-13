import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "StorageUsageExceptionsPage": thin ArkTS NavDestination
// shell embedding the Cangjie page (diag-suite_settings_data_storage-TC-0430-round2.md
// M-2 grant, feature.json commit 019274cbc). Shape copied verbatim from
// StorageUsagePage.ets (same three-piece NavDestination/Stack/CJHybridComponent +
// CustomTransition register/unregister pattern), only `component:` and the
// struct/builder names changed — no onShown wiring needed this round (nothing else in
// this feature reads state back from this screen on return).
@Builder
export function storageUsageExceptionsPageBuilder() {
  StorageUsageExceptionsPageShell();
}

@Component
struct StorageUsageExceptionsPageShell {
  // CTL-SHARED-003: push transition offset/dim (driven by CustomTransition)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';
  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'StorageUsageExceptionsPage'
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
