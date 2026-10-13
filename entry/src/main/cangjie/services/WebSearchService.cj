package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.random.Random
import std.sync.*

// ─────────────────────────────────────────────────────────────────────────────
// TL Data Structure — messages.sendInlineBotResult (unique to WebSearchService)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * messages.sendInlineBotResult#c0cf7646 (iOS current layer)
 * flags:# silent:flags.5?true background:flags.6?true
 * clear_draft:flags.7?true hide_via:flags.11?true
 * peer:InputPeer reply_to:flags.0?InputReplyTo random_id:long query_id:long id:string
 * schedule_date:flags.10?int send_as:flags.13?InputPeer
 * quick_reply_shortcut:flags.17?InputQuickReplyShortcut
 * allow_paid_stars:flags.21?long
 * = Updates
 *
 * Constructor: 0xc0cf7646
 * ctor verified: python3 -c "import struct; print(hex(struct.unpack('<I',struct.pack('<i',-1060145594))[0]))"
 *   → 0xc0cf7646
 * iOS ref: Api42.swift:9369 buffer.appendInt32(-1060145594)
 *
 * P2-AUDIT-coverage: previous ctor 0xb16d1f94 was stale (old layer).
 * Updated to iOS current layer ctor 0xc0cf7646.
 *
 * 发送用户从 inline bot 结果中选中的媒体/文章到当前聊天。
 */
public class MessagesSendInlineBotResult <: TLObject {
    public var peerType: String = "user"
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var randomId: Int64 = 0
    public var queryId: Int64 = 0
    public var resultId: String = ""
    public var replyToMsgId: Int32 = 0
    /** silent:flags.5?true —— 静默发送。 */
    public var silent: Bool = false
    /** scheduleDate:flags.10?int —— 定时发送的 Unix 时间戳。 */
    public var scheduleDate: Option<Int32> = None

    public func getConstructorId(): UInt32 { return 0xc0cf7646 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = if (this.replyToMsgId > 0) { 1 } else { 0 }
        if (this.silent) { flags = flags | (1 << 5) }
        match (this.scheduleDate) { case Some(_) => flags = flags | (1 << 10); case None => () }
        serializer.writeInt32(flags)
        if (this.peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (this.peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        if (this.replyToMsgId > 0) {
            serializer.writeUInt32(0x3bd4b7c2)
            serializer.writeInt32(0)
            serializer.writeInt32(this.replyToMsgId)
        }
        serializer.writeInt64(this.randomId)
        serializer.writeInt64(this.queryId)
        serializer.writeString(this.resultId)
        // schedule_date 紧跟 id:string（send_as 等更高位本实现不发）
        match (this.scheduleDate) { case Some(d) => serializer.writeInt32(d); case None => () }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Result Models (web search specific, not present elsewhere)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * 解析后的 inline bot 单条结果（图片/GIF 网格展示用）。
 * 对应 BotInlineResult / BotInlineMediaResult 两种构造器。
 *
 * Note: ChatContextQueryService 有 BotInlineResultEntry / ContextQueryResultItem，
 * 但结构不同（偏向 mention/hashtag/command 场景）；此处专为图片/GIF 网格展示设计。
 */
public class InlineBotResult {
    public var queryId: Int64 = 0
    public var id: String = ""
    public var resultType: String = ""     // "photo", "gif", "video", "article"
    public var title: String = ""
    public var description: String = ""
    public var thumbUrl: String = ""       // 缩略图 URL（用于网格展示）
    public var contentUrl: String = ""     // 完整内容 URL
    public var document: GifItem = GifItem()

    public init() {}
}

/**
 * 解析后的 InlineBotResults 集合（messages.botResults#e021f2f6）。
 */
public class InlineBotResultSet {
    public var queryId: Int64 = 0
    public var nextOffset: String = ""
    public var results: ArrayList<InlineBotResult> = ArrayList<InlineBotResult>()

    public init() {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

private var _webSearchServiceInstance: Option<WebSearchService> = None
private let _webSearchServiceMonitor: Monitor = Monitor()

public func getWebSearchService(): WebSearchService {
    return synchronized(_webSearchServiceMonitor) {
        match (_webSearchServiceInstance) {
            case Some(svc) => svc
            case None =>
                let svc = WebSearchService()
                _webSearchServiceInstance = Some(svc)
                svc
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// WebSearchService
// ─────────────────────────────────────────────────────────────────────────────

/**
 * WebSearchService — Telegram 内置 bot 网络搜索服务
 *
 * 功能：
 *   1. resolveBot(username) → 获取 botId / accessHash（复用 ContactsResolveUsername from TLMethods）
 *   2. getInlineBotResults(botId, query) → 图片 / GIF 结果网格
 *      （复用 MessagesGetInlineBotResults from ChatContextQueryService）
 *   3. sendSelectedResult(queryId, resultId, peer) → 发送用户选中的结果
 *      （使用 MessagesSendInlineBotResult，本文件独有）
 *
 * 对应 iOS WebSearchUI/Sources/WebSearchController.swift：
 *   WebSearchController 协调 @gif/@pic bot 查询，使用 messages.getInlineBotResults
 *
 * 调用链:
 *   getInlineBotResults()
 *     → getMTProtoClient().sendRequest(MessagesGetInlineBotResults)
 *     → parse messages.botResults → InlineBotResultSet
 *   sendSelectedResult()
 *     → getMTProtoClient().sendRequest(MessagesSendInlineBotResult)
 *   resolveBot()
 *     → getMTProtoClient().sendRequest(ContactsResolveUsername)
 *     → parse contacts.resolvedPeer → (botId, accessHash)
 *
 * S-64: aboutToAppear public; R-69: 网络调用放 spawn → launch
 */
public class WebSearchService {

    // 有状态 PRNG，每次调用产生不同 random_id（仿照 RealMessageService:1427 模式）
    private static let _rand = Random()

    // 缓存已解析的 bot 信息，避免重复 resolveBot 调用
    private var cachedGifBotId: Int64 = 0
    private var cachedGifBotHash: Int64 = 0
    private var cachedPicBotId: Int64 = 0
    private var cachedPicBotHash: Int64 = 0
    private var cachedAccountGeneration: Int64 = -1

    /**
     * 解析 bot 用户名（@gif / @pic / 任意 inline bot）。
     *
     * 对应 contacts.resolveUsername#f93ccba3 username:string = contacts.ResolvedPeer
     * 返回 contacts.resolvedPeer#7f077ad9 peer:Peer users:Vector chats:Vector
     *
     * 复用 TLMethods.cj 中的 ContactsResolveUsername。
     *
     * @param username  bot 用户名（不含 @）
     * @return          (userId: Int64, accessHash: Int64) tuple; userId==0 表示失败
     */
    public func resolveBot(username: String): (Int64, Int64) {
        Hilog.info(0, "CjTelegram", "[WebSearchService] resolveBot: ${username}")
        match (getResolveService().resolvePeerByName(username)) {
            case Some(peer) =>
                if (peer.peerType == "user") { return (peer.peerId, peer.accessHash) }
            case None => ()
        }
        return (0, 0)
    }

    /**
     * 向 inline bot 发送搜索查询，获取图片/GIF 结果列表。
     *
     * 对应 messages.getInlineBotResults#514e999d
     * 复用 ChatContextQueryService.MessagesGetInlineBotResults。
     *
     * @param botId        Bot user_id（通过 resolveBot 获取）
     * @param botAccessHash Bot access_hash
     * @param query        搜索关键词
     * @param offset       分页 offset（首页传空字符串）
     * @param peerId       当前聊天 peer ID（可为0，会用 inputPeerUser 或 inputPeerEmpty）
     * @param peerAccessHash 当前聊天 peer access hash
     * @return             InlineBotResultSet，包含结果列表和下一页 offset
     */
    public func getInlineBotResults(
        botId: Int64,
        botAccessHash: Int64,
        query: String,
        offset!: String = "",
        peerId!: Int64 = 0,
        peerAccessHash!: Int64 = 0
    ): InlineBotResultSet {
        Hilog.info(0, "CjTelegram", "[WebSearchService] getInlineBotResults: botId=${botId} query=${query}")
        let client = getMTProtoClient()
        let req = MessagesGetInlineBotResults()
        req.botId = botId
        req.botAccessHash = botAccessHash
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        // iOS GIF search uses the account peer as context; inputPeerSelf is the
        // wire-equivalent form and avoids fabricating user_id=0.
        req.peerType = if (peerId == 0) { "self" } else { "user" }
        req.query = query
        req.offset = offset
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[WebSearchService] getInlineBotResults: empty response")
            return InlineBotResultSet()
        }
        return this.parseBotResults(responseData)
    }

    /**
     * 发送用户选中的 inline bot 结果到当前聊天。
     *
     * 对应当前层 messages.sendInlineBotResult#c0cf7646
     *
     * @param queryId      来自 InlineBotResultSet.queryId
     * @param resultId     来自 InlineBotResult.id（用户选中的那条）
     * @param peerId       目标聊天 peer ID
     * @param peerAccessHash 目标聊天 peer access hash
     * @return             是否发送成功
     */
    public func sendSelectedResult(
        queryId: Int64,
        resultId: String,
        peerId: Int64,
        peerAccessHash: Int64,
        peerType!: String = "user",
        replyToMsgId!: Int32 = 0,
        silent!: Bool = false,
        scheduleDate!: Option<Int32> = None
    ): Bool {
        Hilog.info(0, "CjTelegram", "[WebSearchService] sendSelectedResult: queryId=${queryId} resultId=${resultId}")
        let client = getMTProtoClient()
        let req = MessagesSendInlineBotResult()
        req.peerType = peerType
        req.silent = silent
        req.scheduleDate = scheduleDate
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.randomId = this.makeRandomId()
        req.queryId = queryId
        req.resultId = resultId
        req.replyToMsgId = replyToMsgId
        let responseData = client.sendRequest(req.toBytes())
        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[WebSearchService] sendSelectedResult: no response")
            return false
        }
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()
        if (constructor == 0x2144ca19u32 || constructor == TLConstructors.RPC_ERROR) {
            Hilog.info(0, "CjTelegram", "[WebSearchService] sendSelectedResult: RPC error")
            return false
        }
        Hilog.info(0, "CjTelegram", "[WebSearchService] sendSelectedResult: success")
        return true
    }

    /**
     * 便捷方法：用 @gif bot 搜索 GIF，自动解析 bot 并查询。
     *
     * @param query    搜索词（如 "cat"）
     * @param offset   分页（首页传 ""）
     * @return         InlineBotResultSet
     */
    public func searchGif(query: String, offset!: String = ""): InlineBotResultSet {
        this.ensureAccountCache()
        if (this.cachedGifBotId == 0) {
            let (uid, uhash) = this.resolveBot("gif")
            if (uid == 0) {
                Hilog.info(0, "CjTelegram", "[WebSearchService] searchGif: could not resolve @gif bot")
                return InlineBotResultSet()
            }
            this.cachedGifBotId = uid
            this.cachedGifBotHash = uhash
        }
        return this.getInlineBotResults(
            this.cachedGifBotId,
            this.cachedGifBotHash,
            query,
            offset: offset
        )
    }

    /**
     * 便捷方法：用 @pic bot 搜索图片，自动解析 bot 并查询。
     *
     * @param query    搜索词
     * @param offset   分页（首页传 ""）
     * @return         InlineBotResultSet
     */
    public func searchImage(query: String, offset!: String = ""): InlineBotResultSet {
        this.ensureAccountCache()
        if (this.cachedPicBotId == 0) {
            let (uid, uhash) = this.resolveBot("pic")
            if (uid == 0) {
                Hilog.info(0, "CjTelegram", "[WebSearchService] searchImage: could not resolve @pic bot")
                return InlineBotResultSet()
            }
            this.cachedPicBotId = uid
            this.cachedPicBotHash = uhash
        }
        return this.getInlineBotResults(
            this.cachedPicBotId,
            this.cachedPicBotHash,
            query,
            offset: offset
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private parse helpers
    // ─────────────────────────────────────────────────────────────────────────

    /** Inline bot identities are account-owned; never reuse them after switching. */
    private func ensureAccountCache(): Unit {
        let generation = getEntityKeyboardStore().currentToken().generation
        if (this.cachedAccountGeneration != generation) {
            this.cachedAccountGeneration = generation
            this.cachedGifBotId = 0
            this.cachedGifBotHash = 0
            this.cachedPicBotId = 0
            this.cachedPicBotHash = 0
        }
    }

    /**
     * 解析 messages.botResults#e021f2f6 响应。
     */
    private func parseBotResults(data: Array<Byte>): InlineBotResultSet {
        let d = TLDeserializer(data)
        let resultSet = InlineBotResultSet()
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19u32) {
            if (data.size >= 12) {
                let errorCode = d.readInt32()
                let _ = d.readString()
                Hilog.info(0, "CjTelegram", "[WebSearchService] getInlineBotResults RPC error ${errorCode}")
            }
            return resultSet
        }

        // messages.botResults#e021f2f6
        if (constructor != 0xe021f2f6u32) {
            Hilog.info(0, "CjTelegram", "[WebSearchService] parseBotResults: unknown constructor")
            return resultSet
        }

        if (d.getOffset() + 12 > data.size) { return resultSet }
        let flags = d.readInt32()
        resultSet.queryId = d.readInt64()

        // next_offset: flags.1?string
        if ((flags & 2) != 0 && d.getOffset() + 4 < data.size) {
            resultSet.nextOffset = d.readString()
        }

        // switch_pm: flags.2?InlineBotSwitchPM — skip
        if ((flags & 4) != 0 && d.getOffset() + 8 < data.size) {
            let _ = d.readString()
            let _ = d.readString()
        }

        // switch_webview: flags.3?InlineBotWebView — skip
        if ((flags & 8) != 0 && d.getOffset() + 8 < data.size) {
            let _ = d.readString()
            let _ = d.readString()
        }

        // results: Vector<BotInlineResult>
        if (d.getOffset() + 8 > data.size) { return resultSet }
        let vecCtor = d.readUInt32()
        if (vecCtor != TLConstructors.VECTOR) { return resultSet }
        let resultCount = d.readInt32()

        var ri: Int32 = 0
        while (ri < resultCount && d.getOffset() + 4 < data.size) {
            let itemOpt = this.parseBotInlineResult(d, data)
            match (itemOpt) {
                case Some(r) =>
                    // A query id is scoped to the returned collection. Keep it on
                    // every item so loading page N never invalidates page N-1.
                    r.queryId = resultSet.queryId
                    resultSet.results.add(r)
                case None => ri = resultCount
            }
            ri += 1
        }

        Hilog.info(0, "CjTelegram", "[WebSearchService] parseBotResults: ${resultSet.results.size} results")
        return resultSet
    }

    /**
     * 解析单条 BotInlineResult 或 BotInlineMediaResult。
     *
     * botInlineResult#11965f3a — web results (有 url / thumb)
     * botInlineMediaResult#17db940b — media results (有 photo / document)
     */
    private func parseBotInlineResult(d: TLDeserializer, data: Array<Byte>): Option<InlineBotResult> {
        if (d.getOffset() + 4 > data.size) { return None }
        let ctor = d.readUInt32()
        let item = InlineBotResult()

        if (ctor == 0x11965f3au32) {
            // botInlineResult
            if (d.getOffset() + 4 > data.size) { return None }
            let flags = d.readInt32()
            item.id = d.readString()
            item.resultType = d.readString()
            if ((flags & 2) != 0) { item.title = d.readString() }
            if ((flags & 4) != 0) { item.description = d.readString() }
            if ((flags & 8) != 0) { item.contentUrl = d.readString() }
            if ((flags & 16) != 0) {
                item.thumbUrl = this.skipWebDocument(d, data)
            }
            if ((flags & 32) != 0) {
                let content = this.skipWebDocument(d, data)
                if (!content.isEmpty()) { item.contentUrl = content }
            }
            if (!this.skipBotInlineMessage(d)) { return None }
            return Some(item)
        } else if (ctor == 0x17db940bu32) {
            // botInlineMediaResult
            if (d.getOffset() + 4 > data.size) { return None }
            let flags = d.readInt32()
            item.id = d.readString()
            item.resultType = d.readString()
            if ((flags & 1) != 0) { skipPhoto(d) }
            if ((flags & 2) != 0) { item.document = parseGifDocument(d) }
            if ((flags & 4) != 0) { item.title = d.readString() }
            if ((flags & 8) != 0) { item.description = d.readString() }
            if (!this.skipBotInlineMessage(d)) { return None }
            return Some(item)
        }

        Hilog.info(0, "CjTelegram", "[WebSearchService] parseBotInlineResult: unknown ctor")
        return None
    }

    /**
     * Skip a WebDocument entry and return its URL (if readable).
     * webDocument#1c570ed1 url:string access_hash:long size:int mime_type:string
     *   attributes:Vector<DocumentAttribute>
     */
    private func skipWebDocument(d: TLDeserializer, data: Array<Byte>): String {
        if (d.getOffset() + 4 > data.size) { return "" }
        let wdCtor = d.readUInt32()
        if (wdCtor != 0x1c570ed1u32 && wdCtor != 0xf9c8bcc6u32) { return "" }
        if (d.getOffset() + 4 > data.size) { return "" }
        let url = d.readString()
        if (d.getOffset() + 12 > data.size) { return url }
        if (wdCtor == 0x1c570ed1u32) { let _ = d.readInt64() } // access_hash
        let _ = d.readInt32()   // size
        let _ = d.readString()  // mime_type
        // skip attributes vector
        if (d.getOffset() + 8 < data.size) {
            let avCtor = d.readUInt32()
            if (avCtor == TLConstructors.VECTOR) {
                let attrCount = d.readInt32()
                var ai: Int32 = 0
                while (ai < attrCount && d.getOffset() + 4 < data.size) {
                    skipDocumentAttribute(d)
                    ai += 1
                }
            }
        }
        return url
    }

    /**
     * Consume the complete BotInlineMessage attached to a GIF result. The old
     * parser returned before this mandatory field, so the next result started at
     * the message constructor and pagination appeared to contain a single item.
     */
    private func skipBotInlineMessage(d: TLDeserializer): Bool {
        let ctor = d.readUInt32()
        if (ctor == 0x764cf810 || ctor == 0x8c7f65e2) {
            let flags = d.readInt32()
            let _ = d.readString()
            if ((flags & 2) != 0) { skipMessageEntitiesVector(d) }
            if ((flags & 4) != 0) { skipReplyMarkup(d) }
            return true
        }
        if (ctor == 0x18d1cdc2) {
            let flags = d.readInt32()
            let _ = d.readString()
            let _ = d.readString()
            let _ = d.readString()
            let _ = d.readString()
            if ((flags & 4) != 0) { skipReplyMarkup(d) }
            return true
        }
        if (ctor == 0x051846fd) {
            let flags = d.readInt32()
            skipGeoPoint(d)
            if ((flags & 1) != 0) { let _ = d.readInt32() }
            if ((flags & 2) != 0) { let _ = d.readInt32() }
            if ((flags & 8) != 0) { let _ = d.readInt32() }
            if ((flags & 4) != 0) { skipReplyMarkup(d) }
            return true
        }
        if (ctor == 0x8a86659c) {
            let flags = d.readInt32()
            skipGeoPoint(d)
            let _ = d.readString()
            let _ = d.readString()
            let _ = d.readString()
            let _ = d.readString()
            let _ = d.readString()
            if ((flags & 4) != 0) { skipReplyMarkup(d) }
            return true
        }
        if (ctor == 0x809ad9a6) {
            let flags = d.readInt32()
            let _ = d.readString()
            if ((flags & 2) != 0) { skipMessageEntitiesVector(d) }
            let _ = d.readString()
            if ((flags & 4) != 0) { skipReplyMarkup(d) }
            return true
        }
        Hilog.info(0, "CjTelegram", "[WebSearchService] unsupported BotInlineMessage ctor=${ctor}")
        return false
    }

    /**
     * 生成随机 Int64 用作 random_id（有状态 PRNG，每次调用返回不同值）。
     * 仿照 RealMessageService._rand 模式：high/low 各取一个 nextUInt32()。
     */
    private func makeRandomId(): Int64 {
        let high = Int64(WebSearchService._rand.nextUInt32() & 0x7FFFFFFF)
        let low = Int64(WebSearchService._rand.nextUInt32())
        return (high << 32) | (low & 0xFFFFFFFF)
    }
}
