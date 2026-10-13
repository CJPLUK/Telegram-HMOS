package ohos_app_cangjie_entry.router

import ohos_app_cangjie_entry.interop.*

// 仓颉侧 router（SSOT §4）：经 interop 驱动 ArkTS 持有的 NavPathStack；只管独立页面(D5)。
// 覆盖层/sheet/menu 不走这里，留仓颉内部渲染。

// 导航命令直接投递到主 JSContext：ArkUI 事件回调（点按会话行等）没有 JSValueScope，通用
// callArk 会先在内联路径抛 BusinessException 34300003 再回退 postJSTask（见 interop.cj
// callArkOnJSTask 的注释，实测一次点击因此慢数百毫秒）。router 命令不需要返回值，直接投递
// 即可；push/pop/replace 同走一条任务队列，相对顺序不变。
private func routerCall(name: String, route: String): Unit {
    callArkOnJSTask(name, route, { _ => () })
}

public func routerPush(route: String, paramJson: String): Unit {
    setPending(route, paramJson)
    setArrivalRoot(route, false)
    routerCall(ROUTER_PUSH, route)
}

public func routerPush(route: String): Unit {
    routerPush(route, "{}")
}

public func routerPop(): Unit {
    routerCall(ROUTER_POP, "")
}

public func routerReplace(route: String, paramJson: String): Unit {
    setPending(route, paramJson)
    setArrivalRoot(route, true)
    routerCall(ROUTER_REPLACE, route)
}

// diag-suite_settings_root-TC-0083.md M-2-c：对位源侧 replaceTopController —— 弹出栈顶
// 一层、原地 push 新页面，栈内更下层历史（如设置根屏）保持不动。
// setArrivalRoot(route, false) 是关键边界：到达点不是栈底（其下仍有历史条目），
// 若照抄 routerReplace 传 true，navPreviousItem() 会把它误判成 NavPreviousItem.None，
// 抹掉新页面的返回入口。routerReplaceTop 不进入本文件「已核对的 root 集合」
// （它到达的路由恒非栈底）。
public func routerReplaceTop(route: String, paramJson: String): Unit {
    setPending(route, paramJson)
    setArrivalRoot(route, false)
    routerCall(ROUTER_REPLACE_TOP, route)
}

// ==================== P2-009 M2：导航栏返回入口存在性不变式 ====================
// 对位 submodules/Display/Source/Navigation/NavigationContainer.swift:341-353
// update(layout:canBeClosed:controllers:transition:)：容器每次栈变更后遍历全栈统一赋值——
// i==0 时 canBeClosed ? .close : nil；i>0 时恒为 .item(controllers[i-1].navigationItem)。
// 「非栈底就必有返回入口」是容器级不变式，不再由页面各自决定。
//
// 目标侧 Navigation(AppRouter.stack) 是唯一容器（entry/src/main/ets/pages/Home.ets:22），
// 但没有源侧那种显式 controllers 栈快照可供遍历。改用等价推导（边界条件见交付报告）：
//   AppRouter.replace 先 clear(false) 再 push（entry/src/main/ets/router/AppRouter.ets:19-21）
//   ⇒ 经 replace 到达的路由是新栈的第 0 层（栈底，i==0）；
//   经 push 到达的路由只在既有栈顶新增一层 ⇒ 天然是非栈底（i>0）；
//   该属性在页面实例生命周期内恒定（push/pop 只增删更上层，只有 replace 才重置整栈）。
// 因此「isRootScreen(route)」（见 param_store.cj）等价于源侧的 i==0 判定——
// 但仅限于"经本包 routerPush/routerReplace 到达"的路由（这两个函数是全仓唯一调用
// setArrivalRoot 的入口）。
//
// rework_round=1 修复（RF-1，2026-08-08）：上一轮自检对以下两点结论有误，已订正——
// 1. "AppRoot" 不经 routerPush/routerReplace 到达（宿主 ArkTS 侧
//    entry/src/main/ets/pages/Home.ets:18 `AppRouter.push('AppRoot')` 直调，
//    绕过 entry/src/main/ets/interop/InteropRegistry.ets 的 ROUTER_PUSH/ROUTER_REPLACE
//    回调），isRootScreen("AppRoot") 无法由这两个函数动态推导。现改为在
//    param_store.cj 里对 "AppRoot" 做包加载时静态标记（见该文件 ARRIVAL 声明处的
//    注释与安全性论证），不依赖本文件的 routerPush/routerReplace。
// 2. 上一轮自检用 `grep -o 'routerReplace("[^"]*"' -r entry/src/main/cangjie`
//    未排除注释，把 pages/AppRoot.cj:28 文档注释里描述的一个尚未实现的
//    AwaitingAccountReset 分支（`routerReplace("AccountResetPage", ...)`）误判为
//    真实代码命中。核实结论：AccountResetPage 目前只经 routerPush 到达
//    （auth/CodeInputPage.cj:493、auth/PasswordInputPage.cj:358），isRootScreen
//    对它现在恒为 false（Item），不在当前真实可达的 root 集合内——这是本机制的
//    正确行为，不是缺陷；若未来 AwaitingAccountReset 分支被实现并用 routerReplace
//    到达 AccountResetPage，isRootScreen 会在那次调用后动态正确判 true，无需再改
//    本文件。
//
// 校正后的自检命令（先过滤行首 `//` 单行注释，仍可能残留 /** */ 块注释里的
// 命中——单纯 grep 无法区分块注释与代码，这是已知局限；块注释范围必须人工核对，
// 例如 pages/AppRoot.cj:15-39 就是一段含 `routerReplace(...)` 字样的 /** */ 文档
// 注释，会被下面这条命令误纳入，需人工排除）：
//   grep -rn 'routerReplace(' entry/src/main/cangjie --include='*.cj' | grep -v '^\S*:[0-9]*:\s*//'
//   （不算 AppRoot——它由 param_store.cj 静态标记，不出现在 routerReplace 调用里）
// 本轮已就每个命中文件手工核对块注释边界，结果见下方“已核对的 root 集合”。
// 已核对的 root 集合（截至本轮，均为可执行代码命中，非注释假阳性）：
//   - "MainTabPage"     经 routerReplace 到达（多处，如 pages/AppRoot.cj:81）
//   - "PhoneInputPage"  经 routerReplace 到达（pages/AppRoot.cj:86）
//   - "SplashPage"      经 routerReplace 到达（多处，如 pages/AppRoot.cj:91）
//   - "AppRoot"         经 param_store.cj 静态种子标记（不经 routerReplace）
// "AccountResetPage" 不在此集合内（理由见上）。M3 逐页接线时，若某页 route 不在
// 这四个之内，应传 NavPreviousItem.Item（非 None），除非该页新增了到达它的
// routerReplace 调用（那种情况下 isRootScreen 会自动正确反映，无需改本文件）。
public enum NavPreviousItem {
    | Item
    | Close
    | None
}

// P2-009 M2 边界条件：镜像 entry/src/main/ets/router/CustomTransition.ets 的
// MODAL_ROUTES（当前成员 'QrLoginPage' / 'ArchiveInfoPage'，对位 iOS navigationPresentation=.modal/.flatModal）。
// 新增模态路由需同时更新两侧；核对命令：grep -n "MODAL_ROUTES" entry/src/main/ets/router/CustomTransition.ets
func isModalRoute(route: String): Bool {
    match (route) {
        case "QrLoginPage" => true
        case "ArchiveInfoPage" => true
        case "LogoutOptionsPage" => true
        case "UsernameSettingsPage" => true
        // diag-suite_settings_data_storage-TC-0432-round2.md §N1：对位源
        // ProxyListSettingsController.swift:470 / ProxyServerSettingsController.swift:363
        // navigationPresentation = .modal。同步更新 ets/router/CustomTransition.ets 的
        // MODAL_ROUTES（跨 allowlist，已按 emitted_integration_contracts[] 上报，owner
        // shell_settings_misc）。
        case "ProxySettingsPage" => true
        // diag-suite_settings_root-TC-0074-qrsharescreen.md §7-B：对位源
        // ChatQrCodeScreen.swift:626 navigationPresentation = .flatModal。
        // 同步更新 ets/router/CustomTransition.ets 的 MODAL_ROUTES（跨 allowlist，
        // 已按 emitted_integration_contracts[] 上报，owner shell_settings_misc）。
        case "ChatQrCodeSharePage" => true
        // review round5 D-166_modal_route_two_spot_registration：对位源
        // DeleteAccountOptionsController.swift:432（与孪生 LogoutOptionsController.swift:290
        // 同为 .modal）。同步更新 ets/router/CustomTransition.ets 的 MODAL_ROUTES（跨
        // allowlist，已按 emitted_integration_contracts[] 上报，owner shell_settings_misc）。
        case "DeleteAccountOptionsScreen" => true
        case "ThemeAccentColorPickerPage" => true
        case "AutosaveExceptionPeerSelectionPage" => true
        // Source SaveIncomingMediaController assigns `.modal` to both `.peer`
        // and `.addPeer` scopes.  The ArkTS shell already uses DIALOG mode, so this
        // route must participate in the same modal transition/close-button contract.
        case "AutosaveExceptionConfigPage" => true
        case _ => false
    }
}

// 三态判定，对位 NavigationContainer.swift:341-353 的 previousItem 赋值：
// isRootScreen(route) ⇒ None（栈底，无返回入口）；
// route 属模态路由 ⇒ Close（对位 canBeClosed ⇒ .close）；
// 其余（非栈底、非模态）⇒ Item（对位 .item(controllers[i-1].navigationItem)）。
public func navPreviousItem(route: String): NavPreviousItem {
    if (isRootScreen(route)) {
        return NavPreviousItem.None
    }
    if (isModalRoute(route)) {
        return NavPreviousItem.Close
    }
    return NavPreviousItem.Item
}
