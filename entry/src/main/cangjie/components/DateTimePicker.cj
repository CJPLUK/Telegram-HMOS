/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 */
package ohos_app_cangjie_entry.components

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import std.time.*

/**
 * DateTimePicker — 可复用的日期 / 时间滚轮选择组件 (Phase P2-414)
 *
 * 对应 iOS Telegram-iOS submodules/DatePickerNode：滚轮式日期 / 时间选择，
 * 带确认 / 取消按钮。用途：定时发送、静音到某时刻、自毁定时等"选时间点 / 时长"UI。
 *
 * ──────────────────────── 实现策略（以 cangjie-kb 实证为准） ────────────────────────
 * 鸿蒙 ArkUI（仓颉绑定）提供原生 `DatePicker` 日期滚轮组件，但**未提供** TimePicker
 * 的仓颉绑定 doc。为避免臆造 API，本组件：
 *   - "date" / "datetime" 模式的日期列：用实证的原生 `DatePicker`
 *       DatePicker(start!: ?DateTime, end!: ?DateTime, selected!: ?DateTime)
 *       .onDateChange(callback)  —— 回调参数 res 是一个 std.time.DateTime，
 *       读 res.year / res.month / res.dayOfMonth 得到选中的日期。
 *   - "time" / "datetime" 模式的时分列：用实证的原生 `TextPicker`
 *       TextPicker(range!: ?Array<String>, selected!: ?UInt32, value!: ?String)
 *       .onChange(callback)      —— 回调 (String, UInt32) -> Unit，UInt32 为选中索引。
 *       小时列 range = ["00".."23"]，分钟列 range = ["00".."59"]。
 *
 * unix ↔ DateTime 互转（实证 std.time.DateTime / Duration）：
 *   - unix → DateTime：DateTime.ofEpoch(second: unixSec, nanosecond: 0)
 *       （UnixEpoch 起算的 UTC 瞬时；再 .inLocal() 取本地时区视图供 picker 显示）
 *   - DateTime → unix：dt.toUnixTimeStamp().toSeconds(): Int64
 *       （toUnixTimeStamp() 返回自 UnixEpoch 的 Duration，toSeconds() 取整秒）
 *   两者在"绝对瞬时"层面无歧义、可往返一致。
 *
 * ──────────────────────── 用法示例 ────────────────────────
 *   @Component
 *   class ScheduleSheet {
 *       @State var nowSec: Int64 = DateTime.now().toUnixTimeStamp().toSeconds()
 *       func build() {
 *           DateTimePicker(
 *               initialUnixSec: this.nowSec,
 *               mode: "datetime",
 *               onConfirm: { picked => /* 用 picked（unix 秒）安排定时发送 */ },
 *               onCancel:  { => /* 关闭面板 */ }
 *           )
 *       }
 *   }
 *
 * @Component 基本类型参数用普通 var（非 @Prop）—— 见 CodeInputViewComponent / UndoToast 约定。
 * 命名参数用 `!`。顶层辅助名加 `dtp` 前缀避免包级冲突。
 */

/** 一天的秒数。 */
let DTP_SECONDS_PER_DAY: Int64 = 86400
/** 一小时秒数。 */
let DTP_SECONDS_PER_HOUR: Int64 = 3600
/** 一分钟秒数。 */
let DTP_SECONDS_PER_MINUTE: Int64 = 60

/**
 * unix 秒 → 本地时区 DateTime。
 * DateTime.ofEpoch(second:, nanosecond:) 从 UnixEpoch 构造瞬时，inLocal() 取本地视图。
 */
func dtpUnixToDate(unixSec: Int64): DateTime {
    DateTime.ofEpoch(second: unixSec, nanosecond: 0).inLocal()
}

/**
 * DateTime → unix 秒。toUnixTimeStamp() 返回自 UnixEpoch 的 Duration，toSeconds() 取整秒。
 */
func dtpDateToUnix(dt: DateTime): Int64 {
    dt.toUnixTimeStamp().toSeconds()
}

/** 两位补零（小时 / 分钟显示）。 */
func dtpPad2(v: Int64): String {
    if (v < 10) {
        "0" + v.toString()
    } else {
        v.toString()
    }
}

/** 生成 ["00".."count-1"] 的两位字符串列表，供 TextPicker 的 range 使用。 */
func dtpRange2(count: Int64): Array<String> {
    let arr = Array<String>(count, repeat: "")
    var i: Int64 = 0
    while (i < count) {
        arr[i] = dtpPad2(i)
        i++
    }
    arr
}

/**
 * 常用时长预设（给静音 / 自毁定时用）。
 * 返回 (label, seconds) 列表：15 分钟 / 1 小时 / 8 小时 / 1 天。
 */
public func dtpPresetDurations(): Array<(String, Int64)> {
    [
        ("15 min", 15 * DTP_SECONDS_PER_MINUTE),
        ("1 hour", DTP_SECONDS_PER_HOUR),
        ("8 hours", 8 * DTP_SECONDS_PER_HOUR),
        ("1 day", DTP_SECONDS_PER_DAY)
    ]
}

/**
 * DateTimePicker — 日期 / 时间滚轮选择组件。
 *
 * 参数（普通 var）：
 *   - initialUnixSec: 初始选中时间点（unix 秒）。
 *   - mode:           "date" | "time" | "datetime"，控制显示哪些滚轮。
 *   - minUnixSec / maxUnixSec: 可选范围下 / 上界（unix 秒）；<= 0 视为不限制。
 *   - onConfirm:      点确认回调，回传选定的 unix 秒。
 *   - onCancel:       点取消回调。
 */
@Component
public class DateTimePicker {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    var initialUnixSec: Int64 = 0
    var mode: String = "datetime"
    var minUnixSec: Int64 = 0
    var maxUnixSec: Int64 = 0
    var onConfirm: (Int64) -> Unit = { _ => }
    var onCancel: () -> Unit = { => }
    // S2-70: label of the confirm button for the currently composed time; empty → "Confirm".
    var confirmLabel: (Int64) -> String = { _ => "" }

    // ==================== 渲染状态（@State 驱动重绘） ====================
    // 当前选中的日期部分（年月日），来自 DatePicker.onDateChange。
    @State var selDate: DateTime = DateTime.now()
    // 当前选中的小时 / 分钟（0..23 / 0..59），来自 TextPicker.onChange。
    @State var selHour: Int64 = 0
    @State var selMinute: Int64 = 0

    public override func aboutToAppear(): Unit {
        let initDt = dtpUnixToDate(this.initialUnixSec)
        this.selDate = initDt
        this.selHour = initDt.hour
        this.selMinute = initDt.minute
    }

    /** 确认键文案：调用方给的动态文案优先（读 selDate/selHour/selMinute，随选择刷新）。 */
    func confirmButtonText(): String {
        let custom = this.confirmLabel(this.composedUnix())
        return if (custom.size > 0) { custom } else { trSource("Confirm") }
    }

    /** 是否需要日期列。 */
    func wantsDate(): Bool {
        this.mode == "date" || this.mode == "datetime"
    }

    /** 是否需要时分列。 */
    func wantsTime(): Bool {
        this.mode == "time" || this.mode == "datetime"
    }

    /**
     * 把当前选中的日期 + 时分组合回一个 DateTime，再换算为 unix 秒。
     * 用实证的 DateTime.of(month: Month 重载)：selDate.month 是一个 Month 枚举，
     * 直接喂回 of() 的 Month 重载，避免依赖已废弃的 monthValue。
     */
    func composedUnix(): Int64 {
        let d = this.selDate
        let hour = if (this.wantsTime()) { this.selHour } else { d.hour }
        let minute = if (this.wantsTime()) { this.selMinute } else { d.minute }
        let combined = DateTime.of(
            year: d.year,
            month: d.month,
            dayOfMonth: d.dayOfMonth,
            hour: hour,
            minute: minute,
            second: 0
        )
        var sec = dtpDateToUnix(combined)
        // 夹到 [min, max]（<= 0 视为该侧不限制）。
        if (this.minUnixSec > 0 && sec < this.minUnixSec) {
            sec = this.minUnixSec
        }
        if (this.maxUnixSec > 0 && sec > this.maxUnixSec) {
            sec = this.maxUnixSec
        }
        sec
    }

    /** DatePicker 的起始边界：有 min 用 min，否则 1970-01-01。 */
    func datePickerStart(): DateTime {
        if (this.minUnixSec > 0) {
            dtpUnixToDate(this.minUnixSec)
        } else {
            DateTime.of(year: 1970, month: 1, dayOfMonth: 1)
        }
    }

    /** DatePicker 的结束边界：有 max 用 max，否则 2100-12-31。 */
    func datePickerEnd(): DateTime {
        if (this.maxUnixSec > 0) {
            dtpUnixToDate(this.maxUnixSec)
        } else {
            DateTime.of(year: 2100, month: 12, dayOfMonth: 31)
        }
    }

    /** 日期滚轮（原生 DatePicker）。start / end 由可选范围推导，selected 为当前选中日期。 */
    @Builder
    func datePickerColumn() {
        DatePicker(
            start: this.datePickerStart(),
            end: this.datePickerEnd(),
            selected: this.selDate
        )
            .onDateChange({ res =>
                // res 是一个 DateTime；保留已选的时分，仅更新年月日。
                this.selDate = DateTime.of(
                    year: res.year,
                    month: res.month,
                    dayOfMonth: res.dayOfMonth,
                    hour: this.selHour,
                    minute: this.selMinute,
                    second: 0
                )
            })
    }

    /** 时分滚轮（两列 TextPicker：小时 + 分钟）。 */
    @Builder
    func timePickerColumns() {
        Row {
            TextPicker(
                range: dtpRange2(24),
                selected: UInt32(this.selHour)
            )
                .canLoop(true)
                .width(120)
                .onChange({ _, idx =>
                    this.selHour = Int64(idx)
                })
            TextPicker(
                range: dtpRange2(60),
                selected: UInt32(this.selMinute)
            )
                .canLoop(true)
                .width(120)
                .onChange({ _, idx =>
                    this.selMinute = Int64(idx)
                })
        }
    }

    public func build() {
        Column(space: 8) {
            if (this.wantsDate()) {
                this.datePickerColumn()
            }
            if (this.wantsTime()) {
                this.timePickerColumns()
            }
            // 确认 / 取消按钮行。
            Row(space: 12) {
                Button(trSource("Cancel"))
                    .height(40)
                    .padding(left: 20, right: 20)
                    .backgroundColor(0xE5E5EA)
                    .fontColor(0x000000)
                    .onClick({ _ =>
                        this.onCancel()
                    })
                Button(this.confirmButtonText())
                    .height(40)
                    .padding(left: 20, right: 20)
                    .backgroundColor(0x007AFF)
                    .fontColor(0xFFFFFF)
                    .onClick({ _ =>
                        this.onConfirm(this.composedUnix())
                    })
            }
            .margin(top: 12)
        }
        .padding(16)
        .width(100.percent)
    }
}
