package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getDialogService
import ohos_app_cangjie_entry.services.DIALOG_DESTRUCTIVE_COLOR

/**
 * DialogHost — 标准确认弹窗的根部宿主组件（host for native AlertDialog）
 *
 * 对应 iOS Telegram-iOS submodules/AlertUI：标题 + 消息 + 确认/取消两按钮，
 * 按钮可标 destructive（红）/default（高亮）。
 *
 * 为什么需要宿主组件：鸿蒙 getUIContext()（弹原生 AlertDialog 的入口）只能在
 * @Component 的 UI 上下文里解析，不能在 services 包的顶层函数里调。故 services/
 * DialogService.cj 的 showAlert/showConfirm 只把「弹窗请求」推进 DialogService（单例），
 * 真正弹窗动作由本组件执行 getUIContext().showAlertDialog(AlertDialogParamWithButtons(...))。
 *
 * TC-0012 修复：原实现用 Timer.repeat(100ms) tick 轮询 DialogService 的 epoch 变化后
 * 异步弹窗，实测鸿蒙 ArkUI 原生 showAlertDialog 在脱离用户手势同步调用栈的时序下
 * 会被静默丢弃（不报错也不渲染）。现改为 aboutToAppear 时向 DialogService 注册
 * 一个同步 presenter 闭包；DialogService.request() 命中后立即同步调用它 ——
 * request() 本身是从调用方 `.onClick()` 处理器同步调用的（见 showAlert/showConfirm），
 * 因此 presentAlert 现在与工程内其余所有成功的 showAlertDialog 调用点一样，
 * 处在同一条用户手势同步调用栈内。
 *
 * 用法：在 root 容器挂一次即可（全局共用）：
 *     DialogHost()
 * 本组件自身不渲染任何可见 UI（弹窗由系统 AlertDialog 呈现），只挂一个 0 尺寸占位。
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 */
@Component
public class DialogHost {
    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        // 注册同步 presenter：DialogService.request() 命中后直接同步调用本函数。
        getDialogService().setPresenter(
            { title: String, message: String, confirmText: String, cancelText: String,
              destructive: Bool, onConfirm: () -> Unit, onCancel: () -> Unit =>
                this.presentAlert(title, message, confirmText, cancelText, destructive, onConfirm, onCancel)
            }
        )
        Hilog.info(0, "CjTelegram", "[DialogHost] aboutToAppear: presenter registered")
    }

    public override func aboutToDisappear(): Unit {
        getDialogService().clearPresenter()
    }

    // ==================== 弹原生 AlertDialog（必须在 UI 上下文，同步调用栈）====================

    private func presentAlert(
        title: String,
        message: String,
        confirmText: String,
        cancelText: String,
        destructive: Bool,
        onConfirm: () -> Unit,
        onCancel: () -> Unit
    ): Unit {
        let confirmColor: ?ResourceColor = if (destructive) {
            DIALOG_DESTRUCTIVE_COLOR
        } else {
            None
        }
        let confirmStyle: ?DialogButtonStyle = if (destructive) {
            None
        } else {
            DialogButtonStyle.Highlight
        }
        getUIContext().showAlertDialog(
            AlertDialogParamWithButtons(
                title: title,
                message: message,
                autoCancel: true,
                // primaryButton = 取消（左），secondaryButton = 确认（右，默认焦点）。
                primaryButton: AlertDialogButtonOptions(
                    value: cancelText,
                    action: { => onCancel() }
                ),
                secondaryButton: AlertDialogButtonOptions(
                    defaultFocus: true,
                    style: confirmStyle,
                    value: confirmText,
                    fontColor: confirmColor,
                    action: { => onConfirm() }
                )
            )
        )
        Hilog.info(0, "CjTelegram",
            "[DialogHost] presentAlert title=" + title + " destructive=" + destructive.toString())
    }

    // ==================== UI（无可见内容，仅 0 尺寸占位）====================

    func build() {
        Stack {}
            .width(0)
            .height(0)
    }
}
