package ohos_app_cangjie_entry.viewmodels

import kit.ArkUI.*
import kit.PerformanceAnalysisKit.Hilog
import ohos.arkui.state_macro_manage.*
import std.collection.ArrayList
import std.sync.ReentrantMutex
import ohos_app_cangjie_entry.services.*

/**
 * 聊天输入框上下文查询 ViewModel
 *
 * 对应 iOS ChatContextQuery.swift 的 textInputStateContextQueryRangeAndType 逻辑
 * 以及 TelegramCore contacts.search / messages.getInlineBotResults 的 UI 层封装
 *
 * 功能：
 * - 监听输入框文本变化，识别 @mention / #hashtag / /command / @bot query 触发态
 * - 调用 ChatContextQueryService 获取真实候选列表（contacts.search / getInlineBotResults）
 * - 持有 @Publish 查询结果，供 ChatRoomPage / InputPanel 组件绑定展示
 *
 * 调用链:
 *   onInputChanged(text)
 *     → ChatContextQueryService.queryForInput(...)
 *       → [Mention]   getMTProtoClient().sendRequest(ContactsSearch)    → ContactsFoundResponse
 *       → [InlineBot] getMTProtoClient().sendRequest(MessagesGetInlineBotResults) → BotResultsResponse
 *       → [Hashtag/Command] 本地处理，无 TL 调用
 *     → results @Publish → UI 渲染候选面板
 */
@Observed
public class ChatContextQueryViewModel {

    // ==================== 查询状态 ====================

    /** 当前激活的查询类型（"" 表示无激活查询） */
    @Publish public var activeQueryType: String = ""

    /** 当前查询字符串 */
    @Publish public var activeQueryText: String = ""

    /** 查询结果列表 */
    @Publish public var queryResults: ArrayList<ContextQueryResultItem> = ArrayList<ContextQueryResultItem>()

    /** 查询中标志 */
    @Publish public var isQuerying: Bool = false

    /** 错误信息（空 = 无错误） */
    @Publish public var queryError: String = ""

    /** 是否显示候选面板 */
    @Publish public var showSuggestions: Bool = false

    // inline bot 分页
    @Publish public var inlineBotNextOffset: String = ""
    @Publish public var inlineBotQueryId: Int64 = 0
    // switch_pm 按钮数据（来自 BotResultsResponse.flags.2）
    @Publish public var inlineBotSwitchPmText: String = ""
    @Publish public var inlineBotSwitchPmStartParam: String = ""
    // switch_webview 按钮数据（P2-029 接线点）
    @Publish public var inlineBotSwitchWebviewText: String = ""
    @Publish public var inlineBotSwitchWebviewUrl: String = ""
    // gallery flag: true=横向网格(photo/gif), false=纵向列表(article)
    @Publish public var inlineBotIsGallery: Bool = false

    // ==================== 上下文信息（由 ChatRoomPage 注入） ====================

    /** 当前聊天的 peer ID */
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var peerType: String = "user"

    /** Bot 命令列表（对话是 Bot 时注入） */
    public var botCommands: ArrayList<(String, String)> = ArrayList<(String, String)>()

    // ==================== 内部状态 ====================

    private var _lastInputText: String = ""
    private let _mutex = ReentrantMutex()

    // ==================== 输入变化处理 ====================

    /**
     * 输入框文本变化时调用
     *
     * 解析触发态并异步执行查询；若无触发态则清除建议面板
     *
     * 调用方：ChatRoomPage / InputPanel 的 onChange 回调
     */
    public func onInputChanged(inputText: String): Unit {
        synchronized (this._mutex) {
            this._lastInputText = inputText
        }

        let service = getChatContextQueryService()
        let (qType, queryStr, _) = service.parseQueryType(inputText)

        let hasQuery = match (qType) {
            case ContextQueryType.Mention => queryStr.size > 0
            case ContextQueryType.Hashtag => queryStr.size > 0
            case ContextQueryType.Command => true
            case ContextQueryType.InlineBot => true
        }

        if (!hasQuery) {
            this.clearSuggestions()
            return
        }

        let qTypeName = match (qType) {
            case ContextQueryType.Mention => "mention"
            case ContextQueryType.Hashtag => "hashtag"
            case ContextQueryType.Command => "command"
            case ContextQueryType.InlineBot => "inline_bot"
        }

        this.activeQueryType = qTypeName
        this.activeQueryText = queryStr
        this.isQuerying = true
        this.queryError = ""

        // 在后台线程执行查询，避免阻塞主线程
        let capturedInput = inputText
        let capturedPeerId = this.peerId
        let capturedPeerHash = this.peerAccessHash
        let capturedPeerType = this.peerType
        let capturedCmds = this.botCommands

        let _ = spawn {
            let svc = getChatContextQueryService()
            let resp = svc.queryForInput(
                capturedInput,
                capturedPeerId,
                capturedPeerHash,
                capturedPeerType,
                botCommands: capturedCmds
            )
            this.handleQueryResponse(resp)
        }
    }

    /**
     * 处理查询响应，更新 @Publish 状态
     *
     * 此方法在 spawn 后台线程中调用，所有 @Publish 写操作必须包进 launch{} 回主线程
     */
    private func handleQueryResponse(resp: ContextQueryResponse): Unit {
        if (!resp.success) {
            let capturedError = resp.errorMessage
            launch {
                this.isQuerying = false
                this.queryError = capturedError
                this.showSuggestions = false
            }
            return
        }

        let capturedItems = resp.items
        let capturedNextOffset = resp.nextOffset
        let capturedQueryId = resp.queryId
        let capturedSwitchPmText = resp.switchPmText
        let capturedSwitchPmStartParam = resp.switchPmStartParam
        let capturedSwitchWebviewText = resp.switchWebviewText
        let capturedSwitchWebviewUrl = resp.switchWebviewUrl
        let capturedIsGallery = resp.isGallery
        let capturedShowSuggestions = resp.items.size > 0 || resp.switchPmText.size > 0
        Hilog.info(0, "CjTelegram", "[ChatContextQueryVM] query response: ${resp.items.size} items switchPm='${resp.switchPmText}'")
        launch {
            this.isQuerying = false
            this.queryResults = capturedItems
            this.inlineBotNextOffset = capturedNextOffset
            this.inlineBotQueryId = capturedQueryId
            this.inlineBotSwitchPmText = capturedSwitchPmText
            this.inlineBotSwitchPmStartParam = capturedSwitchPmStartParam
            this.inlineBotSwitchWebviewText = capturedSwitchWebviewText
            this.inlineBotSwitchWebviewUrl = capturedSwitchWebviewUrl
            this.inlineBotIsGallery = capturedIsGallery
            this.showSuggestions = capturedShowSuggestions
        }
    }

    // ==================== 分页加载（InlineBot） ====================

    /**
     * 加载下一页内联 Bot 结果（nextOffset 非空时可用）
     */
    public func loadNextInlineBotPage(
        botId: Int64,
        botAccessHash: Int64,
        query: String
    ): Unit {
        if (this.inlineBotNextOffset.isEmpty()) {
            return
        }

        let capturedOffset = this.inlineBotNextOffset
        let capturedPeerId = this.peerId
        let capturedPeerHash = this.peerAccessHash
        let capturedPeerType = this.peerType
        this.isQuerying = true

        let _ = spawn {
            let svc = getChatContextQueryService()
            let resp = svc.getInlineBotResults(
                botId,
                botAccessHash,
                capturedPeerId,
                capturedPeerHash,
                capturedPeerType,
                query,
                offset: capturedOffset
            )
            if (resp.success) {
                // 追加到现有结果：先在后台线程收集好新条目，再用 launch 回主线程写 @Publish
                let capturedNewItems = resp.items
                let capturedNextOffset = resp.nextOffset
                launch {
                    // temp-var pattern: @State/@Publish ArrayList 禁止直接 .add()，必须全量替换
                    var merged = ArrayList<ContextQueryResultItem>()
                    for (existing in this.queryResults) { merged.add(existing) }
                    for (item in capturedNewItems) { merged.add(item) }
                    this.queryResults = merged
                    this.inlineBotNextOffset = capturedNextOffset
                    this.isQuerying = false
                    this.showSuggestions = this.queryResults.size > 0
                }
            } else {
                let capturedError = resp.errorMessage
                launch {
                    this.isQuerying = false
                    this.queryError = capturedError
                }
            }
        }
    }

    // ==================== 用户选中候选项 ====================

    /**
     * 用户点击候选项后调用
     *
     * 返回需要替换到输入框的文本（调用方负责替换 inputText）
     * - Mention: "@username "
     * - Hashtag: "#tag "
     * - Command: "/command"
     * - InlineBot: 由上层用 inlineSendText 直接发送，此处返回空
     */
    public func onResultSelected(item: ContextQueryResultItem): String {
        this.clearSuggestions()

        match (item.queryType) {
            case "mention" =>
                if (item.username.size > 0) {
                    return "@" + item.username + " "
                }
                return ""
            case "hashtag" =>
                return "#" + item.hashtagText + " "
            case "command" =>
                return "/" + item.commandText
            case "inline_bot" =>
                return ""
            case _ =>
                return ""
        }
    }

    // ==================== 清除状态 ====================

    /**
     * 清除建议面板（输入框清空或用户取消）
     */
    public func clearSuggestions(): Unit {
        this.showSuggestions = false
        this.activeQueryType = ""
        this.activeQueryText = ""
        this.queryResults = ArrayList<ContextQueryResultItem>()
        this.queryError = ""
        this.isQuerying = false
        this.inlineBotNextOffset = ""
        this.inlineBotQueryId = 0
        this.inlineBotSwitchPmText = ""
        this.inlineBotSwitchPmStartParam = ""
        this.inlineBotSwitchWebviewText = ""
        this.inlineBotSwitchWebviewUrl = ""
        this.inlineBotIsGallery = false
    }
}
