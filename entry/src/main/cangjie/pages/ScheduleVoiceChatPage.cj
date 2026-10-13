package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.services.{getCallsService, GroupCallInfo}
import ohos_app_cangjie_entry.router.*
import std.time.DateTime
import std.convert.*

/**
 * P2-062 预约语音/视频聊天页 (Schedule Voice/Video Chat)（混合工程迁移版）
 *
 * iOS 对照: TelegramCallsUI/ScheduleVideoChatSheetScreen.swift
 *
 * Fidelity gaps closed:
 * - DatePicker 组件真实日期选择（当前日期 + 7天内）
 * - 小时/分钟 Slider 选择时间
 * - scheduleDate 计算为 Unix 时间戳 (Int32) — 不是透传参数
 * - 真实 phone.createGroupCall(scheduleDate) TL 调用
 * - 预约成功后显示预约状态
 *
 * 路由参数: "{peerId}:{peerAccessHash}:{isChannel}:{title}"
 *   isChannel: "true"/"false"
 *
 * 混合迁移改动（recipe §12 Phase 4）：
 *  - @Component → @HybridComponentEntry
 *  - 去掉 @Consume NavPathStack（pageStack.pop() → routerPop()）
 *  - build() 根去掉 NavDestination 包裹，只留内容
 *  - onReady param(NavDestinationContext) → takePending("ScheduleVoiceChatPage")
 *  - aboutToAppear(默认明天 18:00) + onReady(解析参数) → 合并进 ensureLoaded() + .onAppear
 */

// 解析路由参数（混合版：从 takePending 拿到的 raw String 解析）
private func parseScheduleParam(raw: String): (Int64, Int64, Bool, String) {
    if (raw.size == 0) { return (0, 0, false, "") }
    let parts = raw.split(":")
    if (parts.size < 4) { return (0, 0, false, "") }
    var peerId: Int64 = 0
    var peerHash: Int64 = 0
    var isChannel: Bool = false
    var title: String = ""
    try { peerId = Int64.parse(parts[0]) } catch (_: Exception) {}
    try { peerHash = Int64.parse(parts[1]) } catch (_: Exception) {}
    isChannel = parts[2] == "true"
    title = parts[3]
    return (peerId, peerHash, isChannel, title)
}

// 计算预约 Unix 时间戳（基于选定日期 + 小时 + 分钟）
// 简化计算：取当前时间基准 + 天数差偏移 + 小时+分钟偏移（UTC 基准）
private func computeScheduleTimestamp(now: DateTime, dayOffset: Int32, hour: Int32, minute: Int32): Int32 {
    let todayTs = now.toUnixTimeStamp().toSeconds()
    // 今天 UTC 零点 = 当前时间戳向下取整到天（86400 秒）
    let dayStartTs = todayTs - (todayTs % 86400)
    let targetTs = dayStartTs + Int64(dayOffset) * 86400 + Int64(hour) * 3600 + Int64(minute) * 60
    // 必须在未来 5 分钟后
    let minTs = todayTs + 300
    let finalTs = if (targetTs < minTs) { minTs } else { targetTs }
    // 安全截断为 Int32 范围（约 2038 年前有效）
    return Int32(finalTs & 0x7FFFFFFF)
}

@HybridComponentEntry
@Component
public class ScheduleVoiceChatPage {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 路由参数
    @State var peerId: Int64 = 0
    @State var peerAccessHash: Int64 = 0
    @State var isChannel: Bool = false
    @State var chatTitle: String = ""

    // 日期选择：偏移天数 (0=今天, 1=明天, ..., 6=后天等)
    @State var selectedDayOffset: Int32 = 1
    // 时间选择：小时 (0-23), 分钟 slot (0=0min, 1=15min, 2=30min, 3=45min)
    @State var selectedHour: Float64 = 18.0
    @State var selectedMinuteSlot: Float64 = 0.0

    // 选定的 DatePicker 日期（用于显示）
    @State var selectedDate: DateTime = DateTime.now()

    // 提交状态
    @State var isSubmitting: Bool = false
    @State var scheduledCallId: Int64 = 0
    @State var errorMsg: String = ""

    // 日期 picker 是否展开
    @State var showDatePicker: Bool = false

    @State var loaded: Bool = false

    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // 解析路由参数（原 onReady 逻辑）
        let raw = takePending("ScheduleVoiceChatPage")
        let (pId, pHash, isCh, ttl) = parseScheduleParam(raw)
        this.peerId = pId
        this.peerAccessHash = pHash
        this.isChannel = isCh
        this.chatTitle = ttl
        Hilog.info(0, "CjTelegram", "[ScheduleVoiceChatPage] appear peerId=${this.peerId}")
        // 默认选明天 18:00（原 aboutToAppear 逻辑）
        let now = DateTime.now()
        let tomorrow = DateTime.of(
            year: now.year,
            month: now.month,
            dayOfMonth: now.dayOfMonth + 1
        )
        this.selectedDate = tomorrow
    }

    // 计算当前分钟数（从 slot Float64 -> Int32）
    private func minuteFromSlot(): Int32 {
        let slot = Int32(this.selectedMinuteSlot)
        if (slot == 1) { return 15 }
        if (slot == 2) { return 30 }
        if (slot == 3) { return 45 }
        return 0
    }

    private func minuteFromSlotStr(): String {
        let slot = Int32(this.selectedMinuteSlot)
        if (slot == 1) { return "15" }
        if (slot == 2) { return "30" }
        if (slot == 3) { return "45" }
        return "00"
    }

    // 格式化时间预览
    private func timePreview(): String {
        let h = Int32(this.selectedHour)
        let hh = if (h < 10) { "0${h}" } else { "${h}" }
        let mm = minuteFromSlotStr()
        return "${hh}:${mm}"
    }

    // 日期标签
    private func dateLabel(): String {
        match (this.selectedDayOffset) {
            case 0 => "Today"
            case 1 => "Tomorrow"
            case _ => "In ${this.selectedDayOffset} days"
        }
    }

    private func handleSchedule(): Unit {
        if (this.peerId <= 0) { return }
        if (this.isSubmitting) { return }

        let now = DateTime.now()
        let ts = computeScheduleTimestamp(now, this.selectedDayOffset, Int32(this.selectedHour), this.minuteFromSlot())
        let pId = this.peerId
        let pHash = this.peerAccessHash
        let isCh = this.isChannel
        let ttl = this.chatTitle
        let schedTs = ts

        launch { this.isSubmitting = true }

        let _ = spawn {
            let svc = getCallsService()
            let result = svc.createGroupCall(pId, pHash, isCh, ttl, schedTs)
            match (result) {
                case Some(info) =>
                    let cId = info.callId
                    launch {
                        this.scheduledCallId = cId
                        this.isSubmitting = false
                        this.errorMsg = ""
                    }
                    Hilog.info(0, "CjTelegram", "[ScheduleVoiceChatPage] scheduled callId=${cId} at ts=${schedTs}")
                case None =>
                    launch {
                        this.isSubmitting = false
                        this.errorMsg = "Failed to schedule the call. Please try again."
                    }
                    Hilog.info(0, "CjTelegram", "[ScheduleVoiceChatPage] createGroupCall failed")
            }
        }
    }

    private func dayLabel(dayOff: Int32): String {
        match (dayOff) {
            case 0 => "Today"
            case 1 => "Tmrw"
            case 2 => "+2d"
            case 3 => "+3d"
            case 4 => "+4d"
            case 5 => "+5d"
            case 6 => "+6d"
            case _ => ""
        }
    }

    // ---- Day selector row ----
    @Builder
    func buildDaySelector() {
        Row {
            Column {
                Text(this.dayLabel(0))
                    .fontSize(13)
                    .fontColor(if (0 == this.selectedDayOffset) { 0xFFFFFF } else { 0x8E8E93 })
                    .fontWeight(if (0 == this.selectedDayOffset) { FontWeight.Bold } else { FontWeight.Normal })
            }
            .padding(left: 10, right: 10, top: 8, bottom: 8)
            .backgroundColor(if (0 == this.selectedDayOffset) { 0x317AFF } else { 0x2AFFFFFF })
            .borderRadius(8)
            .margin(right: 6)
            .onClick({ _evt => launch { this.selectedDayOffset = 0 } })

            Column {
                Text(this.dayLabel(1))
                    .fontSize(13)
                    .fontColor(if (1 == this.selectedDayOffset) { 0xFFFFFF } else { 0x8E8E93 })
                    .fontWeight(if (1 == this.selectedDayOffset) { FontWeight.Bold } else { FontWeight.Normal })
            }
            .padding(left: 10, right: 10, top: 8, bottom: 8)
            .backgroundColor(if (1 == this.selectedDayOffset) { 0x317AFF } else { 0x2AFFFFFF })
            .borderRadius(8)
            .margin(right: 6)
            .onClick({ _evt => launch { this.selectedDayOffset = 1 } })

            Column {
                Text(this.dayLabel(2))
                    .fontSize(13)
                    .fontColor(if (2 == this.selectedDayOffset) { 0xFFFFFF } else { 0x8E8E93 })
                    .fontWeight(if (2 == this.selectedDayOffset) { FontWeight.Bold } else { FontWeight.Normal })
            }
            .padding(left: 10, right: 10, top: 8, bottom: 8)
            .backgroundColor(if (2 == this.selectedDayOffset) { 0x317AFF } else { 0x2AFFFFFF })
            .borderRadius(8)
            .margin(right: 6)
            .onClick({ _evt => launch { this.selectedDayOffset = 2 } })

            Column {
                Text(this.dayLabel(3))
                    .fontSize(13)
                    .fontColor(if (3 == this.selectedDayOffset) { 0xFFFFFF } else { 0x8E8E93 })
                    .fontWeight(if (3 == this.selectedDayOffset) { FontWeight.Bold } else { FontWeight.Normal })
            }
            .padding(left: 10, right: 10, top: 8, bottom: 8)
            .backgroundColor(if (3 == this.selectedDayOffset) { 0x317AFF } else { 0x2AFFFFFF })
            .borderRadius(8)
            .margin(right: 6)
            .onClick({ _evt => launch { this.selectedDayOffset = 3 } })

            Column {
                Text(this.dayLabel(4))
                    .fontSize(13)
                    .fontColor(if (4 == this.selectedDayOffset) { 0xFFFFFF } else { 0x8E8E93 })
                    .fontWeight(if (4 == this.selectedDayOffset) { FontWeight.Bold } else { FontWeight.Normal })
            }
            .padding(left: 10, right: 10, top: 8, bottom: 8)
            .backgroundColor(if (4 == this.selectedDayOffset) { 0x317AFF } else { 0x2AFFFFFF })
            .borderRadius(8)
            .margin(right: 6)
            .onClick({ _evt => launch { this.selectedDayOffset = 4 } })

            Column {
                Text(this.dayLabel(5))
                    .fontSize(13)
                    .fontColor(if (5 == this.selectedDayOffset) { 0xFFFFFF } else { 0x8E8E93 })
                    .fontWeight(if (5 == this.selectedDayOffset) { FontWeight.Bold } else { FontWeight.Normal })
            }
            .padding(left: 10, right: 10, top: 8, bottom: 8)
            .backgroundColor(if (5 == this.selectedDayOffset) { 0x317AFF } else { 0x2AFFFFFF })
            .borderRadius(8)
            .margin(right: 6)
            .onClick({ _evt => launch { this.selectedDayOffset = 5 } })

            Column {
                Text(this.dayLabel(6))
                    .fontSize(13)
                    .fontColor(if (6 == this.selectedDayOffset) { 0xFFFFFF } else { 0x8E8E93 })
                    .fontWeight(if (6 == this.selectedDayOffset) { FontWeight.Bold } else { FontWeight.Normal })
            }
            .padding(left: 10, right: 10, top: 8, bottom: 8)
            .backgroundColor(if (6 == this.selectedDayOffset) { 0x317AFF } else { 0x2AFFFFFF })
            .borderRadius(8)
            .margin(right: 6)
            .onClick({ _evt => launch { this.selectedDayOffset = 6 } })
        }
        .width(100.percent)
        .padding(left: 4, right: 4)
    }

    public func build() {
        Column {
            // 顶部导航栏
            Row {
                Button(trSource("Cancel"))
                    .backgroundColor(Color.Transparent)
                    .fontColor(0x8E8E93)
                    .fontSize(16)
                    .onClick({ _evt => routerPop() })
                Column {}.layoutWeight(1)
                Text(trSource("Schedule"))
                    .fontSize(17)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
                Column {}.layoutWeight(1)
            }
            .width(100.percent)
            .padding(left: 12, right: 12, top: 12, bottom: 8)

            // 分隔线
            Column {}
                .width(100.percent)
                .height(1)
                .backgroundColor(0x1AFFFFFF)

            Column {
                // 日历图标
                Text("📅")
                    .fontSize(48)
                    .margin(top: 28, bottom: 12)

                // 标题
                Text("Schedule Voice/Video Chat")
                    .fontSize(20)
                    .fontColor(0xFFFFFF)
                    .fontWeight(FontWeight.Medium)
                    .margin(bottom: 6)

                Text(if (this.chatTitle.size > 0) { this.chatTitle } else { "Group Call" })
                    .fontSize(14)
                    .fontColor(0x8E8E93)
                    .margin(bottom: 28)

                // ---- 日期选择区 ----
                Column {
                    Text(trSource("Date"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 10)
                        .alignSelf(ItemAlign.Start)

                    this.buildDaySelector()

                    // DatePicker 折叠/展开
                    Row {
                        Text(this.dateLabel())
                            .fontSize(15)
                            .fontColor(0x317AFF)
                        Text(" (pick specific date)")
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                    }
                    .margin(top: 8)
                    .onClick({ _evt =>
                        let v = !this.showDatePicker
                        launch { this.showDatePicker = v }
                    })

                    if (this.showDatePicker) {
                        DatePicker(
                            start: DateTime.now(),
                            end: DateTime.of(year: DateTime.now().year + 1,
                                              month: DateTime.now().month,
                                              dayOfMonth: DateTime.now().dayOfMonth),
                            selected: this.selectedDate
                        )
                        .onDateChange({ res =>
                            let nowCheck = DateTime.now()
                            // 计算天数差近似（忽略月份跨越，简化计算）
                            let diff = Int32(res.dayOfMonth) - Int32(nowCheck.dayOfMonth)
                            let clampedDiff: Int32 = if (diff < 0) { 0 } else { if (diff > 6) { 6 } else { diff } }
                            let newDate = DateTime.of(year: res.year, month: res.month, dayOfMonth: res.dayOfMonth)
                            launch {
                                this.selectedDayOffset = clampedDiff
                                this.selectedDate = newDate
                            }
                        })
                        .margin(top: 8)
                        .height(200)
                    }
                }
                .width(100.percent)
                .padding(16)
                .backgroundColor(0x1AFFFFFF)
                .borderRadius(12)
                .margin(bottom: 16)

                // ---- 时间选择区 ----
                Column {
                    Text(trSource("Time"))
                        .fontSize(13)
                        .fontColor(0x8E8E93)
                        .margin(bottom: 12)
                        .alignSelf(ItemAlign.Start)

                    // 显示当前选定时间
                    Text(this.timePreview())
                        .fontSize(36)
                        .fontColor(0xFFFFFF)
                        .fontWeight(FontWeight.Medium)
                        .margin(bottom: 16)

                    // 小时 Slider (0-23)
                    Row {
                        Text("Hour")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .width(50)
                        Slider(value: this.selectedHour, min: 0.0, max: 23.0, step: 1.0)
                            .layoutWeight(1)
                            .onChange({ val: Float64, _mode: SliderChangeMode =>
                                launch { this.selectedHour = val }
                            })
                        Text(if (Int32(this.selectedHour) < 10) { "0${Int32(this.selectedHour)}" } else { "${Int32(this.selectedHour)}" })
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .width(32)
                            .textAlign(TextAlign.End)
                    }
                    .width(100.percent)
                    .margin(bottom: 12)

                    // 分钟 Slider (4档: 0/15/30/45)
                    Row {
                        Text("Min")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .width(50)
                        Slider(value: this.selectedMinuteSlot, min: 0.0, max: 3.0, step: 1.0)
                            .layoutWeight(1)
                            .onChange({ val: Float64, _mode: SliderChangeMode =>
                                launch { this.selectedMinuteSlot = val }
                            })
                        Text(this.minuteFromSlotStr())
                            .fontSize(14)
                            .fontColor(0xFFFFFF)
                            .width(32)
                            .textAlign(TextAlign.End)
                    }
                    .width(100.percent)
                }
                .width(100.percent)
                .padding(16)
                .backgroundColor(0x1AFFFFFF)
                .borderRadius(12)
                .margin(bottom: 24)

                // ---- 已预约状态 ----
                if (this.scheduledCallId != 0) {
                    Column {
                        Text("✅")
                            .fontSize(32)
                            .margin(bottom: 8)
                        Text("Voice chat scheduled")
                            .fontSize(16)
                            .fontColor(0x34C759)
                            .fontWeight(FontWeight.Medium)
                        Text("${this.dateLabel()} at ${this.timePreview()}")
                            .fontSize(14)
                            .fontColor(0x8E8E93)
                            .margin(top: 4)
                    }
                    .width(100.percent)
                    .padding(20)
                    .backgroundColor(0x1A34C759)
                    .borderRadius(12)
                    .alignItems(HorizontalAlign.Center)
                    .margin(bottom: 16)
                }

                // ---- 错误信息 ----
                if (this.errorMsg.size > 0) {
                    Text(this.errorMsg)
                        .fontSize(14)
                        .fontColor(0xFF3B30)
                        .textAlign(TextAlign.Center)
                        .margin(bottom: 16)
                }

                Column {}.layoutWeight(1)

                // ---- 提交按钮 ----
                if (this.scheduledCallId == 0) {
                    Button(if (this.isSubmitting) { "Scheduling..." } else { "Schedule for ${this.timePreview()}" })
                        .width(100.percent)
                        .height(52)
                        .borderRadius(12)
                        .backgroundColor(if (this.isSubmitting) { 0x8E8E93 } else { 0x317AFF })
                        .fontColor(0xFFFFFF)
                        .fontSize(17)
                        .margin(bottom: 16)
                        .onClick({ _evt =>
                            if (!this.isSubmitting && this.peerId > 0) {
                                this.handleSchedule()
                            }
                        })
                } else {
                    Button(trSource("Done"))
                        .width(100.percent)
                        .height(52)
                        .borderRadius(12)
                        .backgroundColor(0x34C759)
                        .fontColor(0xFFFFFF)
                        .fontSize(17)
                        .margin(bottom: 16)
                        .onClick({ _evt => routerPop() })
                }
            }
            .width(100.percent)
            .layoutWeight(1)
            .padding(left: 20, right: 20, top: 8)
            .alignItems(HorizontalAlign.Center)
        }
        .width(100.percent)
        .height(100.percent)
        .backgroundColor(0xFF1C1C1E)
        .onAppear({ => this.ensureLoaded() })
    }
}
