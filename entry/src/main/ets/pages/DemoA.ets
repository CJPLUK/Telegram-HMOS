import { CJHybridComponent } from '@cangjie/cjhybridcomponent';

// route_map buildFunction for "DemoA": 薄 ArkTS NavDestination 壳，内嵌 cangjie 子包页 DemoA。
@Builder
export function demoABuilder() {
  DemoAShell();
}

@Component
struct DemoAShell {
  build() {
    NavDestination() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'DemoA'
      })
        .width('100%')
        .height('100%')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .title('DemoA');
  }
}
