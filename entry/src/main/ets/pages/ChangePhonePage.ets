import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "ChangePhonePage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function changePhonePageBuilder() {
  ChangePhonePageShell();
}

@Component
struct ChangePhonePageShell {
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
        component: 'ChangePhonePage'
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
    // test_failed 返修（diag-suite_settings_root-TC-0083.md 归因 F2，C2 判据）：源侧换号号码
    // 输入屏与登录号码输入屏共用同一个 AuthorizationSequencePhoneEntryController，其
    // attemptNavigation 恒返回 false，禁用交互式（侧滑/系统返回键）pop，只能走导航栏
    // 显式返回按钮（AuthorizationSequencePhoneEntryController.swift:85-88）。本文件宿主的
    // ChangePhonePage（entry/src/main/cangjie/pages/ChangePhonePage.cj）当前是独立自绘页、
    // 未复用该登录屏（复用需要参数化 auth/PhoneInputPage.cj，属跨 feature
    // auth_phone_entry_screen，已按 emitted_integration_contracts[] 交给该 feature，详见
    // featureX.md Hand-off），因此需要在本壳文件独立补一份同语义的禁用。
    // 与同仓兄弟壳 entry/src/main/ets/pages/PhoneInputPage.ets:44-46 完全相同的写法/证据链
    // （真机 hilog 已实测：未覆写时系统返回键/侧滑手势被 NavDestination 默认消费并对栈顶
    // 执行 pop；SDK 声明 nav_destination.d.ts:912 onBackPressed(callback: () => boolean)）。
    // 页面内显式的"← Back"文字按钮（ChangePhonePage.cj build()）走应用层 routerPop()/
    // 内部步骤切换，不经过这个系统回调，不受影响。
    .onBackPressed((): boolean => {
      return true;
    })
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
