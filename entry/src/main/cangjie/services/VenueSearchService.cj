package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.random.Random

/**
 * VenueSearchService — Foursquare 场所搜索服务 (P2-184)
 *
 * iOS 对应: LocationSearchContainerNode.swift → nearbyVenues() → requestChatContextResults
 *   uses messages.getInlineBotResults#514e999d with geo_point + foursquare bot
 *
 * 实现:
 *   1. resolveVenueBot("foursquare") → botId / accessHash
 *   2. searchVenues(lat, lng, query) → messages.getInlineBotResults with geo_point flag
 *      → parse messages.botResults → ArrayList<VenueItemData>
 *
 * TL 参考 (RequestChatContextResults.swift line 125):
 *   messages.getInlineBotResults flags:# bot:InputUser peer:InputPeer
 *     geo_point:flags.0?InputGeoPoint query:string offset:string
 *   Constructor: 0x514e999d
 *
 * inputGeoPoint#0x48222faf flags:# lat:double long:double accuracy_radius:flags.0?int
 *   Constructor: 0x48222faf (客户端发送用;geoPoint#b2a2f663 是服务端只读类型)
 *
 * 调用链:
 *   VenuePickerPage.searchVenues → getVenueSearchService().searchVenues(lat, lng, query)
 *     → resolveFoursquareBot → getMTProtoClient().sendRequest
 *     → parseBotResultsAsVenues → ArrayList<VenueItemData>
 */

// ─────────────────────────────────────────────────────────────────────────────
// TL: MessagesGetInlineBotResultsGeo — 带 geo_point 的 getInlineBotResults
// ─────────────────────────────────────────────────────────────────────────────

/**
 * messages.getInlineBotResults#514e999d flags:# ...
 *
 * 本类带 geo_point (flags bit 0 = 1)，专用于 venue 搜索。
 * 与 ChatContextQueryService.MessagesGetInlineBotResults 不同:
 *   该类序列化 geo_point (flags=1, inputGeoPoint#0x48222faf 客户端发送类型)
 */
public class MessagesGetInlineBotResultsGeo <: TLObject {
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var latitude: Float64 = 0.0
    public var longitude: Float64 = 0.0
    public var query: String = ""
    public var offset: String = ""

    public func getConstructorId(): UInt32 { return 0x514e999d }

    public func serialize(serializer: TLSerializer) {
        // flags = 1 (geo_point present)
        serializer.writeInt32(1)
        // bot: InputUser = inputUser#f21158c6 user_id:long access_hash:long
        serializer.writeUInt32(0xf21158c6)
        serializer.writeInt64(this.botId)
        serializer.writeInt64(this.botAccessHash)
        // peer: InputPeer = inputPeerEmpty#7f3b18ea
        serializer.writeUInt32(0x7f3b18ea)
        // geo_point: InputGeoPoint = inputGeoPoint#0x48222faf flags:# lat:double long:double accuracy_radius:flags.0?int
        //   (iOS Api10:609 appendInt32(1210199983)=0x48222faf; 客户端发送用)
        serializer.writeUInt32(0x48222faf)
        serializer.writeInt32(0)         // flags (no accuracy_radius)
        serializer.writeDouble(this.latitude)
        serializer.writeDouble(this.longitude)
        // query: string
        serializer.writeString(this.query)
        // offset: string
        serializer.writeString(this.offset)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

private var _venueSearchServiceInstance: Option<VenueSearchService> = None

public func getVenueSearchService(): VenueSearchService {
    match (_venueSearchServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = VenueSearchService()
            _venueSearchServiceInstance = Some(svc)
            return svc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VenueSearchService
// ─────────────────────────────────────────────────────────────────────────────

/**
 * VenueSearchService — 附近 venue 搜索服务
 *
 * iOS 原版 SearchBotsConfiguration: venueBotUsername = "foursquare"
 * 仓颉侧复用 WebSearchService.resolveBot / MessagesGetInlineBotResults 体系,
 * 但新增带 geo_point 的序列化类 MessagesGetInlineBotResultsGeo。
 */
public class VenueSearchService {
    private var _cachedBotId: Int64 = 0
    private var _cachedBotAccessHash: Int64 = 0

    /**
     * 解析 Foursquare venue bot (username="foursquare")，获取 botId / accessHash
     * 缓存避免重复 RPC。
     */
    private func resolveFoursquareBot(): (Int64, Int64) {
        if (this._cachedBotId != 0) {
            return (this._cachedBotId, this._cachedBotAccessHash)
        }
        Hilog.info(0, "CjTelegram", "[VenueSearchService] resolving foursquare bot")
        let svc = getWebSearchService()
        let (botId, accessHash) = svc.resolveBot("foursquare")
        if (botId != 0) {
            this._cachedBotId = botId
            this._cachedBotAccessHash = accessHash
            Hilog.info(0, "CjTelegram", "[VenueSearchService] foursquare botId=${botId}")
        } else {
            Hilog.info(0, "CjTelegram", "[VenueSearchService] foursquare resolve failed")
        }
        return (botId, accessHash)
    }

    /**
     * 搜索附近场所（Foursquare via messages.getInlineBotResults + geo_point）
     *
     * iOS 对应 nearbyVenues() → requestChatContextResults 带 geo_point:
     *   geoPoint = Api.InputGeoPoint.inputGeoPoint(lat, long)
     *
     * @param lat   纬度
     * @param lng   经度
     * @param query 搜索关键词（可为空字符串，空时返回附近推荐）
     * @return ArrayList<VenueItemData> 场所列表
     */
    public func searchVenues(lat: Float64, lng: Float64, query: String): ArrayList<VenueItemData> {
        let results: ArrayList<VenueItemData> = ArrayList<VenueItemData>()
        let (botId, accessHash) = this.resolveFoursquareBot()
        if (botId == 0) {
            Hilog.info(0, "CjTelegram", "[VenueSearchService] no bot, skip searchVenues")
            return results
        }
        Hilog.info(0, "CjTelegram", "[VenueSearchService] searchVenues lat=${lat} lng=${lng} q=${query}")
        let req = MessagesGetInlineBotResultsGeo()
        req.botId = botId
        req.botAccessHash = accessHash
        req.latitude = lat
        req.longitude = lng
        req.query = query
        req.offset = ""
        let client = getMTProtoClient()
        let data = client.sendRequest(req.toBytes())
        if (data.size < 8) {
            Hilog.info(0, "CjTelegram", "[VenueSearchService] empty response")
            return results
        }
        this.parseBotResultsAsVenues(data, results)
        Hilog.info(0, "CjTelegram", "[VenueSearchService] got ${results.size} venues")
        return results
    }

    /**
     * 解析 messages.botResults#e021f2f6 → ArrayList<VenueItemData>
     *
     * Foursquare bot 返回 botInlineResult#11965f3a 类型的位置结果，
     * send_message 字段是 botInlineMessageMediaGeo / botInlineMessageMediaVenue:
     *   botInlineMessageMediaVenue#b722de65 flags:# geo:GeoPoint title:string
     *     address:string provider:string venue_id:string venue_type:string
     *     reply_markup:flags.2?ReplyMarkup
     *   Constructor: 0xb722de65
     *
     * 对于无法深入解析 venue 媒体消息的 fallback: 从 title/description 构建 VenueItemData
     */
    private func parseBotResultsAsVenues(data: Array<Byte>, out: ArrayList<VenueItemData>): Unit {
        if (data.size < 4) { return }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        // messages.botResults#e021f2f6
        if (ctor != 0xe021f2f6) {
            Hilog.info(0, "CjTelegram", "[VenueSearchService] unexpected ctor=${ctor}")
            return
        }
        let flags = d.readInt32()
        let queryId = d.readInt64()
        Hilog.info(0, "CjTelegram", "[VenueSearchService] queryId=${queryId}")
        // next_offset flags.1?string
        if ((flags & 2) != 0) {
            let _ = d.readString()
        }
        // switch_pm flags.2?InlineBotSwitchPM
        if ((flags & 4) != 0) {
            let _ = d.readString()
            let _ = d.readString()
        }
        // switch_webview flags.3?InlineBotWebView
        if ((flags & 8) != 0) {
            let _ = d.readString()
            let _ = d.readString()
        }
        // results: Vector<BotInlineResult>
        let vecCtor = d.readUInt32()
        if (vecCtor != TLConstructors.VECTOR) { return }
        let count = d.readInt32()
        var i: Int32 = 0
        while (i < count && out.size < 50) {
            try {
                let venue = this.parseSingleBotResult(d)
                match (venue) {
                    case Some(v) => out.add(v)
                    case None => ()
                }
            } catch (_: Exception) {
                break
            }
            i = i + 1
        }
    }

    /**
     * 解析单条 BotInlineResult，提取 venue 信息
     *
     * botInlineResult#11965f3a flags:# id:string type:string
     *   title:flags.1?string description:flags.2?string
     *   url:flags.3?string thumb:flags.4?WebDocument content:flags.5?WebDocument
     *   send_message:BotInlineMessage
     */
    private func parseSingleBotResult(d: TLDeserializer): Option<VenueItemData> {
        let resultCtor = d.readUInt32()
        if (resultCtor == 0x11965f3a) {
            // botInlineResult
            let flags = d.readInt32()
            let resultId = d.readString()
            let resultType = d.readString()
            var title = ""
            var address = ""
            if ((flags & 2) != 0) { title = d.readString() }
            if ((flags & 4) != 0) { address = d.readString() }
            if ((flags & 8) != 0) { let _ = d.readString() }   // url
            // thumb: flags.4?WebDocument
            if ((flags & 16) != 0) { skipWebDocument(d) }
            // content: flags.5?WebDocument
            if ((flags & 32) != 0) { skipWebDocument(d) }
            // send_message: parse for venue geo + type
            let venue = parseBotInlineMessageForVenue(d, resultId, title, address)
            return Some(venue)
        } else if (resultCtor == 0x17db940b) {
            // botInlineMediaResult
            let flags = d.readInt32()
            let resultId = d.readString()
            let _ = d.readString()   // type
            if ((flags & 1) != 0) { skipTLObject(d) }  // photo
            if ((flags & 2) != 0) { skipTLObject(d) }  // document
            var title = ""
            var address = ""
            if ((flags & 4) != 0) { title = d.readString() }
            if ((flags & 8) != 0) { address = d.readString() }
            let venue = parseBotInlineMessageForVenue(d, resultId, title, address)
            return Some(venue)
        } else {
            // unknown — skip rest conservatively
            return None
        }
    }
}

/**
 * 跳过 WebDocument (url:string access_hash:long size:int mime_type:string attributes:Vector)
 */
func skipWebDocument(d: TLDeserializer): Unit {
    let _ = d.readString()   // url
    let _ = d.readInt64()    // access_hash
    let _ = d.readInt32()    // size
    let _ = d.readString()   // mime_type
    // attributes: Vector<DocumentAttribute>
    let attrVec = d.readUInt32()
    if (attrVec == TLConstructors.VECTOR) {
        let ac = d.readInt32()
        var ai: Int32 = 0
        while (ai < ac) {
            skipTLObject(d)
            ai = ai + 1
        }
    }
}

/**
 * 解析 BotInlineMessage，尝试提取 venue 坐标和类型
 *
 * botInlineMessageMediaVenue#b722de65 flags:# geo:GeoPoint
 *   title:string address:string provider:string venue_id:string venue_type:string
 *   Constructor: 0xb722de65
 *
 * geoPoint#b2a2f663 flags:# lat:double long:double accuracy_radius:flags.0?int
 *   Constructor: 0xb2a2f663 (不同于 inputGeoPoint)
 * geoPoint = 0x296f104 flags:# lat:double long:double access_hash:long accuracy_radius:flags.0?int
 *
 * Fallback: 构建一个使用传入 title/address 的 VenueItemData（坐标=0,0）
 */
func parseBotInlineMessageForVenue(d: TLDeserializer, id: String, fallbackTitle: String, fallbackAddress: String): VenueItemData {
    let venue = VenueItemData()
    venue.venueId = id
    venue.title = fallbackTitle
    venue.address = fallbackAddress
    try {
        let msgCtor = d.readUInt32()
        if (msgCtor == 0xb722de65) {
            // botInlineMessageMediaVenue
            let flags = d.readInt32()
            // geo: GeoPoint
            let geoCtor = d.readUInt32()
            if (geoCtor == 0x0296f104) {
                // geoPoint#0296f104 flags:# lat:double long:double access_hash:long accuracy_radius:flags.0?int
                let geoFlags = d.readInt32()
                venue.latitude = d.readDouble()
                venue.longitude = d.readDouble()
                let _ = d.readInt64()  // access_hash
                if ((geoFlags & 1) != 0) { let _ = d.readInt32() }
            } else if (geoCtor == 0xb2a2f663) {
                // inputGeoPoint variant (fallback)
                let geoFlags = d.readInt32()
                venue.latitude = d.readDouble()
                venue.longitude = d.readDouble()
                if ((geoFlags & 1) != 0) { let _ = d.readInt32() }
            }
            let vTitle = d.readString()
            let vAddr = d.readString()
            let _ = d.readString()   // provider
            let vId = d.readString() // venue_id
            let vType = d.readString() // venue_type
            if (vTitle.size > 0) { venue.title = vTitle }
            if (vAddr.size > 0) { venue.address = vAddr }
            if (vId.size > 0) { venue.venueId = vId }
            venue.type_ = vType
            venue.provider = "foursquare"
            // reply_markup: flags.2?ReplyMarkup (skip)
            if ((flags & 4) != 0) { skipTLObject(d) }
        } else if (msgCtor == 0x3a8fd8b8) {
            // botInlineMessageText — text only, no venue coordinates
            let flags = d.readInt32()
            let _ = d.readString()   // message
            if ((flags & 2) != 0) { skipTLObject(d) }  // entities vector
            if ((flags & 4) != 0) { skipTLObject(d) }  // reply_markup
        } else if (msgCtor == 0x764cf810) {
            // botInlineMessageMediaAuto
            let flags = d.readInt32()
            let _ = d.readString()   // message
            if ((flags & 2) != 0) { skipTLObject(d) }
            if ((flags & 4) != 0) { skipTLObject(d) }
        } else if (msgCtor == 0x35edb4d4) {
            // botInlineMessageMediaGeo
            let flags = d.readInt32()
            let geoCtor = d.readUInt32()
            if (geoCtor == 0x0296f104) {
                let geoFlags = d.readInt32()
                venue.latitude = d.readDouble()
                venue.longitude = d.readDouble()
                let _ = d.readInt64()
                if ((geoFlags & 1) != 0) { let _ = d.readInt32() }
            }
            if ((flags & 1) != 0) { let _ = d.readInt32() }  // heading
            if ((flags & 4) != 0) { let _ = d.readInt32() }  // period
            if ((flags & 8) != 0) { let _ = d.readInt32() }  // proximity_notification_radius
            if ((flags & 2) != 0) { skipTLObject(d) }         // reply_markup
        }
    } catch (_: Exception) {
        // parse error, return with fallback data
    }
    return venue
}
