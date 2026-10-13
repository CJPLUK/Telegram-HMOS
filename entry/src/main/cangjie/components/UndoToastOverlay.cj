package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * UndoToastOverlay — UndoToast 的根叠加层入口（ArkTS Home.ets 的 UndoToastOverlayHost
 * 经 CJHybridComponent(component: 'UndoToastOverlay') 挂载，位于整个 Navigation 栈之上）。
 *
 * 只做一件事：常驻挂一个非受控 UndoToast()，让它在 aboutToAppear 向 UndoToastService
 * 注册 presenter。浮条矩形由 UndoToast 经 UNDO_TOAST_REGION 推给 ArkTS 宿主设置
 * responseRegion，浮条以外的触摸落到下层页面（iOS UndoOverlayController 非模态）。
 */
@HybridComponentEntry
@Component
public class UndoToastOverlay {
    public func build() {
        Stack {
            UndoToast()
        }
        .width(100.percent)
        .height(100.percent)
    }
}
