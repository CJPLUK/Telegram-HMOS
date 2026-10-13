import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';

@Builder
export function chatFolderEditorPageBuilder() {
  ChatFolderEditorPageShell();
}

@Component
struct ChatFolderEditorPageShell {
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';
  build() {
    NavDestination() {
      Stack() {
        CJHybridComponent({ library: 'ohos_app_cangjie_entry', component: 'ChatFolderEditorPage' })
          .width('100%').height('100%');
        if (this.ctDim > 0.001) {
          Column().width('100%').height('100%').backgroundColor(Color.Black).opacity(this.ctDim);
        }
      }.width('100%').height('100%').expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .hideTitleBar(true)
    .translate({ x: `${this.ctTransX}%`, y: `${this.ctTransY}%` })
    .onReady((ctx: NavDestinationContext) => {
      this.ctNavId = ctx.navDestinationId ?? '';
      CustomTransition.register(this.ctNavId, (x: number, y: number, d: number) => {
        this.ctTransX = x; this.ctTransY = y; this.ctDim = d;
      });
    })
    .onDisAppear(() => CustomTransition.unregister(this.ctNavId));
  }
}
