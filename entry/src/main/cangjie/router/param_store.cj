package ohos_app_cangjie_entry.router

import std.collection.HashMap

// 富参数固定字段存储（SSOT §4）。原生导航 param 仅 String 且嵌入页收不到传入值，
// 所以：调用方 push 前 setPending(route, json)，目标仓颉页渲染时 takePending(route) 取回并清。
let PENDING = HashMap<String, String>()

public func setPending(route: String, paramJson: String): Unit {
    PENDING[route] = paramJson
}

public func takePending(route: String): String {
    match (PENDING.get(route)) {
        case Some(v) =>
            PENDING.remove(route)
            return v
        case None => return "{}"
    }
}

// P2-009 M2：容器级「返回入口存在性」不变式的落地存储，对位
// submodules/Display/Source/Navigation/NavigationContainer.swift:341-353
// update(layout:canBeClosed:controllers:transition:) 的 i==0 判定 —— 该处容器遍历全栈，
// 统一给每个 controller 挂 previousItem（i==0 时才可能是 nil/.close，i>0 恒为 .item(上一屏)）。
// value=true 表示该路由是当前导航栈的栈底（即 i==0，无法通过上一屏返回）。
// 与 PENDING 不同：本值需要被 build() 每次重建 header 时反复读取，不是一次性消费，
// 所以不复用 takePending 的 remove 语义。
//
// rework_round=1 修复（RF-1）：动态填充（routerPush/routerReplace 触发的 setArrivalRoot）
// 只覆盖"经本包 routerPush/routerReplace 到达"的路由，天然遗漏 "AppRoot" ——
// 它是全仓唯一由宿主 ArkTS 直接推栈的冷启动首帧（entry/src/main/ets/pages/Home.ets:18
// `AppRouter.push('AppRoot')`，aboutToAppear 直调，完全不经 entry/src/main/ets/interop/
// InteropRegistry.ets 的 ROUTER_PUSH/ROUTER_REPLACE 回调，因此也不会调用下面的
// setArrivalRoot）。用带初始条目的 HashMap 构造函数（std.collection.cj.d:1063
// `public init(elements: Array<(K, V)>)`，SDK 签名已核实）在包加载时静态标记
// "AppRoot" → true，对位源侧 i==0 字面栈底事实（AppRoot 是应用生命周期内唯一的、
// 结构性的导航栈第 0 层，不依赖运行时判定）。
// 安全性：全仓 grep 'routerPush("AppRoot"\|routerReplace("AppRoot"' 结果为空
// （无任何 cangjie 侧代码以 "AppRoot" 为目标路由调用这两个函数），故此静态种子
// 不会被后续任何真实调用覆盖或产生竞争。若未来新增此类调用，需同步复核本注释。
let ARRIVAL = HashMap<String, Bool>([("AppRoot", true)])

public func setArrivalRoot(route: String, isRoot: Bool): Unit {
    ARRIVAL[route] = isRoot
}

public func isRootScreen(route: String): Bool {
    match (ARRIVAL.get(route)) {
        case Some(v) => return v
        case None => return false
    }
}
