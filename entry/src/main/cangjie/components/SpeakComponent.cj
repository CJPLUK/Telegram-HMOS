package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getSpeakService

/**
 * SpeakComponent — 文字转语音朗读按钮组件
 *
 * iOS 对应：speakText(context:text:) / SpeechSynthesizerHolder（Speak.swift）
 * HarmonyOS 实现：调用 SpeakService，使用鸿蒙 textToSpeech Kit（AI 朗读）真实合成语音。
 *
 * 用法：
 *   SpeakComponent(text: "要朗读的消息内容")
 *
 * 组件显示一个圆形按钮：
 *   - 未朗读时：扬声器图标（▶），点击开始朗读
 *   - 朗读中：停止图标（■），点击停止
 */
@Component
public class SpeakComponent {
    /** 要朗读的文本内容 */
    public var text: String = ""

    /** 是否正在朗读（驱动 UI 刷新） */
    @State
    var speaking: Bool = false

    /** 异步轮询计时器是否已注册 */
    @State
    var polling: Bool = false

    /**
     * 查询当前是否处于朗读状态（用于 UI 表达式，不含 let）
     */
    private func isSpeakingNow(): Bool {
        return getSpeakService().isSpeaking()
    }

    /**
     * 按钮图标文字：朗读中显示停止 ■，否则显示 ▶
     */
    private func buttonLabel(): String {
        if (this.speaking) { "■" } else { "▶" }
    }

    /**
     * 按钮颜色：朗读中橙色，否则主题蓝
     */
    private func buttonColor(): Int64 {
        if (this.speaking) { 0xFFFF6B00 } else { 0xFF2AABEE }
    }

    /**
     * 开始轮询朗读状态（每 500ms 检查一次，完成后自动停止轮询）
     */
    private func startPolling(): Unit {
        if (this.polling) { return }
        this.polling = true
        let _ = spawn {
            var running = true
            while (running) {
                sleep(Duration.millisecond * 500)
                let nowSpeaking = getSpeakService().isSpeaking()
                launch {
                    this.speaking = nowSpeaking
                    if (!nowSpeaking) {
                        this.polling = false
                    }
                }
                if (!nowSpeaking) {
                    running = false
                }
            }
        }
    }

    public func aboutToAppear(): Unit {
        this.speaking = getSpeakService().isSpeaking()
    }

    func build() {
        Row {
            Button(this.buttonLabel())
                .width(36)
                .height(36)
                .borderRadius(18)
                .backgroundColor(this.buttonColor())
                .fontColor(0xFFFFFFFF)
                .fontSize(14)
                .onClick({ _ =>
                    if (getSpeakService().isSpeaking()) {
                        getSpeakService().stopSpeaking()
                        launch {
                            this.speaking = false
                            this.polling = false
                        }
                    } else {
                        let ok = getSpeakService().speakText(this.text)
                        launch {
                            this.speaking = ok
                            if (ok) {
                                this.startPolling()
                            }
                        }
                    }
                })
        }
        .alignItems(VerticalAlign.Center)
    }
}
