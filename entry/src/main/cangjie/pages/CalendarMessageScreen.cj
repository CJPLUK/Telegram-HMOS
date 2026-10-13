package ohos_app_cangjie_entry.pages

import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, currentPresentationStrings}

import ohos_app_cangjie_entry.core.storage.trSource
import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import kit.PerformanceAnalysisKit.Hilog
import std.time.DateTime
import std.core.Duration
import ohos_app_cangjie_entry.services.{
    getCalendarMessageScreenService,
    getSelectedChatId,
    getSelectedChatPeerType,
    getAppFilesDir,
    getFileDownloadService,
    CalendarPeriodsResult,
    DayMediaResult,
    DeleteRangeResult
}
import ohos_app_cangjie_entry.core.mtproto.{
    TLMessage,
    SearchResultsCalendarPeriod
}
import ohos_app_cangjie_entry.utils.{localDayIndexOf, decodeTinyThumbnailToDataUrl}
import kit.CoreFileKit.*
import std.collection.{ArrayList, HashMap}
import kit.LocalizationKit.getCalendar
import ohos.i18n.System as I18nSystem
import ohos.business_exception.BusinessException
import ohos_app_cangjie_entry.router.*
import ohos_app_cangjie_entry.app.{getSafeAreaTop, getSafeAreaBottom}

/**
 * MonthEntry — 月份条目，存储按月翻页/滚动（P2-097）的月份序列
 */
public struct MonthEntry {
    public var year: Int32
    public var month: Int32
    public var dayCount: Int32
    public var indexInList: Int32

    public init(y: Int32, m: Int32, d: Int32, i: Int32) {
        this.year = y
        this.month = m
        this.dayCount = d
        this.indexInList = i
    }
}

/**
 * CalendarMessageScreen — 日历跳转页（P2-095 / P2-096 / P2-097 / P2-098 / P2-099）
 *
 * 对应 iOS CalendarMessageScreen.swift：
 * - P2-095: firstWeekday 本地化（按系统 locale 周首日）、星期名本地化
 * - P2-096: messages.getSearchResultsCalendar → 有消息的天高亮显示圆点
 * - P2-097: 多月连续滚动视图（List 渲染月份序列，上界当前月，下界 2013-08）
 * - P2-098: 选择模式 → 点起始/结束天选区间 → deleteHistory(min_date/max_date) 区间删除；清空历史
 * - P2-099: 长按某天 → 拉取该天媒体 → 缩略 Grid 预览
 *
 * 调用链：
 *   P2-096: aboutToAppear → loadCalendarPeriods(peerType, peerId)
 *             → MessagesGetSearchResultsCalendar → markedDays
 *   P2-097: aboutToAppear → buildMonthList() → months[]
 *             locale firstWeekday → getWeekdayOffsetForMonth()
 *   P2-098: tapRangeStart → tapRangeEnd → confirmDeleteRange
 *             → deleteHistoryRange(minDate, maxDate) / clearHistory()
 *   P2-099: onDayCellLongPress(day) → searchDayMedia → showMediaPreview
 */
@HybridComponentEntry
@Component
public class CalendarMessageScreen {
    @StorageLink["presentationStrings"] var sourceLocalizationPresentation: PresentationStringsSnapshot = currentPresentationStrings()
    // 混合迁移：删除 @Consume var pageStack（NavDestination 由 ArkTS 壳提供，导航经 router.*）

    // P2-097: 多月连续滚动 — 月份序列（从当前月向历史方向排列）
    @State var months: Array<MonthEntry> = Array<MonthEntry>(0, { _ => MonthEntry(0, 0, 0, 0) })

    // P2-095: locale 首周日（ICU: 1=Sun, 2=Mon... 7=Sat）
    @State var firstWeekday: Int32 = 2

    @State var isLoading: Bool = false
    @State var statusMessage: String = ""
    @State var selectedDay: Int32 = 0
    @State var selectedMonthIdx: Int32 = -1

    // P2-096: 有消息日期标记 — 从 getSearchResultsCalendar 加载
    @State var markedTimestamps: Array<Int32> = Array<Int32>(0, repeat: 0)
    // CG-02 / iOS MonthModel.mediaByDay：本地日序号（自纪元起的本地日）→ 该日首条图片/视频消息
    @State var dayMediaByIndex: HashMap<Int64, TLMessage> = HashMap<Int64, TLMessage>()
    // 本地日序号 → 缩略图 URI（先 strippedThumb data URL，下载完 "m" 档后换成 file://）
    @State var dayThumbUris: HashMap<Int64, String> = HashMap<Int64, String>()

    // P2-098: 选择模式 — 区间删除 / 清空历史
    @State var selectionMode: Bool = false
    @State var rangeStartDay: Int32 = 0
    @State var rangeEndDay: Int32 = 0
    @State var rangeMonthIdx: Int32 = -1
    @State var isDeleting: Bool = false
    @State var showClearConfirm: Bool = false

    // P2-099: 长按媒体预览
    @State var showMediaPreview: Bool = false
    @State var previewDay: Int32 = 0
    @State var previewMonth: Int32 = 0
    @State var previewYear: Int32 = 0
    @State var previewMedia: Array<TLMessage> = Array<TLMessage>(0, { _ => TLMessage() })
    @State var isLoadingPreview: Bool = false
    @State var longPressTimerActive: Bool = false
    @State var longPressTargetDay: Int32 = 0
    @State var longPressTargetMonthIdx: Int32 = -1
    @State var touchStartX: Float64 = 0.0
    @State var touchStartY: Float64 = 0.0

    @State var loaded: Bool = false

    // 混合迁移：aboutToAppear 有实逻辑 → 移入 ensureLoaded()，经根容器 .onAppear 触发
    private func ensureLoaded(): Unit {
        if (this.loaded) { return }
        this.loaded = true
        // P2-095: 读取系统 locale 获取 firstWeekday
        this.loadLocaleSettings()
        // P2-097: 构建多月序列
        this.buildMonthList()
        // P2-096: 加载日历聚合周期（有消息日期标记）
        this.triggerLoadCalendarPeriods()
    }

    // P2-095: 从系统 locale 读取 firstWeekday（iOS Calendar.current.firstWeekday）；
    // 星期名不走系统 locale，而是跟随应用语言的 PresentationStrings（见 weekdayHeaderName）
    private func loadLocaleSettings(): Unit {
        var locale = "en-US"
        try {
            locale = I18nSystem.getAppPreferredLanguage()
        } catch (_: BusinessException) {
            locale = "en-US"
        }
        var fw: Int32 = 2
        try {
            let cal = getCalendar(locale)
            fw = cal.getFirstDayOfWeek()
        } catch (_: BusinessException) {
            fw = 2
        }
        // ICU convention: 1=Sun, 2=Mon ... 7=Sat
        // Clamp to valid range
        if (fw < 1 || fw > 7) { fw = 2 }
        this.firstWeekday = fw
    }

    // CG-02 / P2-095: 星期名表头跟随应用语言（iOS CalendarMessageScreen.gridDayName →
    // strings.Calendar_ShortSun…Calendar_ShortSat，英文为 S M T W T F S），
    // 列 column 从 firstWeekday 起算；每次 build 读 PresentationStrings 快照，切语言即刷新。
    private func weekdayHeaderName(column: Int32): String {
        // ICU 0-based: 0=Sun,1=Mon,...6=Sat
        let icuIdx = ((this.firstWeekday - 1) + column) % 7
        let strings = this.sourceLocalizationPresentation
        if (icuIdx == 0) { return strings.getOr("Calendar.ShortSun", "S") }
        if (icuIdx == 1) { return strings.getOr("Calendar.ShortMon", "M") }
        if (icuIdx == 2) { return strings.getOr("Calendar.ShortTue", "T") }
        if (icuIdx == 3) { return strings.getOr("Calendar.ShortWed", "W") }
        if (icuIdx == 4) { return strings.getOr("Calendar.ShortThu", "T") }
        if (icuIdx == 5) { return strings.getOr("Calendar.ShortFri", "F") }
        return strings.getOr("Calendar.ShortSat", "S")
    }

    // P2-097: 构建多月序列，从当前月向历史方向，下界 2013-08，上界当前月，最多 240 个月
    private func buildMonthList(): Unit {
        let todayTs = localTodayTs()
        let todayYM = timestampToYearMonth(todayTs)
        var currentYear = todayYM[0]
        var currentMonth = todayYM[1]

        var list = ArrayList<MonthEntry>()
        var idx: Int32 = 0
        var i = 0
        while (i < 240) {
            // Check lower bound: 2013-08
            if (currentYear < 2013) { break }
            if (currentYear == 2013 && currentMonth < 8) { break }

            let dc = daysInMonth(currentYear, currentMonth)
            list.add(MonthEntry(currentYear, currentMonth, dc, idx))
            idx += 1

            // Go to previous month
            if (currentMonth == 1) {
                currentMonth = 12
                currentYear -= 1
            } else {
                currentMonth -= 1
            }
            i += 1
        }

        let n = list.size
        var arr = Array<MonthEntry>(n, { _ => MonthEntry(0, 0, 0, 0) })
        var k: Int64 = 0
        while (k < n) {
            arr[k] = list[k]
            k += 1
        }
        this.months = arr
    }

    // P2-096: 触发日历聚合加载（后台线程）
    private func triggerLoadCalendarPeriods(): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        let _ = spawn {
            try {
                let svc = getCalendarMessageScreenService()
                let calResult = svc.loadCalendarPeriods(peerType, peerId)
                if (calResult.errorMessage.size == 0 && calResult.periods.size > 0) {
                    let periods = calResult.periods
                    let n = periods.size
                    let timestamps = Array<Int32>(n, repeat: 0)
                    var i: Int64 = 0
                    while (i < n) {
                        timestamps[i] = periods[i].date
                        i += 1
                    }
                    // iOS CalendarMessageScreen.reloadMediaInfo：按 message.timestamp 落到本地日
                    // （Calendar.current 当天 00:00 ~ 次日 00:00），每天取首条含 image/file 的消息
                    let mediaMap = HashMap<Int64, TLMessage>()
                    let thumbMap = HashMap<Int64, String>()
                    let pending = ArrayList<(Int64, TLMessage)>()
                    for (msg in calResult.messages) {
                        if (msg.photoId == 0 && msg.documentId == 0) { continue }
                        let dayIdx = localDayIndexOf(Int64(msg.date))
                        if (mediaMap.contains(dayIdx)) { continue }
                        mediaMap[dayIdx] = msg
                        if (msg.strippedThumb.size > 0) {
                            thumbMap[dayIdx] = decodeTinyThumbnailToDataUrl(msg.strippedThumb)
                        }
                        pending.add((dayIdx, msg))
                    }
                    launch {
                        this.markedTimestamps = timestamps
                        this.dayMediaByIndex = mediaMap
                        this.dayThumbUris = thumbMap
                    }
                    this.downloadDayThumbnails(pending)
                }
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[CalendarMsgScreen] triggerLoadCalendarPeriods exception")
            }
        }
    }

    // 本地日序号（自纪元起的本地日），与 localDayIndexOf(message.date) 同口径
    private func dayIndexOf(year: Int32, month: Int32, day: Int32): Int64 {
        return Int64(dateToTimestamp(year, month, day)) / 86400
    }

    private func isTodayInMonth(day: Int32, entry: MonthEntry): Bool {
        let todayTs = localTodayTs()
        let todayYM = timestampToYearMonth(todayTs)
        return entry.year == todayYM[0] && entry.month == todayYM[1] && day == timestampToDay(todayTs)
    }

    /**
     * iOS MediaPreviewView：按 DirectMediaImageCache 取 100px 缩略图；这里与 SharedMediaPage /
     * ChatRoomViewModel 共用落盘位置（photos/photo_<id>_m.jpg、thumbs/thumb_<docId>.jpg）。
     * 顺序下载，每张就绪即刷新对应日格；失败保留 strippedThumb 模糊图。
     */
    private func downloadDayThumbnails(items: ArrayList<(Int64, TLMessage)>): Unit {
        if (items.size == 0) { return }
        let _ = spawn {
            let filesDir = getAppFilesDir()
            if (filesDir.isEmpty()) { return }
            let photoDir = filesDir + "/photos"
            let thumbDir = filesDir + "/thumbs"
            try { FileIo.mkdir(photoDir) } catch (_e: Exception) {}
            try { FileIo.mkdir(thumbDir) } catch (_e: Exception) {}
            let downloadService = getFileDownloadService()
            var count = 0
            for ((dayIdx, m) in items) {
                if (count >= 90) { break }
                count += 1
                var path = ""
                try {
                    if (m.photoId != 0) {
                        path = photoDir + "/photo_${m.photoId}_m.jpg"
                        if (!calendarFileExists(path)) {
                            let bytes = downloadService.downloadPhoto(m.photoId, m.photoAccessHash, m.photoFileReference, thumbSize: "m")
                            if (bytes.size > 0) { calendarWriteFile(path, bytes) } else { path = "" }
                        }
                    } else if (m.documentId != 0) {
                        path = thumbDir + "/thumb_${m.documentId}.jpg"
                        if (!calendarFileExists(path)) {
                            let bytes = downloadService.downloadDocumentThumb(m.documentId, m.documentAccessHash,
                                m.documentFileReference, thumbSize: "m", dcId: m.documentDcId)
                            if (bytes.size > 0) { calendarWriteFile(path, bytes) } else { path = "" }
                        }
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CalendarMsgScreen] thumb download failed for msg ${m.id}: ${e}")
                    path = ""
                }
                if (path.size > 0) {
                    let uri = "file://" + path
                    let key = dayIdx
                    launch {
                        let updated = HashMap<Int64, String>()
                        for ((k, v) in this.dayThumbUris) { updated[k] = v }
                        updated[key] = uri
                        this.dayThumbUris = updated
                    }
                }
            }
        }
    }

    private func onDayTap(day: Int32, monthIdx: Int32): Unit {
        if (monthIdx < 0 || Int64(monthIdx) >= this.months.size) { return }
        let entry = this.months[Int64(monthIdx)]
        let year = entry.year
        let month = entry.month

        // P2-098: 选择模式 → 记录区间（仅在同一个月内有效）
        if (this.selectionMode) {
            if (this.rangeStartDay == 0) {
                this.rangeStartDay = day
                this.rangeMonthIdx = monthIdx
            } else if (this.rangeEndDay == 0 && this.rangeMonthIdx == monthIdx) {
                if (day < this.rangeStartDay) {
                    this.rangeEndDay = this.rangeStartDay
                    this.rangeStartDay = day
                } else {
                    this.rangeEndDay = day
                }
            } else {
                // 重置选区
                this.rangeStartDay = day
                this.rangeEndDay = 0
                this.rangeMonthIdx = monthIdx
            }
            return
        }
        // 普通模式：定位跳转（iOS searchMessageIdByTimestamp 传的是 Calendar.current 的本地 00:00）
        let dayTs = localMidnightTs(year, month, day)
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        launch { this.isLoading = true }
        let _ = spawn {
            try {
                let svc = getCalendarMessageScreenService()
                let result = svc.getMessagesForDate(peerType, peerId, dayTs)
                if (result.errorMessage.size > 0) {
                    launch {
                        this.isLoading = false
                        this.statusMessage = "Error: " + result.errorMessage
                    }
                } else if (!result.hasMessages) {
                    launch {
                        this.isLoading = false
                        this.statusMessage = "No messages on selected date"
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[CalendarMsgScreen] day=${dayTs} first msg id=${result.offsetMsgId}")
                    storeCalendarJumpMsgId(result.offsetMsgId)
                    launch {
                        this.isLoading = false
                        this.statusMessage = ""
                        this.selectedDay = day
                        this.selectedMonthIdx = monthIdx
                        routerPop()
                        fireCalendarJumpHandler(result.offsetMsgId)
                    }
                }
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[CalendarMsgScreen] onDayTap exception")
                launch {
                    this.isLoading = false
                    this.statusMessage = "Error loading messages"
                }
            }
        }
    }

    // P2-098: 触发区间删除
    private func confirmDeleteRange(): Unit {
        let midx = this.rangeMonthIdx
        if (midx < 0 || Int64(midx) >= this.months.size) { return }
        let entry = this.months[Int64(midx)]
        let year = entry.year
        let month = entry.month
        let startDay = this.rangeStartDay
        let endDay = this.rangeEndDay
        if (startDay == 0 || endDay == 0) {
            return
        }
        let minDate = localMidnightTs(year, month, startDay)
        let maxDate = localMidnightTs(year, month, endDay) + 86399
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        launch { this.isDeleting = true }
        let _ = spawn {
            try {
                let svc = getCalendarMessageScreenService()
                let result = svc.deleteHistoryRange(peerType, peerId, minDate, maxDate, true)
                if (result.success) {
                    Hilog.info(0, "CjTelegram", "[CalendarMsgScreen] deleteHistoryRange success")
                    launch {
                        this.isDeleting = false
                        this.selectionMode = false
                        this.rangeStartDay = 0
                        this.rangeEndDay = 0
                        this.rangeMonthIdx = -1
                        this.statusMessage = "Messages deleted"
                        this.triggerLoadCalendarPeriods()
                    }
                } else {
                    launch {
                        this.isDeleting = false
                        this.statusMessage = "Delete failed: " + result.errorMessage
                    }
                }
            } catch (_: Exception) {
                launch {
                    this.isDeleting = false
                    this.statusMessage = "Delete error"
                }
            }
        }
    }

    // P2-098: 清空整个历史
    private func doClearHistory(): Unit {
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        launch {
            this.showClearConfirm = false
            this.isDeleting = true
        }
        let _ = spawn {
            try {
                let svc = getCalendarMessageScreenService()
                let result = svc.clearHistory(peerType, peerId, false)
                if (result.success) {
                    Hilog.info(0, "CjTelegram", "[CalendarMsgScreen] clearHistory success")
                    launch {
                        this.isDeleting = false
                        this.statusMessage = "History cleared"
                        this.markedTimestamps = Array<Int32>(0, repeat: 0)
                        this.dayMediaByIndex = HashMap<Int64, TLMessage>()
                        this.dayThumbUris = HashMap<Int64, String>()
                    }
                } else {
                    launch {
                        this.isDeleting = false
                        this.statusMessage = "Clear failed: " + result.errorMessage
                    }
                }
            } catch (_: Exception) {
                launch {
                    this.isDeleting = false
                    this.statusMessage = "Clear error"
                }
            }
        }
    }

    // P2-099: 长按某天 → 加载媒体预览
    private func onDayCellLongPress(day: Int32, monthIdx: Int32): Unit {
        if (monthIdx < 0 || Int64(monthIdx) >= this.months.size) { return }
        let entry = this.months[Int64(monthIdx)]
        let year = entry.year
        let month = entry.month
        let dayTs = localMidnightTs(year, month, day)
        let peerType = getSelectedChatPeerType()
        let peerId = getSelectedChatId()
        launch {
            this.previewDay = day
            this.previewMonth = month
            this.previewYear = year
            this.isLoadingPreview = true
            this.showMediaPreview = true
            this.previewMedia = Array<TLMessage>(0, { _ => TLMessage() })
        }
        let _ = spawn {
            try {
                let svc = getCalendarMessageScreenService()
                let mediaResult = svc.searchDayMedia(peerType, peerId, dayTs)
                let msgs = mediaResult.mediaMessages
                let n = msgs.size
                let arr = Array<TLMessage>(n, { _ => TLMessage() })
                var i: Int64 = 0
                while (i < n) {
                    arr[i] = msgs[i]
                    i += 1
                }
                launch {
                    this.previewMedia = arr
                    this.isLoadingPreview = false
                }
            } catch (_: Exception) {
                launch {
                    this.isLoadingPreview = false
                }
            }
        }
    }

    // P2-095: 获取某月1号在网格中的偏移列数（0-based，基于 firstWeekday locale）
    // firstWeekday ICU: 1=Sun,2=Mon,...7=Sat; monthFirstWeekday 0=Sun,1=Mon,...6=Sat
    private func getWeekdayOffsetForMonth(year: Int32, month: Int32): Int32 {
        let ts = dateToTimestamp(year, month, 1)
        let daysSinceEpoch = ts / 86400
        // ICU 0-indexed day of week (0=Sun, 1=Mon, ..., 6=Sat)
        let monthFirstDay = Int32((daysSinceEpoch + 4) % 7)
        // Convert firstWeekday from ICU 1-indexed to 0-indexed
        let weekStart = this.firstWeekday - 1
        // Grid offset: number of blank cells before day 1
        return (monthFirstDay - weekStart + 7) % 7
    }

    private func monthLabel(year: Int32, month: Int32): String {
        let names = ["January", "February", "March", "April", "May", "June",
                     "July", "August", "September", "October", "November", "December"]
        let idx = Int64(month) - 1
        if (idx >= 0 && idx < 12) {
            return names[idx] + " " + year.toString()
        }
        return ""
    }

    private func dayNumberToString(d: Int32): String {
        return d.toString()
    }

    private func previewDayLabel(): String {
        let names = ["January", "February", "March", "April", "May", "June",
                     "July", "August", "September", "October", "November", "December"]
        let idx = Int64(this.previewMonth) - 1
        if (idx >= 0 && idx < 12) {
            return names[idx] + " " + this.previewDay.toString()
        }
        return ""
    }

    func build() {
        Stack(alignContent: Alignment.TopStart) {
                Column {
                    // 顶部工具栏：选择模式切换 + 操作按钮
                    Row {
                        Button(if (this.selectionMode) { "Cancel" } else { "Select" })
                            .fontSize(14)
                            .fontColor(0x007AFF)
                            .backgroundColor(Color.Transparent)
                            .onClick({ _ =>
                                if (this.selectionMode) {
                                    this.selectionMode = false
                                    this.rangeStartDay = 0
                                    this.rangeEndDay = 0
                                    this.rangeMonthIdx = -1
                                } else {
                                    this.selectionMode = true
                                }
                            })
                        Blank()
                            .layoutWeight(1)
                        if (this.selectionMode && this.rangeStartDay > 0 && this.rangeEndDay > 0) {
                            Button("Delete Range")
                                .fontSize(14)
                                .fontColor(0xFF3B30)
                                .backgroundColor(Color.Transparent)
                                .onClick({ _ => this.confirmDeleteRange() })
                        }
                        Blank()
                            .width(12)
                        Button(trSource("Clear All"))
                            .fontSize(14)
                            .fontColor(0xFF3B30)
                            .backgroundColor(Color.Transparent)
                            .onClick({ _ =>
                                this.showClearConfirm = true
                            })
                    }
                    .width(100.percent)
                    .height(40)
                    .padding(left: 16, right: 16)
                    .alignItems(VerticalAlign.Center)

                    // 加载/状态指示
                    if (this.isLoading || this.isDeleting) {
                        Row {
                            Text(if (this.isDeleting) { "Deleting..." } else { "Loading..." })
                                .fontSize(14)
                                .fontColor(0x8E8E93)
                        }
                        .width(100.percent)
                        .height(32)
                        .justifyContent(FlexAlign.Center)
                    }

                    if (this.statusMessage.size > 0) {
                        Row {
                            Text(this.statusMessage)
                                .fontSize(14)
                                .fontColor(0xFF3B30)
                                .padding(left: 16, right: 16)
                                .textAlign(TextAlign.Center)
                        }
                        .width(100.percent)
                        .height(36)
                        .justifyContent(FlexAlign.Center)
                    }

                    // P2-098: 选择模式提示
                    if (this.selectionMode) {
                        Row {
                            Text(this.buildSelectionHint())
                                .fontSize(13)
                                .fontColor(0x007AFF)
                                .textAlign(TextAlign.Center)
                                .padding(left: 16, right: 16)
                        }
                        .width(100.percent)
                        .height(32)
                        .justifyContent(FlexAlign.Center)
                        .backgroundColor(0xF2F2F7)
                    }

                    // P2-097: 多月连续滚动 List
                    List() {
                        ForEach(
                            this.months,
                            itemGenerator: { entry: MonthEntry, _idx: Int64 =>
                                ListItem() {
                                    this.buildMonthCard(entry)
                                }
                            }
                        )
                    }
                    .width(100.percent)
                    .layoutWeight(1)
                    .edgeEffect(EdgeEffect.Spring)
                }
                .width(100.percent)
                .height(100.percent)
                .backgroundColor(0xFFFFFF)
                .padding(top: getSafeAreaTop(), bottom: getSafeAreaBottom())

                // P2-099: 长按媒体预览浮层
                if (this.showMediaPreview) {
                    this.buildMediaPreviewOverlay()
                }

                // P2-098: 清空确认对话框
                if (this.showClearConfirm) {
                    this.buildClearConfirmOverlay()
                }
            }
            .width(100.percent)
            .height(100.percent)
            .onAppear({ => this.ensureLoaded() })
    }

    private func buildSelectionHint(): String {
        if (this.rangeStartDay == 0) {
            return "Tap first day of range"
        } else if (this.rangeEndDay == 0) {
            return "Tap last day of range (start: " + this.rangeStartDay.toString() + ")"
        } else {
            return "Range: " + this.rangeStartDay.toString() + " - " + this.rangeEndDay.toString()
        }
    }

    // P2-097: 渲染单个月份卡片（含月标题 + 星期名行 + 日历网格）
    @Builder
    func buildMonthCard(entry: MonthEntry) {
        Column {
            // 月份标题
            Row {
                Text(this.monthLabel(entry.year, entry.month))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(0x000000)
            }
            .width(100.percent)
            .height(44)
            .padding(left: 16, right: 16)
            .justifyContent(FlexAlign.Start)
            .alignItems(VerticalAlign.Center)

            // P2-095: 星期名行（应用语言 PresentationStrings，按 firstWeekday 排序）
            Row {
                ForEach(
                    Array<Int32>(7, { colIdx: Int64 => Int32(colIdx) }),
                    itemGenerator: { col: Int32, _ci: Int64 =>
                        Text(this.weekdayHeaderName(col))
                            .fontSize(12)
                            .fontColor(0x8E8E93)
                            .width(14.percent)
                            .textAlign(TextAlign.Center)
                    }
                )
            }
            .width(100.percent)
            .height(28)
            .padding(left: 4, right: 4)

            // 日历网格
            Column {
                this.buildCalendarGridForMonth(entry)
            }
            .width(100.percent)
            .padding(left: 4, right: 4, bottom: 8)
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
        .margin(bottom: 8)
    }

    @Builder
    func buildCalendarGridForMonth(entry: MonthEntry) {
        ForEach(
            Array<Int32>(Int64(this.getCalendarRowCount(entry)), { rowIdx: Int64 => Int32(rowIdx) }),
            itemGenerator: { rowIdx: Int32, _idx: Int64 =>
                Row {
                    ForEach(
                        Array<Int32>(7, { colIdx: Int64 => Int32(colIdx) }),
                        itemGenerator: { colIdx: Int32, _cIdx: Int64 =>
                            this.buildDayCell(rowIdx, colIdx, entry)
                        }
                    )
                }
                .width(100.percent)
                .height(52)
                .justifyContent(FlexAlign.SpaceAround)
            }
        )
    }

    // Helper functions for day cell state computation (no let/var in @Builder)

    private func dayCellDay(rowIdx: Int32, colIdx: Int32, entry: MonthEntry): Int32 {
        let offset = this.getWeekdayOffsetForMonth(entry.year, entry.month)
        return rowIdx * 7 + colIdx - offset + 1
    }

    private func dayCellIsValid(rowIdx: Int32, colIdx: Int32, entry: MonthEntry): Bool {
        let day = this.dayCellDay(rowIdx, colIdx, entry)
        return day >= 1 && day <= entry.dayCount
    }

    private func dayCellIsSelected(day: Int32, monthIdx: Int32): Bool {
        return day == this.selectedDay && monthIdx == this.selectedMonthIdx
    }

    private func dayCellIsRangeStart(day: Int32, monthIdx: Int32): Bool {
        return this.selectionMode && day == this.rangeStartDay && monthIdx == this.rangeMonthIdx
    }

    private func dayCellIsRangeEnd(day: Int32, monthIdx: Int32): Bool {
        return this.selectionMode && day == this.rangeEndDay && monthIdx == this.rangeMonthIdx
    }

    private func dayCellIsInRange(day: Int32, monthIdx: Int32): Bool {
        return this.selectionMode && this.rangeMonthIdx == monthIdx &&
            this.rangeStartDay > 0 && this.rangeEndDay > 0 &&
            day > this.rangeStartDay && day < this.rangeEndDay
    }

    private func isFutureDayInMonth(day: Int32, entry: MonthEntry): Bool {
        let todayTs = localTodayTs()
        let todayYM = timestampToYearMonth(todayTs)
        let todayDay = timestampToDay(todayTs)
        let isCurrentMonth = entry.year == todayYM[0] && entry.month == todayYM[1]
        return isCurrentMonth && day > todayDay
    }

    private func dayCellEnabled(day: Int32, entry: MonthEntry): Bool {
        return !this.isFutureDayInMonth(day, entry) && !this.isLoading && !this.isDeleting
    }

    // iOS DayComponent.media != nil：该日有图片/视频消息 → 缩略图 + 20% 黑圈 + 白字
    private func dayCellHasMedia(day: Int32, entry: MonthEntry): Bool {
        return this.dayMediaByIndex.contains(this.dayIndexOf(entry.year, entry.month, day))
    }

    private func dayCellThumbUri(day: Int32, entry: MonthEntry): String {
        match (this.dayThumbUris.get(this.dayIndexOf(entry.year, entry.month, day))) {
            case Some(u) => return u
            case None => return ""
        }
    }

    private func dayCellIsEdge(day: Int32, monthIdx: Int32): Bool {
        return this.dayCellIsSelected(day, monthIdx) ||
            this.dayCellIsRangeStart(day, monthIdx) ||
            this.dayCellIsRangeEnd(day, monthIdx)
    }

    // iOS DayComponent titleColor：media → itemCheckColors.foregroundColor(白)；edge → 白；
    // isCurrent → itemAccentColor；enabled → itemPrimaryTextColor；否则 itemDisabledTextColor
    private func dayCellTitleColor(day: Int32, entry: MonthEntry): Int64 {
        if (this.dayCellHasMedia(day, entry) || this.dayCellIsEdge(day, entry.indexInList)) {
            return 0xFFFFFFFF
        }
        if (this.isTodayInMonth(day, entry)) { return 0xFF007AFF }
        if (this.isFutureDayInMonth(day, entry)) { return 0xFFC7C7CC }
        return 0xFF000000
    }

    // iOS titleFontIsSemibold：有媒体 / 选区内 / 今天 → semibold
    private func dayCellTitleWeight(day: Int32, entry: MonthEntry): FontWeight {
        if (this.dayCellHasMedia(day, entry) || this.dayCellIsEdge(day, entry.indexInList) ||
            this.dayCellIsInRange(day, entry.indexInList) || this.isTodayInMonth(day, entry)) {
            return FontWeight.Medium
        }
        return FontWeight.Normal
    }

    private func startLongPressTimer(day: Int32, monthIdx: Int32): Unit {
        let entry = this.months[Int64(monthIdx)]
        if (!this.isFutureDayInMonth(day, entry) && !this.isLoading && !this.selectionMode) {
            this.longPressTimerActive = true
            this.longPressTargetDay = day
            this.longPressTargetMonthIdx = monthIdx
            let targetDay = day
            let targetMonthIdx = monthIdx
            let _ = spawn {
                sleep(500 * Duration.millisecond)
                if (this.longPressTimerActive && this.longPressTargetDay == targetDay &&
                    this.longPressTargetMonthIdx == targetMonthIdx) {
                    launch {
                        this.longPressTimerActive = false
                        this.onDayCellLongPress(targetDay, targetMonthIdx)
                    }
                }
            }
        }
    }

    @Builder
    func buildDayCell(rowIdx: Int32, colIdx: Int32, entry: MonthEntry) {
        if (!this.dayCellIsValid(rowIdx, colIdx, entry)) {
            Blank().width(14.percent).height(52)
        } else {
            this.buildActiveDayCell(this.dayCellDay(rowIdx, colIdx, entry), entry)
        }
    }

    /**
     * iOS DayComponent.View：圆形日格（diameter = min(格宽, 46)）。
     * 层序自底向上：媒体缩略图（圆形裁剪）→ 20% 黑色高亮圈 → 选区圈（有媒体时为 2pt 描边环）→ 日期数字。
     * 不用 Button：Button 自带内边距会把 36vp 宽的标签压成碎片，且 0x00000000 被当作不透明黑底。
     */
    @Builder
    func buildActiveDayCell(day: Int32, entry: MonthEntry) {
        Stack(alignContent: Alignment.Center) {
            if (this.dayCellHasMedia(day, entry)) {
                if (this.dayCellThumbUri(day, entry).size > 0) {
                    Image(this.dayCellThumbUri(day, entry))
                        .width(44)
                        .height(44)
                        .borderRadius(22)
                        .objectFit(ImageFit.Cover)
                }
                Text("")
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(0x33000000)
                if (this.dayCellIsEdge(day, entry.indexInList)) {
                    Text("")
                        .width(44)
                        .height(44)
                        .border(width: 2, color: 0xFF007AFF)
                        .borderRadius(22)
                }
            } else if (this.dayCellIsEdge(day, entry.indexInList)) {
                Text("")
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(0xFF007AFF)
            } else if (this.dayCellIsInRange(day, entry.indexInList)) {
                Text("")
                    .width(44)
                    .height(44)
                    .borderRadius(22)
                    .backgroundColor(0x1A007AFF)
            }
            Text(this.dayNumberToString(day))
                .fontSize(17)
                .fontWeight(this.dayCellTitleWeight(day, entry))
                .fontColor(this.dayCellTitleColor(day, entry))
        }
        .width(14.percent)
        .height(52)
        .onClick({ _ =>
            if (this.dayCellEnabled(day, entry)) {
                this.onDayTap(day, entry.indexInList)
            }
        })
        .onTouch({ evt =>
            match (evt.eventType) {
                case TouchType.Down =>
                    if (evt.touches.size > 0) {
                        this.touchStartX = evt.touches[0].x
                        this.touchStartY = evt.touches[0].y
                    }
                    if (Int64(entry.indexInList) < this.months.size) {
                        this.startLongPressTimer(day, entry.indexInList)
                    }
                case TouchType.Move =>
                    if (evt.touches.size > 0 && this.longPressTimerActive) {
                        let dx = evt.touches[0].x - this.touchStartX
                        let dy = evt.touches[0].y - this.touchStartY
                        if (dx * dx + dy * dy > 100.0) {
                            this.longPressTimerActive = false
                        }
                    }
                case TouchType.Up =>
                    this.longPressTimerActive = false
                case TouchType.Cancel =>
                    this.longPressTimerActive = false
                case _ => ()
            }
        })
    }

    // P2-099: 长按媒体预览浮层
    @Builder
    func buildMediaPreviewOverlay() {
        Column {
            // 顶部标题栏
            Row {
                Text(this.previewDayLabel() + " Media")
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(0x000000)
                    .layoutWeight(1)
                Button(trSource("Close"))
                    .fontSize(14)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .onClick({ _ =>
                        this.showMediaPreview = false
                        this.previewDay = 0
                        this.previewMedia = Array<TLMessage>(0, { _ => TLMessage() })
                    })
            }
            .width(100.percent)
            .height(48)
            .padding(left: 16, right: 16)
            .alignItems(VerticalAlign.Center)

            // 媒体网格或加载状态
            if (this.isLoadingPreview) {
                Column {
                    Text("Loading media...")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(180)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else if (this.previewMedia.size == 0) {
                Column {
                    Text("No media on this day")
                        .fontSize(14)
                        .fontColor(0x8E8E93)
                }
                .width(100.percent)
                .height(180)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            } else {
                this.buildMediaGrid()
            }
        }
        .width(100.percent)
        .backgroundColor(0xFFFFFF)
        .borderRadius(12)
        .shadow(radius: 8.0, color: 0x22000000, offsetX: 0.0, offsetY: 4.0)
        .margin(top: 200)
        .margin(left: 8)
        .margin(right: 8)
    }

    @Builder
    func buildMediaGrid() {
        Grid() {
            ForEach(
                this.previewMedia,
                itemGenerator: { msg: TLMessage, _idx: Int64 =>
                    GridItem() {
                        Column {
                            Text(
                                if (msg.mediaType == "photo") { "[Photo]" }
                                else if (msg.mediaType == "video") { "[Video]" }
                                else { "[Media]" }
                            )
                                .fontSize(12)
                                .fontColor(0x8E8E93)
                                .textAlign(TextAlign.Center)
                                .width(100.percent)
                                .height(100.percent)
                        }
                        .width(100.percent)
                        .height(100.percent)
                        .backgroundColor(0xF2F2F7)
                        .borderRadius(6)
                    }
                    .height(80)
                }
            )
        }
        .columnsTemplate("1fr 1fr 1fr")
        .columnsGap(4)
        .rowsGap(4)
        .width(100.percent)
        .height(180)
        .padding(left: 8, right: 8, bottom: 8)
    }

    // P2-098: 清空确认对话框
    @Builder
    func buildClearConfirmOverlay() {
        Column {
            Text("Clear All History?")
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(0x000000)
                .margin(top: 24)
                .margin(bottom: 8)
            Text("This will clear your local message history. This action cannot be undone.")
                .fontSize(14)
                .fontColor(0x8E8E93)
                .textAlign(TextAlign.Center)
                .padding(left: 24, right: 24)
                .margin(bottom: 24)
            Row {
                Button(trSource("Cancel"))
                    .fontSize(16)
                    .fontColor(0x007AFF)
                    .backgroundColor(Color.Transparent)
                    .layoutWeight(1)
                    .onClick({ _ => this.showClearConfirm = false })
                Button(trSource("Clear"))
                    .fontSize(16)
                    .fontColor(0xFF3B30)
                    .backgroundColor(Color.Transparent)
                    .layoutWeight(1)
                    .onClick({ _ => this.doClearHistory() })
            }
            .width(100.percent)
            .height(48)
            .margin(bottom: 8)
        }
        .width(280)
        .backgroundColor(0xFFFFFF)
        .borderRadius(14)
        .shadow(radius: 16.0, color: 0x44000000, offsetX: 0.0, offsetY: 8.0)
        .alignItems(HorizontalAlign.Center)
        .alignSelf(ItemAlign.Center)
        .margin(top: 240)
        .margin(left: 48)
    }

    private func getCalendarRowCount(entry: MonthEntry): Int32 {
        let offset = this.getWeekdayOffsetForMonth(entry.year, entry.month)
        let totalCells = offset + entry.dayCount
        return (totalCells + 6) / 7
    }
}

// ==================== 全局日历跳转锚点 ====================

private var _calendarJumpMsgId: Int32 = 0
// 日历选日后回调到聊天室（ChatRoomPage 在 push 前注册；NavDestination 返回不会重触发
// onAppear，故用显式回调而非轮询 getCalendarJumpMsgId）
private var _calendarJumpHandler: Option<(Int32) -> Unit> = None

public func registerCalendarJumpHandler(handler: (Int32) -> Unit): Unit {
    _calendarJumpHandler = Some(handler)
}

public func clearCalendarJumpHandler(): Unit {
    _calendarJumpHandler = None
}

func fireCalendarJumpHandler(msgId: Int32): Unit {
    match (_calendarJumpHandler) {
        case Some(h) => h(msgId)
        case None => ()
    }
}

public func storeCalendarJumpMsgId(msgId: Int32): Unit {
    _calendarJumpMsgId = msgId
}

public func getCalendarJumpMsgId(): Int32 {
    return _calendarJumpMsgId
}

// ==================== 日期/时间工具函数 ====================

/**
 * 获取当前 Unix 时间戳（秒）
 */
private func getCurrentTimestamp(): Int32 {
    return Int32(DateTime.now().toUnixTimeStamp().toSeconds())
}

/**
 * 本地“今天 00:00”的日序号 × 86400（iOS MonthModel 用 Calendar.current，日界按本地时区）。
 * 返回值喂给 timestampToYearMonth / timestampToDay 得到本地今天的年月日。
 */
private func localTodayTs(): Int32 {
    return Int32(localDayIndexOf(Int64(getCurrentTimestamp())) * 86400)
}

/**
 * 某本地日历日的本地 00:00 Unix 秒（iOS MonthModel.firstDay + 24h*day，Calendar.current 时区）。
 * dateToTimestamp 给的是该日期的 UTC 00:00，减去该时刻的本地时区偏移即得本地 00:00（偏移按当日取，含夏令时）。
 */
private func localMidnightTs(year: Int32, month: Int32, day: Int32): Int32 {
    let utcMidnight = Int64(dateToTimestamp(year, month, day))
    let offsetSec = DateTime.fromUnixTimeStamp(Duration.second * utcMidnight).inLocal().zoneOffset.toSeconds()
    return Int32(utcMidnight - offsetSec)
}

private func calendarFileExists(path: String): Bool {
    try { return FileIo.access(path) } catch (_e: Exception) { return false }
}

private func calendarWriteFile(path: String, bytes: Array<Byte>): Unit {
    let file = FileIo.open(path, mode: 0o1101)
    FileIo.write(file.fd, bytes)
    FileIo.close(file)
}

/**
 * 判断是否是闰年
 */
private func isLeapYear(year: Int32): Bool {
    if ((year % 400) == 0) { return true }
    if ((year % 100) == 0) { return false }
    return (year % 4) == 0
}

/**
 * 获取某年某月的天数（1月=1...12月=12）
 */
private func daysInMonth(year: Int32, month: Int32): Int32 {
    if (month == 1 || month == 3 || month == 5 || month == 7 ||
        month == 8 || month == 10 || month == 12) {
        return 31
    }
    if (month == 4 || month == 6 || month == 9 || month == 11) {
        return 30
    }
    if (month == 2) {
        return if (isLeapYear(year)) { 29 } else { 28 }
    }
    return 30
}

/**
 * 将 Unix 时间戳转换为 [year, month] 数组
 * 使用格里历算法
 */
private func timestampToYearMonth(ts: Int32): Array<Int32> {
    var days = Int64(ts) / 86400
    var year: Int32 = 1970
    var month: Int32 = 1
    while (true) {
        let daysInYear: Int64 = if (isLeapYear(year)) { 366 } else { 365 }
        if (days < daysInYear) { break }
        days -= daysInYear
        year += 1
    }
    while (month < 12) {
        let md = Int64(daysInMonth(year, month))
        if (days < md) { break }
        days -= md
        month += 1
    }
    return [year, month]
}

/**
 * 获取时间戳对应月份内的日（1-31）
 */
private func timestampToDay(ts: Int32): Int32 {
    var days = Int64(ts) / 86400
    var year: Int32 = 1970
    var month: Int32 = 1
    while (true) {
        let daysInYear: Int64 = if (isLeapYear(year)) { 366 } else { 365 }
        if (days < daysInYear) { break }
        days -= daysInYear
        year += 1
    }
    while (month < 12) {
        let md = Int64(daysInMonth(year, month))
        if (days < md) { break }
        days -= md
        month += 1
    }
    return Int32(days) + 1
}

/**
 * 将 year/month/day 转换为 Unix 时间戳
 * 使用格里历算法（与 iOS 中 Int32(monthModel.firstDay.timeIntervalSince1970) 对应）
 */
private func dateToTimestamp(year: Int32, month: Int32, day: Int32): Int32 {
    var totalDays: Int64 = 0
    var y: Int32 = 1970
    while (y < year) {
        totalDays += if (isLeapYear(y)) { 366 } else { 365 }
        y += 1
    }
    var m: Int32 = 1
    while (m < month) {
        totalDays += Int64(daysInMonth(year, m))
        m += 1
    }
    totalDays += Int64(day) - 1
    return Int32(totalDays * 86400)
}
