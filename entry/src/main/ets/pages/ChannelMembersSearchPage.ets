import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// route_map buildFunction for "ChannelMembersSearchPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// 注意：路由名 "ChannelMembersSearchPage"（PeerInfoPage 按此名 push），
// 而可导航的仓颉类是 ChannelMembersSearchPageNode（源 pages/ChannelMembersSearchPageNode.cj）。
@Builder
export function channelMembersSearchPageBuilder() {
  ChannelMembersSearchPageShell();
}

@Component
struct ChannelMembersSearchPageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';
  @StorageProp('safeAreaTopVp') safeAreaTopVp: number = 0;
  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'ChannelMembersSearchPageNode'
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
    .hideTitleBar(false)
    .padding({ top: this.safeAreaTopVp })
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
