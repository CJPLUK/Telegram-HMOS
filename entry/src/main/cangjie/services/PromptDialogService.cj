package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * PromptDialogService — 带单行输入框的弹窗状态管理器（单例）
 *
 * 对应 iOS Telegram-iOS submodules/PromptUI（promptController.swift）：
 *   带单行输入框的确认弹窗（改名、输 URL 等），含 标题 + 输入框（占位符 +
 *   默认文案）+ 确定/取消两按钮；确定时把当前输入文本回传调用方。
 *
 * 为什么用「状态服务 + 受控 @Component overlay」而非原生 AlertDialog：
 *   鸿蒙 ArkUI 的 getUIContext().showAlertDialog(...) 是固定样式弹窗，
 *   弹窗体里**不能塞 TextInput**（只有 title/message/按钮）；而
 *   CustomDialogController 依赖 @CustomDialog 宏 + CustomView 绑定，必须作为
 *   某个 @Component 的成员实例化，无法从一个普通顶层工具函数里直接驱动。
 *   因此带输入的 prompt 退而走本仓库既有的「单例状态服务 + 根叠加层组件」范式
 *   （与 OverlayStatusService / OverlayStatusView、UndoToastService / UndoToast 同构）：
 *   本服务只持有状态，UI 由 components/PromptDialog.cj 以根叠加层方式消费，
 *   组件用 Timer.repeat tick 轮询服务状态并驱动 @State 重绘。
 *   标准确认/带破坏性按钮的弹窗（无输入框）仍走原生 showAlertDialog，
 *   见 utils/DialogUtils.cj 的 showAlert / showConfirm。
 *
 * 调用方（任意需要带输入弹窗的 feature，经 utils/DialogUtils.cj 的 showPrompt 转发）：
 *   getPromptDialogService().show(
 *       title: "Rename",
 *       placeholder: "New name",
 *       defaultText: oldName,
 *       onConfirm: { value: String => ... },
 *       onCancel: { => ... })
 *
 * 生命周期（一次弹窗）：
 *   show     → visible=true，记录 title/placeholder/当前输入文本 = defaultText，epoch 自增
 *   组件 tick 轮询 epoch 变化 → 同步 title/placeholder/输入框初值
 *   用户编辑 → 组件 onChange 回写 setInputText()（服务持有「当前输入文本」）
 *   confirm  → 取出当前输入文本，触发 onConfirm(text)，dismiss
 *   cancel   → 触发 onCancel，dismiss
 *   dismiss  → visible=false，清回调
 */
private var _promptDialogServiceInstance: Option<PromptDialogService> = None<PromptDialogService>

public func getPromptDialogService(): PromptDialogService {
    match (_promptDialogServiceInstance) {
        case Some(s) => s
        case None =>
            let s = PromptDialogService()
            _promptDialogServiceInstance = Some(s)
            s
    }
}

public class PromptDialogService {
    // 是否正在显示
    private var _visible: Bool = false

    // 弹窗标题
    private var _title: String = ""

    // 输入框占位符
    private var _placeholder: String = ""

    // 当前输入文本（初值 = defaultText，随用户编辑实时回写）
    private var _inputText: String = ""

    // 确定/取消按钮文字
    private var _confirmText: String = "OK"
    private var _cancelText: String = "Cancel"

    // 单调递增「轮次」标记 —— 每次 show 自增，供组件感知「换了一次弹窗」并重置输入框初值
    private var _epoch: Int64 = 0

    // 回调
    private var _onConfirm: (String) -> Unit = { _: String => }
    private var _onCancel: () -> Unit = { => }

    /**
     * 弹出带单行输入的弹窗。
     * @param title       标题
     * @param placeholder 输入框占位符
     * @param defaultText 输入框初始文本（确定时若未编辑则回传此值）
     * @param confirmText 确定按钮文字，默认 "OK"
     * @param cancelText  取消按钮文字，默认 "Cancel"
     * @param onConfirm   确定回调，参数为当前输入文本
     * @param onCancel    取消回调
     */
    public func show(
        title!: String,
        placeholder!: String = "",
        defaultText!: String = "",
        confirmText!: String = "OK",
        cancelText!: String = "Cancel",
        onConfirm!: (String) -> Unit = { _: String => },
        onCancel!: () -> Unit = { => }
    ): Unit {
        this._title = title
        this._placeholder = placeholder
        this._inputText = defaultText
        this._confirmText = confirmText
        this._cancelText = cancelText
        this._onConfirm = onConfirm
        this._onCancel = onCancel
        this._visible = true
        this._epoch = this._epoch + 1
        Hilog.info(0, "CjTelegram",
            "[PromptDialogService] show title=" + title + " placeholder=" + placeholder)
    }

    /**
     * 组件在用户编辑输入框时回写当前文本。
     */
    public func setInputText(text: String): Unit {
        this._inputText = text
    }

    /**
     * 用户点「确定」：取当前输入文本回传 onConfirm，然后退场。
     */
    public func confirm(): Unit {
        if (!this._visible) {
            return
        }
        let cb = this._onConfirm
        let text = this._inputText
        this.dismiss()
        cb(text)
        Hilog.info(0, "CjTelegram", "[PromptDialogService] confirm text=" + text)
    }

    /**
     * 用户点「取消」（或点遮障层）：触发 onCancel，然后退场。
     */
    public func cancel(): Unit {
        if (!this._visible) {
            return
        }
        let cb = this._onCancel
        this.dismiss()
        cb()
        Hilog.info(0, "CjTelegram", "[PromptDialogService] cancel")
    }

    /**
     * 退场：清可见态与回调。
     */
    public func dismiss(): Unit {
        this._visible = false
        this._onConfirm = { _: String => }
        this._onCancel = { => }
    }

    // ==================== 状态查询（供 PromptDialog 组件 tick 轮询）====================

    public func isShowing(): Bool {
        return this._visible
    }

    public func getTitle(): String {
        return this._title
    }

    public func getPlaceholder(): String {
        return this._placeholder
    }

    public func getInputText(): String {
        return this._inputText
    }

    public func getConfirmText(): String {
        return this._confirmText
    }

    public func getCancelText(): String {
        return this._cancelText
    }

    public func getEpoch(): Int64 {
        return this._epoch
    }
}
