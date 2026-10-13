import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "IncomingMessagePrivacyPage": 薄 ArkTS NavDestination 壳，
// 内嵌仓颉页。路由名字面量 IncomingMessagePrivacyPage 与 route_map.json / PrivacySettingsPage.cj
// 根屏 G-7 接线的 routerPush 目标逐字一致，不得改名。
@Builder
export function incomingMessagePrivacyPageBuilder() {
  IncomingMessagePrivacyPageShell();
}

// 事件名字面量须与 entry/src/main/cangjie/pages/IncomingMessagePrivacyPage.cj 内
// subscribe(this.shownEvent, ...) 逐字一致（同 SelectivePrivacySettingsPage.ets/.cj 既有先例）。
const INCOMING_MESSAGE_PRIVACY_SHOWN_EVENT = 'settings.incomingMessagePrivacyPage.shown';

@Component
struct IncomingMessagePrivacyPageShell {
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
        component: 'IncomingMessagePrivacyPage'
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
    // onShown 在本 NavDestination 每次(重新)可见时触发（含冷启动 + 任意 push/pop 返回路径，
    // 同 SelectivePrivacySettingsPage.ets 既有先例），经 dispatchEvent 转发给 Cangjie 侧
    // subscribe(this.shownEvent, ...) 注册的 handler 重新拉服务端真值（Premium 状态可能在
    // 离开本页期间变化）。
    .onShown((_reason: VisibilityChangeReason) => {
      dispatchEvent(INCOMING_MESSAGE_PRIVACY_SHOWN_EVENT, '{}');
    });
  }
}
