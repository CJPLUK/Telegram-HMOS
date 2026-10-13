package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getRaiseToListenService

/**
 * RaiseToListenComponent — 抬起收听 UI 组件
 *
 * 对应 Telegram-iOS RaiseToListenManager 的 UI 侧反映。
 * 显示一个状态指示器：激活时显示"听筒"图标，未激活时显示"扬声器"图标。
 *
 * 使用方法：
 *   RaiseToListenComponent(isVoiceMessagePlaying: true)
 *
 * 组件在 aboutToAppear 时向 RaiseToListenService 注册回调；
 * 在 aboutToDisappear 时禁用服务并清理回调。
 *
 * @State 更新规则（R-69）：
 *   传感器回调在后台线程，更新 @State 必须通过 launch{} 回到主线程。
 */
@Component
class RaiseToListenComponent {
    // 是否正在播放语音消息（调用方控制；@Prop 不支持 Bool primitive，使用普通 var）
    var isVoiceMessagePlaying: Bool = false

    // 当前是否已激活（听筒模式）
    @State var isEarpieceActive: Bool = false

    // 是否正在监听手势
    @State var isListening: Bool = false

    func build() {
        Column() {
            if (this.isListening) {
                Row() {
                    if (this.isEarpieceActive) {
                        Text("听筒")
                            .fontSize(12)
                            .fontColor(0xFF34C759)
                            .padding(4)
                    } else {
                        Text("扬声器")
                            .fontSize(12)
                            .fontColor(0xFF8E8E93)
                            .padding(4)
                    }
                    Text(if (this.isEarpieceActive) { "靠近耳朵收听" } else { "举起手机切听筒" })
                        .fontSize(11)
                        .fontColor(0xFF8E8E93)
                        .padding(left: 4)
                }
                .padding(8)
                .borderRadius(8)
                .backgroundColor(if (this.isEarpieceActive) { 0x1A34C759 } else { 0x1A8E8E93 })
            }
        }
    }

    public override func aboutToAppear(): Unit {
        this.setupService()
    }

    public override func aboutToDisappear(): Unit {
        this.teardownService()
    }

    private func setupService(): Unit {
        if (!this.isVoiceMessagePlaying) {
            return
        }
        let svc = getRaiseToListenService()
        svc.configure(
            { =>
                launch {
                    this.isEarpieceActive = true
                    Hilog.info(0, "CjTelegram", "[RaiseToListenUI] Activated")
                }
            },
            { =>
                launch {
                    this.isEarpieceActive = false
                    Hilog.info(0, "CjTelegram", "[RaiseToListenUI] Deactivated")
                }
            }
        )
        svc.setEnabled(true)
        launch {
            this.isListening = true
            this.isEarpieceActive = svc.isActive()
        }
        Hilog.info(0, "CjTelegram", "[RaiseToListenUI] Service started for voice message")
    }

    private func teardownService(): Unit {
        let svc = getRaiseToListenService()
        svc.setEnabled(false)
        launch {
            this.isListening = false
            this.isEarpieceActive = false
        }
        Hilog.info(0, "CjTelegram", "[RaiseToListenUI] Service stopped")
    }
}
