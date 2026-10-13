import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "AppearanceSettingsPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function appearanceSettingsPageBuilder() {
  AppearanceSettingsPageShell();
}

// TC-0403 D1 返修：事件名字面量须与 entry/src/main/cangjie/pages/AppearanceSettingsPage.cj 内
// subscribe(this.appearanceShownEvent, ...) 逐字一致（同 PhoneInputPage.ets/.cj 既有先例——
// entry/src/main/cangjie/interop/interop.cj 不在本 feature target_files 内，故不新增共享常量，
// 两侧各自持有同一字面量，交叉引用见双方注释）。
const APPEARANCE_SETTINGS_SHOWN_EVENT = 'settings.appearanceSettingsPage.shown';

@Component
struct AppearanceSettingsPageShell {
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
        component: 'AppearanceSettingsPage'
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
    })
    // TC-0403 D1: Auto-Night 摘要行读的是 AppearanceSettingsPage.cj#autoNightThemeRightValue()，
    // 派生自本页 @State autoNightMode 字段——只在该字段被显式重新赋值时才会触发本
    // NavDestination 重新 build()（bare @State 驱动重建，同 D-125 记载的机制）。从
    // AutoNightSettingsPage 改完模式 routerPop() 回到本页时，本 NavDestination 已挂载，
    // 不会仅因为重新可见就自动重新 build()。onShown 在本 NavDestination 每次(重新)可见时
    // 触发（含冷启动 + 任意 push/pop 返回路径，同 PhoneInputPage.ets 的既有先例），经
    // dispatchEvent 转发给 Cangjie 侧 subscribe(this.appearanceShownEvent, ...) 注册的
    // handler 重新读取真实持久化值并赋回该 @State 字段。
    .onShown((_reason: VisibilityChangeReason) => {
      dispatchEvent(APPEARANCE_SETTINGS_SHOWN_EVENT, '{}');
    });
  }
}
