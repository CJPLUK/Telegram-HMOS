package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getGridMessageSelectionService
import ohos_app_cangjie_entry.utils.safeAnimateTo

/**
 * 网格消息多选 Overlay 组件（GridMessageSelectionNode）
 *
 * 在媒体网格的每个 cell 右上角渲染一个带选中态的圆形勾选圈（checkmark circle overlay）。
 * 点击 overlay 触发 GridMessageSelectionService.toggleSelection() 切换消息选中状态。
 * 进入/退出多选模式时播放 opacity + scale 淡入/淡出动画。
 *
 * 参考 iOS: GridMessageSelectionNode.swift
 *   - checkNode: CheckNode(overlay style, hasInset: true)，size 28×28，右上角偏移 (-2, 2)
 *   - animateIn: alpha 0→1 + scale 0.2→1，spring，0.5s
 *   - animateOut: alpha 1→0 + scale 1→0.2，spring，0.3s
 *   - updateSelected: 切换 checkNode.setSelected
 *   - tap → toggle(!selected)
 *
 * 使用方法：
 *   在媒体网格 cell 的 Stack 根容器内（alignment: TopEnd）使用本组件，
 *   传入 msgId（当前 cell 对应的消息 ID）与 isVisible（多选模式开关）。
 */
@Component
public class GridMessageSelectionComponent {
    // 当前 cell 对应的消息 ID
    public var msgId: Int64 = 0

    // 多选模式是否开启（由父页面控制，true=显示 overlay）
    public var isVisible: Bool = false

    // 选中态回调（外部可选注入，用于通知父层刷新计数等）
    public var onToggle: (Bool) -> Unit = { _: Bool => }

    // 本地选中状态（从 Service 同步）
    @State var isSelected: Bool = false

    // overlay 透明度（动画驱动：0=不可见，1=可见）
    @State var overlayOpacity: Float64 = 0.0

    // overlay 缩放（动画驱动）
    @State var overlayScale: Float64 = 0.2

    public override func aboutToAppear(): Unit {
        this.isSelected = getGridMessageSelectionService().isSelected(this.msgId)
        if (this.isVisible) {
            this.startAppearAnimation()
        }
    }

    // ─────────────────── 动画 ───────────────────

    /**
     * 淡入动画：opacity 0→1，scale 0.2→1（对应 iOS animateIn，spring 0.5s）
     */
    private func startAppearAnimation(): Unit {
        safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 500, curve: Curve.EaseOut), {
            =>
            this.overlayOpacity = 1.0
            this.overlayScale = 1.0
        })
    }

    /**
     * 淡出动画：opacity 1→0，scale 1→0.2（对应 iOS animateOut，spring 0.3s）
     */
    private func startDisappearAnimation(): Unit {
        safeAnimateTo({ => getUIContext() }, AnimateParam(duration: 300, curve: Curve.EaseIn), {
            =>
            this.overlayOpacity = 0.0
            this.overlayScale = 0.2
        })
    }

    // ─────────────────── 交互 ───────────────────

    /**
     * 处理 tap 事件：调用 Service.toggleSelection 切换状态
     * 对应 iOS tapGesture → toggle(!self.selected)
     */
    private func handleTap(): Unit {
        let nowSelected = getGridMessageSelectionService().toggleSelection(this.msgId)
        this.isSelected = nowSelected
        Hilog.info(0, "CjTelegram", "[GridMsgSelectComp] tap toggle")
        this.onToggle(nowSelected)
    }

    /**
     * 根据当前选中状态返回圆圈背景色
     * 选中：蓝色（Telegram accent）；未选中：白色半透明
     * 不能在 build 中使用 let，抽出为辅助方法（S-41）
     */
    private func checkBgColor(): Int64 {
        if (this.isSelected) {
            return 0xFF2EA6FF
        } else {
            return 0x80FFFFFF
        }
    }

    /**
     * 边框色：未选中时显示白色描边，选中时透明
     */
    private func checkBorderColor(): Int64 {
        if (this.isSelected) {
            return 0x002EA6FF
        } else {
            return 0xCCFFFFFF
        }
    }

    // ─────────────────── build ───────────────────

    func build() {
        Stack(alignContent: Alignment.TopEnd) {
            if (this.isVisible) {
                Stack(alignContent: Alignment.Center) {
                    Circle()
                        .width(28)
                        .height(28)
                        .fill(this.checkBgColor())
                        .stroke(this.checkBorderColor())
                        .strokeWidth(1.5)
                    if (this.isSelected) {
                        Text("✓")
                            .fontSize(16)
                            .fontColor(0xFFFFFFFF)
                            .fontWeight(FontWeight.Bold)
                    }
                }
                .width(28)
                .height(28)
                .opacity(this.overlayOpacity)
                .scale(x: Float32(this.overlayScale), y: Float32(this.overlayScale))
                .margin(top: 2, right: 2)
                .onClick({ _event =>
                    this.handleTap()
                })
            }
        }
        .width(100.percent)
        .height(100.percent)
    }
}
