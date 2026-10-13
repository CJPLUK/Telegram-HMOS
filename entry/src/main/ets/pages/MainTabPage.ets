import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { dispatchEvent, registerArkFunc } from 'libohos_app_cangjie_entry.so';

// 系统返回键先交给仓颉侧（ChatListViewModel.cj ensureMainTabBackSubscription）：Chats 处于
// 归档视图时仓颉同步回调本函数表示已消费（返回主列表），否则照旧整应用退后台。
let mainTabBackHandled: boolean = false;
registerArkFunc('mainTab.backHandled', (_arg: string, onResult: (r: string) => void): void => {
  mainTabBackHandled = true;
  onResult('{}');
});

// route_map buildFunction for "MainTabPage": 薄 ArkTS NavDestination 壳，内嵌仓颉 Tab 宿主页。
@Builder
export function mainTabPageBuilder() {
  MainTabPageShell();
}

@Component
struct MainTabPageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  // diag-suite_settings_root-TC-0081-round7.md §6.2: 模态呈现期本页(下层壳)的缩放系数,
  // 由 Home.ets 经 CustomTransition 第 4 参写入,缺省 1.0(非模态期不缩放)。
  @State ctScale: number = 1.0;
  private ctNavId: string = '';
  // EntryAbility.dispatchSafeAreaChanged 发布的顶部安全区(vp)，offset 公式需要。
  @StorageProp('safeAreaTopVp') safeAreaTopVp: number = 0;

  // diag-suite_settings_root-TC-0081-round7.md §6.2: 逐字对位
  // NavigationController.swift:1220 maxOffset = topInset - (H - H*maxScale)/2(H 取视口 vp)。
  private getCtOffsetY(): number {
    if (this.ctScale >= 0.999) {
      return 0;
    }
    const winHeightVp = px2vp(display.getDefaultDisplaySync().height);
    return this.safeAreaTopVp - (winHeightVp - winHeightVp * this.ctScale) / 2;
  }
  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'MainTabPage'
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
    // diag-suite_settings_root-TC-0081-round7.md §6.2: 模态呈现期下层壳整体缩小 + 圆角裁剪,
    // 对位源 NavigationController.swift:1219-1230 对 root container 的 scale/offset + 四角圆角。
    .borderRadius(10)
    .clip(true)
    .scale({ x: this.ctScale, y: this.ctScale, centerX: '50%', centerY: '50%' })
    .translate({
      x: `${this.ctTransX}%`,
      // ctScale < 1 时(模态呈现期)用 vp 定值的 offset 承接缩放上移;
      // 两者互斥(模态呈现期 ctTransY 恒为 0,本页自身 push/pop 期 ctScale 恒为 1)。
      y: this.ctScale < 0.999 ? `${this.getCtOffsetY()}vp` : `${this.ctTransY}%`
    })
    .onReady((ctx: NavDestinationContext) => {
      this.ctNavId = ctx.navDestinationId ?? '';
      CustomTransition.register(this.ctNavId, (x: number, y: number, d: number, s: number) => {
        this.ctTransX = x;
        this.ctTransY = y;
        this.ctDim = d;
        this.ctScale = s;
      });
    })
    .onDisAppear(() => {
      CustomTransition.unregister(this.ctNavId);
    })
    // 栈顶可见性转发给仓颉 UndoToast（components/UndoToast.cj）：在栈顶时撤销条画在本页
    // 根 Stack 里、只占浮条的响应区；被其它路由页盖住时才走 bindContentCover 模态层。
    .onShown(() => {
      dispatchEvent('mainTabPage.shown', '{}');
    })
    .onHidden(() => {
      dispatchEvent('mainTabPage.hidden', '{}');
    })
    // 根 tab 页按返回不出栈（否则露出空白 Navigation 根 = 白屏），改为整应用退后台，
    // 对齐移动端惯例（Android back-on-home 行为）。
    .onBackPressed(() => {
      mainTabBackHandled = false;
      dispatchEvent('mainTabPage.backPressed', '{}');
      if (mainTabBackHandled) {
        return true;
      }
      try {
        const ctx = getContext(this) as common.UIAbilityContext;
        ctx.moveAbilityToBackground();
      } catch (e) {
        // 移后台失败也要消费事件，绝不允许 pop 出空白根
      }
      return true;
    });
  }
}
