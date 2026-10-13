package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.getCallService
import std.collection.ArrayList
import std.convert.*
import ohos_app_cangjie_entry.router.*

/**
 * P2-059 通话评分/反馈页 (Call Rating & Feedback)（混合工程迁移版）
 *
 * iOS 对照: TelegramCallsUI/CallRatingController.swift + callFeedbackController
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack
 *  - build() 根去掉 NavDestination 包裹与其上的 .hideTitleBar(true)/.onReady（NavDestination 由 ArkTS 壳提供，hideTitleBar=true）
 *  - pageStack.pop() → routerPop()
 *  - 路由参数（"{callId}:{accessHash}:{isVideo}"）：源经 onReady context 读取；此处经 takePending("CallRatingPage") 读取
 *  - aboutToAppear 仅日志 → 删除；param 读取移入 ensureLoaded()，经根容器 .onAppear 触发
 */

// 低分原因枚举 — 必须 public，operator == 支持比较
public enum CallFeedbackReason {
    | Echo
    | Noise
    | Interruption
    | Distorted
    | Silent

    public func ordinal(): Int32 {
        match (this) {
            case Echo => 0
            case Noise => 1
            case Interruption => 2
            case Distorted => 3
            case Silent => 4
        }
    }

    public operator func ==(rhs: CallFeedbackReason): Bool {
        this.ordinal() == rhs.ordinal()
    }

    public operator func !=(rhs: CallFeedbackReason): Bool {
        this.ordinal() != rhs.ordinal()
    }

    public func displayName(): String {
        match (this) {
            case Echo => "Echo"
            case Noise => "Noise"
            case Interruption => "Interruptions"
            case Distorted => "Distorted sound"
            case Silent => "Silent call"
        }
    }
}

// 所有可选原因列表
private func allFeedbackReasons(): Array<CallFeedbackReason> {
    return [CallFeedbackReason.Echo, CallFeedbackReason.Noise,
            CallFeedbackReason.Interruption, CallFeedbackReason.Distorted,
            CallFeedbackReason.Silent]
}

// 判断某原因是否已选
private func isReasonSelected(reason: CallFeedbackReason, selected: Array<Bool>): Bool {
    let idx = Int64(reason.ordinal())
    if (idx < selected.size) { return selected[idx] }
    return false
}

// 从路由参数字符串解析通话路由参数（混合工程：param 经 takePending 取回）
private func parseCallRatingParam(raw: String): (Int64, Int64, Bool) {
    if (raw.size == 0) { return (0, 0, false) }
    let parts = raw.split(":")
    if (parts.size < 3) { return (0, 0, false) }
    var callId: Int64 = 0
    var accessHash: Int64 = 0
    var isVideo: Bool = false
    try { callId = Int64.parse(parts[0]) } catch (_: Exception) {}
    try { accessHash = Int64.parse(parts[1]) } catch (_: Exception) {}
    isVideo = parts[2] == "true"
    return (callId, accessHash, isVideo)
}

// 把选中原因拼为 comment 字符串
private func buildCommentFromReasons(reasons: Array<Bool>): String {
    let all = allFeedbackReasons()
    var result = ""
    var i: Int64 = 0
    while (i < all.size && i < reasons.size) {
        if (reasons[i]) {
            if (result.size > 0) { result = result + ", " }
            result = result + all[i].displayName()
        }
        i = i + 1
    }
    return result
}

@HybridComponentEntry
@Component
public class CallRatingPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 路由参数
    @State var callId: Int64 = 0
    @State var callAccessHash: Int64 = 0
    @State var isVideo: Bool = false

    // 评分状态
    @State var currentRating: Float64 = 0.0

    // 低分反馈 sheet 状态
    @State var showFeedbackSheet: Bool = false
    @State var reason0Selected: Bool = false  // Echo
    @State var reason1Selected: Bool = false  // Noise
    @State var reason2Selected: Bool = false  // Interruption
    @State var reason3Selected: Bool = false  // Distorted
    @State var reason4Selected: Bool = false  // Silent
    @State var includeLogs: Bool = false

    // 提交状态
    @State var isSubmitting: Bool = false
    @State var submitted: Bool = false
    @State var submitError: String = ""

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        let (cId, cHash, iv) = parseCallRatingParam(takePending("CallRatingPage"))
        this.callId = cId
        this.callAccessHash = cHash
        this.isVideo = iv
        Hilog.info(0, "CjTelegram", "[CallRatingPage] onAppear callId=${this.callId}")
    }

    private func handleRatingChanged(value: Float64): Unit {
        let newVal = value
        launch { this.currentRating = newVal }
    }

    private func handleSubmitRating(): Unit {
        if (this.currentRating <= 0.0) { return }
        if (this.isSubmitting) { return }

        let rating = Int32(this.currentRating)
        // iOS: if rating < 4, show feedback sheet
        if (rating < 4) {
            launch { this.showFeedbackSheet = true }
        } else {
            this.doSubmitRating(rating, "")
        }
    }

    private func doSubmitRating(rating: Int32, comment: String): Unit {
        let cId = this.callId
        let cHash = this.callAccessHash
        launch { this.isSubmitting = true }

        let _ = spawn {
            let svc = getCallService()
            let ok = svc.rateCallQuality(cId, cHash, rating, comment)
            let err = if (ok) { "" } else { "Failed to submit rating" }
            let subm = ok
            launch {
                this.isSubmitting = false
                this.submitted = subm
                this.submitError = err
                this.showFeedbackSheet = false
                if (subm) {
                    // 短暂等待后自动关闭页面
                    let _ = spawn {
                        sleep(Duration.millisecond * 800)
                        launch { routerPop() }
                    }
                }
            }
        }
    }

    private func handleSubmitFeedback(): Unit {
        let r = this.currentRating
        let rating = Int32(r)
        let reasons: Array<Bool> = [this.reason0Selected, this.reason1Selected,
                                     this.reason2Selected, this.reason3Selected,
                                     this.reason4Selected]
        let comment = buildCommentFromReasons(reasons)
        this.doSubmitRating(rating, comment)
    }

    private func handleSkip(): Unit {
        routerPop()
    }

    // ---- 辅助：当前评分星级文字 ----
    private func ratingLabel(): String {
        let r = Int32(this.currentRating)
        match (r) {
            case 1 => "Terrible"
            case 2 => "Bad"
            case 3 => "Okay"
            case 4 => "Good"
            case 5 => "Excellent"
            case _ => "Tap to rate"
        }
    }

    // ---- 反馈原因行 ----
    @Builder
    func buildReasonRow(label: String, selected: Bool, onToggle: () -> Unit) {
        Row {
            Text(label)
                .fontSize(16)
                .fontColor(0xFFFFFF)
                .layoutWeight(1)
            if (selected) {
                Text("✓")
                    .fontSize(18)
                    .fontColor(0x34C759)
            }
        }
        .width(100.percent)
        .padding(left: 16, right: 16, top: 14, bottom: 14)
        .backgroundColor(if (selected) { 0x2034C759 } else { 0x1AFFFFFF })
        .borderRadius(10)
        .margin(bottom: 8)
        .onClick({ _evt => onToggle() })
    }

    // ---- 反馈 sheet 内容 ----
    @Builder
    func buildFeedbackSheet() {
        Column {
            Text(trSource("What went wrong?"))
                .fontSize(18)
                .fontColor(0xFFFFFF)
                .fontWeight(FontWeight.Medium)
                .margin(top: 24, bottom: 4)

            Text("Select all that apply")
                .fontSize(14)
                .fontColor(0x8E8E93)
                .margin(bottom: 20)

            this.buildReasonRow("Echo", this.reason0Selected, { => let v = !this.reason0Selected; launch { this.reason0Selected = v } })
            this.buildReasonRow("Noise", this.reason1Selected, { => let v = !this.reason1Selected; launch { this.reason1Selected = v } })
            this.buildReasonRow("Interruptions", this.reason2Selected, { => let v = !this.reason2Selected; launch { this.reason2Selected = v } })
            this.buildReasonRow("Distorted sound", this.reason3Selected, { => let v = !this.reason3Selected; launch { this.reason3Selected = v } })
            this.buildReasonRow("Silent call", this.reason4Selected, { => let v = !this.reason4Selected; launch { this.reason4Selected = v } })

            // include-logs 开关
            Row {
                Column {
                    Text("Include debug logs")
                        .fontSize(15)
                        .fontColor(0xFFFFFF)
                    Text("Helps improve call quality")
                        .fontSize(12)
                        .fontColor(0x8E8E93)
                        .margin(top: 2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle(ToggleType.Switch, isOn: this.includeLogs)
                    .onChange({ isOn: Bool =>
                        let v = isOn
                        launch { this.includeLogs = v }
                    })
                    .margin(left: 12)
            }
            .width(100.percent)
            .padding(left: 16, right: 16, top: 14, bottom: 14)
            .backgroundColor(0x1AFFFFFF)
            .borderRadius(10)
            .margin(bottom: 24)

            Button(if (this.isSubmitting) { "Sending..." } else { "Submit" })
                .width(100.percent)
                .height(50)
                .borderRadius(12)
                .backgroundColor(if (this.isSubmitting) { 0x8E8E93 } else { 0x317AFF })
                .fontColor(0xFFFFFF)
                .fontSize(17)
                .margin(bottom: 16)
                .onClick({ _evt =>
                    if (!this.isSubmitting) {
                        this.handleSubmitFeedback()
                    }
                })

            Button(trSource("Skip"))
                .width(100.percent)
                .height(44)
                .borderRadius(12)
                .backgroundColor(Color.Transparent)
                .fontColor(0x8E8E93)
                .fontSize(15)
                .margin(bottom: 32)
                .onClick({ _evt => this.handleSkip() })

        }
        .width(100.percent)
        .padding(left: 20, right: 20)
        .backgroundColor(0xFF1C1C1E)
        .alignItems(HorizontalAlign.Center)
    }

    public func build() {
        Column {
            // 标题行
            Row {
                Button("✕")
                    .backgroundColor(Color.Transparent)
                    .fontColor(0x8E8E93)
                    .fontSize(20)
                    .onClick({ _evt => routerPop() })
                Column {}.layoutWeight(1)
            }
            .width(100.percent)
            .padding(left: 8, right: 8, top: 8)

            // 通话图标
            Text(if (this.isVideo) { "📹" } else { "📞" })
                .fontSize(56)
                .margin(top: 24, bottom: 16)

            // 标题
            Text("Rate this call")
                .fontSize(22)
                .fontColor(0xFFFFFF)
                .fontWeight(FontWeight.Medium)
                .margin(bottom: 8)

            Text(if (this.isVideo) { "Video call" } else { "Voice call" })
                .fontSize(14)
                .fontColor(0x8E8E93)
                .margin(bottom: 32)

            // Rating 组件 (1-5 星)
            Rating(rating: this.currentRating, indicator: false)
                .stars(5)
                .stepSize(1.0)
                .onChange({ value: Float64 =>
                    this.handleRatingChanged(value)
                })
                .margin(bottom: 16)
                .width(200)
                .height(40)

            // 评分标签
            if (this.currentRating > 0.0) {
                Text(this.ratingLabel())
                    .fontSize(15)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 32)
            }

            Column {}.layoutWeight(1)

            // 提交成功
            if (this.submitted) {
                Text("Thanks for your feedback!")
                    .fontSize(16)
                    .fontColor(0x34C759)
                    .margin(bottom: 24)
            }

            // 错误信息
            if (this.submitError.size > 0) {
                Text(this.submitError)
                    .fontSize(14)
                    .fontColor(0xFF3B30)
                    .margin(bottom: 12)
            }

            // 提交按钮 (评分 ≥ 4 时直接提交，< 4 时展开 sheet)
            if (this.currentRating > 0.0 && !this.submitted) {
                Button(if (this.isSubmitting) { "Sending..." } else { "Submit Rating" })
                    .width(100.percent)
                    .height(50)
                    .borderRadius(12)
                    .backgroundColor(if (this.isSubmitting) { 0x8E8E93 } else { 0x317AFF })
                    .fontColor(0xFFFFFF)
                    .fontSize(17)
                    .margin(bottom: 16)
                    .onClick({ _evt =>
                        if (!this.isSubmitting) {
                            this.handleSubmitRating()
                        }
                    })
            }

            // 跳过按钮
            if (!this.submitted) {
                Button(trSource("Not Now"))
                    .width(100.percent)
                    .height(44)
                    .borderRadius(12)
                    .backgroundColor(Color.Transparent)
                    .fontColor(0x8E8E93)
                    .fontSize(15)
                    .margin(bottom: 32)
                    .onClick({ _evt => this.handleSkip() })
            }
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF1C1C1E)
        .alignItems(HorizontalAlign.Center)
        .padding(left: 20, right: 20)
        .bindSheet(this.showFeedbackSheet, this.buildFeedbackSheet, options: SheetOptions(onDisappear: { => launch { this.showFeedbackSheet = false } }))
        .onAppear({ => this.ensureLoaded() })
    }
}
