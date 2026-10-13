import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "StorageUsagePage": 薄 ArkTS NavDestination 壳，内嵌仓颉页
// (diag-suite_settings_data_storage-TC-0438-round2.md 修法方向 §1/§0 grant). Shape copied
// verbatim from AutodownloadConnectionTypePage.ets (same three-piece NavDestination/Stack/
// CJHybridComponent + CustomTransition register/unregister pattern), only `component:` and
// the struct/builder names changed.
//
// diag-suite_settings_data_storage-TC-0430-round5.md 修法方向 S-0b：从
// StorageUsageExceptionsPage pop 回来时本 NavDestination 已挂载，不会仅因重新可见就自动
// 重新 build() —— 例外计数 @State 镜像字段停留在陈旧值。onShown 在本 NavDestination 每次
// (重新)可见时触发（含冷启动 + push/pop 返回路径，同 DataStorageSettingsPage.ets /
// PhoneInputPage.ets 既有先例），经 dispatchEvent 转发给 Cangjie 侧
// subscribe(this.storageUsageShownEvent, ...) 注册的 handler 重新读取三个例外计数。
@Builder
export function storageUsagePageBuilder() {
  StorageUsagePageShell();
}

// TC-0430-round5 S-0b：事件名字面量须与 entry/src/main/cangjie/pages/StorageUsagePage.cj 内
// subscribe(this.storageUsageShownEvent, ...) 逐字一致（同 DataStorageSettingsPage.ets/.cj
// 既有先例 —— interop.cj 不在本 feature target_files 内，故不新增共享常量）。
const STORAGE_USAGE_SHOWN_EVENT = 'settings.storageUsage.shown';

@Component
struct StorageUsagePageShell {
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
        component: 'StorageUsagePage'
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
    .onShown((_reason: VisibilityChangeReason) => {
      dispatchEvent(STORAGE_USAGE_SHOWN_EVENT, '{}');
    });
  }
}
