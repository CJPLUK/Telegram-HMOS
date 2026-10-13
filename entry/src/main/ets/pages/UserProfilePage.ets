import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { window } from '@kit.ArkUI';
import { dispatchEvent, registerArkFunc } from 'libohos_app_cangjie_entry.so';

// 系统返回键先交给仓颉资料页（UserProfilePage.cj registerUserProfileBackHandler）：头像展开态 / 分享面板 /
// 复制菜单打开时仓颉自行收起并同步回调本函数表示已消费，本页留在栈里；否则照旧出栈。
let userProfileBackHandled: boolean = false;
registerArkFunc('userProfile.backHandled', (_arg: string, onResult: (r: string) => void): void => {
  userProfileBackHandled = true;
  onResult('{}');
});

// route_map buildFunction for "UserProfilePage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function userProfilePageBuilder() {
  UserProfilePageShell();
}

@Component
struct UserProfilePageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';
  private updateSystemBars(profileMode: boolean): void {
    window.getLastWindow(getContext()).then((mainWindow: window.Window): void => {
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: profileMode ? '#00000000' : '#00000000',
        statusBarContentColor: profileMode ? '#FFFFFFFF' : '#FF000000'
      });
    });
  }

  aboutToAppear(): void {
    this.updateSystemBars(true);
  }

  aboutToDisappear(): void {
    this.updateSystemBars(false);
  }

  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'UserProfilePage'
      })
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP]);
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
    .onBackPressed((): boolean => {
      userProfileBackHandled = false;
      dispatchEvent('userProfilePage.backPressed', '{}');
      return userProfileBackHandled;
    });
  }
}
