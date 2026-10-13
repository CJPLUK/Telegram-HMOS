package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*

/**
 * CodeInputViewComponent — 可复用的 OTP/验证码输入组件
 *
 * 对应 Telegram-iOS CodeInputView：渲染独立数字框，支持自动前进、退格。
 * 使用隐藏 TextInput 捕获键盘输入（HarmonyOS 标准模式）。
 *
 * Props:
 *   codeLength: 数字框数量（默认 5）
 *   code: 当前验证码字符串（由父组件通过回调更新）
 * Callbacks:
 *   onCodeChanged: 每次输入变化时调用
 *   onCodeComplete: 当所有位填满时调用
 *
 * 注意: @Prop 不支持 primitive 类型，使用普通 var（参考 Avatar.cj）
 */
@Component
public class CodeInputViewComponent {
    var codeLength: Int32 = 5
    var code: String = ""

    public var onCodeChanged: (String) -> Unit = { _: String => }
    public var onCodeComplete: (String) -> Unit = { _: String => }

    private func getDigitAt(idx: Int64): String {
        let runes = this.code.toRuneArray()
        if (idx >= 0 && idx < Int64(runes.size)) {
            return runes[idx].toString()
        }
        return ""
    }

    private func isActiveBox(idx: Int64): Bool {
        return idx == Int64(this.code.size)
    }

    private func filterDigitsOnly(value: String): String {
        let runes = value.toRuneArray()
        var out = ""
        for (r in runes) {
            let c = UInt32(r)
            if (c >= 48 && c <= 57) {
                out = out + r.toString()
            }
        }
        return out
    }

    private func truncateToMax(value: String, maxLen: Int32): String {
        let runes = value.toRuneArray()
        if (Int64(runes.size) <= Int64(maxLen)) {
            return value
        }
        var out = ""
        var i: Int64 = 0
        while (i < Int64(maxLen)) {
            out = out + runes[i].toString()
            i = i + 1
        }
        return out
    }

    private func handleInputChange(value: String): Unit {
        let filtered = this.filterDigitsOnly(value)
        let truncated = this.truncateToMax(filtered, this.codeLength)
        this.onCodeChanged(truncated)
        if (Int64(truncated.size) == Int64(this.codeLength)) {
            this.onCodeComplete(truncated)
        }
    }

    func build() {
        Stack() {
            Row() {
                ForEach(Array<Int64>(Int64(this.codeLength), { i: Int64 => i }), itemGenerator: { idx: Int64, _i: Int64 =>
                    Column() {
                        Text(this.getDigitAt(idx))
                            .fontSize(24)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(0x000000)
                    }
                    .width(48)
                    .height(56)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .border(width: 2, color: if (this.isActiveBox(idx)) { 0x317AFF } else { 0xE0E0E0 })
                    .borderRadius(8)
                    .margin(right: if (idx < Int64(this.codeLength) - 1) { 8 } else { 0 })
                })
            }
            .width(100.percent)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .onClick({ _ =>
                // 点击时聚焦隐藏输入框（通过覆盖层触发）
            })

            TextInput(text: this.code, placeholder: "")
                .width(100.percent)
                .height(56)
                .fontSize(24)
                .inputFilter("[0-9]", error: { _: String => })
                .opacity(0.001)
                .onChange({ value: String =>
                    this.handleInputChange(value)
                })
        }
        .width(100.percent)
        .height(56)
        .alignContent(Alignment.Center)
    }
}
