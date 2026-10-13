package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.WeatherData
import std.collection.ArrayList

/**
 * WeatherBotService — 天气数据服务 (P2-404)
 *
 * iOS 对应: Telegram 内置 weather bot inline query
 *   messages.getInlineBotResults bot=@weather peer=inputPeerEmpty
 *   query="<lat>,<lng>" → 解析 botInlineResult title/description
 *
 * 实现与 VenueSearchService (P2-184) 完全相同的 inline bot 机制:
 *   1. resolveWeatherBot("weather") → botId / accessHash
 *   2. queryWeather(lat, lng) → MessagesGetInlineBotResults (无 geo_point，用坐标作 query string)
 *   → 解析 messages.botResults → WeatherData
 *
 * 坐标来源: LocationService.getCurrentDeviceLocation() (P2-180 C FFI kit.LocationKit)
 *
 * ctor verification:
 *   MessagesGetInlineBotResults#514e999d (flags=0, no geo_point)
 *   messages.botResults#e021f2f6
 *   botInlineResult#11965f3a
 */

private var _weatherBotServiceInstance: Option<WeatherBotService> = None

public func getWeatherBotService(): WeatherBotService {
    match (_weatherBotServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = WeatherBotService()
            _weatherBotServiceInstance = Some(svc)
            return svc
    }
}

public class WeatherBotService {
    private var _cachedBotId: Int64 = 0
    private var _cachedBotAccessHash: Int64 = 0

    /**
     * 解析 weather bot (username="weather")，获取 botId / accessHash。
     * 缓存避免重复 RPC。
     *
     * iOS 源: SearchBotsConfiguration.weatherBotUsername = "weather"
     */
    private func resolveWeatherBot(): (Int64, Int64) {
        if (this._cachedBotId != 0) {
            return (this._cachedBotId, this._cachedBotAccessHash)
        }
        Hilog.info(0, "CjTelegram", "[WeatherBotService] resolving @weather bot")
        let webSvc = getWebSearchService()
        let (botId, accessHash) = webSvc.resolveBot("weather")
        if (botId != 0) {
            this._cachedBotId = botId
            this._cachedBotAccessHash = accessHash
            Hilog.info(0, "CjTelegram", "[WeatherBotService] @weather botId=${botId}")
        } else {
            Hilog.info(0, "CjTelegram", "[WeatherBotService] @weather resolve failed")
        }
        return (botId, accessHash)
    }

    /**
     * 根据经纬度查询天气
     *
     * query 格式: "<lat>,<lng>" (weather bot 标准接口)
     *
     * @param lat 纬度
     * @param lng 经度
     * @return WeatherData (isValid=false 表示查询失败)
     */
    public func queryWeather(lat: Float64, lng: Float64): WeatherData {
        let result = WeatherData()
        let (botId, accessHash) = this.resolveWeatherBot()
        if (botId == 0) {
            Hilog.info(0, "CjTelegram", "[WeatherBotService] no bot, skip queryWeather")
            return result
        }

        let queryStr = "${lat},${lng}"
        Hilog.info(0, "CjTelegram", "[WeatherBotService] queryWeather q=${queryStr}")

        let req = MessagesGetInlineBotResults()
        req.botId = botId
        req.botAccessHash = accessHash
        req.peerId = 0
        req.peerAccessHash = 0
        req.query = queryStr
        req.offset = ""

        let client = getMTProtoClient()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 8) {
            Hilog.info(0, "CjTelegram", "[WeatherBotService] empty response")
            return result
        }
        return this.parseBotResultsAsWeather(data, lat, lng)
    }

    /**
     * 解析 messages.botResults#e021f2f6 → WeatherData
     * 取第一条 botInlineResult 的 title + description 解析天气
     */
    private func parseBotResultsAsWeather(data: Array<Byte>, lat: Float64, lng: Float64): WeatherData {
        let result = WeatherData()
        if (data.size < 4) { return result }

        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor != 0xe021f2f6) {
            Hilog.info(0, "CjTelegram", "[WeatherBotService] unexpected ctor=${ctor}")
            return result
        }

        let flags = d.readInt32()
        let _ = d.readInt64()   // queryId

        if ((flags & 2) != 0) { let _ = d.readString() }   // next_offset
        if ((flags & 4) != 0) {
            let _ = d.readString()
            let _ = d.readString()
        }
        if ((flags & 8) != 0) {
            let _ = d.readString()
            let _ = d.readString()
        }

        let vecCtor = d.readUInt32()
        if (vecCtor != TLConstructors.VECTOR) { return result }

        let count = d.readInt32()
        if (count <= 0) { return result }

        try {
            let resultCtor = d.readUInt32()
            if (resultCtor == 0x11965f3a) {
                // botInlineResult
                let rFlags = d.readInt32()
                let _ = d.readString()    // id
                let _ = d.readString()    // type
                var title = ""
                var description_ = ""
                if ((rFlags & 2) != 0) { title = d.readString() }
                if ((rFlags & 4) != 0) { description_ = d.readString() }

                result.rawTitle = title
                result.rawDescription = description_
                result.isValid = true
                this.parseWeatherStrings(result, title, description_)
                let latStr = "${lat}"
                let lngStr = "${lng}"
                Hilog.info(0, "CjTelegram", "[WeatherBotService] weather at lat=${latStr} lng=${lngStr}: ${title}")
            }
        } catch (_: Exception) {
            Hilog.info(0, "CjTelegram", "[WeatherBotService] parse error")
        }
        return result
    }

    /**
     * 从 title/description 字符串中提取天气字段
     *
     * weather bot 格式 (example):
     *   title: "☀️ +24°C Beijing, China"
     *   description: "Humidity: 45%\nWind: 5 km/h\nSunrise: 05:17\nSunset: 19:43"
     */
    private func parseWeatherStrings(result: WeatherData, title: String, description_: String): Unit {
        result.weatherEmoji = this.extractEmoji(title)
        result.tempString = this.extractTemperature(title)
        result.location = this.extractLocation(title)
        result.description_ = this.extractWeatherDesc(title)

        let lines = description_.split("\n")
        for (line in lines) {
            let lower = line.toAsciiLower()
            if (lower.startsWith("humidity")) {
                result.humidity = line
            } else if (lower.startsWith("wind")) {
                result.wind = line
            } else if (lower.startsWith("sunrise")) {
                result.sunrise = line
            } else if (lower.startsWith("sunset")) {
                result.sunset = line
            } else if (lower.startsWith("moon")) {
                result.moonPhase = line
            }
        }
    }

    private func extractEmoji(s: String): String {
        let runes = s.toRuneArray()
        var i = 0
        while (i < runes.size) {
            let cp = UInt32(runes[i])
            if (cp >= 0x1F300) {
                return runes[i].toString()
            }
            i = i + 1
        }
        return "🌤"
    }

    private func extractTemperature(s: String): String {
        let runes = s.toRuneArray()
        var degPos = -1
        var i = 0
        while (i < runes.size) {
            if (UInt32(runes[i]) == 0xB0) {
                degPos = i
                break
            }
            i = i + 1
        }
        if (degPos < 0) { return "" }
        var start = degPos - 1
        while (start > 0) {
            let cp = UInt32(runes[start])
            if ((cp >= 0x30 && cp <= 0x39) || cp == 0x2B || cp == 0x2D) {
                start = start - 1
            } else {
                break
            }
        }
        start = start + 1
        var cPos = degPos + 1
        while (cPos < runes.size && (UInt32(runes[cPos]) == 0x43 || UInt32(runes[cPos]) == 0x46)) {
            cPos = cPos + 1
        }
        return s[start..cPos]
    }

    private func extractLocation(s: String): String {
        let runes = s.toRuneArray()
        var cPos = -1
        var i = 0
        while (i < runes.size) {
            let cp = UInt32(runes[i])
            if (cp == 0xB0) {
                var j = i + 1
                while (j < runes.size && (UInt32(runes[j]) == 0x43 || UInt32(runes[j]) == 0x46)) {
                    j = j + 1
                }
                if (j < runes.size) {
                    cPos = j
                }
                break
            }
            i = i + 1
        }
        if (cPos >= 0 && cPos < runes.size) {
            return s[cPos..s.size].trimAscii()
        }
        return s
    }

    private func extractWeatherDesc(s: String): String {
        let emojiEnd = this.findEmojiEnd(s)
        if (emojiEnd < 0) { return "" }
        let runes = s.toRuneArray()
        var tempPos = -1
        var i = 0
        while (i < runes.size) {
            if (UInt32(runes[i]) == 0xB0) {
                tempPos = i
                break
            }
            i = i + 1
        }
        if (tempPos > emojiEnd) {
            return s[emojiEnd..tempPos].trimAscii()
        }
        return ""
    }

    private func findEmojiEnd(s: String): Int64 {
        let runes = s.toRuneArray()
        var i = 0
        while (i < runes.size) {
            let cp = UInt32(runes[i])
            if (cp >= 0x1F300) {
                return Int64(i + 1)
            }
            i = i + 1
        }
        return -1
    }
}
