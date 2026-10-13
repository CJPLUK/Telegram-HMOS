import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { dispatchEvent } from 'libohos_app_cangjie_entry.so';
import { CustomTransition } from '../router/CustomTransition';
import { KeyboardAvoidMode } from '@kit.ArkUI';

// route_map buildFunction for "PhoneInputPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function phoneInputPageBuilder() {
  PhoneInputPageShell();
}

// M4 返修 round2（diag: auth_phone_entry_screen review round2 kb_cross_check/behavioral_repro/
// call_chain_walk 三项 FAIL 的替代实现）：事件名字面量须与
// entry/src/main/cangjie/auth/PhoneInputPage.cj 内 subscribe(this.phoneInputShownEvent, ...)
// 逐字一致——本轮 scope 只允许改本文件与该 .cj 文件，interop.cj 不在 target_files 内，
// 故不新增共享常量，两侧各自持有同一字面量，交叉引用见双方注释。
const PHONE_INPUT_SHOWN_EVENT = 'auth.phoneInputPage.shown';

@Component
struct PhoneInputPageShell {
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';

  aboutToAppear(): void {
    // iOS 以 inputHeight 缩短 layoutAuthorizationItems 的可用高度。
    // RESIZE 给仓颉页传入同样的可用区域变化，而不是默认 OFFSET
    // 把整页保留原高度后整体平移。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  aboutToDisappear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
  }

  build() {
    NavDestination() {
      Stack() {
        CJHybridComponent({
          library: 'ohos_app_cangjie_entry',
          component: 'PhoneInputPage'
        })
          .width('100%')
          .height('100%');
        if (this.ctDim > 0.001) {
          Column().width('100%').height('100%').backgroundColor(Color.Black).opacity(this.ctDim);
        }
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    // QA #3-residual: PhoneInputPage 只经 replace() 到达（Splash→PhoneInputPage 是认证根，
    // 不是 push 进来的），iOS 首次登录手机号输入页没有"返回到 Splash"的返回按钮
    // （对照 AuthorizationSequencePhoneEntryController 作为 sequence 起始 controller 无返回项）。
    // 隐藏原生标题栏/返回按钮，与 CountrySelectionPage/AppRoot 同为 replace-only 根页的写法一致；
    // 从 PhoneInputPage routerPush 出去的 CodeInputPage 是独立 NavDestination，不受此设置影响，
    // 仍保留系统默认返回（push 进去的页面 hideTitleBar 各自独立配置）。
    .hideTitleBar(true)
    // QA #3-residual（真机 hilog 实测追加根因）：即使隐藏了标题栏/返回按钮，ArkUI
    // 系统返回键/手势仍会被 NavDestination 默认消费并执行 pop —— hilog 证据：
    // "OnBackPressed called" → "navDestination consume back button event: PhoneInputPage"
    // → "sync with js stack ... newStackSize: 0" → 栈清空后 Navigation 渲染一片空白。
    // AppRouter.replace() 里的 clear()+pushPathByName() 已经解决了"栈里残留幻影条目"
    // 这一半问题，但 PhoneInputPage 作为 replace-only 认证根，系统返回键本身就不应该
    // 有事可做（iOS 对应 controller 是 sequence 起点，物理返回键在此本就无动作）。
    // onBackPressed 返回 true = "本页已处理，不要继续默认 pop"，从根上吞掉这次返回，
    // 不依赖"栈里还有没有可弹条目"这个易碎的前提。
    .onBackPressed((): boolean => {
      return true;
    })
    // M4 返修 round2：上一轮用 Cangjie 侧 `onPageShow()`（@HybridComponentEntry 覆写点）
    // 作为「冷启动 + 从 CountrySelectionPage 返回」的唯一恢复焦点机制，被 Reviewer 反证——
    // SDK 声明 ~/.cangjie-sdk/6.1/cangjie/api/modules/linux_ohos_aarch64_cjnative/ohos/
    // ohos.arkui.component.custom_view.cj.d:48-57 字面限定该回调「仅对 @Entry 装饰的组件
    // 生效」，而本页宿主 PhoneInputPageShell（本文件）是普通 @Component，未声明 @Entry，
    // 与该限定不匹配；全仓颉源码此前也无 onPageShow/onPageHide 既有先例佐证。
    //
    // 本处改用官方 ArkTS 原生 API `NavDestinationAttribute.onShown`（@since 10，声明见
    // DevEco SDK .../ets/component/nav_destination.d.ts:832-860：「Called when the
    // navigation destination page is displayed.」）——这是本 .ets 文件直接使用的原生
    // ArkTS Navigation 组件方法，不经过 Cangjie SDK 对 NavDestinationAttribute 的窄化
    // 绑定（Reviewer 反证的 ohos.arkui.component.navigation.cj.d 只暴露 onBackPressed/
    // onReady/title/hideTitleBar 四个方法，是两套不同的 API 表面），对任意 NavDestination
    // 生效、不要求 @Entry。该回调在本 NavDestination 每次（重新）成为栈内可见节点时触发，
    // 覆盖本轮要求的全部三条返回路径 + 冷启动：
    //  1) 冷启动首次 push 显示；
    //  2) 选中国家返回——CountrySelectionPage.selectCountry() 写回 authVM 后调用
    //     routerPop()（entry/src/main/cangjie/pages/CountrySelectionPage.cj:102-112）；
    //  3) 取消/关闭按钮返回——同文件关闭图标 onClick 调用 routerPop()
    //     （entry/src/main/cangjie/pages/CountrySelectionPage.cj:293-294）；
    //  4) 系统返回键/手势——CountrySelectionPage 的 ArkTS 壳（CountrySelectionPage.ets）
    //     未覆写 onBackPressed，走 ArkUI 默认行为：系统返回键/手势被 NavDestination
    //     默认消费并对当前栈顶 NavDestination 执行 pop（与本文件上方 :27-35 记录的
    //     PhoneInputPage 自身默认行为同一份真机 hilog 证据佐证的框架机制一致）。
    // 三条返回路径 + 冷启动共四个触发点均由 ArkTS 原生 Navigation 栈的可见性事件驱动，
    // 不依赖 Cangjie 侧任何自动回调，经 dispatchEvent 转发给 Cangjie 侧
    // subscribe(this.phoneInputShownEvent, ...) 注册的 handler 调用 activateInput()
    // （PhoneInputPage.cj，幂等，重复调用无副作用）。
    .onShown((_reason: VisibilityChangeReason) => {
      dispatchEvent(PHONE_INPUT_SHOWN_EVENT, '{}');
    })
    // Add Account 是 push 进认证流，需与其他 NavDestination 一样接入
    // 全局 push/pop 转场。此页原先未注册 setter，转场期无任何几何更新，
    // 表现为点击后停顿再跳变。首次登录使用 replace，Home 会跳过转场，不受影响。
    .translate({ x: `${this.ctTransX}%`, y: `${this.ctTransY}%` })
    .onReady((ctx: NavDestinationContext) => {
      this.ctNavId = ctx.navDestinationId ?? '';
      CustomTransition.register(this.ctNavId, (x: number, y: number, d: number) => {
        this.ctTransX = x;
        this.ctTransY = y;
        this.ctDim = d;
      });
    })
    .onDisAppear(() => CustomTransition.unregister(this.ctNavId));
  }
}
