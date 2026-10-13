import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

// iOS peer selection is presented as a rounded modal sheet above the source page.
@Builder
export function autosaveExceptionPeerSelectionPageBuilder() {
  AutosaveExceptionPeerSelectionPageShell();
}

@Component
struct AutosaveExceptionPeerSelectionPageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  @StorageProp('safeAreaTopVp') safeAreaTopVp: number = 0;
  private ctNavId: string = '';
  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'AutosaveExceptionPeerSelectionPage'
      })
        .width('100%')
        .height('100%')
        .borderRadius({ topLeft: 10, topRight: 10 })
        .clip(true);
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
      .padding({ top: this.safeAreaTopVp + 10 })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]);
    }
    .hideTitleBar(true)
    .mode(NavDestinationMode.DIALOG)
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
