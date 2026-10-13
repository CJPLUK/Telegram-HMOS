import { CJHybridComponent } from '@cangjie/cjhybridcomponent';

// route_map buildFunction for "PaymentCardEntryScreen": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// 源页 NavDestination 使用 hideTitleBar(false) + title("Add Payment Method")，此处保留。
@Builder
export function paymentCardEntryScreenBuilder() {
  PaymentCardEntryScreenShell();
}

@Component
struct PaymentCardEntryScreenShell {
  @StorageProp('safeAreaTopVp') safeAreaTopVp: number = 0;
  build() {
    NavDestination() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'PaymentCardEntryScreen'
      })
        .width('100%')
        .height('100%')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .title('Add Payment Method')
    .hideTitleBar(false)
    .padding({ top: this.safeAreaTopVp });
  }
}
