import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "NotificationSettingsPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
//
// S7-64 (WP-E)：从 NotificationsPeerCategoryPage（某分类的 Alert 开关）pop 回来时本 NavDestination
// 已挂载，不会仅因重新可见就重新 build() —— 根屏 Private/Group/Channels 行的 On/Off 停留在进入前
// 的值。onShown 在每次(重新)可见时触发（同 StorageUsagePage.ets 先例），经 dispatchEvent 转发给
// 仓颉侧 subscribe(this.notificationsShownEvent, ...) 重新拉取全局通知设置。
@Builder
export function notificationSettingsPageBuilder() {
  NotificationSettingsPageShell();
}

// 事件名须与 entry/src/main/cangjie/pages/NotificationSettingsPage.cj 内 notificationsShownEvent 逐字一致。
const NOTIFICATION_SETTINGS_SHOWN_EVENT = 'settings.notifications.shown';

@Component
struct NotificationSettingsPageShell {
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
        component: 'NotificationSettingsPage'
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
      dispatchEvent(NOTIFICATION_SETTINGS_SHOWN_EVENT, '{}');
    });
  }
}
