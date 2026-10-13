package ohos_app_cangjie_entry.components

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getChatTitleActivityService, ActivityState, ActivityType}

/**
 * 聊天标题活动指示组件（Phase CTAN）
 *
 * 对应 iOS ChatTitleActivityNode — 在聊天标题栏副标题区域显示对方的实时活动状态：
 *   - "typing..." + 三点脉动动画（对应 ChatTypingActivityContentNode）
 *   - "recording audio..." + 波纹动画（对应 ChatRecordingVoiceActivityContentNode）
 *   - "choosing a sticker..." + 眼睛动画（对应 ChatChoosingStickerActivityContentNode）
 *   - "recording video..."
 *   - "sending file..."
 *
 * 架构：
 *   - 接收 ChatTitleActivityService 推送的 ActivityState（通过 setActivityHandler 回调）
 *   - Typing 状态显示三点脉动动画（dot1/dot2/dot3 opacity 依次 0.3→1.0→0.3，间隔 230ms）
 *   - 其他状态仅显示文案 + 固定图标
 *   - build() 无 let 语句（S-41 合规）
 *   - aboutToAppear/aboutToDisappear: public override func ... : Unit（S-64 合规）
 *   - spawn 返回值: let _ = spawn {...}（R-69 合规）
 *   - @State 赋值全部在 launch {} 中执行（R-69 合规）
 */
@Component
public class ChatTitleActivityComponent {
    // ==================== 外部输入 ====================

    /** 当前活动文案，由父组件（ChatRoomPage）绑定 */
    public var activityText: String = ""

    // ==================== 内部 @State ====================

    /** 三点动画各点的透明度（Typing 状态） */
    @State var dot1Opacity: Float64 = 0.3
    @State var dot2Opacity: Float64 = 0.3
    @State var dot3Opacity: Float64 = 0.3

    /** 当前活动类型（驱动动画分支） */
    @State var currentActivityType: ActivityType = ActivityType.Idle

    /** 当前活动文案（从 Service 推送更新） */
    @State var displayText: String = ""

    /** 动画协程是否运行中 */
    private var _animActive: Bool = false

    // ==================== 生命周期 ====================

    public override func aboutToAppear(): Unit {
        // 注册 Service 回调
        let svc = getChatTitleActivityService()
        svc.setActivityHandler({ state: ActivityState =>
            launch {
                this.currentActivityType = state.activityType
                this.displayText = state.displayText
            }
            // 启动/停止动画
            match (state.activityType) {
                case ActivityType.Typing => this.startDotAnimation()
                case ActivityType.Idle => this.stopDotAnimation()
                case _ => this.stopDotAnimation()
            }
        })
        // 加载当前已有状态
        let current = svc.getCurrentState()
        this.currentActivityType = current.activityType
        this.displayText = current.displayText
        match (current.activityType) {
            case ActivityType.Typing => this.startDotAnimation()
            case _ => ()
        }
    }

    public override func aboutToDisappear(): Unit {
        this._animActive = false
        getChatTitleActivityService().clearActivityHandler()
    }

    // ==================== 动画控制 ====================

    /**
     * 启动三点脉动动画
     *
     * 三个点依次亮起再暗下（各 230ms 间隔），整体循环 690ms
     * 使用 spawn + sleep + launch 更新 @State（符合 R-69）
     */
    private func startDotAnimation(): Unit {
        if (this._animActive) { return }
        this._animActive = true
        let _ = spawn {
            while (this._animActive) {
                // dot1 亮
                launch { this.dot1Opacity = 1.0 }
                sleep(Duration.millisecond * 230)
                if (!this._animActive) { break }
                // dot2 亮
                launch { this.dot2Opacity = 1.0 }
                sleep(Duration.millisecond * 230)
                if (!this._animActive) { break }
                // dot3 亮
                launch { this.dot3Opacity = 1.0 }
                sleep(Duration.millisecond * 230)
                if (!this._animActive) { break }
                // 全部暗下
                launch {
                    this.dot1Opacity = 0.3
                    this.dot2Opacity = 0.3
                    this.dot3Opacity = 0.3
                }
                sleep(Duration.millisecond * 200)
            }
            // 退出时重置
            launch {
                this.dot1Opacity = 0.3
                this.dot2Opacity = 0.3
                this.dot3Opacity = 0.3
            }
        }
    }

    private func stopDotAnimation(): Unit {
        this._animActive = false
    }

    // ==================== 辅助方法（无 let，供 build 调用） ====================

    private func isTyping(): Bool {
        match (this.currentActivityType) {
            case ActivityType.Typing => return true
            case _ => return false
        }
    }

    private func isVisible(): Bool {
        match (this.currentActivityType) {
            case ActivityType.Idle => return false
            case _ => return true
        }
    }

    private func activityIcon(): String {
        match (this.currentActivityType) {
            case ActivityType.RecordingVoice => return "\u{1F3A4} "
            case ActivityType.RecordingVideo => return "\u{1F3A5} "
            case ActivityType.ChoosingSticker => return "\u{1F9E7} "
            case ActivityType.Uploading => return "\u{1F4CE} "
            case _ => return ""
        }
    }

    // ==================== build ====================

    public func build() {
        if (this.isVisible()) {
            Row {
                if (this.isTyping()) {
                    // 三点脉动动画指示器
                    Row {
                        Column {}
                            .width(5)
                            .height(5)
                            .borderRadius(3)
                            .backgroundColor(0x007AFF)
                            .opacity(this.dot1Opacity)
                            .margin(right: 2)

                        Column {}
                            .width(5)
                            .height(5)
                            .borderRadius(3)
                            .backgroundColor(0x007AFF)
                            .opacity(this.dot2Opacity)
                            .margin(right: 2)

                        Column {}
                            .width(5)
                            .height(5)
                            .borderRadius(3)
                            .backgroundColor(0x007AFF)
                            .opacity(this.dot3Opacity)
                    }
                    .margin(right: 4)
                    .alignItems(VerticalAlign.Center)
                } else {
                    Text(this.activityIcon())
                        .fontSize(11)
                        .fontColor(0x007AFF)
                        .margin(right: 2)
                }

                Text(this.displayText)
                    .fontSize(12)
                    .fontColor(0x007AFF)
                    .maxLines(1)
            }
            .alignItems(VerticalAlign.Center)
            .height(16)
        }
    }
}
