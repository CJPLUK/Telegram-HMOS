// ArkTS 持有全局页面栈（唯一持栈者，D5）。模块级单例，供注册进 cangjie 的回调操作。
// 仓颉侧 router 经 interop 调用 router.push/pop/replace 来驱动这个栈。
class AppRouterClass {
  stack: NavPathStack = new NavPathStack();

  push(route: string): void {
    this.stack.pushPathByName(route, '');
  }

  pop(): void {
    this.stack.pop();
  }

  // QA #3-residual: replacePathByName() 只替换栈顶条目的路由信息，栈内仍保留一个
  // "幻影" NavPathInfo（旧 name 的历史条目），点返回/系统返回手势会弹到这个空壳条目，
  // 呈现一片空白。真正的"替换根"语义须先清空整个栈再 push，确保被替换到的页面
  // 没有任何可返回的历史条目（validated against ArkUI NavPathStack API: clear()/pushPathByName()）。
  replace(route: string): void {
    this.stack.clear(false);
    this.stack.pushPathByName(route, '', false);
  }

  // diag-suite_settings_root-TC-0083.md M-2-c：对位源侧 replaceTopController —— 弹出
  // 当前栈顶（说明前置屏）后原地 push 新页面，栈内其余历史（如设置根屏）保持不动。
  // 只用本文件已验证过的 pop() / pushPathByName()；不用 replacePathByName()，理由同上
  // 一条注释（会留下幻影 NavPathInfo）。
  replaceTop(route: string): void {
    this.stack.pop(false);
    this.stack.pushPathByName(route, '', false);
  }
}

export const AppRouter = new AppRouterClass();
