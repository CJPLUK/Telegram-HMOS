import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "ChatQrCodeSharePage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// 结构与 QrScannerPage.ets 逐字同构（diag-suite_settings_root-TC-0074-qrsharescreen.md §7
// 跨 allowlist 依赖表：本文件是本页可达性的硬依赖，缺失则 route_map.json 的路由条目指向
// 不存在的 builder）。'ChatQrCodeSharePage' 这个字面量与 router/router.cj 的
// isModalRoute case、route_map.json 的 "name" 三处必须逐字一致。
@Builder
export function chatQrCodeSharePageBuilder() {
  ChatQrCodeSharePageShell();
}

@Component
struct ChatQrCodeSharePageShell {
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
        component: 'ChatQrCodeSharePage'
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
    });
  }
}
