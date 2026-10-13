import { CJHybridComponent } from '@cangjie/cjhybridcomponent';

// route_map buildFunction for "WeatherPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function weatherPageBuilder() {
  WeatherPageShell();
}

@Component
struct WeatherPageShell {
  @StorageProp('safeAreaTopVp') safeAreaTopVp: number = 0;
  build() {
    NavDestination() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'WeatherPage'
      })
        .width('100%')
        .height('100%')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .title('Weather')
    .hideTitleBar(false)
    .padding({ top: this.safeAreaTopVp });
  }
}
