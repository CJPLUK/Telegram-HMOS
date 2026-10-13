package ohos_app_cangjie_entry.utils

import std.time.DateTime
import std.time.TimeZone
import ohos_app_cangjie_entry.core.storage.{PresentationStringsSnapshot, trOr}

/**
 * 统一的本地化时间 / 日期 / 计数格式化工具。
 *
 * 对应 iOS Telegram 的 submodules/TelegramStringFormatting：
 *   - stringForMessageTimestamp        → formatMessageTimestamp
 *   - stringForRelativeTimestamp       → formatRelativeTimestamp
 *   - stringForFullDate                → formatFullDate
 *   - stringForCompactDate             → formatCompactDate
 *   - stringForRelativeActivityTimestamp / "last seen ..." → formatRelativeTime
 *   - "X members" / "X online" 计数本地化 → formatCount
 *
 * 设计要点：
 *   - 所有入参都是 UTC Unix 秒（服务端时间戳口径），内部统一通过
 *     DateTime.fromUnixTimeStamp(...).inLocal() 转成 **本地时区** 后再取年月日时分，
 *     因此分级判断（今天 / 昨天 / 本周）使用本地日历日，而非 UTC。
 *   - 12/24 小时制：默认 24h；formatMessageTimestamp / formatRelativeTimestamp
 *     提供可选 use24h 参数，无需接系统设置。
 *   - 周首日 / 星期名 / 月份名：硬编码英文缩写。完整 i18n（本地化星期、
 *     周首日按地区调整、12h 制 AM/PM 本地串）不在本单元范围，后续可接 LocalizationKit。
 */

// 月份缩写（1..12）
let MONTH_ABBREV: Array<String> = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
]

// 星期缩写，索引为 DayOfWeek.toInteger()：0=Sunday .. 6=Saturday
let WEEKDAY_ABBREV: Array<String> = [
    "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"
]

/**
 * 把 UTC Unix 秒转成本地时区的 DateTime。
 * fromUnixTimeStamp 得到的是 UTC 口径，.inLocal() 转换到 TimeZone.Local。
 */
func localDateTime(unixSec: Int64): DateTime {
    return DateTime.fromUnixTimeStamp(Duration.second * unixSec).inLocal()
}

/**
 * 本地日历“第几天”（自 Unix 纪元起的本地日序号），用于今天 / 昨天 / 同周判断。
 * 取本地 DateTime 的 (year, dayOfYear) 不便直接做差，这里改用
 * “本地时间戳（含时区偏移）整除 86400”得到本地日序号。
 */
func localDayIndex(unixSec: Int64): Int64 {
    let dt = localDateTime(unixSec)
    // zoneOffset 是相对 UTC 的偏移（Duration），加到 UTC 秒上得到“本地墙钟秒”。
    let offsetSec = dt.zoneOffset.toSeconds()
    let localWallSec = unixSec + offsetSec
    // 向下取整到日（处理负数情形：纪元前不会出现在本应用，但仍保证单调）
    if (localWallSec >= 0) {
        return localWallSec / 86400
    } else {
        return (localWallSec - 86399) / 86400
    }
}

/** 两位补零。 */
func pad2(v: Int64): String {
    if (v < 10) {
        return "0${v}"
    }
    return "${v}"
}

/** "HH:MM"（24 小时制）。 */
func hhmm24(dt: DateTime): String {
    return "${pad2(dt.hour)}:${pad2(dt.minute)}"
}

/** "h:MM AM/PM"（12 小时制）。 */
func hhmm12(dt: DateTime): String {
    let h24 = dt.hour
    let suffix = if (h24 < 12) { "AM" } else { "PM" }
    var h12 = h24 % 12
    if (h12 == 0) {
        h12 = 12
    }
    return "${h12}:${pad2(dt.minute)} ${suffix}"
}

func clockString(dt: DateTime, use24h: Bool): String {
    if (use24h) {
        return hhmm24(dt)
    }
    return hhmm12(dt)
}

/** 星期缩写（"Mon" 等），输入为本地 DateTime。 */
func weekdayAbbrev(dt: DateTime): String {
    let idx = dt.dayOfWeek.toInteger()
    if (idx >= 0 && idx <= 6) {
        let keys: Array<String> = [
            "Weekday_ShortSunday", "Weekday_ShortMonday", "Weekday_ShortTuesday",
            "Weekday_ShortWednesday", "Weekday_ShortThursday", "Weekday_ShortFriday",
            "Weekday_ShortSaturday"
        ]
        return trOr(keys[idx], WEEKDAY_ABBREV[idx])
    }
    return ""
}

/** Source PresentationStrings-driven weekday used by reactive UI callers. */
func weekdayAbbrev(dt: DateTime, strings: PresentationStringsSnapshot): String {
    let idx = dt.dayOfWeek.toInteger()
    if (idx >= 0 && idx <= 6) {
        let keys: Array<String> = [
            "Weekday_ShortSunday", "Weekday_ShortMonday", "Weekday_ShortTuesday",
            "Weekday_ShortWednesday", "Weekday_ShortThursday", "Weekday_ShortFriday",
            "Weekday_ShortSaturday"
        ]
        return strings.getOr(keys[idx], WEEKDAY_ABBREV[idx])
    }
    return ""
}

/** 月份缩写（"Jan" 等），输入为本地 DateTime。 */
func monthAbbrev(dt: DateTime): String {
    let m = dt.month.toInteger()
    if (m >= 1 && m <= 12) {
        let keys: Array<String> = [
            "Month_ShortJanuary", "Month_ShortFebruary", "Month_ShortMarch",
            "Month_ShortApril", "Month_ShortMay", "Month_ShortJune",
            "Month_ShortJuly", "Month_ShortAugust", "Month_ShortSeptember",
            "Month_ShortOctober", "Month_ShortNovember", "Month_ShortDecember"
        ]
        return trOr(keys[m - 1], MONTH_ABBREV[m - 1])
    }
    return "${m}"
}

/** Source PresentationStrings-driven month used by reactive UI callers. */
func monthAbbrev(dt: DateTime, strings: PresentationStringsSnapshot): String {
    let m = dt.month.toInteger()
    if (m >= 1 && m <= 12) {
        let keys: Array<String> = [
            "Month_ShortJanuary", "Month_ShortFebruary", "Month_ShortMarch",
            "Month_ShortApril", "Month_ShortMay", "Month_ShortJune",
            "Month_ShortJuly", "Month_ShortAugust", "Month_ShortSeptember",
            "Month_ShortOctober", "Month_ShortNovember", "Month_ShortDecember"
        ]
        return strings.getOr(keys[m - 1], MONTH_ABBREV[m - 1])
    }
    return "${m}"
}

/**
 * 本地 "HH:MM"（24h）时钟串。供旧 formatMessageTime 等纯时分展示场景复用，
 * 与旧实现相比改为使用本地时区（旧实现按 UTC 取时分）。
 */
public func formatClockHHMM(unixSec: Int64): String {
    return hhmm24(localDateTime(unixSec))
}

/**
 * 消息气泡时间戳（对应 iOS stringForMessageTimestamp）：
 *   - 今天        → "HH:MM"
 *   - 昨天        → "Yesterday"
 *   - 本周内(≤6 天前) → 星期缩写（"Mon".."Sun"）
 *   - 更早        → "MM/DD/YYYY"
 *
 * use24h 默认 true。
 */
public func formatMessageTimestamp(unixSec: Int64, use24h!: Bool = true): String {
    let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
    return formatMessageTimestampAt(unixSec, nowSec, use24h)
}

/**
 * 可注入“现在”的纯函数版本，便于 selfCheck 断言（避免依赖真实时钟）。
 */
public func formatMessageTimestampAt(unixSec: Int64, nowSec: Int64, use24h: Bool): String {
    let dt = localDateTime(unixSec)
    let msgDay = localDayIndex(unixSec)
    let todayDay = localDayIndex(nowSec)

    if (msgDay == todayDay) {
        return clockString(dt, use24h)
    } else if (msgDay == todayDay - 1) {
        return trOr("Weekday_Yesterday", "Yesterday")
    } else if (msgDay < todayDay && msgDay >= todayDay - 6) {
        return weekdayAbbrev(dt)
    } else {
        // MM/DD/YYYY
        return "${pad2(dt.month.toInteger())}/${pad2(dt.dayOfMonth)}/${dt.year}"
    }
}

/**
 * 会话列表时间戳（对应 iOS stringForRelativeTimestamp）。
 * 比 message 版更紧凑：今天 → HH:MM，昨天 → "Yesterday"，
 * 本周 → 星期缩写，更早 → "MMM D"（紧凑日期，不带年）。
 */
public func formatRelativeTimestamp(unixSec: Int64, use24h!: Bool = true): String {
    let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
    return formatRelativeTimestampAt(unixSec, nowSec, use24h)
}

public func formatRelativeTimestampAt(unixSec: Int64, nowSec: Int64, use24h: Bool): String {
    let dt = localDateTime(unixSec)
    let msgDay = localDayIndex(unixSec)
    let todayDay = localDayIndex(nowSec)

    if (msgDay == todayDay) {
        return clockString(dt, use24h)
    } else if (msgDay == todayDay - 1) {
        return trOr("Weekday_Yesterday", "Yesterday")
    } else if (msgDay < todayDay && msgDay >= todayDay - 6) {
        return weekdayAbbrev(dt)
    } else {
        // 紧凑日期 "MMM D"
        return "${monthAbbrev(dt)} ${dt.dayOfMonth}"
    }
}

/**
 * Reactive PresentationStrings variant of the chat-list timestamp formatter.
 * Telegram-iOS passes the current PresentationStrings into
 * stringForRelativeTimestamp; keeping it as an explicit argument also makes
 * ArkUI invalidate the timestamp Text when the app language changes.
 */
public func formatRelativeTimestamp(
    unixSec: Int64,
    strings: PresentationStringsSnapshot,
    use24h!: Bool = true
): String {
    let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
    let dt = localDateTime(unixSec)
    let msgDay = localDayIndex(unixSec)
    let todayDay = localDayIndex(nowSec)

    if (msgDay == todayDay) {
        return clockString(dt, use24h)
    } else if (msgDay == todayDay - 1) {
        return strings.getOr("Weekday_Yesterday", "Yesterday")
    } else if (msgDay < todayDay && msgDay >= todayDay - 6) {
        return weekdayAbbrev(dt, strings)
    } else {
        return "${monthAbbrev(dt, strings)} ${dt.dayOfMonth}"
    }
}

/**
 * 完整日期（对应 iOS stringForFullDate）：本地 "MMM D, YYYY"。
 * 例：2024-05-22 → "May 22, 2024"。
 */
public func formatFullDate(unixSec: Int64): String {
    let dt = localDateTime(unixSec)
    return "${monthAbbrev(dt)} ${dt.dayOfMonth}, ${dt.year}"
}

/**
 * 紧凑日期（对应 iOS stringForCompactDate）：本地 "MM/DD/YYYY"。
 */
public func formatCompactDate(unixSec: Int64): String {
    let dt = localDateTime(unixSec)
    return "${pad2(dt.month.toInteger())}/${pad2(dt.dayOfMonth)}/${dt.year}"
}

/**
 * 相对时间（对应 iOS stringForRelativeActivityTimestamp / "last seen ..."），
 * 用于在线状态 / 最近上线展示：
 *   - <60s     → "just now"
 *   - <60min   → "N minutes ago"（1 → "1 minute ago"）
 *   - <24h     → "N hours ago"（1 → "1 hour ago"）
 *   - 昨天      → "yesterday"
 *   - 更早      → 紧凑日期 "MMM D"
 * 未来时间（unixSec > nowSec）按 "just now" 处理，避免出现负数。
 */
public func formatRelativeTime(unixSec: Int64): String {
    let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()
    return formatRelativeTimeAt(unixSec, nowSec)
}

public func formatRelativeTimeAt(unixSec: Int64, nowSec: Int64): String {
    let delta = nowSec - unixSec
    if (delta < 60) {
        return "just now"
    } else if (delta < 3600) {
        let mins = delta / 60
        return formatCount(mins, "1 minute ago", "${mins} minutes ago")
    } else if (delta < 86400) {
        let hours = delta / 3600
        return formatCount(hours, "1 hour ago", "${hours} hours ago")
    }
    // 跨天后用本地日历日判断昨天 / 更早
    let msgDay = localDayIndex(unixSec)
    let todayDay = localDayIndex(nowSec)
    if (msgDay == todayDay - 1) {
        return "yesterday"
    }
    let dt = localDateTime(unixSec)
    return "${monthAbbrev(dt)} ${dt.dayOfMonth}"
}

/**
 * 本地日历日序号（公开导出，供 presence 等做"今天/昨天"判断）。
 */
public func localDayIndexOf(unixSec: Int64): Int64 {
    return localDayIndex(unixSec)
}

/**
 * 短斜杠日期 "dd/MM/yy"（iOS lastSeen 旧日期档实测格式，如 "21/01/26"）。
 */
public func formatShortDateSlashed(unixSec: Int64): String {
    let dt = localDateTime(unixSec)
    let yy = dt.year % 100
    return "${pad2(dt.dayOfMonth)}/${pad2(dt.month.toInteger())}/${pad2(yy)}"
}

/**
 * 简单复数计数（对应 iOS "X members" / "X online" 等 i18n 计数串的弱化版）。
 * n == 1 → singular，否则 → plural。
 * 调用方自行把数字拼进串里，例如：
 *   formatCount(n, "1 member", "${n} members")
 */
public func formatCount(n: Int64, singular: String, plural: String): String {
    if (n == 1) {
        return singular
    }
    return plural
}

/**
 * selfCheck：用注入的 now 构造相对偏移，避免依赖真实时钟与具体时区。
 * 所有断言围绕“本地日历日序号”的相对关系成立，不依赖运行环境时区。
 * 返回 true 表示全部通过；失败处通过 Hilog 记录（这里用返回值，调用方可断言）。
 */
public func timeFormatUtilsSelfCheck(): Bool {
    var ok = true

    // 固定一个“现在”：选一个本地日的正午附近，确保同日内的偏移不会跨日。
    // 取本地某天 12:00 对应的 UTC 秒：先用本地日序号 * 86400 得到本地午夜墙钟秒，
    // 再回退到 UTC 需减去 offset；但 selfCheck 只比较“相对关系”，
    // 直接用一个具体 now，并用 ±偏移构造同日 / 昨日 / 本周 / 更早即可。
    let nowSec = DateTime.now().toUnixTimeStamp().toSeconds()

    // 把 now 对齐到“本地正午”，保证 ±数小时仍落在同一本地日，避免边界翻车。
    let nowDay = localDayIndex(nowSec)
    let nowOffset = DateTime.fromUnixTimeStamp(Duration.second * nowSec).inLocal().zoneOffset.toSeconds()
    // 本地午夜（墙钟）对应的 UTC 秒 = nowDay*86400 - offset；正午再 +43200。
    let localNoonUtc = nowDay * 86400 - nowOffset + 43200

    // ① 今天：同一本地日 → 应为 HH:MM（含冒号），不是 "Yesterday"
    let todayStr = formatMessageTimestampAt(localNoonUtc, localNoonUtc, true)
    if (!todayStr.contains(":")) {
        ok = false
    }
    if (todayStr == "Yesterday") {
        ok = false
    }

    // ② 昨天：now - 1 天（24h 前的同正午）→ "Yesterday"
    let yesterdayTs = localNoonUtc - 86400
    let yStr = formatMessageTimestampAt(yesterdayTs, localNoonUtc, true)
    if (yStr != "Yesterday") {
        ok = false
    }

    // ③ 本周内（3 天前）→ 星期缩写（长度 3，非 HH:MM、非 Yesterday、非日期）
    let threeDaysAgo = localNoonUtc - 3 * 86400
    let wStr = formatMessageTimestampAt(threeDaysAgo, localNoonUtc, true)
    if (wStr.contains(":") || wStr == "Yesterday" || wStr.contains("/")) {
        ok = false
    }

    // ④ 更早（30 天前）→ 日期 "MM/DD/YYYY"（含 "/"）
    let monthAgo = localNoonUtc - 30 * 86400
    let oldStr = formatMessageTimestampAt(monthAgo, localNoonUtc, true)
    if (!oldStr.contains("/")) {
        ok = false
    }

    // ⑤ 24h 制 HH:MM 形如 "12:00"
    if (formatMessageTimestampAt(localNoonUtc, localNoonUtc, true) != "12:00") {
        ok = false
    }

    // ⑥ 12h 制：正午 → "12:00 PM"
    if (formatMessageTimestampAt(localNoonUtc, localNoonUtc, false) != "12:00 PM") {
        ok = false
    }

    // ⑦ formatCount 单复数
    if (formatCount(1, "1 member", "2 members") != "1 member") {
        ok = false
    }
    if (formatCount(5, "1 member", "5 members") != "5 members") {
        ok = false
    }
    if (formatCount(0, "1 member", "0 members") != "0 members") {
        ok = false
    }

    // ⑧ 相对时间分级
    if (formatRelativeTimeAt(localNoonUtc - 30, localNoonUtc) != "just now") {
        ok = false
    }
    if (formatRelativeTimeAt(localNoonUtc - 60, localNoonUtc) != "1 minute ago") {
        ok = false
    }
    if (formatRelativeTimeAt(localNoonUtc - 120, localNoonUtc) != "2 minutes ago") {
        ok = false
    }
    if (formatRelativeTimeAt(localNoonUtc - 3600, localNoonUtc) != "1 hour ago") {
        ok = false
    }
    if (formatRelativeTimeAt(localNoonUtc - 7200, localNoonUtc) != "2 hours ago") {
        ok = false
    }

    return ok
}

/**
 * 预约 Video Chat 的开始时间（iOS Conversation.ScheduledVoiceChatStarts{Today,Tomorrow,On}Short）：
 * 本地时区的 "Starts today at 22:28" / "Starts tomorrow at 09:00" / "Starts on Sep 23 at 09:00"。
 */
public func formatScheduledCallStarts(unixSec: Int64): String {
    let dt = localDateTime(unixSec)
    let clock = clockString(dt, true)
    let diff = localDayIndex(unixSec) - localDayIndex(DateTime.now().toUnixTimeStamp().toSeconds())
    if (diff == 0) { return "Starts today at ${clock}" }
    if (diff == 1) { return "Starts tomorrow at ${clock}" }
    return "Starts on ${monthAbbrev(dt)} ${dt.dayOfMonth} at ${clock}"
}

/**
 * 服务消息 "… scheduled a video chat for %@"（iOS Notification.VoiceChatScheduled{,Today,Tomorrow}）的时间部分：
 * "today at 22:51" / "tomorrow at 09:00" / "Sep 23 at 09:00"，本地时区。
 */
public func formatScheduledCallFor(unixSec: Int64): String {
    let dt = localDateTime(unixSec)
    let clock = clockString(dt, true)
    let diff = localDayIndex(unixSec) - localDayIndex(DateTime.now().toUnixTimeStamp().toSeconds())
    if (diff == 0) { return "today at ${clock}" }
    if (diff == 1) { return "tomorrow at ${clock}" }
    return "${monthAbbrev(dt)} ${dt.dayOfMonth} at ${clock}"
}
