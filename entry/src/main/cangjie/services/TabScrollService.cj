package ohos_app_cangjie_entry.services

/**
 * TabScrollService — active-tab 重按回顶信号通道
 *
 * iOS parity（TC-TAB-002 / TC-SETTINGS-005）：点击当前已选中的根 tab 时，
 * 对应根控制器滚动回顶（TabBarController.scrollToTopWithTabBar 语义）。
 *
 * 机制：各根页面在挂载时注册自己的回顶回调（按 tab index），
 * MainTabPage.selectPrimaryTab 检测到重按当前 tab 时 fire。
 * 回调在 UI 线程（onClick）内同步触发，无跨线程问题。
 */
import std.collection.HashMap

private var _retapHandlers = HashMap<Int32, () -> Unit>()

/** 根页面注册：tab index → 回顶动作（重复注册覆盖，页面重建安全） */
public func registerTabRetapHandler(index: Int32, handler: () -> Unit): Unit {
    _retapHandlers[index] = handler
}

/** MainTabPage 触发：重按当前 tab */
public func fireTabRetap(index: Int32): Unit {
    if (_retapHandlers.contains(index)) {
        _retapHandlers[index]()
    }
}
