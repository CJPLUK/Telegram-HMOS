import { CJHybridComponent } from '@cangjie/cjhybridcomponent';

@Entry
@Component
struct TestPage {
  @State message: string = 'Hello World';

  build() {
    Column() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'TestPage'
      })
    }
    .height('100%')
    .width('100%')
  }
}
