import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "ProxySettingsPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function proxySettingsPageBuilder() {
  ProxySettingsPageShell();
}

@Component
struct ProxySettingsPageShell {
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
        component: 'ProxySettingsPage'
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
