import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "AutosaveExceptionConfigPage": 薄 ArkTS NavDestination 壳，
// 内嵌仓颉页。diag-suite_settings_data_storage-TC-0424-round7.md F-1(4) 新建——逐字照抄
// UsernameSettingsPage.ets 的 DIALOG 壳形态(圆角/顶部安全区补偿/.mode(DIALOG))，只改
// component: 名与 builder 名（round7 F-1(4) 边界：本壳登记为 modal；兄弟路由
// AutosaveExceptionPeerSelectionPage 保持 push，不套用本壳）。
@Builder
export function autosaveExceptionConfigPageBuilder() {
  AutosaveExceptionConfigPageShell();
}

@Component
struct AutosaveExceptionConfigPageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  // 祖先 Home.ets 的 Navigation.expandSafeArea([SYSTEM],[TOP,BOTTOM]) 把这个 DIALOG 壳的
  // 布局盒钉在 y=0；expandSafeArea 只能扩不能缩，壳自己去不掉这段内缩，只能由
  // EntryAbility.dispatchSafeAreaChanged 发布的这个值在内容侧显式补偿。
  @StorageProp('safeAreaTopVp') safeAreaTopVp: number = 0;
  private ctNavId: string = '';
  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'AutosaveExceptionConfigPage'
      })
        .width('100%')
        .height('100%')
        .borderRadius({ topLeft: 10, topRight: 10 })
        .clip(true);
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
      .padding({ top: this.safeAreaTopVp + 10 })
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
