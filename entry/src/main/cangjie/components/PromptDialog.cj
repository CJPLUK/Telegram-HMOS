package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.sync.*
import std.time.*
import ohos_app_cangjie_entry.services.getPromptDialogService

/**
 * PromptDialog — 带单行输入框的弹窗组件（根叠加层）
 *
 * 对应 iOS Telegram-iOS submodules/PromptUI（promptController.swift）：
 *   半透明黑底 + 居中卡片：标题 + 单行 TextInput（占位符 + 默认文案）+
 *   取消/确定两按钮；确定时把当前输入文本回传调用方。用于改名、输 URL 等。
 *
 * 渲染分离范式参考 OverlayStatusView ← OverlayStatusService、UndoToast ← UndoToastService：
 *   本组件不持有业务状态，纯渲染；标题/占位符/输入文本/回调由
 *   PromptDialogService（单例）维护，组件用 Timer.repeat tick 轮询服务状态
 *   并驱动 @State 重绘。用户编辑输入框时通过 setInputText 回写服务。
 *
 * 用法：挂在 root 容器一次即可（全局共用一个 prompt 叠加层）：
 *     PromptDialog()
 *   调用方经 utils/DialogUtils.cj 的 showPrompt 转发，无需直接接触本组件。
 *
 * 为什么 prompt 用受控叠加层而非原生 showAlertDialog：见 PromptDialogService 顶部注释
 *   （原生 AlertDialog 弹窗体不能塞 TextInput；CustomDialogController 需 @CustomDialog
 *    宏 + CustomView 绑定，无法从顶层工具函数驱动）。
 *
 * S-64: aboutToAppear/aboutToDisappear 必须 public override func ... : Unit
 * R-69: Timer 回调内 @State 写必须包 launch{}
 */
@Component
public class PromptDialog {
    // ==================== 渲染状态（@State 驱动重绘）====================

    // 当前是否可见
    @State var visible: Bool = false

    // 当前渲染用的标题 / 占位符 / 输入框文本（来自服务）
    @State var curTitle: String = ""
    @State var curPlaceholder: String = ""
    @State var curInput: String = ""
    @State var curConfirm: String = "OK"
    @State var curCancel: String = "Cancel"

    // 记录上次见到的服务 epoch（换一次弹窗时重置输入框初值）
    private var lastSeenEpoch: Int64 = -1

    // tick 定时器
    var tickTimer: Option<Timer> = None<Timer>

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        this.startTick()
        Hilog.info(0, "CjTelegram", "[PromptDialog] aboutToAppear")
    }

    public override func aboutToDisappear(): Unit {
        this.stopTick()
    }

    // ==================== tick：轮询服务状态 ====================

    private func startTick(): Unit {
        if (this.tickTimer.isSome()) {
            return
        }
        this.tickTimer = Some(Timer.repeat(
            Duration.millisecond * 100,
            Duration.millisecond * 100,
            { => this.onTick() },
            style: CatchupStyle.Skip
        ))
    }

    private func stopTick(): Unit {
        match (this.tickTimer) {
            case Some(t) =>
                t.cancel()
                this.tickTimer = None<Timer>
            case None => ()
        }
    }

    private func onTick(): Unit {
        let svc = getPromptDialogService()
        let showing = svc.isShowing()
        if (!showing) {
            if (this.visible) {
                launch { this.visible = false }
            }
            return
        }
        // 换了一次弹窗 → 同步标题/占位符/输入框初值
        let epoch = svc.getEpoch()
        if (epoch != this.lastSeenEpoch) {
            this.lastSeenEpoch = epoch
            let title = svc.getTitle()
            let placeholder = svc.getPlaceholder()
            let input = svc.getInputText()
            let confirmText = svc.getConfirmText()
            let cancelText = svc.getCancelText()
            launch {
                this.curTitle = title
                this.curPlaceholder = placeholder
                this.curInput = input
                this.curConfirm = confirmText
                this.curCancel = cancelText
                this.visible = true
            }
        }
    }

    // ==================== 用户操作 ====================

    private func handleConfirm(): Unit {
        getPromptDialogService().confirm()
        launch { this.visible = false }
        Hilog.info(0, "CjTelegram", "[PromptDialog] handleConfirm")
    }

    private func handleCancel(): Unit {
        getPromptDialogService().cancel()
        launch { this.visible = false }
        Hilog.info(0, "CjTelegram", "[PromptDialog] handleCancel")
    }

    private func handleInputChange(value: String): Unit {
        // 实时回写服务，确定时取最新文本
        getPromptDialogService().setInputText(value)
    }

    // ==================== UI ====================

    func build() {
        if (this.visible) {
            this.buildOverlay()
        }
    }

    @Builder
    private func buildOverlay() {
        // 半透明黑底遮障层（点击=取消）
        Stack {
            Column {
                this.buildCard()
            }
            .width(100.percent)
            .height(100.percent)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0x80000000)
        .onClick({ _ => this.handleCancel() })
    }

    @Builder
    private func buildCard() {
        Column {
            // 标题
            Text(this.curTitle)
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFF000000)
                .margin(bottom: 16)

            // 单行输入框
            TextInput(text: this.curInput, placeholder: this.curPlaceholder)
                .fontSize(16)
                .width(100.percent)
                .height(44)
                .margin(bottom: 20)
                .onChange({ value: String => this.handleInputChange(value) })

            // 取消 / 确定 两按钮
            Row {
                Text(this.curCancel)
                    .fontSize(16)
                    .fontColor(0xFF3E88F7)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ => this.handleCancel() })

                Text(this.curConfirm)
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0xFF3E88F7)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                    .onClick({ _ => this.handleConfirm() })
            }
            .width(100.percent)
        }
        .width(80.percent)
        .padding(top: 24, bottom: 20, left: 20, right: 20)
        .borderRadius(14)
        .backgroundColor(0xFFFFFFFF)
        // 阻止卡片点击冒泡到遮障层（避免点卡片触发取消）
        .onClick({ _ => () })
    }
}
