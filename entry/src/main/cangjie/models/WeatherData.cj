package ohos_app_cangjie_entry.models

/**
 * WeatherData — 天气数据模型 (P2-404)
 *
 * iOS 对应: Telegram-iOS/submodules/TelegramUI/Sources/
 *   WeatherBot inline result via messages.getInlineBotResults → weather bot
 *   (同 P2-184 venue 的 inline bot 机制)
 *
 * 数据来源: weather bot inline query → botInlineResult 消息文本解析
 *   title 字段含温度/天气描述；description 含城市/扩展信息
 */
public class WeatherData {
    /** 城市/地点名称 */
    public var location: String = ""
    /** 天气描述（e.g. "Partly cloudy"） */
    public var description_: String = ""
    /** 温度摄氏度（来自解析结果，未获得时为 Int32.max） */
    public var tempCelsius: Int32 = 0
    /** 温度原始字符串（保留完整格式如"24°C"） */
    public var tempString: String = ""
    /** 天气 emoji（从描述解析，e.g. ☀️ ⛅ 🌧） */
    public var weatherEmoji: String = ""
    /** 湿度描述（可选） */
    public var humidity: String = ""
    /** 风速描述（可选） */
    public var wind: String = ""
    /** 日出时间（可选） */
    public var sunrise: String = ""
    /** 日落时间（可选） */
    public var sunset: String = ""
    /** 月相（可选） */
    public var moonPhase: String = ""
    /** 是否解析成功 */
    public var isValid: Bool = false
    /** 原始 bot 返回标题 */
    public var rawTitle: String = ""
    /** 原始 bot 返回描述 */
    public var rawDescription: String = ""

    public init() {}
}
