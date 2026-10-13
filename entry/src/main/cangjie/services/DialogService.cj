package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * DialogService — 统一弹窗工具（unified dialog helpers）
 *
 * 对应 iOS Telegram-iOS submodules/AlertUI（标准/自定义确认弹窗：标题+消息+多按钮，
 * 按钮可标 destructive/default）与 submodules/PromptUI（带单行输入框的弹窗）。
 * 收口工程里各页手搓 Column/Stack 浮层与零散弹窗写法，统一为三个调用入口
 * showAlert / showConfirm / showPrompt。
 *
 * ── 关键约束（实证踩坑）──────────────────────────────────────────────
 *   鸿蒙 ArkUI 的 getUIContext()（弹原生 AlertDialog 的入口）**只能在 @Component
 *   的 UI 上下文里解析**；放到 services 包的普通顶层函数里直接调会编译报
 *   `undeclared identifier 'getUIContext'`。因此三个入口都不能在本工具函数内
 *   直接弹窗，而是把「弹窗请求」推进单例状态服务，真正弹窗动作交给根部挂载的
 *   components/DialogHost.cj。
 *
 *   TC-0012 修复：原实现让 DialogHost 用 Timer.repeat(100ms) tick 轮询本服务
 *   epoch 变化后再异步调用 getUIContext().showAlertDialog(...)。实测证实鸿蒙
 *   ArkUI 的原生 showAlertDialog 在脱离「用户手势事件处理器同步调用栈」的时序下
 *   （独立组件的定时器回调）会被静默丢弃：hilog 显示调用执行到了，但屏幕上无渲染。
 *   工程内其余所有 showAlertDialog 成功用法都是在 `.onClick()` 处理器内同步调用。
 *
 *   故本服务改为「注册 presenter + 同步直调」：DialogHost 在 aboutToAppear 时把
 *   自己的弹窗渲染函数注册进本服务（setPresenter）；request() 被调用时（本身
 *   就发生在调用方 `.onClick()` 的同步栈内）直接同步调用该 presenter，不再有
 *   epoch/tick 的异步中间层。epoch 字段保留供潜在的只读观察者使用，但不再是
 *   DialogHost 弹窗触发的驱动源：
 *     - alert 请求 → request() 同步直调 presenter → getUIContext().showAlertDialog(...)
 *     - prompt 请求 → 由 PromptDialogService + 受控叠加层 UI 渲染（不受影响，
 *       走的是 @State 驱动的普通组件渲染，非原生 showAlertDialog）
 *
 *   为什么 prompt 不用原生 AlertDialog：原生 showAlertDialog 弹窗体不能塞
 *   TextInput；CustomDialogController 又需 @CustomDialog 宏 + CustomView 绑定
 *   （必须作为某 @Component 成员实例化），无法从顶层工具函数驱动。故 prompt
 *   走受控叠加层（components/PromptDialog.cj + PromptDialogService）。
 *
 * ── 宿主前置条件 ────────────────────────────────────────────────────
 *   宿主需在 root 容器各挂一次：DialogHost() 与 PromptDialog()
 *   （与 OverlayStatusView()/UndoToast() 同样的根叠加层约定）。
 *
 * 顶层函数名加 Dialog 前缀避包级冲突；命名参数用 `!`。
 */

// destructive（破坏性操作）确认按钮的红色，与工程通用红 0xFFFF3B30 对齐。
public let DIALOG_DESTRUCTIVE_COLOR: UInt32 = 0xFFFF3B30

// ==================== 单例 alert 状态服务 ====================

private var _dialogServiceInstance: Option<DialogService> = None<DialogService>

public func getDialogService(): DialogService {
    match (_dialogServiceInstance) {
        case Some(s) => s
        case None =>
            let s = DialogService()
            _dialogServiceInstance = Some(s)
            s
    }
}

/**
 * 持有「待弹原生 AlertDialog」请求的单例。DialogHost 在 aboutToAppear 时通过
 * setPresenter 注册自己的弹窗渲染函数；request() 在调用方 `.onClick()` 的
 * 同步栈内直接同步调用该 presenter（TC-0012 修复：不再走 epoch/tick 异步轮询，
 * 原因见文件头注释）。
 */
public class DialogService {
    private var _title: String = ""
    private var _message: String = ""
    private var _confirmText: String = "OK"
    private var _cancelText: String = "Cancel"
    private var _destructive: Bool = false
    private var _onConfirm: () -> Unit = { => }
    private var _onCancel: () -> Unit = { => }

    // 单调递增「轮次」标记，保留供只读观察者/诊断使用；不再是弹窗触发的驱动源。
    private var _epoch: Int64 = 0

    // DialogHost 注册的同步 presenter：request() 命中即直接同步调用，
    // 保证 showAlertDialog 与调用方点击处理器处在同一个同步调用栈。
    private var _presenter: Option<(String, String, String, String, Bool, () -> Unit, () -> Unit) -> Unit> = None

    /**
     * DialogHost.aboutToAppear 注册自身弹窗渲染函数。
     */
    public func setPresenter(presenter: (String, String, String, String, Bool, () -> Unit, () -> Unit) -> Unit): Unit {
        this._presenter = Some(presenter)
    }

    /**
     * DialogHost.aboutToDisappear 注销，避免持有已销毁组件的闭包。
     */
    public func clearPresenter(): Unit {
        this._presenter = None
    }

    public func request(
        title: String,
        message: String,
        confirmText: String,
        cancelText: String,
        destructive: Bool,
        onConfirm: () -> Unit,
        onCancel: () -> Unit
    ): Unit {
        this._title = title
        this._message = message
        this._confirmText = confirmText
        this._cancelText = cancelText
        this._destructive = destructive
        this._onConfirm = onConfirm
        this._onCancel = onCancel
        this._epoch = this._epoch + 1
        Hilog.info(0, "CjTelegram",
            "[DialogService] request title=" + title + " destructive=" + destructive.toString())
        match (this._presenter) {
            case Some(present) =>
                present(title, message, confirmText, cancelText, destructive, onConfirm, onCancel)
            case None =>
                // DialogHost 尚未挂载/已卸载：无法弹窗，记录以便排查（不静默吞掉）。
                Hilog.info(0, "CjTelegram", "[DialogService] request dropped: no presenter registered")
        }
    }

    // ==================== 只读快照查询（诊断 / 潜在观察者用，非弹窗驱动源）====================

    public func getEpoch(): Int64 {
        return this._epoch
    }

    public func getTitle(): String {
        return this._title
    }

    public func getMessage(): String {
        return this._message
    }

    public func getConfirmText(): String {
        return this._confirmText
    }

    public func getCancelText(): String {
        return this._cancelText
    }

    public func isDestructive(): Bool {
        return this._destructive
    }

    public func getOnConfirm(): () -> Unit {
        return this._onConfirm
    }

    public func getOnCancel(): () -> Unit {
        return this._onCancel
    }
}

// ==================== 三个调用入口 ====================

/**
 * 标准确认弹窗：标题 + 消息 + 确认/取消两按钮（原生 AlertDialog，由 DialogHost 弹出）。
 *
 * @param title       弹窗标题
 * @param message     弹窗正文
 * @param confirmText 确认按钮文字
 * @param onConfirm   点确认回调
 * @param cancelText  取消按钮文字
 * @param onCancel    点取消回调
 * @param destructive 是否破坏性操作（true 时确认按钮文字红色），默认 false
 */
public func showAlert(
    title!: String,
    message!: String,
    confirmText!: String = "OK",
    onConfirm!: () -> Unit = { => },
    cancelText!: String = "Cancel",
    onCancel!: () -> Unit = { => },
    destructive!: Bool = false
): Unit {
    getDialogService().request(
        title,
        message,
        confirmText,
        cancelText,
        destructive,
        onConfirm,
        onCancel
    )
}

/**
 * 简化确认弹窗：固定「取消 / 确定」两按钮，只需传标题、消息与确定回调。
 *
 * @param title     弹窗标题
 * @param message   弹窗正文
 * @param onConfirm 点确定回调
 */
public func showConfirm(
    title!: String,
    message!: String,
    onConfirm!: () -> Unit
): Unit {
    showAlert(
        title: title,
        message: message,
        confirmText: "OK",
        onConfirm: onConfirm,
        cancelText: "Cancel",
        onCancel: { => },
        destructive: false
    )
}

/**
 * 带单行输入的弹窗（改名 / 输 URL 等）。
 * 经 PromptDialogService 转发，UI 由根部挂载的 PromptDialog() 渲染。
 *
 * @param title       弹窗标题
 * @param placeholder 输入框占位符
 * @param defaultText 输入框初始文本（确定时若未编辑则回传此值）
 * @param onConfirm   点确定回调，参数为当前输入文本
 * @param onCancel    点取消回调
 */
public func showPrompt(
    title!: String,
    placeholder!: String = "",
    defaultText!: String = "",
    onConfirm!: (String) -> Unit = { _: String => },
    onCancel!: () -> Unit = { => }
): Unit {
    getPromptDialogService().show(
        title: title,
        placeholder: placeholder,
        defaultText: defaultText,
        confirmText: "OK",
        cancelText: "Cancel",
        onConfirm: onConfirm,
        onCancel: onCancel
    )
    Hilog.info(0, "CjTelegram", "[DialogService] showPrompt title=" + title)
}
