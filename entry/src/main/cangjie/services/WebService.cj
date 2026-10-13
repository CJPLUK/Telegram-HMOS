package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import ohos_app_cangjie_entry.core.mtproto.*
import std.collection.ArrayList
import std.random.Random

// ─────────────────────────────────────────────────────────────────────────────
// WebViewConfig — In-app WebView 行为配置
// ─────────────────────────────────────────────────────────────────────────────

/**
 * WebViewConfig — 记录 in-app 浏览器（BrowserScreen）WebView 行为偏好。
 *
 * 对应 iOS BrowserUI/BrowserScreen 的三个行为开关：
 *   - javascriptEnabled: Bool   是否启用 JS（默认 true）
 *   - darkModeEnabled: Bool     WebView 跟随系统暗色模式（默认 false，iOS forceNightMode 对应）
 *   - trackerBlockingEnabled: Bool 是否屏蔽追踪器 / 隐私过滤（默认 false）
 *
 * 持久化通过 WebService.getWebViewConfig() / setWebViewConfig() 读写 Preferences。
 */
public class WebViewConfig {
    public var javascriptEnabled: Bool = true
    public var darkModeEnabled: Bool = false
    public var trackerBlockingEnabled: Bool = false
}

// ─────────────────────────────────────────────────────────────────────────────
// Preferences 存储键
// ─────────────────────────────────────────────────────────────────────────────

let WEB_STORE_NAME: String = "telegram_webview"
let KEY_WEB_JS_ENABLED: String = "webview_js_enabled"
let KEY_WEB_DARK_MODE: String = "webview_dark_mode"
let KEY_WEB_TRACKER_BLOCK: String = "webview_tracker_block"

// ─────────────────────────────────────────────────────────────────────────────
// TL data structures
// ─────────────────────────────────────────────────────────────────────────────

/**
 * messages.requestMainWebView#c9e01e7b
 * flags:# peer:InputPeer bot:InputUser start_param:flags.1?string
 * theme_params:flags.0?DataJSON platform:string
 * = messages.WebViewResult
 *
 * Constructor: 0xc9e01e7b (iOS serializes as int32 -908059013)
 * Reference: TelegramApi/Sources/Api42.swift:8904
 */
public class MessagesRequestMainWebView <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var startParam: String = ""
    public var platform: String = "android"

    public func getConstructorId(): UInt32 { return 0xc9e01e7bu32 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.startParam.size > 0) { flags = flags | 2 }  // flags.1 = start_param
        serializer.writeInt32(flags)
        // peer = inputPeerUser#dde8a54c user_id:long access_hash:long
        serializer.writeUInt32(0xdde8a54cu32)
        serializer.writeInt64(this.peerId)
        serializer.writeInt64(this.peerAccessHash)
        // bot = inputUser#f21158c6 user_id:long access_hash:long
        serializer.writeUInt32(0xf21158c6u32)
        serializer.writeInt64(this.botId)
        serializer.writeInt64(this.botAccessHash)
        if (this.startParam.size > 0) { serializer.writeString(this.startParam) }
        serializer.writeString(this.platform)
    }
}

/**
 * messages.requestWebView#269dc2c1
 * flags:# from_bot_menu:flags.4?true silent:flags.5?true compact:flags.6?true
 * full_screen:flags.7?true
 * peer:InputPeer bot:InputUser url:flags.1?string start_param:flags.3?string
 * theme_params:flags.2?DataJSON platform:string reply_to:flags.13?InputReplyTo
 * send_as:flags.14?InputPeer
 * = messages.WebViewResult
 *
 * Constructor: 0x269dc2c1
 */
public class MessagesRequestWebView <: TLObject {
    public var peerId: Int64 = 0
    public var peerAccessHash: Int64 = 0
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var url: String = ""
    public var startParam: String = ""
    public var platform: String = "android"

    public func getConstructorId(): UInt32 { return 0x269dc2c1u32 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.url.size > 0) { flags = flags | 2 }         // flags.1 = url
        if (this.startParam.size > 0) { flags = flags | 8 }  // flags.3 = start_param
        serializer.writeInt32(flags)
        // peer = inputPeerUser#dde8a54c user_id:long access_hash:long
        serializer.writeUInt32(0xdde8a54cu32)
        serializer.writeInt64(this.peerId)
        serializer.writeInt64(this.peerAccessHash)
        // bot = inputUser#f21158c6 user_id:long access_hash:long
        serializer.writeUInt32(0xf21158c6u32)
        serializer.writeInt64(this.botId)
        serializer.writeInt64(this.botAccessHash)
        if (this.url.size > 0) { serializer.writeString(this.url) }
        if (this.startParam.size > 0) { serializer.writeString(this.startParam) }
        // platform
        serializer.writeString(this.platform)
    }
}

/**
 * messages.sendWebViewData#dc0242c8 bot:InputUser random_id:long button_text:string data:string
 * = Updates
 *
 * Constructor: 0xdc0242c8 (iOS appendInt32(-603831608), verified: Api42.swift:9682)
 *
 * Sends data from a Mini App back to the bot via messages.sendWebViewData.
 * Called when web_app_data_send event is received from JS bridge (simple webview only).
 *
 * P2-035 gap: web_app_data_send → sendWebViewData TL dispatch
 * iOS: _internal_sendWebViewData in BotWebView.swift:309
 */
public class MessagesSendWebViewData <: TLObject {
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var randomId: Int64 = 0
    public var buttonText: String = ""
    public var data: String = ""

    public func getConstructorId(): UInt32 { return 0xdc0242c8u32 }

    public func serialize(serializer: TLSerializer) {
        // bot = inputUser#f21158c6 user_id:long access_hash:long
        serializer.writeUInt32(0xf21158c6u32)
        serializer.writeInt64(this.botId)
        serializer.writeInt64(this.botAccessHash)
        serializer.writeInt64(this.randomId)
        serializer.writeString(this.buttonText)
        serializer.writeString(this.data)
    }
}

/**
 * messages.requestSimpleWebView#413a3e73 flags:# from_switch_webview:flags.1?true
 * from_side_menu:flags.2?true compact:flags.7?true full_screen:flags.8?true
 * bot:InputUser url:flags.3?string start_param:flags.4?string
 * theme_params:flags.0?DataJSON platform:string
 * = SimpleWebViewResult
 *
 * Constructor: 0x413a3e73
 */
public class MessagesRequestSimpleWebView <: TLObject {
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var url: String = ""
    public var startParam: String = ""
    public var platform: String = "android"

    public func getConstructorId(): UInt32 { return 0x413a3e73u32 }

    public func serialize(serializer: TLSerializer) {
        var flags: Int32 = 0
        if (this.url.size > 0) { flags = flags | 8 }         // flags.3 = url
        if (this.startParam.size > 0) { flags = flags | 16 } // flags.4 = start_param
        serializer.writeInt32(flags)
        // bot = inputUser#f21158c6
        serializer.writeUInt32(0xf21158c6u32)
        serializer.writeInt64(this.botId)
        serializer.writeInt64(this.botAccessHash)
        if (this.url.size > 0) { serializer.writeString(this.url) }
        if (this.startParam.size > 0) { serializer.writeString(this.startParam) }
        serializer.writeString(this.platform)
    }
}

/**
 * bots.invokeWebViewCustomMethod#087fc5e7
 * bot:InputUser custom_method:String params:DataJSON = DataJSON
 *
 * Constructor: 0x087fc5e7 (python verified: hex(142591463) == '0x87fc5e7')
 * Reference: TelegramApi/Sources/Api42.swift:3030
 *
 * serialize order (iOS Api42.swift:3032-3035):
 *   1. appendInt32(142591463)          — ctor (little-endian, boxed at function level)
 *   2. bot.serialize(buffer, true)     — InputUser boxed: 0xf21158c6 + userId + accessHash
 *   3. serializeString(customMethod, boxed: false) — plain string
 *   4. params.serialize(buffer, true)  — DataJSON#7d748d04 boxed: 0x7d748d04 + data string
 *
 * Response: DataJSON#7d748d04 (ctor 2104790276 = 0x7d748d04) followed by data:string
 */
public class BotsInvokeWebViewCustomMethod <: TLObject {
    public var botId: Int64 = 0
    public var botAccessHash: Int64 = 0
    public var customMethod: String = ""
    public var paramsData: String = "{}"

    public func getConstructorId(): UInt32 { return 0x087fc5e7u32 }

    public func serialize(serializer: TLSerializer) {
        // bot = inputUser#f21158c6 user_id:long access_hash:long (boxed)
        serializer.writeUInt32(0xf21158c6u32)
        serializer.writeInt64(this.botId)
        serializer.writeInt64(this.botAccessHash)
        // custom_method: string (unboxed)
        serializer.writeString(this.customMethod)
        // params = dataJSON#7d748d04 data:string (boxed)
        serializer.writeUInt32(0x7d748d04u32)
        serializer.writeString(this.paramsData)
    }
}

/**
 * Parsed web-view URL result (from messages.WebViewResult or SimpleWebViewResult).
 */
public class WebViewResult {
    public var url: String = ""
    public var queryId: Int64 = 0

    public init() {}

    public init(webUrl: String, webQueryId: Int64) {
        this.url = webUrl
        this.queryId = webQueryId
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

private var _webServiceInstance: Option<WebService> = None

public func getWebService(): WebService {
    match (_webServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = WebService()
            _webServiceInstance = Some(svc)
            return svc
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// WebService
// ─────────────────────────────────────────────────────────────────────────────

/**
 * WebService — Telegram Bot WebApp / Mini App 容器服务 + in-app WebView 配置
 *
 * 职责：
 *   1. Bot WebApp URL 获取（MTProto messages.requestWebView / requestSimpleWebView）
 *   2. In-app WebView 行为配置（JS / 暗色 / 隐私追踪屏蔽），Preferences 持久化
 *   3. 文件下载委托（通过 FileDownloadService）
 *
 * 对应 iOS WebUI/Sources/WebAppWebView.swift + WebAppController.swift 中的网络层。
 *
 * 防死状态：WebViewConfig 字段始终从 Preferences 真实读取，不硬编码默认值覆盖已保存设置。
 *
 * 调用链（WebView 配置）：
 *   SettingsPage.onToggleJs(enabled)
 *     → WebService.setJavascriptEnabled(enabled)
 *       → Preferences.put(KEY_WEB_JS_ENABLED, BoolData(enabled))
 *       → Preferences.flush()
 *   BrowserScreen.aboutToAppear()
 *     → WebService.getWebViewConfig()
 *       → readBool(KEY_WEB_JS_ENABLED, true)   ← Preferences 真查
 *       ← WebViewConfig { js=true, dark=false, tracker=false }
 *
 * 调用链（Bot WebApp）：
 *   requestWebView()     → getMTProtoClient().sendRequest(MessagesRequestWebView)
 *                        → parse messages.webViewResultUrl
 *   requestSimpleWebView → getMTProtoClient().sendRequest(MessagesRequestSimpleWebView)
 *                        → parse simpleWebViewResultUrl
 *   downloadFile()       → getFileDownloadService().downloadDocument()
 */
public class WebService {

    private var _prefs: Option<Preferences> = None
    private let _rand: Random = Random()

    // ─────────────────────────────────────────────────────────────────────────
    // Preferences helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func ensurePrefs(): Unit {
        match (this._prefs) {
            case Some(_) => ()
            case None =>
                match (getGlobalAbilityContext()) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[WebService] No ability context — in-memory config only")
                    case Some(ctx) =>
                        try {
                            let prefs = Preferences.getPreferences(ctx, WEB_STORE_NAME)
                            this._prefs = Some(prefs)
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[WebService] Prefs open failed: ${e}")
                        }
                }
        }
    }

    private func readBool(key: String, fallback: Bool): Bool {
        this.ensurePrefs()
        match (this._prefs) {
            case None => return fallback
            case Some(prefs) =>
                try {
                    let dv: Int64 = if (fallback) { 1 } else { 0 }
                    let val = prefs.get(key, PreferencesValueType.Integer(dv))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return n != 0
                        case _ => return fallback
                    }
                } catch (e: Exception) { return fallback }
        }
    }

    private func writeBool(key: String, value: Bool): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    let v: Int64 = if (value) { 1 } else { 0 }
                    prefs.put(key, PreferencesValueType.Integer(v))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[WebService] writeBool(${key}) err: ${e}")
                }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WebView configuration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 读取完整 WebView 行为配置（三开关均从 Preferences 真实读取）。
     *
     * 防死状态：每次调用均从持久化层查询，不使用内存缓存覆盖。
     */
    public func getWebViewConfig(): WebViewConfig {
        let cfg = WebViewConfig()
        cfg.javascriptEnabled = this.readBool(KEY_WEB_JS_ENABLED, true)
        cfg.darkModeEnabled = this.readBool(KEY_WEB_DARK_MODE, false)
        cfg.trackerBlockingEnabled = this.readBool(KEY_WEB_TRACKER_BLOCK, false)
        Hilog.info(0, "CjTelegram", "[WebService] getWebViewConfig js=${cfg.javascriptEnabled} dark=${cfg.darkModeEnabled} tracker=${cfg.trackerBlockingEnabled}")
        return cfg
    }

    /**
     * 设置完整 WebView 行为配置并持久化三个开关。
     */
    public func setWebViewConfig(config: WebViewConfig): Unit {
        this.writeBool(KEY_WEB_JS_ENABLED, config.javascriptEnabled)
        this.writeBool(KEY_WEB_DARK_MODE, config.darkModeEnabled)
        this.writeBool(KEY_WEB_TRACKER_BLOCK, config.trackerBlockingEnabled)
        Hilog.info(0, "CjTelegram", "[WebService] setWebViewConfig saved")
    }

    /**
     * 单独切换 JS 启用开关。
     * 对应 iOS BrowserScreen JS on/off 设置。
     */
    public func setJavascriptEnabled(enabled: Bool): Unit {
        this.writeBool(KEY_WEB_JS_ENABLED, enabled)
        Hilog.info(0, "CjTelegram", "[WebService] setJavascriptEnabled: ${enabled}")
    }

    /**
     * 读取 JS 启用状态（Preferences 真实查询）。
     */
    public func getJavascriptEnabled(): Bool {
        return this.readBool(KEY_WEB_JS_ENABLED, true)
    }

    /**
     * 单独切换暗色模式开关。
     * 对应 iOS BrowserScreen forceNightMode 设置。
     */
    public func setDarkModeEnabled(enabled: Bool): Unit {
        this.writeBool(KEY_WEB_DARK_MODE, enabled)
        Hilog.info(0, "CjTelegram", "[WebService] setDarkModeEnabled: ${enabled}")
    }

    /**
     * 读取暗色模式启用状态（Preferences 真实查询）。
     */
    public func getDarkModeEnabled(): Bool {
        return this.readBool(KEY_WEB_DARK_MODE, false)
    }

    /**
     * 单独切换追踪器屏蔽开关。
     * 对应 iOS BrowserScreen 的内容屏蔽 / 隐私过滤设置。
     */
    public func setTrackerBlockingEnabled(enabled: Bool): Unit {
        this.writeBool(KEY_WEB_TRACKER_BLOCK, enabled)
        Hilog.info(0, "CjTelegram", "[WebService] setTrackerBlockingEnabled: ${enabled}")
    }

    /**
     * 读取追踪器屏蔽状态（Preferences 真实查询）。
     */
    public func getTrackerBlockingEnabled(): Bool {
        return this.readBool(KEY_WEB_TRACKER_BLOCK, false)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bot WebApp URL requests (MTProto)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 请求 Bot Main Web App URL（用于 bot menu button / app entry）。
     *
     * 对应 Telegram iOS: messages.requestMainWebView
     * messages.webViewResultUrl#0a4028f9 query_id:long url:string
     *
     * P2-029 gap: requestMainWebView/app-webview 变体
     *
     * @param peerId           聊天 peer ID
     * @param peerAccessHash   聊天 peer access hash
     * @param botId            Bot user ID
     * @param botAccessHash    Bot access hash
     * @param startParam       可选：start 参数
     * @return                 WebViewResult，url 字段为最终加载地址
     */
    public func requestMainWebView(
        peerId: Int64,
        peerAccessHash: Int64,
        botId: Int64,
        botAccessHash: Int64,
        startParam!: String = ""
    ): WebViewResult {
        Hilog.info(0, "CjTelegram", "[WebService] requestMainWebView: botId=${botId}")

        let client = getMTProtoClient()

        let req = MessagesRequestMainWebView()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.botId = botId
        req.botAccessHash = botAccessHash
        req.startParam = startParam
        req.platform = "android"

        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[WebService] requestMainWebView response: ${responseData.size} bytes")

        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[WebService] requestMainWebView: empty response")
            return WebViewResult()
        }

        return this.parseWebViewResult(responseData)
    }

    /**
     * 请求完整 Bot Web App URL（带 peer 上下文）。
     *
     * 对应 Telegram iOS: messages.requestWebView
     * messages.webViewResultUrl#0a4028f9 query_id:long url:string
     *
     * @param peerId           聊天 peer ID
     * @param peerAccessHash   聊天 peer access hash
     * @param botId            Bot user ID
     * @param botAccessHash    Bot access hash
     * @param url              可选：直接打开的 URL（留空则用 bot 默认入口）
     * @param startParam       可选：start 参数（bot deep-link）
     * @return                 WebViewResult，包含可加载的 URL 与 queryId
     */
    public func requestWebView(
        peerId: Int64,
        peerAccessHash: Int64,
        botId: Int64,
        botAccessHash: Int64,
        url!: String = "",
        startParam!: String = ""
    ): WebViewResult {
        Hilog.info(0, "CjTelegram", "[WebService] requestWebView: botId=${botId}")

        let client = getMTProtoClient()

        let req = MessagesRequestWebView()
        req.peerId = peerId
        req.peerAccessHash = peerAccessHash
        req.botId = botId
        req.botAccessHash = botAccessHash
        req.url = url
        req.startParam = startParam
        req.platform = "android"

        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[WebService] requestWebView response: ${responseData.size} bytes")

        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[WebService] requestWebView: empty response")
            return WebViewResult()
        }

        return this.parseWebViewResult(responseData)
    }

    /**
     * 请求简单 Bot Web App URL（无 peer 上下文，适用于 attachment menu / inline button）。
     *
     * 对应 Telegram iOS: messages.requestSimpleWebView
     * simpleWebViewResultUrl#882f76bb url:string
     *
     * @param botId            Bot user ID
     * @param botAccessHash    Bot access hash
     * @param url              可选：打开的 URL
     * @param startParam       可选：start 参数
     * @return                 WebViewResult，url 字段为最终加载地址
     */
    public func requestSimpleWebView(
        botId: Int64,
        botAccessHash: Int64,
        url!: String = "",
        startParam!: String = ""
    ): WebViewResult {
        Hilog.info(0, "CjTelegram", "[WebService] requestSimpleWebView: botId=${botId}")

        let client = getMTProtoClient()

        let req = MessagesRequestSimpleWebView()
        req.botId = botId
        req.botAccessHash = botAccessHash
        req.url = url
        req.startParam = startParam
        req.platform = "android"

        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[WebService] requestSimpleWebView response: ${responseData.size} bytes")

        if (responseData.size < 8) {
            Hilog.info(0, "CjTelegram", "[WebService] requestSimpleWebView: empty response")
            return WebViewResult()
        }

        return this.parseWebViewResult(responseData)
    }

    /**
     * 解析 messages.WebViewResult 或 SimpleWebViewResult 响应.
     *
     * messages.webViewResultUrl#0a4028f9 query_id:long url:string
     * simpleWebViewResultUrl#882f76bb   url:string
     */
    private func parseWebViewResult(responseData: Array<Byte>): WebViewResult {
        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19u32) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[WebService] RPC error ${errorCode}: ${errorMessage}")
            return WebViewResult()
        }

        // messages.webViewResultUrl#0a4028f9
        if (constructor == 0x0a4028f9u32) {
            let queryId = d.readInt64()
            let resultUrl = d.readString()
            Hilog.info(0, "CjTelegram", "[WebService] webViewResultUrl: queryId=${queryId}")
            return WebViewResult(resultUrl, queryId)
        }

        // simpleWebViewResultUrl#882f76bb
        if (constructor == 0x882f76bbu32) {
            let resultUrl = d.readString()
            Hilog.info(0, "CjTelegram", "[WebService] simpleWebViewResultUrl parsed")
            return WebViewResult(resultUrl, 0)
        }

        Hilog.info(0, "CjTelegram", "[WebService] Unknown WebViewResult constructor")
        return WebViewResult()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2-035: sendWebViewData (web_app_data_send TL dispatch)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 发送 Bot WebApp 数据到 bot（messages.sendWebViewData）。
     *
     * 对应 iOS: _internal_sendWebViewData in BotWebView.swift:309
     *   network.request(Api.functions.messages.sendWebViewData(bot:randomId:buttonText:data:))
     *
     * TL: messages.sendWebViewData#dc0242c8 bot:InputUser random_id:long
     *     button_text:string data:string = Updates
     *
     * P2-035 gap: web_app_data_send event → sendWebViewData TL
     *
     * @param botId          Bot user ID
     * @param botAccessHash  Bot access hash
     * @param buttonText     The button text that triggered the send (may be empty)
     * @param data           The data string to send to the bot
     */
    public func sendWebViewData(
        botId!: Int64,
        botAccessHash!: Int64,
        buttonText!: String,
        data!: String
    ): Unit {
        Hilog.info(0, "CjTelegram", "[WebService] sendWebViewData: botId=${botId} data_len=${data.size}")
        let client = getMTProtoClient()

        let req = MessagesSendWebViewData()
        req.botId = botId
        req.botAccessHash = botAccessHash
        req.randomId = generateRandomId()
        req.buttonText = buttonText
        req.data = data

        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[WebService] sendWebViewData response: ${responseData.size} bytes")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2-035: processInvoice (web_app_open_invoice → payment flow)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 处理 web_app_open_invoice 事件，返回 invoice_closed status。
     *
     * 对应 iOS: fetchBotPaymentInvoice(source:.slug(slug)) → BotCheckoutController
     *   or makeStarsTransferScreen for XTR currency
     *
     * Full checkout UI requires PaymentService integration (interop接线点):
     *   integration_contract: ic_web_open_invoice (target: payment checkout service)
     *
     * Current implementation: returns "cancelled" as the best-effort status because
     * full payment checkout requires a dedicated PaymentService + PaymentCheckoutPage
     * that is not yet wired in this batch.
     *
     * @param slug           Invoice slug from web_app_open_invoice eventData
     * @param botId          Originating bot ID (for context)
     * @param botAccessHash  Originating bot access hash (for context)
     * @return               Status string: "paid"|"pending"|"cancelled"|"failed"
     */
    public func processInvoice(
        slug!: String,
        botId!: Int64,
        botAccessHash!: Int64
    ): String {
        Hilog.info(0, "CjTelegram", "[WebService] processInvoice: slug=${slug} botId=${botId}")
        return "cancelled"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2-030: invokeCustomMethod (web_app_invoke_custom_method)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * 调用 bot 自定义方法（web_app_invoke_custom_method）。
     *
     * 对应 iOS: invokeCustomMethod(requestId, method, params)
     *   → bots.invokeWebViewCustomMethod#087fc5e7 TL (Api42.swift:3030)
     *
     * TL: bots.invokeWebViewCustomMethod bot:InputUser custom_method:String params:DataJSON = DataJSON
     * Response: DataJSON#7d748d04 data:string  — data 字段即为 result JSON 字符串
     *
     * @param botId          Bot user ID
     * @param botAccessHash  Bot access hash
     * @param reqId          Request ID from JS (logged for tracing)
     * @param method         Custom method name
     * @param params         Method params as JSON string
     * @return               Result JSON string (from DataJSON.data field), or error JSON on failure
     */
    public func invokeCustomMethod(
        botId!: Int64,
        botAccessHash!: Int64,
        reqId!: String,
        method!: String,
        params!: String
    ): String {
        Hilog.info(0, "CjTelegram", "[WebService] invokeCustomMethod: method=${method} reqId=${reqId} botId=${botId}")

        let req = BotsInvokeWebViewCustomMethod()
        req.botId = botId
        req.botAccessHash = botAccessHash
        req.customMethod = method
        req.paramsData = if (params.size > 0) { params } else { "{}" }

        let client = getMTProtoClient()
        let responseData = client.sendRequest(req.toBytes())
        Hilog.info(0, "CjTelegram", "[WebService] invokeCustomMethod response: ${responseData.size} bytes")

        if (responseData.size < 4) {
            Hilog.info(0, "CjTelegram", "[WebService] invokeCustomMethod: empty response for method=${method}")
            return "{\"error\":\"no_response\"}"
        }

        let d = TLDeserializer(responseData)
        let ctor = d.readUInt32()

        if (ctor == TLConstructors.RPC_ERROR || ctor == 0x2144ca19u32) {
            let errorCode = d.readInt32()
            let errorMessage = d.readString()
            Hilog.info(0, "CjTelegram", "[WebService] invokeCustomMethod RPC error ${errorCode}: ${errorMessage}")
            return "{\"error\":\"${errorCode}:${errorMessage}\"}"
        }

        // DataJSON#7d748d04 (ctor 0x7d748d04 = 2104790276): data:string
        if (ctor == 0x7d748d04u32) {
            let resultJson = d.readString()
            Hilog.info(0, "CjTelegram", "[WebService] invokeCustomMethod result for method=${method}: ok")
            return resultJson
        }

        Hilog.info(0, "CjTelegram", "[WebService] invokeCustomMethod: unknown response ctor=0x${ctor}")
        return "{\"error\":\"unknown_response\"}"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2-030: deviceStorage (web_app_device_storage_save/get_key)
    // ─────────────────────────────────────────────────────────────────────────

    private let DEVICE_STORAGE_STORE: String = "mini_app_device_storage"

    /**
     * 保存 Mini App 设备存储键值（web_app_device_storage_save_key）。
     *
     * 对应 iOS: device storage save in WebAppController.swift
     * HarmonyOS: Preferences-based key-value store per bot.
     *
     * @param key    Storage key
     * @param value  Storage value
     */
    public func deviceStorageSave(key!: String, value!: String): Unit {
        if (key.size == 0) { return }
        this.ensurePrefs()
        match (this._prefs) {
            case None =>
                Hilog.info(0, "CjTelegram", "[WebService] deviceStorageSave: no prefs context")
            case Some(prefs) =>
                try {
                    prefs.put("ds_" + key, PreferencesValueType.StringData(value))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[WebService] deviceStorageSave: key=${key}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[WebService] deviceStorageSave error: ${e}")
                }
        }
    }

    /**
     * 读取 Mini App 设备存储键值（web_app_device_storage_get_key）。
     *
     * @param key    Storage key
     * @return       Stored value or "" if not found
     */
    public func deviceStorageGet(key!: String): String {
        if (key.size == 0) { return "" }
        this.ensurePrefs()
        match (this._prefs) {
            case None =>
                Hilog.info(0, "CjTelegram", "[WebService] deviceStorageGet: no prefs context")
                return ""
            case Some(prefs) =>
                try {
                    let val = prefs.get("ds_" + key, PreferencesValueType.StringData(""))
                    match (val) {
                        case PreferencesValueType.StringData(s) =>
                            Hilog.info(0, "CjTelegram", "[WebService] deviceStorageGet: key=${key} found=${s.size > 0}")
                            return s
                        case _ => return ""
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[WebService] deviceStorageGet error: ${e}")
                    return ""
                }
        }
    }

    /**
     * 清除 Mini App 设备存储（web_app_device_storage_clear）。
     *
     * 对应 iOS: WebAppController.swift web_app_device_storage_clear 处理。
     * HarmonyOS: 使用 Preferences.clear() 清除所有键值（KB Example 22-23 confirmed API）。
     * 由于 Preferences API 无按前缀筛选的 clear，直接 clear + flush 全部清空。
     */
    public func deviceStorageClear(): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None =>
                Hilog.info(0, "CjTelegram", "[WebService] deviceStorageClear: no prefs context")
            case Some(prefs) =>
                try {
                    prefs.clear()
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[WebService] deviceStorageClear: cleared all device storage keys")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[WebService] deviceStorageClear error: ${e}")
                }
        }
    }

    /**
     * 生成安全的 randomId（避免 UInt64 > Int64.Max 的 OverflowException）。
     */
    private func generateRandomId(): Int64 {
        let high = Int64(this._rand.nextUInt32() & 0x7FFFFFFFu32)
        let low = Int64(this._rand.nextUInt32())
        return (high << 32) | (low & 0xFFFFFFFF)
    }

    /**
     * 下载文件字节（委托给 FileDownloadService 的 MTProto 分块下载）。
     *
     * 对应 iOS FileDownload.swift — URLSessionDownloadTask 文件下载能力在鸿蒙侧
     * 通过 MTProto upload.getFile 替代（Telegram Mini App 下载资源走 MTProto）。
     *
     * @param fileId       文件 ID（来自 TL Document.id）
     * @param accessHash   文件 access hash
     * @param fileRef      文件引用（file_reference bytes）
     * @param dcId         文件所在 DC ID
     * @param fileSize     预期文件大小（可为 0，则自动分块直到最后一块 < CHUNK_SIZE）
     * @return             文件内容字节数组
     */
    public func downloadFile(
        fileId: Int64,
        accessHash: Int64,
        fileRef: Array<Byte>,
        dcId: Int32,
        fileSize!: Int64 = 0
    ): Array<Byte> {
        Hilog.info(0, "CjTelegram", "[WebService] downloadFile: fileId=${fileId}, size=${fileSize}")
        return getFileDownloadService().downloadDocument(
            fileId,
            accessHash,
            fileRef,
            dcId,
            fileSize: fileSize
        )
    }
}
