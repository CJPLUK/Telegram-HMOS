import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "ChangePhoneIntroPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function changePhoneIntroPageBuilder() {
  ChangePhoneIntroPageShell();
}

@Component
struct ChangePhoneIntroPageShell {
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
        component: 'ChangePhoneIntroPage'
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
    // diag-suite_settings_root-TC-0083.md round4 M-2-b 点 1：与宿主 ChangePhonePage.ets
    // 不同——说明前置屏源侧可正常交互式返回（AuthorizationSequencePhoneEntryController 的
    // attemptNavigation==false 只锁定"号码输入屏"这一层，PrivacyIntroController 无此限制，
    // backBarButtonItem = Common_Back 是普通可返回按钮）。故本壳文件不覆写
    // .onBackPressed，系统返回键/侧滑手势与页面内 "← Back" 按钮行为一致，均为 routerPop()。
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
