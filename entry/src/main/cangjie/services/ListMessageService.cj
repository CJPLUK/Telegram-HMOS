package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.Message
import std.collection.ArrayList

// ==================== 列表消息项类型常量 ====================

public let LIST_MSG_TYPE_FILE: String = "file"
public let LIST_MSG_TYPE_LINK: String = "link"
public let LIST_MSG_TYPE_MUSIC: String = "music"

// ==================== 数据模型 ====================

/**
 * 列表消息项数据模型
 *
 * 对应 iOS ListMessageItem 的单行显示数据：
 *   - file 行: 文件图标 + 文件名 + 文件大小 + 日期
 *   - link 行: 缩略图 + 链接标题 + 站点名 + 日期
 *   - music 行: 专辑封面 + 曲名 + 艺术家 + 时长
 *
 * 纯渲染组件，iOS 原版无 TL 网络方法（ListMessageFileItemNode 直接展示
 * 已存在于 Message 对象中的元数据）。
 */
public class ListMessageItem {
    public var msgId: Int64 = 0
    // "file" / "link" / "music"
    public var itemType: String = LIST_MSG_TYPE_FILE

    // ---- 文件行 ----
    public var fileName: String = ""
    public var fileSize: Int64 = 0          // bytes
    public var fileExtension: String = ""   // "pdf", "zip", "mp3", …
    public var localPath: String = ""       // 已下载本地路径（空 = 未下载）

    // ---- 链接行 ----
    public var linkUrl: String = ""
    public var linkTitle: String = ""
    public var linkSiteName: String = ""
    public var linkThumbPath: String = ""   // 链接缩略图本地路径

    // ---- 音乐行 ----
    public var musicTitle: String = ""
    public var musicArtist: String = ""
    public var musicDuration: Int32 = 0     // 秒
    public var albumArtPath: String = ""    // 专辑封面本地路径

    // 发送时间（Unix 时间戳）
    public var timestamp: Int64 = 0

    // 发件人名字
    public var senderName: String = ""

    public init() {}
}

/**
 * 日期分组头
 *
 * 对应 iOS ListMessageDateHeader：以 "January 2024" 格式显示月份分组头，
 * roundedTimestamp = year * 100 + month 用于分组唯一标识。
 */
public class ListMessageDateGroup {
    // 唯一标识：year * 100 + month（对应 iOS listMessageDateHeaderId 逻辑）
    public var groupId: Int64 = 0
    public var year: Int32 = 0
    public var month: Int32 = 0
    // 显示文字，例如 "January 2024"
    public var displayText: String = ""
    public var items: ArrayList<ListMessageItem> = ArrayList<ListMessageItem>()

    public init() {}
}

// ==================== 单例 ====================

private var _listMessageServiceInstance: Option<ListMessageService> = None

public func getListMessageService(): ListMessageService {
    match (_listMessageServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ListMessageService()
            _listMessageServiceInstance = Some(inst)
            return inst
    }
}

// ==================== 服务主体 ====================

/**
 * ListMessageService — 列表消息项数据处理服务
 *
 * 职责：
 *   1. 将 Message 对象转换为适合列表展示的 ListMessageItem
 *   2. 将 ListMessageItem 列表按月份分组（仿 iOS listMessageDateHeaderId 逻辑）
 *   3. 提供文件大小 / 时长格式化辅助
 *
 * 不发起任何 MTProto 请求（iOS 原版亦如此）；
 * 文件下载由 FileDownloadService 负责（跨 feature 接线）。
 */
public class ListMessageService {

    public init() {}

    // ==================== 消息 → 列表项转换 ====================

    /**
     * 从 Message 构建 ListMessageItem
     *
     * 支持三种类型：
     *   - messageType == "document" 且 documentMimeType 包含 "audio" → music
     *   - messageType == "webpage"（web_page）                         → link
     *   - 其余文档类型                                                  → file
     */
    public func buildListItem(msg: Message): Option<ListMessageItem> {
        let item = ListMessageItem()
        item.msgId = msg.id
        item.timestamp = msg.rawTimestamp
        item.senderName = msg.senderName

        let mtype = msg.messageType
        if (mtype == "document" || mtype == "file" || mtype == "music" || mtype == "audio" || mtype == "voice") {
            let mimeType = msg.documentMimeType
            let isAudio = mimeType.size > 0 && (
                mimeType.startsWith("audio/") ||
                mtype == "music" ||
                mtype == "audio"
            )
            if (isAudio) {
                item.itemType = LIST_MSG_TYPE_MUSIC
                item.musicTitle = if (msg.audioTitle.size > 0) { msg.audioTitle } else { msg.documentFileName }
                item.musicArtist = msg.audioPerformer
                item.musicDuration = msg.audioDuration
                item.albumArtPath = msg.documentLocalPath
            } else {
                item.itemType = LIST_MSG_TYPE_FILE
                item.fileName = if (msg.documentFileName.size > 0) { msg.documentFileName } else { "file" }
                item.fileSize = msg.documentSize
                item.fileExtension = getFileExtension(msg.documentFileName)
                item.localPath = msg.documentLocalPath
            }
            return Some(item)
        } else if (mtype == "webpage" || mtype == "web_page") {
            if (msg.webPageUrl.size == 0) {
                return None
            }
            item.itemType = LIST_MSG_TYPE_LINK
            item.linkUrl = msg.webPageUrl
            item.linkTitle = if (msg.webPageTitle.size > 0) { msg.webPageTitle } else { msg.webPageUrl }
            item.linkSiteName = msg.webPageSiteName
            item.linkThumbPath = msg.webPagePhotoLocalPath
            return Some(item)
        }
        return None
    }

    /**
     * 将 ListMessageItem 列表按年-月分组
     *
     * 对应 iOS listMessageDateHeaderId：groupId = year * 100 + month
     * 输出按时间倒序排列的 ListMessageDateGroup 列表（最新月份在前）。
     */
    public func groupByDate(items: ArrayList<ListMessageItem>): ArrayList<ListMessageDateGroup> {
        let groups = ArrayList<ListMessageDateGroup>()

        for (item in items) {
            let (year, month) = timestampToYearMonth(item.timestamp)
            let groupId = Int64(year) * 100 + Int64(month)

            var found = false
            for (g in groups) {
                if (g.groupId == groupId) {
                    g.items.add(item)
                    found = true
                    break
                }
            }
            if (!found) {
                let g = ListMessageDateGroup()
                g.groupId = groupId
                g.year = year
                g.month = month
                g.displayText = formatMonthYear(year, month)
                g.items.add(item)
                groups.add(g)
            }
        }
        return groups
    }

    // ==================== 格式化辅助 ====================

    /**
     * 格式化文件大小为人类可读字符串
     *
     * 例如: 1536 → "1.5 KB", 2097152 → "2.0 MB"
     */
    public func formatFileSize(bytes: Int64): String {
        if (bytes < 0) { return "0 B" }
        if (bytes < 1024) {
            return "${bytes} B"
        } else if (bytes < 1024 * 1024) {
            let kb10 = (bytes * 10) / 1024
            let whole = kb10 / 10
            let frac = kb10 % 10
            return "${whole}.${frac} KB"
        } else if (bytes < 1024 * 1024 * 1024) {
            let mb10 = (bytes * 10) / (1024 * 1024)
            let whole = mb10 / 10
            let frac = mb10 % 10
            return "${whole}.${frac} MB"
        } else {
            let gb10 = (bytes * 10) / (1024 * 1024 * 1024)
            let whole = gb10 / 10
            let frac = gb10 % 10
            return "${whole}.${frac} GB"
        }
    }

    /**
     * 格式化音乐时长为 "m:ss" 或 "h:mm:ss"
     */
    public func formatDuration(seconds: Int32): String {
        let s = Int64(seconds)
        if (s < 0) { return "0:00" }
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        let secStr = if (sec < 10) { "0${sec}" } else { "${sec}" }
        if (h > 0) {
            let minStr = if (m < 10) { "0${m}" } else { "${m}" }
            return "${h}:${minStr}:${secStr}"
        }
        return "${m}:${secStr}"
    }

    /**
     * 返回文件扩展名对应的颜色（仿 iOS extensionColorsMap）
     *
     * 返回 ARGB Int64 颜色值：
     *   红系 (pdf, ppt, pptx, key)  → 0xFFFF875F
     *   绿系 (xls, xlsx, csv)        → 0xFF99DE6F
     *   黄系 (zip, rar, gzip, ai)    → 0xFFFFA24B
     *   蓝系 (其他)                  → 0xFF72D5FD
     */
    public func extensionColor(ext: String): Int64 {
        let lower = ext.toAsciiLower()
        if (lower == "pdf" || lower == "ppt" || lower == "pptx" || lower == "key") {
            return 0xFFFF875F
        } else if (lower == "xls" || lower == "xlsx" || lower == "csv") {
            return 0xFF99DE6F
        } else if (lower == "zip" || lower == "rar" || lower == "gzip" || lower == "ai") {
            return 0xFFFFA24B
        }
        return 0xFF72D5FD
    }

    // ==================== 内部辅助 ====================

    private func getFileExtension(filename: String): String {
        let runes = filename.toRuneArray()
        var lastDot = -1
        var i = 0
        for (r in runes) {
            if (r.toString() == ".") { lastDot = i }
            i = i + 1
        }
        if (lastDot < 0 || lastDot >= runes.size - 1) { return "" }
        var ext = ""
        var j = lastDot + 1
        while (j < runes.size) {
            ext = ext + runes[j].toString()
            j = j + 1
        }
        return ext
    }

    private func timestampToYearMonth(ts: Int64): (Int32, Int32) {
        if (ts <= 0) { return (1970, 1) }
        let days = ts / 86400
        var remaining = days
        var year: Int32 = 1970
        while (true) {
            let daysInYear: Int64 = if (isLeapYear(year)) { 366 } else { 365 }
            if (remaining < daysInYear) { break }
            remaining = remaining - daysInYear
            year = year + 1
        }
        let leapYear = isLeapYear(year)
        let monthDays: Array<Int64> = if (leapYear) {
            [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        } else {
            [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        }
        var month: Int32 = 0
        for (md in monthDays) {
            if (remaining < md) { break }
            remaining = remaining - md
            month = month + 1
        }
        return (year, month + 1)
    }

    private func isLeapYear(year: Int32): Bool {
        if (year % 400 == 0) { return true }
        if (year % 100 == 0) { return false }
        return year % 4 == 0
    }

    private func formatMonthYear(year: Int32, month: Int32): String {
        let monthNames: Array<String> = [
            "January", "February", "March", "April",
            "May", "June", "July", "August",
            "September", "October", "November", "December"
        ]
        let idx = Int64(month) - 1
        let name = if (idx >= 0 && idx < 12) { monthNames[idx] } else { "Month" }
        return "${name} ${year}"
    }
}

// ==================== 顶层辅助函数 ====================

/**
 * 格式化文件大小（顶层函数，可直接在 UI 层调用）
 */
public func formatListFileSize(bytes: Int64): String {
    return getListMessageService().formatFileSize(bytes)
}

/**
 * 格式化音乐时长（顶层函数）
 */
public func formatListMusicDuration(seconds: Int32): String {
    return getListMessageService().formatDuration(seconds)
}
