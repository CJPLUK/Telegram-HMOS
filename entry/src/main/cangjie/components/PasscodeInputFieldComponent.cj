package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * PasscodeInputFieldComponent — 可复用的密码输入点阵显示组件（P2-266/268）
 *
 * 对应 Telegram-iOS PasscodeInputFieldNode：渲染 4 或 6 个圆点。
 * 纯展示组件，键盘由父组件处理。
 *
 * Props:
 *   codeLength:  圆点总数量（4 或 6），普通 var（同一次输入流程内不变）
 *   filledCount: 已填充圆点数量，@Prop（无默认值，调用方必须显式传入，见下方补记）
 *   showError:   true 时触发 shake 动画（声明式 translate ±8vp + animation 补间），@Prop（同上）
 *
 * TC-0139 附带发现补记（零视觉反馈缺陷，修法 6）：
 *   filledCount/showError 曾是普通 var。普通 var 只在组件首次构造时被赋值一次，父组件
 *   （AppLockPage）@State 变化重渲染并不会刷新已存在子组件实例的普通 var 字段 —— 实测占位符
 *   在 0 位与 N 位时像素差均值为 0（零反馈），showError 的 shake 动画同样永不触发。改用 @Prop
 *   （父子单向同步，父组件重渲染时子组件的 @Prop 随父侧最新值刷新）修复；先例见
 *   components/SolidRoundedButton.cj 的 enabled/loading 字段与同一注释。三个既有调用点
 *   （AppLockPage.cj 的 setup/change/disable 三处）均已显式传参，无需改动。
 *
 * P2-268 shake 实现：
 *   使用 @State shakeX（Float64），父组件通过 showError=true → false 切换驱动 —
 *   以下等式成立：showError=true → shakeX=8.0（右移），showError=false → shakeX=0.0（归位）。
 *   声明式 .animation(AnimateParam) 自动补间，实现左右摇摆效果。
 *   父组件在错误发生时先置 showError=true（shake出现），100ms 后置回 false（shake复位）。
 *   这是 ArkUI 声明式属性动画标准模式（参见 cj-attribute-animation-apis）。
 */
@Component
public class PasscodeInputFieldComponent {
    var codeLength: Int32 = 6
    @Prop var filledCount: Int32
    @Prop var showError: Bool

    private func isDotFilled(idx: Int64): Bool {
        return idx < Int64(this.filledCount)
    }

    private func dotSize(): Int64 {
        return 13
    }

    private func dotSpacing(): Int64 {
        return 24
    }

    private func shakeOffset(): Float64 {
        if (this.showError) { return 8.0 }
        return 0.0
    }

    func build() {
        Row() {
            ForEach(Array<Int64>(Int64(this.codeLength), { i: Int64 => i }), itemGenerator: { idx: Int64, _i: Int64 =>
                Column() {}
                    .width(this.dotSize())
                    .height(this.dotSize())
                    .borderRadius(this.dotSize() / 2)
                    // D-144: 0x00000000 在本 SDK 下被 alphaAdapt 强制补 alpha=FF，渲染成不透明黑，
                    // 不是透明；未填充态一律用 Color.Transparent（仓内 68+ 处已验证生效的唯一写法）。
                    .backgroundColor(if (this.isDotFilled(idx)) { 0x317AFF } else { Color.Transparent })
                    .border(width: if (this.isDotFilled(idx)) { 0 } else { 1 }, color: 0xE0E0E0)
                    .margin(right: if (idx < Int64(this.codeLength) - 1) { this.dotSpacing() } else { 0 })
            })
        }
        .justifyContent(FlexAlign.Center)
        .translate(x: this.shakeOffset())
        .animation(AnimateParam(duration: 80, curve: Curve.Linear))
    }
}
