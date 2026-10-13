import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "SaveIncomingMediaPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// diag-suite_settings_data_storage-round3-data_storage_root-batch.md §F-C 改动 2. Shape
// copied verbatim from AutodownloadConnectionTypePage.ets per the diag's 修法方向 通则
// ("新建 .ets 壳一律逐字照抄...只改 component: 名与 builder 名").
@Builder
export function saveIncomingMediaPageBuilder() {
  SaveIncomingMediaPageShell();
}

// diag-suite_settings_data_storage-TC-0424-round6.md I-1 / TC-0423.md FIX-B: 事件名字面量
// 须与 entry/src/main/cangjie/pages/SaveIncomingMediaPage.cj 内
// subscribe(this.saveIncomingMediaShownEvent, ...) 逐字一致（同 DataStorageSettingsPage.ets/
// .cj TC-0420 M1 既有先例）。
const SAVE_INCOMING_MEDIA_SHOWN_EVENT = 'settings.saveIncomingMedia.shown';

@Component
struct SaveIncomingMediaPageShell {
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
        component: 'SaveIncomingMediaPage'
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
    // TC-0424-round6 I-1: 本 NavDestination 全程 mounted，从
    // AutosaveExceptionPeerSelectionPage routerPop() 回来时不会仅因重新可见就自动
    // 重新 build()——onShown 每次(重新)可见时触发（含冷启动 + 任意 push/pop 返回路径），
    // 转发给 Cangjie 侧 subscribe(...) 注册的 handler 重新读取 exceptions 真值。
    .onShown((_reason: VisibilityChangeReason) => {
      dispatchEvent(SAVE_INCOMING_MEDIA_SHOWN_EVENT, '{}');
    });
  }
}
