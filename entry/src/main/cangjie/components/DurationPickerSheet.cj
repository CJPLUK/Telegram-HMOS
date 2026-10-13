package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList

/**
 * DurationPickerSheet — 可复用的自定义时长选择器（S226）
 *
 * 对位 iOS ChatTimerScreen
 * （TelegramUI/Components/ChatTimerScreen/Sources/ChatTimerScreen.swift）。
 *
 * 背景：本工程此前**没有任何自定义时长选择器**——GlobalAutoremoveScreen.cj:24 的
 * 头注释已明确记录「全仓 grep ChatTimerScreen/TimerScreen 零命中」，因此该屏不渲染
 * 源侧的 "Set a Custom Time" 行，PeerInfoPage 的自动删除也只有四个固定档。本组件
 * 补上这一能力。
 *
 * iOS 的 ChatTimerScreen 有 media / sendTimer / autoremove / mute 四种 mode，
 * 分别服务阅后即焚、定时发送、自动删除、静音至。本组件先落 autoremove 语义
 * （时长 → 秒），其余 mode 的取值域不同，接入方按需扩展 unitDefs 即可复用轮盘本体。
 *
 * 取值域参照 iOS autoremove 的可选粒度：天 / 周 / 月，另补小时以覆盖短时长场景
 * （源侧 debug 档亦有 5 秒 / 5 分钟的短值，说明短时长在协议上合法）。
 */
@Component
public class DurationPickerSheet {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 单位索引：0=小时 1=天 2=周 3=月
    @State var unitIndex: Int64 = 1
    // 数量索引（0 基，实际数量 = idx + 1）
    @State var amountIndex: Int64 = 0

    public var title: String = "Set a Custom Time"
    // 确认回调，回传秒数
    public var onConfirm: (Int32) -> Unit = { _s: Int32 => }
    public var onCancel: () -> Unit = { => }

    // 注意：这些表用实例方法返回，不用 `static let` 数组字面量——后者会让
    // cjc 在 --scan-dependency 阶段静默挂死（实测 20 分钟零进展、CPU 0%，
    // 与 R-145 同类）。工程内唯一被验证过的 @Component 静态成员形态是
    // `static func`（SinglePhoneInputComponent.cj:69），静态字段无先例。
    private func unitLabels(): Array<String> {
        return ["Hours", "Days", "Weeks", "Months"]
    }

    // 每单位的秒数。月按 31 天，与本工程既有 1 Month = 2678400 一致
    private func unitSeconds(idx: Int64): Int64 {
        if (idx == 0) { return 3600 }
        if (idx == 1) { return 86400 }
        if (idx == 2) { return 604800 }
        return 2678400
    }

    // 每单位的最大数量，避免出现「30 个月」这类越界档
    private func unitMax(idx: Int64): Int64 {
        if (idx == 0) { return 23 }
        if (idx == 1) { return 30 }
        if (idx == 2) { return 4 }
        return 12
    }

    private func amountRange(): Array<String> {
        let maxN = this.unitMax(Int64(this.unitIndex))
        let arr = ArrayList<String>()
        var i: Int64 = 1
        while (i <= maxN) {
            arr.add("${i}")
            i += 1
        }
        return arr.toArray()
    }

    /** 当前选择折算成秒；超出 Int32 时截断到 Int32 上界（协议字段为 int） */
    private func selectedSeconds(): Int32 {
        let n = this.amountIndex + 1
        let total = n * this.unitSeconds(Int64(this.unitIndex))
        if (total > 2147483647) { return 2147483647 }
        return Int32(total)
    }

    private func summaryText(): String {
        let n = this.amountIndex + 1
        var unit = this.unitLabels()[Int64(this.unitIndex)]
        // 数量为 1 时用单数形式，对齐 iOS 的 1 Day / 1 Week 措辞
        if (n == 1) { unit = unit[0..unit.size - 1] }
        return "${n} ${unit}"
    }

    public func build() {
        Column {
            Text(this.title)
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0xFF000000)
                .margin(top: 16, bottom: 4)

            Text(this.summaryText())
                .fontSize(14)
                .fontColor(0xFF8E8E93)
                .margin(bottom: 8)

            Row {
                // 数量列
                TextPicker(
                    range: this.amountRange(),
                    selected: UInt32(this.amountIndex)
                )
                    .canLoop(false)
                    .layoutWeight(1)
                    .onChange({ _, idx =>
                        this.amountIndex = Int64(idx)
                    })

                // 单位列
                TextPicker(
                    range: this.unitLabels(),
                    selected: UInt32(this.unitIndex)
                )
                    .canLoop(false)
                    .layoutWeight(1)
                    .onChange({ _, idx =>
                        this.unitIndex = Int64(idx)
                        // 换单位后数量可能越界（如 23 小时 → 周），夹到该单位上限
                        let maxIdx = this.unitMax(Int64(idx)) - 1
                        if (this.amountIndex > maxIdx) {
                            this.amountIndex = maxIdx
                        }
                    })
            }
            .width(100.percent)
            .height(180)

            Button(trSource("Done"))
                .fontSize(16)
                .fontColor(0xFFFFFFFF)
                .backgroundColor(0xFF317AFF)
                .borderRadius(10)
                .height(46)
                .width(100.percent)
                .margin(top: 8)
                .onClick({ _evt =>
                    this.onConfirm(this.selectedSeconds())
                })

            Button(trSource("Cancel"))
                .fontSize(16)
                .fontColor(0xFF317AFF)
                .backgroundColor(0xFFF2F2F7)
                .borderRadius(10)
                .height(46)
                .width(100.percent)
                .margin(top: 8, bottom: 16)
                .onClick({ _evt =>
                    this.onCancel()
                })
        }
        .width(100.percent)
        .padding(left: 20, right: 20)
        .backgroundColor(0xFFFFFFFF)
        .borderRadius(16)
        .alignItems(HorizontalAlign.Center)
    }
}
