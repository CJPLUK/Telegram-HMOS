import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "DataStorageSettingsPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function dataStorageSettingsPageBuilder() {
  DataStorageSettingsPageShell();
}

// TC-0420 M1 返修（diag round2）：事件名字面量须与
// entry/src/main/cangjie/pages/DataStorageSettingsPage.cj 内
// subscribe(this.dataStorageShownEvent, ...) 逐字一致（同 PhoneInputPage.ets/.cj、
// AppearanceSettingsPage.ets/.cj 既有先例——interop.cj 不在本 feature target_files 内，
// 故不新增共享常量，两侧各自持有同一字面量，交叉引用见双方注释）。
const DATA_STORAGE_SHOWN_EVENT = 'settings.dataStorage.shown';

@Component
struct DataStorageSettingsPageShell {
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
        component: 'DataStorageSettingsPage'
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
    // TC-0420 M1: 根屏摘要行/Reset 启用门读的是 DataStorageSettingsPage.cj 的裸 @State
    // 镜像字段，只在字段被显式重新赋值时才随本 NavDestination 重新 build()。子屏
    // （Using Cellular 的 AutodownloadConnectionTypePage 等）改完设置 routerPop() 回到本页时，
    // 本 NavDestination 已挂载，不会仅因重新可见就自动重新 build()，导致摘要串与 Reset
    // 行颜色停留在陈旧值（diag-suite_settings_data_storage-TC-0420-round2.md B0 证据）。
    // onShown 在本 NavDestination 每次(重新)可见时触发（含冷启动 + 任意 push/pop 返回路径，
    // 同 PhoneInputPage.ets / AppearanceSettingsPage.ets 的既有先例），经 dispatchEvent
    // 转发给 Cangjie 侧 subscribe(this.dataStorageShownEvent, ...) 注册的 handler 重新
    // 读取真实持久化值并赋回相关 @State 字段。
    .onShown((_reason: VisibilityChangeReason) => {
      dispatchEvent(DATA_STORAGE_SHOWN_EVENT, '{}');
    });
  }
}
