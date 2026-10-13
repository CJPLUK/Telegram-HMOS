import { CJHybridComponent } from '@cangjie/cjhybridcomponent';

// route_map buildFunction for "DemoB": 内嵌 cangjie 子包页 DemoB（渲染时从 ParamStore 取富参）。
@Builder
export function demoBBuilder() {
  DemoBShell();
}

@Component
struct DemoBShell {
  build() {
    NavDestination() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'DemoB'
      })
        .width('100%')
        .height('100%')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .title('DemoB');
  }
}
