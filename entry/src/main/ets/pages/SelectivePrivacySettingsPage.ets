import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "SelectivePrivacySettingsPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function selectivePrivacySettingsPageBuilder() {
  SelectivePrivacySettingsPageShell();
}

// diag-suite_settings_privacy-TC-0132.md RC-7 返修：事件名字面量须与
// entry/src/main/cangjie/pages/SelectivePrivacySettingsPage.cj 内
// subscribe(this.shownEvent, ...) 逐字一致（同 AppearanceSettingsPage.ets/.cj 既有先例——
// entry/src/main/cangjie/interop/interop.cj 不在本 feature target_files 内，故不新增共享
// 常量，两侧各自持有同一字面量，交叉引用见双方注释）。
const SELECTIVE_PRIVACY_SETTINGS_SHOWN_EVENT = 'settings.selectivePrivacySettingsPage.shown';

@Component
struct SelectivePrivacySettingsPageShell {
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
        component: 'SelectivePrivacySettingsPage'
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
    // TC-0132 RC-7: 从例外名单屏 pop 回本屏时，本 NavDestination 已挂载，不会仅因重新可见就
    // 自动重新 build()；onShown 在每次(重新)可见时触发（含冷启动 + 任意 push/pop 返回路径，
    // 同 AppearanceSettingsPage.ets 既有先例），经 dispatchEvent 转发给 Cangjie 侧
    // subscribe(this.shownEvent, ...) 注册的 handler 重新拉服务端真值。
    .onShown((_reason: VisibilityChangeReason) => {
      dispatchEvent(SELECTIVE_PRIVACY_SETTINGS_SHOWN_EVENT, '{}');
    });
  }
}
