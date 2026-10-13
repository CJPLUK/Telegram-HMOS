package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.AudioWaveformService

/**
 * AudioWaveformComponent — 音频波形可视化组件
 *
 * 将 Telegram 5-bit packed waveform 字节数组渲染为 bar 图形。
 * 支持播放进度高亮（已播放条 / 未播放条分色渲染）。
 *
 * 对应 iOS AudioWaveform 的展示侧，以及 MessageBubble 中语音波形区域。
 *
 * 用法示例：
 *   AudioWaveformComponent(
 *     waveformData: message.audioWaveform,
 *     progress: playerMgr.getProgressForMessage(msgId),
 *     totalDuration: message.audioDuration,
 *     fallbackSeed: message.id,
 *     playedColor: 0x317AFF,
 *     unplayedColor: 0xB0CBEF,
 *     barCount: 20,
 *     barWidth: 3,
 *     barSpacing: 2,
 *     componentHeight: 24
 *   )
 */
@Component
public class AudioWaveformComponent {
    /**
     * Telegram 5-bit packed waveform 字节数组（来自 Message.audioWaveform）。
     * 空数组时使用 fallbackSeed 生成伪随机占位波形。
     */
    public var waveformData: Array<Byte> = Array<Byte>(0, repeat: 0)

    /**
     * 当前播放进度（秒），用于计算高亮 bar 数量。
     * 0 表示未播放，等于 totalDuration 表示播放完毕。
     */
    public var progress: Int32 = 0

    /**
     * 语音总时长（秒），用于计算播放比例。
     */
    public var totalDuration: Int32 = 0

    /**
     * 无波形数据时生成伪随机波形的种子（建议传 messageId）。
     */
    public var fallbackSeed: Int64 = 0

    /**
     * 已播放部分的 bar 颜色。
     */
    public var playedColor: Int32 = 0x317AFF

    /**
     * 未播放部分的 bar 颜色。
     */
    public var unplayedColor: Int32 = 0xB0CBEF

    /**
     * bar 总数量（建议 20）。
     */
    public var barCount: Int64 = 20

    /**
     * 每个 bar 宽度（vp）。
     */
    public var barWidth: Int64 = 3

    /**
     * bar 之间间距（vp）。
     */
    public var barSpacing: Int64 = 2

    /**
     * 组件高度（vp），bar 高度范围在此内自适应。
     */
    public var componentHeight: Int64 = 24

    // 点击回调（可选，用于通知外部触发播放/暂停）
    public var onClick: () -> Unit = { => }

    @State var _tick: Bool = false

    /**
     * S-64: aboutToAppear 必须声明为 public func ... : Unit
     */
    public func aboutToAppear(): Unit {
        Hilog.info(0, "CjTelegram", "[AudioWaveform] Component appeared")
    }

    // ── 辅助方法（不能在 build 内用 let）──

    /**
     * 通过 AudioWaveformService 获取当前波形的 bar 高度数组。
     */
    private func getBarHeights(): Array<Int64> {
        return AudioWaveformService.getWaveformBars(
            waveformData: this.waveformData,
            barCount: this.barCount,
            fallbackSeed: this.fallbackSeed
        )
    }

    /**
     * 计算已播放的 bar 数量（根据进度比例）。
     */
    private func getPlayedBarCount(): Int64 {
        let total: Int32 = if (this.totalDuration > 0) { this.totalDuration } else { 1 }
        let ratio: Float64 = Float64(this.progress) / Float64(total)
        let played: Int64 = Int64(Float64(this.barCount) * ratio)
        if (played < 0) { return 0 }
        if (played > this.barCount) { return this.barCount }
        return played
    }

    /**
     * 将 Int32 颜色值转换为 UInt32（ArkUI Color 参数类型）。
     */
    private func colorU32(c: Int32): Int64 {
        if (c < 0) { return Int64(c) + 0x100000000 } else { return Int64(c) }
    }

    public func build() {
        Row {
            ForEach(this.getBarHeights(), itemGenerator: { height: Int64, idx: Int64 =>
                Column {}
                    .width(this.barWidth)
                    .height(height)
                    .backgroundColor(
                        if (idx < this.getPlayedBarCount()) {
                            this.colorU32(this.playedColor)
                        } else {
                            this.colorU32(this.unplayedColor)
                        }
                    )
                    .opacity(if (idx < this.getPlayedBarCount()) { 1.0 } else { 0.6 })
                    .borderRadius(2)
                    .margin(left: if (idx > 0) { this.barSpacing } else { 0 })
            })
        }
        .height(this.componentHeight)
        .alignItems(VerticalAlign.Center)
        .onClick({ _evt =>
            this.onClick()
        })
    }
}
