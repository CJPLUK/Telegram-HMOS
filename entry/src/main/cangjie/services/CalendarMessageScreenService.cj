package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    MessagesGetHistory,
    MessagesGetSearchResultsCalendar,
    MessagesSearchByDate,
    MessagesDeleteHistory,
    SearchResultsCalendarPeriod,
    InputMessagesFilterEmpty,
    InputMessagesFilterPhotoVideo,
    TLDeserializer,
    TLConstructors,
    TLObject,
    TLMessage,
    MessagesHistoryResponse
}

/**
 * CalendarMessageScreenService — 日历消息跳转服务层
 *
 * 对应 iOS CalendarMessageScreen 中的 SparseMessageCalendar / messages.getHistory。
 *
 * 封装以下 TL 方法调用，直接通过 MTProtoClient 与 Telegram 服务器通信：
 *
 *   messages.getHistory (offset_date)  → 按日期定位消息锚点
 *   messages.search     (offset_date)  → 按日期搜索某天的媒体消息
 *
 * 调用链：CalendarMessageScreenService → getMTProtoClient().sendRequest(TLMethod.toBytes())
 *          → MTProtoClient → MTProtoTransport → Telegram Server
 */

private var _calendarMessageServiceInstance: Option<CalendarMessageScreenService> = None

public func getCalendarMessageScreenService(): CalendarMessageScreenService {
    match (_calendarMessageServiceInstance) {
        case Some(s) => s
        case None =>
            let s = CalendarMessageScreenService()
            _calendarMessageServiceInstance = Some(s)
            s
    }
}

/**
 * 日历某天消息查询结果
 */
public class CalendarDayResult {
    public var messages: ArrayList<TLMessage> = ArrayList<TLMessage>()
    public var offsetMsgId: Int32 = 0
    public var hasMessages: Bool = false
    public var errorMessage: String = ""
}

/**
 * P2-096: messages.getSearchResultsCalendar 响应结果
 * 每个 SearchResultsCalendarPeriod 表示某天/周期内有消息的聚合信息。
 */
public class CalendarPeriodsResult {
    public var periods: ArrayList<SearchResultsCalendarPeriod> = ArrayList<SearchResultsCalendarPeriod>()
    // messages.searchResultsCalendar.messages：每个 period 的 min_msg_id 对应的消息本体
    // （iOS SparseMessageCalendar.Entry.message，日历格缩略图来源）
    public var messages: ArrayList<TLMessage> = ArrayList<TLMessage>()
    public var errorMessage: String = ""
}

/**
 * P2-099: 某天媒体预览查询结果（messages.search with PhotoVideo filter）
 */
public class DayMediaResult {
    public var mediaMessages: ArrayList<TLMessage> = ArrayList<TLMessage>()
    public var errorMessage: String = ""
}

/**
 * P2-098: 区间删除 / 清空历史结果
 */
public class DeleteRangeResult {
    public var success: Bool = false
    public var errorMessage: String = ""
}

public class CalendarMessageScreenService {

    /**
     * 按日期获取消息历史锚点（messages.getHistory with offset_date）
     *
     * 对应 iOS CalendarMessageScreen 中 navigateToOffset：
     * - offsetDate = 目标天 00:00:00 UTC 时间戳（Int32）
     * - addOffset = -1（从该日期向前偏移一条，确保落在该天第一条消息上）
     * - limit = 30（取前 30 条供页面展示）
     *
     * @param peerType  "user" / "chat" / "channel"
     * @param peerId    peer 的数字 ID
     * @param dayTimestamp  目标天 Unix 时间戳（精确到秒）
     * @return CalendarDayResult（含消息列表及首条消息 ID）
     */
    public func getMessagesForDate(
        peerType: String,
        peerId: Int64,
        dayTimestamp: Int32
    ): CalendarDayResult {
        Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] getMessagesForDate peer=${peerId} date=${dayTimestamp}")
        let result = CalendarDayResult()
        try {
            let client = getMTProtoClient()
            let req = MessagesGetHistory()
            req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
            req.offsetDate = dayTimestamp
            req.offsetId = 0
            req.addOffset = -1
            // iOS searchMessageIdByTimestamp：limit 1 → 返回的唯一一条就是 offset_date 之后的首条消息
            req.limit = 1
            req.maxId = 0
            req.minId = 0
            req.hash = 0

            let responseData = client.sendRequest(req.toBytes())

            if (responseData.size == 0) {
                Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] getMessagesForDate: empty response")
                return result
            }

            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let checkConstructor = checkD.readUInt32()
                if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                    let errorCode = checkD.readInt32()
                    let errorMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] getMessagesForDate RPC Error: ${errorCode}")
                    result.errorMessage = errorMsg
                    return result
                }
            }

            let historyResp = MessagesHistoryResponse.deserialize(responseData)
            result.messages = historyResp.messages
            result.hasMessages = historyResp.messages.size > 0
            if (historyResp.messages.size > 0) {
                result.offsetMsgId = historyResp.messages[0].id
            }
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] getMessagesForDate: ${result.messages.size} msgs")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] getMessagesForDate exception")
            result.errorMessage = e.toString()
        }
        return result
    }

    /**
     * 按日期探测某天是否有消息（messages.getHistory with offset_date, limit=1）
     *
     * 对应 iOS CalendarMessageScreen 中 SparseMessageCalendar.loadMore：
     * 以极小 limit=1 探测该天时间点附近是否存在消息，
     * 日历格子据此判断该天是否可点击。
     *
     * @param peerType  "user" / "chat" / "channel"
     * @param peerId    peer 的数字 ID
     * @param dayTimestamp  目标天 Unix 时间戳
     * @return CalendarDayResult（hasMessages == true 表示该天有消息）
     */
    public func probeMessagesInDay(
        peerType: String,
        peerId: Int64,
        dayTimestamp: Int32
    ): CalendarDayResult {
        Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] probeMessagesInDay peer=${peerId} day=${dayTimestamp}")
        let result = CalendarDayResult()
        try {
            let client = getMTProtoClient()
            let req = MessagesGetHistory()
            req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
            req.offsetDate = dayTimestamp
            req.offsetId = 0
            req.addOffset = 0
            req.limit = 1
            req.maxId = 0
            req.minId = 0
            req.hash = 0

            let responseData = client.sendRequest(req.toBytes())

            if (responseData.size == 0) {
                return result
            }

            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let checkConstructor = checkD.readUInt32()
                if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                    let errorCode = checkD.readInt32()
                    let errorMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] probeMessagesInDay RPC Error: ${errorCode}")
                    result.errorMessage = errorMsg
                    return result
                }
            }

            let probeResp = MessagesHistoryResponse.deserialize(responseData)
            result.messages = probeResp.messages
            result.hasMessages = probeResp.messages.size > 0
            if (probeResp.messages.size > 0) {
                result.offsetMsgId = probeResp.messages[0].id
            }
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] probeMessagesInDay: hasMessages=${result.hasMessages}")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] probeMessagesInDay exception")
            result.errorMessage = e.toString()
        }
        return result
    }

    /**
     * P2-096: messages.getSearchResultsCalendar — 加载日历聚合周期
     *
     * 向服务器查询该 peer 的全部消息日历（哪些天有消息），返回 SearchResultsCalendarPeriod 列表。
     * 每个 period.date 是某天/某周期的起始时间戳（UTC 秒），用于日历格"有消息"高亮标记。
     *
     * 调用链: CalendarMessageScreen.aboutToAppear()
     *         → loadCalendarPeriods(peerType, peerId)
     *         → MessagesGetSearchResultsCalendar.toBytes()
     *         → getMTProtoClient().sendRequest(...)
     *         → parse SearchResultsCalendarPeriod[]
     *
     * @param peerType  "user" / "chat" / "channel"
     * @param peerId    peer 数字 ID
     * @return CalendarPeriodsResult（periods = 有消息天列表）
     */
    public func loadCalendarPeriods(
        peerType: String,
        peerId: Int64
    ): CalendarPeriodsResult {
        Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] loadCalendarPeriods peer=${peerId}")
        let result = CalendarPeriodsResult()
        try {
            let client = getMTProtoClient()
            let req = MessagesGetSearchResultsCalendar()
            req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
            // iOS ChatControllerOpenCalendarSearch：sparseMessageCalendar(tag: .photoOrVideo)
            // → 日历格只以图片/视频消息作为"有媒体"标记并显示缩略图
            req.filter = InputMessagesFilterPhotoVideo()
            req.offsetId = 0
            req.offsetDate = 0

            let responseData = client.sendRequest(req.toBytes())

            if (responseData.size == 0) {
                Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] loadCalendarPeriods: empty response")
                return result
            }

            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let checkConstructor = checkD.readUInt32()
                if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] loadCalendarPeriods RPC Error: ${errCode}")
                    result.errorMessage = errMsg
                    return result
                }
            }

            // Parse messages.searchResultsCalendar#147ee23c
            // flags:# count:int min_date:int min_msg_id:int offset_id_offset:flags.0?int
            // periods:Vector<SearchResultsCalendarPeriod> messages:Vector<Message> chats users
            let d = TLDeserializer(responseData)
            let responseConstructor = d.readUInt32()
            if (responseConstructor != 0x147ee23c) {
                Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] loadCalendarPeriods: unexpected constructor ${responseConstructor}")
                return result
            }
            let flags = d.readInt32()
            let _count = d.readInt32()
            let _minDate = d.readInt32()
            let _minMsgId = d.readInt32()
            // flags.0 → offsetIdOffset (optional Int32)
            if ((flags & 1) != 0) {
                let _ = d.readInt32()
            }
            // periods: Vector<SearchResultsCalendarPeriod#c9b0539f>
            let vecConstructor = d.readUInt32()
            if (vecConstructor == 0x1cb5c415) {
                let periodCount = d.readInt32()
                var i: Int32 = 0
                while (i < periodCount) {
                    let periodConstructor = d.readUInt32()
                    if (periodConstructor == 0xc9b0539f) {
                        let period = SearchResultsCalendarPeriod()
                        period.date = d.readInt32()
                        period.minMsgId = d.readInt32()
                        period.maxMsgId = d.readInt32()
                        period.count = d.readInt32()
                        result.periods.add(period)
                    }
                    i += 1
                }
            }
            // messages: Vector<Message>（period.min_msg_id 对应消息，iOS 用其 media 画日历格缩略图）
            try {
                let msgVec = d.readUInt32()
                if (msgVec == 0x1cb5c415) {
                    let msgCount = d.readInt32()
                    var j: Int32 = 0
                    while (j < msgCount) {
                        let msg = TLMessage.deserializeBoxed(d)
                        if (!msg.isEmpty) {
                            result.messages.add(msg)
                        }
                        j += 1
                    }
                }
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] loadCalendarPeriods: messages vector parse stopped at ${result.messages.size}")
            }
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] loadCalendarPeriods: ${result.periods.size} periods, ${result.messages.size} msgs")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] loadCalendarPeriods exception")
            result.errorMessage = e.toString()
        }
        return result
    }

    /**
     * P2-099: 搜索某天媒体消息用于长按预览
     *
     * 使用 messages.search 以 inputMessagesFilterPhotoVideo 过滤该天范围内的媒体消息（限 12 条）。
     * min_date = 当天 00:00:00 UTC，max_date = 当天 23:59:59 UTC。
     *
     * @param peerType     "user" / "chat" / "channel"
     * @param peerId       peer 数字 ID
     * @param dayTimestamp 当天 00:00:00 UTC 时间戳
     * @return DayMediaResult（mediaMessages = 该天媒体消息列表，最多 12 条）
     */
    public func searchDayMedia(
        peerType: String,
        peerId: Int64,
        dayTimestamp: Int32
    ): DayMediaResult {
        Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] searchDayMedia peer=${peerId} day=${dayTimestamp}")
        let result = DayMediaResult()
        try {
            let client = getMTProtoClient()
            let req = MessagesSearchByDate()
            req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
            req.q = ""
            req.filter = InputMessagesFilterPhotoVideo()
            req.minDate = dayTimestamp
            req.maxDate = dayTimestamp + 86399
            req.offsetId = 0
            req.addOffset = 0
            req.limit = 12
            req.maxId = 0
            req.minId = 0
            req.hash = 0

            let responseData = client.sendRequest(req.toBytes())

            if (responseData.size == 0) {
                return result
            }

            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let checkConstructor = checkD.readUInt32()
                if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] searchDayMedia RPC Error: ${errCode}")
                    result.errorMessage = errMsg
                    return result
                }
            }

            let histResp = MessagesHistoryResponse.deserialize(responseData)
            let msgs = histResp.messages
            var idx: Int64 = 0
            while (idx < msgs.size) {
                result.mediaMessages.add(msgs[idx])
                idx += 1
            }
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] searchDayMedia: ${result.mediaMessages.size} media msgs")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] searchDayMedia exception")
            result.errorMessage = e.toString()
        }
        return result
    }

    /**
     * P2-098: 按日期区间删除消息（messages.deleteHistory with min_date/max_date）
     *
     * 使用已有 MessagesDeleteHistory（flags bit2=min_date, bit3=max_date）执行区间删除。
     * revoke=true 表示双向删除（对方也删除）。
     *
     * @param peerType  "user" / "chat" / "channel"
     * @param peerId    peer 数字 ID
     * @param minDate   区间起始时间戳（该天 00:00:00 UTC）
     * @param maxDate   区间结束时间戳（结束天 23:59:59 UTC）
     * @param revoke    true = 双向删除
     * @return DeleteRangeResult
     */
    public func deleteHistoryRange(
        peerType: String,
        peerId: Int64,
        minDate: Int32,
        maxDate: Int32,
        revoke: Bool
    ): DeleteRangeResult {
        Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] deleteHistoryRange peer=${peerId} min=${minDate} max=${maxDate}")
        let result = DeleteRangeResult()
        try {
            let client = getMTProtoClient()
            let req = MessagesDeleteHistory()
            req.peer = getRealMessageService().buildInputPeer(peerType, peerId)
            req.justClear = false
            req.revoke = revoke
            req.maxId = 0
            req.minDate = minDate
            req.maxDate = maxDate

            let responseData = client.sendRequest(req.toBytes())

            if (responseData.size == 0) {
                result.success = true
                return result
            }

            if (responseData.size >= 4) {
                let checkD = TLDeserializer(responseData)
                let checkConstructor = checkD.readUInt32()
                if (checkConstructor == TLConstructors.RPC_ERROR || checkConstructor == 0x2144ca19) {
                    let errCode = checkD.readInt32()
                    let errMsg = checkD.readString()
                    Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] deleteHistoryRange RPC Error: ${errCode}")
                    result.errorMessage = errMsg
                    return result
                }
            }
            result.success = true
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] deleteHistoryRange: success")
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] deleteHistoryRange exception")
            result.errorMessage = e.toString()
        }
        return result
    }

    /**
     * P2-098: 清空整个对话历史（messages.deleteHistory with just_clear=true）
     *
     * just_clear=true: 仅本地清空（服务端保留）; revoke=true 时双向清空。
     * 对应 iOS ClearChatMessages / deleteHistory(clearForEveryone=true)。
     *
     * @param peerType  "user" / "chat" / "channel"
     * @param peerId    peer 数字 ID
     * @param revoke    true = 双向清空（对方也删除）
     * @return DeleteRangeResult
     */
    public func clearHistory(
        peerType: String,
        peerId: Int64,
        revoke: Bool
    ): DeleteRangeResult {
        Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] clearHistory peer=${peerId} revoke=${revoke}")
        let result = DeleteRangeResult()
        try {
            result.success = getRealMessageService().clearHistory(
                peerType, peerId, maxId: 2147483646, justClear: !revoke, revoke: revoke)
            if (!result.success) { result.errorMessage = "Server rejected clear history" }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[CalendarMsgSvc] clearHistory exception")
            result.errorMessage = e.toString()
        }
        return result
    }

}
