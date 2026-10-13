package ohos_app_cangjie_entry.utils

/**
 * 授权页面工具（对应 Telegram-iOS AuthorizationUtils）
 *
 * 提供：
 * - 统一的标题/正文样式参数
 * - Flood wait 时间格式化
 * - 选项文本高亮
 * - 常量：字体大小、强调色等
 */

// --- 常量 ---

public let AUTH_HEADER_FONT_SIZE: Int32 = 24
public let AUTH_BODY_FONT_SIZE: Int32 = 16
public let AUTH_ACCENT_COLOR: Int32 = 0x317AFF
public let AUTH_TEXT_COLOR: Int32 = 0x000000
public let AUTH_SECONDARY_COLOR: Int32 = 0x666666

/**
 * 授权页标题样式参数
 * 返回 (fontSize, fontWeight, color) 等，供 Text 组件使用
 */
public func authorizationHeaderStyle(): AuthTextStyle {
    return AuthTextStyle(fontSize: AUTH_HEADER_FONT_SIZE, color: AUTH_TEXT_COLOR, fontWeight: "Bold")
}

/**
 * 授权页正文样式参数
 */
public func authorizationTextStyle(): AuthTextStyle {
    return AuthTextStyle(fontSize: AUTH_BODY_FONT_SIZE, color: AUTH_TEXT_COLOR, fontWeight: "Normal")
}

/**
 * 格式化 Flood wait 等待时间
 * 如 120 秒 -> "Please wait 2 minutes"
 * 如 45 秒 -> "Please wait 45 seconds"
 */
public func formatFloodWaitTime(seconds: Int64): String {
    if (seconds >= 60) {
        let mins = seconds / 60
        return "Please wait " + mins.toString() + (if (mins == 1) { " minute" } else { " minutes" })
    }
    return "Please wait " + seconds.toString() + (if (seconds == 1) { " second" } else { " seconds" })
}

/**
 * 授权选项文本，支持高亮部分
 * 返回完整文本，调用方可根据 highlightedPart 用 Span 实现高亮
 */
public func authorizationOptionText(text: String, highlightedPart: String): String {
    return text
}

/**
 * 授权选项文本（含高亮部分信息），供 UI 渲染 Span 使用
 */
public func authorizationOptionTextWithHighlight(text: String, highlightedPart: String): AuthOptionTextResult {
    return AuthOptionTextResult(fullText: text, highlightedPart: highlightedPart)
}

// --- 数据结构 ---

public class AuthTextStyle {
    public var fontSize: Int32 = 16
    public var color: Int32 = 0x000000
    public var fontWeight: String = "Normal"

    public init() {}

    public init(fontSize!: Int32, color!: Int32, fontWeight!: String) {
        this.fontSize = fontSize
        this.color = color
        this.fontWeight = fontWeight
    }
}

public class AuthOptionTextResult {
    public var fullText: String = ""
    public var highlightedPart: String = ""

    public init() {}

    public init(fullText!: String, highlightedPart!: String) {
        this.fullText = fullText
        this.highlightedPart = highlightedPart
    }
}
