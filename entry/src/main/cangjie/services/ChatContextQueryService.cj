package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList

// ==================== 上下文查询类型 ====================

/**
 * 输入框上下文查询触发类型
 *
 * 对应 iOS ChatContextQuery.swift PossibleContextQueryTypes / ChatPresentationInputQueryKind
 */
public enum ContextQueryType {
    | Mention      // @ 提及：输入 @username
    | Hashtag      // # 话题标签：输入 #tag
    | Command      // / 命令：输入 /command
    | InlineBot    // @botname query：inline bot 查询
}

// ==================== 上下文查询结果条目 ====================

/**
 * 单条上下文查询结果
 *
 * 对应 iOS ContactDisplayData / InlineBotResult 的合并抽象
 */
public class ContextQueryResultItem {
    // 通用字段
    public var resultId: String = ""
    public var queryType: String = ""   // "mention" | "hashtag" | "command" | "inline_bot"
    // Mention / InlineBot 用户信息
    public var userId: Int64 = 0
    public var accessHash: Int64 = 0
    public var username: String = ""
    public var displayName: String = ""
    public var isBot: Bool = false
    // Hashtag
    public var hashtagText: String = ""
    // Command
    public var commandText: String = ""
    public var commandDescription: String = ""
    // InlineBot 结果
    public var inlineTitle: String = ""
    public var inlineDescription: String = ""
    public var inlineSendText: String = ""
    public var inlineThumbnailUrl: String = ""
    // Inline bot: 机器人信息
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var queryId: Int64 = 0
    // Inline bot: 结果类型 ("article"|"photo"|"gif"|"video"|"audio"|"voice"|"document"|"location"|"venue"|"contact"|"game"|"sticker"|"")
    public var inlineResultType: String = ""
    // switch_pm 按钮数据（来自 BotResultsResponse.switchPmText）
    public var switchPmText: String = ""
    public var switchPmStartParam: String = ""
}

/**
 * 上下文查询响应
 */
public class ContextQueryResponse {
    public var success: Bool = false
    public var queryType: String = ""
    public var items: ArrayList<ContextQueryResultItem> = ArrayList<ContextQueryResultItem>()
    public var nextOffset: String = ""    // inline bot 分页偏移
    public var queryId: Int64 = 0         // inline bot 查询 ID（messages.getInlineBotResults 返回）
    public var errorMessage: String = ""
    // switch_pm 按钮（来自 BotResultsResponse，用于 InlineBotResultPanel UI 显示）
    public var switchPmText: String = ""
    public var switchPmStartParam: String = ""
    // switch_webview 按钮（P2-029 接线点）
    public var switchWebviewText: String = ""
    public var switchWebviewUrl: String = ""
    // gallery: true=横向网格布局（photo/gif）；false=纵向列表（article 等）
    public var isGallery: Bool = false
}

// ==================== TL 方法：MessagesGetInlineBotResults ====================

/**
 * messages.getInlineBotResults#514e999d
 * flags:#
 * bot:InputUser
 * peer:InputPeer
 * geo_point:flags.0?InputGeoPoint
 * query:string
 * offset:string
 * = messages.BotResults
 *
 * 用于 @botname <query> 内联 Bot 查询
 * Constructor: 0x514e999d
 */
public class MessagesGetInlineBotResults <: TLObject {
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"
    public var query: String = ""
    public var offset: String = ""

    public func getConstructorId(): UInt32 { return 0x514e999d }

    public func serialize(serializer: TLSerializer) {
        serializer.writeInt32(0)  // flags (no geo_point)
        // bot: inputUser#f21158c6. 0x7da07ec9 is inputPeerSelf and caused
        // every inline GIF request to be rejected before reaching @gif.
        serializer.writeUInt32(0xf21158c6)
        serializer.writeInt64(this.botId)
        serializer.writeInt64(this.botAccessHash)
        // peer: InputPeer
        if (this.peerType == "channel") {
            serializer.writeUInt32(0x27bcbbfc)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        } else if (this.peerType == "chat") {
            serializer.writeUInt32(0x35a95cb9)
            serializer.writeInt64(this.peerId)
        } else if (this.peerType == "empty") {
            serializer.writeUInt32(0x7f3b18ea)
        } else if (this.peerType == "self") {
            serializer.writeUInt32(0x7da07ec9)
        } else {
            serializer.writeUInt32(0xdde8a54c)
            serializer.writeInt64(this.peerId)
            serializer.writeInt64(this.peerAccessHash)
        }
        serializer.writeString(this.query)
        serializer.writeString(this.offset)
    }
}

// ==================== TL 响应：BotResults ====================

/**
 * messages.botResults#e021f2f6
 * flags:#
 * gallery:flags.0?true
 * query_id:long
 * next_offset:flags.1?string
 * switch_pm:flags.2?InlineBotSwitchPM
 * switch_webview:flags.3?InlineBotWebView
 * results:Vector<BotInlineResult>
 * cache_time:int
 * users:Vector<User>
 */
public class BotResultsResponse {
    public var queryId: Int64 = 0
    public var nextOffset: String = ""
    public var cacheTime: Int32 = 0
    public var results: ArrayList<BotInlineResultEntry> = ArrayList<BotInlineResultEntry>()
    public var users: ArrayList<UserResponse> = ArrayList<UserResponse>()
    // switch_pm button (flags.2): InlineBotSwitchPM text + start_param
    public var switchPmText: String = ""
    public var switchPmStartParam: String = ""
    // switch_webview (flags.3): InlineBotWebView text + url (P2-029 接线点)
    public var switchWebviewText: String = ""
    public var switchWebviewUrl: String = ""
    // gallery flag (flags.0)
    public var isGallery: Bool = false

    public static func deserialize(data: Array<Byte>): BotResultsResponse {
        let r = BotResultsResponse()
        if (data.size < 4) {
            return r
        }
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()

        // messages.botResults#e021f2f6
        if (constructor != 0xe021f2f6) {
            return r
        }

        let flags = d.readInt32()
        // gallery: flags.0?true
        r.isGallery = (flags & 1) != 0
        r.queryId = d.readInt64()

        // next_offset: flags.1?string
        if ((flags & 2) != 0) {
            r.nextOffset = d.readString()
        }
        // switch_pm: flags.2?InlineBotSwitchPM text:string start_param:string
        if ((flags & 4) != 0) {
            r.switchPmText = d.readString()
            r.switchPmStartParam = d.readString()
        }
        // switch_webview: flags.3?InlineBotWebView text:string url:string (P2-029 webview 接线点)
        if ((flags & 8) != 0) {
            r.switchWebviewText = d.readString()
            r.switchWebviewUrl = d.readString()
        }

        // results: Vector<BotInlineResult>
        let vecConst = d.readUInt32()
        if (vecConst == TLConstructors.VECTOR) {
            let count = d.readInt32()
            var i: Int32 = 0
            while (i < count) {
                try {
                    let entry = BotInlineResultEntry.deserializeBoxed(d)
                    r.results.add(entry)
                } catch (_e: Exception) {
                    break
                }
                i = i + 1
            }
        }

        r.cacheTime = d.readInt32()

        // users: Vector<User>
        let usersVec = d.readUInt32()
        if (usersVec == TLConstructors.VECTOR) {
            let usersCount = d.readInt32()
            var j: Int32 = 0
            while (j < usersCount) {
                try {
                    r.users.add(UserResponse.deserializeBoxed(d))
                } catch (_e: Exception) {
                    break
                }
                j = j + 1
            }
        }

        return r
    }
}

/**
 * botInlineResult#11965f3a / botInlineMediaResult#17db940b
 * 内联 Bot 单条结果
 *
 * botInlineResult#11965f3a flags:# id:string type:string
 *     title:flags.1?string description:flags.2?string url:flags.3?string
 *     thumb:flags.4?WebDocument content:flags.5?WebDocument
 *     send_message:BotInlineMessage
 *
 * botInlineMediaResult#17db940b flags:# id:string type:string
 *     photo:flags.0?Photo document:flags.1?Document
 *     title:flags.2?string description:flags.3?string
 *     send_message:BotInlineMessage
 */
public class BotInlineResultEntry {
    public var id: String = ""
    public var resultType: String = ""
    public var title: String = ""
    public var description: String = ""
    public var url: String = ""
    public var thumbUrl: String = ""
    public var sendText: String = ""

    public static func deserializeBoxed(d: TLDeserializer): BotInlineResultEntry {
        let e = BotInlineResultEntry()
        let ctor = d.readUInt32()

        if (ctor == 0x11965f3a) {
            // botInlineResult
            let flags = d.readInt32()
            e.id = d.readString()
            e.resultType = d.readString()
            if ((flags & 2) != 0) { e.title = d.readString() }
            if ((flags & 4) != 0) { e.description = d.readString() }
            if ((flags & 8) != 0) { e.url = d.readString() }
            // thumb: flags.4?WebDocument
            if ((flags & 16) != 0) {
                // skip WebDocument: url:string access_hash:long size:int mime_type:string
                let _ = d.readString()
                let _ = d.readInt64()
                let _ = d.readInt32()
                let _ = d.readString()
                // attributes: Vector<DocumentAttribute> (skip)
                let attrVec = d.readUInt32()
                if (attrVec == TLConstructors.VECTOR) {
                    let ac = d.readInt32()
                    var ai: Int32 = 0
                    while (ai < ac) {
                        let _ = d.readUInt32()
                        ai = ai + 1
                    }
                }
            }
            // content: flags.5?WebDocument (skip)
            if ((flags & 32) != 0) {
                let _ = d.readString()
                let _ = d.readInt64()
                let _ = d.readInt32()
                let _ = d.readString()
                let attrVec2 = d.readUInt32()
                if (attrVec2 == TLConstructors.VECTOR) {
                    let ac2 = d.readInt32()
                    var ai2: Int32 = 0
                    while (ai2 < ac2) {
                        let _ = d.readUInt32()
                        ai2 = ai2 + 1
                    }
                }
            }
            // send_message: BotInlineMessage
            e.sendText = parseBotInlineMessageText(d)
        } else if (ctor == 0x17db940b) {
            // botInlineMediaResult
            let flags = d.readInt32()
            e.id = d.readString()
            e.resultType = d.readString()
            // photo/document: skip (complex nested)
            if ((flags & 1) != 0) { skipTLObject(d) }   // Photo
            if ((flags & 2) != 0) { skipTLObject(d) }   // Document
            if ((flags & 4) != 0) { e.title = d.readString() }
            if ((flags & 8) != 0) { e.description = d.readString() }
            // send_message
            e.sendText = parseBotInlineMessageText(d)
        }

        return e
    }
}

/**
 * 解析 BotInlineMessage 的文本内容
 *
 * botInlineMessageText#3a8fd8b8 flags:# no_webpage:flags.0?true message:string
 *     entities:flags.1?Vector<MessageEntity> reply_markup:flags.2?ReplyMarkup
 * botInlineMessageMediaAuto#764cf810 flags:# message:string
 *     entities:flags.1?Vector<MessageEntity> reply_markup:flags.2?ReplyMarkup
 * 其他类型（geo、contact、invoice）— 仅跳过
 */
func parseBotInlineMessageText(d: TLDeserializer): String {
    let msgCtor = d.readUInt32()
    if (msgCtor == 0x3a8fd8b8) {
        // botInlineMessageText
        let flags = d.readInt32()
        let text = d.readString()
        if ((flags & 2) != 0) {
            let entVec = d.readUInt32()
            if (entVec == TLConstructors.VECTOR) {
                let ec = d.readInt32()
                var ei: Int32 = 0
                while (ei < ec) {
                    skipTLObject(d)
                    ei = ei + 1
                }
            }
        }
        return text
    } else if (msgCtor == 0x764cf810) {
        // botInlineMessageMediaAuto
        let flags = d.readInt32()
        let text = d.readString()
        if ((flags & 2) != 0) {
            let entVec = d.readUInt32()
            if (entVec == TLConstructors.VECTOR) {
                let ec = d.readInt32()
                var ei: Int32 = 0
                while (ei < ec) {
                    skipTLObject(d)
                    ei = ei + 1
                }
            }
        }
        return text
    }
    // other inline message types: ignore
    return ""
}

/**
 * 跳过一个 TL 对象（用于跳过不关心的字段）
 * 仅读取构造器 ID 后跳过整个对象（近似：读完 ID 即止）
 * 注意：这是一个近似操作，适用于我们不解析的嵌套类型
 */
func skipTLObject(d: TLDeserializer): Unit {
    let _ = d.readUInt32()
}

// ==================== ChatContextQueryService ====================

private var _ctxQueryServiceInstance: Option<ChatContextQueryService> = None

public func getChatContextQueryService(): ChatContextQueryService {
    match (_ctxQueryServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatContextQueryService()
            _ctxQueryServiceInstance = Some(inst)
            return inst
    }
}

/**
 * 聊天上下文查询服务
 *
 * 对应 iOS ChatContextQuery.swift + TelegramCore contacts/messages 相关方法
 *
 * 功能：
 * - parseQueryType: 解析输入框文本，识别 @mention/#hashtag/@bot/command 触发态
 * - searchMentions: contacts.search 搜索 @mention 用户
 * - getInlineBotResults: messages.getInlineBotResults 查询内联 Bot 结果
 *
 * 调用链:
 *   searchMentions: Service → getMTProtoClient().sendRequest(ContactsSearch) → ContactsFoundResponse
 *   getInlineBotResults: Service → getMTProtoClient().sendRequest(MessagesGetInlineBotResults) → BotResultsResponse
 */
public class ChatContextQueryService {

    // ==================== 解析输入触发类型 ====================

    /**
     * 解析输入文本，返回当前触发的查询类型和查询字符串
     *
     * 规则（对应 iOS textInputStateContextQueryRangeAndType）：
     * - "@username " + 空格 + query → InlineBot (contextRequest)
     * - "@q" → Mention
     * - "#q" → Hashtag
     * - "/q" → Command
     *
     * 返回: (queryType, queryString, botUsername)
     * botUsername 仅 InlineBot 时有值
     */
    public func parseQueryType(inputText: String): (ContextQueryType, String, String) {
        let runes = inputText.toRuneArray()
        let length = runes.size

        if (length == 0) {
            return (ContextQueryType.Mention, "", "")
        }

        // inline bot: "@botname " 后跟查询内容
        if (length > 1 && runes[0] == r'@') {
            var spaceIdx: Int64 = -1
            var idx: Int64 = 1
            while (idx < length) {
                if (runes[idx] == r' ') {
                    spaceIdx = idx
                    break
                }
                idx = idx + 1
            }
            if (spaceIdx > 1 && spaceIdx < length - 1) {
                let botName = String(runes[1..spaceIdx])
                let query = String(runes[(spaceIdx + 1)..length])
                return (ContextQueryType.InlineBot, query, botName)
            }
        }

        // 从光标位置（末尾）往前找触发符
        var i: Int64 = length - 1
        while (i >= 0) {
            let c = runes[i]
            if (c == r' ' || c == r'\n') {
                return (ContextQueryType.Mention, "", "")
            } else if (c == r'@') {
                let query = String(runes[(i + 1)..length])
                return (ContextQueryType.Mention, query, "")
            } else if (c == r'#') {
                let query = String(runes[(i + 1)..length])
                return (ContextQueryType.Hashtag, query, "")
            } else if (c == r'/') {
                let query = String(runes[(i + 1)..length])
                return (ContextQueryType.Command, query, "")
            }
            i = i - 1
        }

        return (ContextQueryType.Mention, "", "")
    }

    // ==================== @Mention: contacts.search ====================

    /**
     * 搜索 @mention 候选用户
     *
     * TL: contacts.search#11f812d8 q:string limit:int = contacts.Found
     * 返回匹配查询字符串的用户列表
     */
    public func searchMentions(query: String, limit!: Int32 = 20): ContextQueryResponse {
        Hilog.info(0, "CjTelegram", "[ChatContextQueryService] searchMentions: q='${query}'")
        let resp = ContextQueryResponse()
        resp.queryType = "mention"

        let client = getMTProtoClient()
        let req = ContactsSearch()
        req.q = query
        req.limit = limit

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ChatContextQueryService] searchMentions: empty response")
            resp.success = false
            resp.errorMessage = "empty response"
            return resp
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == TLConstructors.RPC_ERROR) {
                let errCode = checkD.readInt32()
                let errMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[ChatContextQueryService] searchMentions RPC error: ${errCode}")
                resp.success = false
                resp.errorMessage = errMsg
                return resp
            }
        }

        let found = ContactsFoundResponse.deserialize(responseData)
        resp.success = true

        for (user in found.users) {
            if (user.isEmpty) { continue }
            let item = ContextQueryResultItem()
            item.resultId = "mention_${user.id}"
            item.queryType = "mention"
            item.userId = user.id
            item.accessHash = user.accessHash
            item.username = user.username
            item.isBot = user.isBot
            var name = user.firstName
            if (user.lastName.size > 0) {
                name = name + " " + user.lastName
            }
            if (name.isEmpty() && user.username.size > 0) {
                name = "@" + user.username
            }
            item.displayName = name
            resp.items.add(item)
        }

        Hilog.info(0, "CjTelegram", "[ChatContextQueryService] searchMentions: found ${resp.items.size} results")
        return resp
    }

    // ==================== #Hashtag (本地处理) ====================

    /**
     * 生成 hashtag 查询结果（本地，无需 TL 调用）
     *
     * iOS 端 hashtag 由本地消息索引处理，这里返回查询字符串本身作为唯一候选
     */
    public func buildHashtagResult(query: String): ContextQueryResponse {
        let resp = ContextQueryResponse()
        resp.queryType = "hashtag"
        resp.success = true

        if (query.size > 0) {
            let item = ContextQueryResultItem()
            item.resultId = "hashtag_${query}"
            item.queryType = "hashtag"
            item.hashtagText = query
            resp.items.add(item)
        }

        return resp
    }

    // ==================== /Command (本地处理) ====================

    /**
     * 解析命令列表（本地处理）
     *
     * 将 bot 的命令列表过滤出与 query 前缀匹配的条目
     * commands: List of (commandText, description) pairs
     */
    public func buildCommandResult(
        query: String,
        commands: ArrayList<(String, String)>
    ): ContextQueryResponse {
        let resp = ContextQueryResponse()
        resp.queryType = "command"
        resp.success = true

        for (cmd in commands) {
            let cmdText = cmd[0]
            let cmdDesc = cmd[1]
            if (query.size == 0 || cmdText.startsWith(query)) {
                let item = ContextQueryResultItem()
                item.resultId = "cmd_${cmdText}"
                item.queryType = "command"
                item.commandText = cmdText
                item.commandDescription = cmdDesc
                resp.items.add(item)
            }
        }

        return resp
    }

    // ==================== @botname query: messages.getInlineBotResults ====================

    /**
     * 获取内联 Bot 结果
     *
     * TL: messages.getInlineBotResults#514e999d
     *     flags:# bot:InputUser peer:InputPeer
     *     geo_point:flags.0?InputGeoPoint query:string offset:string
     *     = messages.BotResults
     *
     * 返回内联 Bot 查询结果列表，支持分页（nextOffset）
     */
    public func getInlineBotResults(
        botId: Int64,
        botAccessHash: Int64,
        peerId: Int64,
        peerAccessHash: Int64,
        peerType: String,
        query: String,
        offset!: String = ""
    ): ContextQueryResponse {
        Hilog.info(0, "CjTelegram", "[ChatContextQueryService] getInlineBotResults: botId=${botId}")
        let resp = ContextQueryResponse()
        resp.queryType = "inline_bot"

        let client = getMTProtoClient()
        let req = MessagesGetInlineBotResults()
        req.botId = botId
        req.botAccessHash = botAccessHash
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.peerType = peerType
        req.query = query
        req.offset = offset

        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[ChatContextQueryService] getInlineBotResults: empty response")
            resp.success = false
            resp.errorMessage = "empty response"
            return resp
        }

        if (responseData.size >= 4) {
            let checkD = TLDeserializer(responseData)
            let checkCtor = checkD.readUInt32()
            if (checkCtor == TLConstructors.RPC_ERROR) {
                let errCode = checkD.readInt32()
                let errMsg = checkD.readString()
                Hilog.info(0, "CjTelegram", "[ChatContextQueryService] getInlineBotResults RPC error: ${errCode}")
                resp.success = false
                resp.errorMessage = errMsg
                return resp
            }
        }

        let botResults = BotResultsResponse.deserialize(responseData)
        resp.success = true
        resp.queryId = botResults.queryId
        resp.nextOffset = botResults.nextOffset
        resp.switchPmText = botResults.switchPmText
        resp.switchPmStartParam = botResults.switchPmStartParam
        resp.switchWebviewText = botResults.switchWebviewText
        resp.switchWebviewUrl = botResults.switchWebviewUrl
        resp.isGallery = botResults.isGallery

        for (entry in botResults.results) {
            let item = ContextQueryResultItem()
            item.resultId = "inline_${entry.id}"
            item.queryType = "inline_bot"
            item.botId = botId
            item.botAccessHash = botAccessHash
            item.queryId = botResults.queryId
            item.inlineTitle = entry.title
            item.inlineDescription = entry.description
            item.inlineThumbnailUrl = entry.thumbUrl
            item.inlineSendText = entry.sendText
            item.inlineResultType = entry.resultType
            item.switchPmText = botResults.switchPmText
            item.switchPmStartParam = botResults.switchPmStartParam
            resp.items.add(item)
        }

        Hilog.info(0, "CjTelegram", "[ChatContextQueryService] getInlineBotResults: found ${resp.items.size} results")
        return resp
    }

    // ==================== 统一入口 ====================

    /**
     * 根据输入文本自动识别并执行查询
     *
     * 调用链:
     *   onInputChanged(text)
     *     → parseQueryType(text)
     *     → searchMentions / buildHashtagResult / buildCommandResult / getInlineBotResults
     *
     * botCommands: 当 peerType 是 bot 时传入命令列表（可为空）
     * botId/botAccessHash: InlineBot 场景用；非 InlineBot 场景忽略
     */
    public func queryForInput(
        inputText: String,
        peerId: Int64,
        peerAccessHash: Int64,
        peerType: String,
        botCommands!: ArrayList<(String, String)> = ArrayList<(String, String)>(),
        inlineBotId!: Int64 = 0,
        inlineBotAccessHash!: Int64 = 0
    ): ContextQueryResponse {
        let (qType, queryStr, botName) = this.parseQueryType(inputText)

        match (qType) {
            case ContextQueryType.Mention =>
                if (queryStr.size == 0) {
                    let empty = ContextQueryResponse()
                    empty.success = true
                    empty.queryType = "mention"
                    return empty
                }
                return this.searchMentions(queryStr)

            case ContextQueryType.Hashtag =>
                return this.buildHashtagResult(queryStr)

            case ContextQueryType.Command =>
                return this.buildCommandResult(queryStr, botCommands)

            case ContextQueryType.InlineBot =>
                var resolvedBotId = inlineBotId
                var resolvedBotHash = inlineBotAccessHash
                if (resolvedBotId == 0 && botName.size > 0) {
                    // 尝试通过 contacts.resolveUsername 解析 bot
                    let contactService = getRealContactService()
                    let resolved = contactService.resolveUsername(botName)
                    match (resolved) {
                        case Some(contact) =>
                            resolvedBotId = contact.userId
                            resolvedBotHash = contact.accessHash
                        case None =>
                            let empty = ContextQueryResponse()
                            empty.success = false
                            empty.queryType = "inline_bot"
                            empty.errorMessage = "bot not found: " + botName
                            return empty
                    }
                }
                return this.getInlineBotResults(
                    resolvedBotId,
                    resolvedBotHash,
                    peerId,
                    peerAccessHash,
                    peerType,
                    queryStr
                )
        }
    }
}
