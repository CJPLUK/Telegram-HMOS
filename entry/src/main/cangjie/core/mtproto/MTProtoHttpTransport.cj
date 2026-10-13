package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import kit.NetworkKit.*
import ohos.base.*
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.ReentrantMutex
import std.sync.Monitor
internal import std.time.*

// ============================================================
// MTProto-over-HTTP 兜底传输（P2-241e）
//
// 定位：TCP + 混淆 + failover（P2-241a-d）均不通时的最后回退。
// 对应 iOS MtProtoKit：MTHttpTransport / td::mtproto::http::Transport。
//
// 协议语义（对照 iOS / TDLib HttpTransport.cpp）：
//   - 把已加密的 MTProto 报文作为 HTTP POST body 发到 DC 端点
//     POST http://<dc.host>:80/api
//     Content-Type: application/x-www-form-urlencoded
//   - 响应 body 是服务端排队的 MTProto 报文（空 = 无数据，继续轮询）。
//   - 长轮询：readTimeout=120s 让单次 request 挂住等数据；收到即 onData 回灌，再发下一个。
//   - 不套 TCP framing / obfuscation（那是 TCPTransport 专有层）。
//
// 与 TCPTransport 共用 TransportCallback 接口，MTProtoClient 可无感替换 transport。
//
// 已验 API（KB 查证 + S-010 规则遵从）：
//   createHttp()                                → HttpRequest
//   HttpRequest.request(url, options, callback) → AsyncCallback<HttpResponse>
//   HttpRequest.destroy()                       → 清理资源
//   HttpRequestOptions.method   = RequestMethod.Post
//   HttpRequestOptions.extraData = HttpData.ArrayData(bytes)
//   HttpRequestOptions.header   = HashMap<String, String>([(...)])
//   HttpRequestOptions.connectTimeout = UInt32
//   HttpRequestOptions.readTimeout    = UInt32（长轮询超时）
//   HttpResponse.result → HttpData.StringData(s) | HttpData.ArrayData(bytes) | _   (S-010)
//   AsyncCallback<HttpResponse> 中 resp 类型 = Option<HttpResponse>
// ============================================================

// ---- 闭包捕获 mutable 变量的 Box（仓颉 spawn/lambda 不能直接捕获 var）----

class HttpPollResultBox {
    // None = 未完成；Some(None) = 错误；Some(Some(bytes)) = 有数据
    public var value: Option<Option<Array<Byte>>> = None
}

class HttpConnectedBox {
    public var called: Bool = false
}

/**
 * HTTP 传输层（MTProto over HTTP，兜底 fallback）。
 *
 * 与 TCPTransport 同接口（send / isConnected / connect / disconnect / setCallback /
 * startReceiveLoop），可作为 MTProtoClient.transportManager 的可替换兜底 transport。
 *
 * 线程安全：_state / _running 受 _mutex 保护；
 * 待发队列 _pendingToSend 同受 _mutex 保护（入队 / 出队都在 mutex 内）。
 */
public class HTTPTransport {
    // ---- 配置 ----
    private let _dc: DataCenter
    // HTTP 端点：http://<host>:80/api（Telegram DC 在 80 端口提供 HTTP MTProto 接入）
    private let _httpUrl: String
    // 长轮询超时（毫秒，UInt32）：120s
    private let _pollTimeoutMs: UInt32 = 120000
    // 连接超时（毫秒，UInt32）：30s
    private let _connectTimeoutMs: UInt32 = 30000

    // ---- 状态（受 _mutex 保护）----
    private let _mutex = ReentrantMutex()
    private var _state: TransportState = TransportState.Disconnected
    private var _running: Bool = false

    // ---- 回调 ----
    private var _callback: Option<TransportCallback> = None

    // ---- 待发队列（受 _mutex 保护）----
    // MTProtoClient 调用 send() 时把已加密 payload 入队；
    // 轮询循环每次取队头作为本轮 POST body；无待发时发空 body（保活轮询）。
    var _pendingToSend: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()

    // ---- 当前 HttpRequest 实例（受 _mutex 保护，disconnect 时销毁）----
    private var _currentHttpRequest: Option<HttpRequest> = None

    public init(dc: DataCenter) {
        this._dc = dc
        // Telegram HTTP MTProto 端点：path 固定为 /api，port 80（对齐 TDLib HttpTransport.cpp）
        this._httpUrl = "http://${dc.host}:80/api"
    }

    public func setCallback(callback: TransportCallback): Unit {
        synchronized(_mutex) {
            this._callback = Some(callback)
        }
    }

    public func getState(): TransportState {
        synchronized(_mutex) {
            return this._state
        }
    }

    public func isConnected(): Bool {
        synchronized(_mutex) {
            return this._state == TransportState.Connected
        }
    }

    /**
     * 启动 HTTP transport（标记 Connected；HTTP 无持久 TCP 连接，无实际握手）。
     * 对应 TCPTransport.connect()。
     */
    public func connect(): Unit {
        synchronized(_mutex) {
            if (this._state == TransportState.Connected || this._state == TransportState.Connecting) {
                return
            }
            this._state = TransportState.Connected
            this._running = true
            Hilog.info(0, "CjTelegram",
                "[HTTPTransport] ready — fallback HTTP endpoint: ${this._httpUrl}")
        }
        let cb = getCb()
        match (cb) {
            case Some(c) => c.onConnected()
            case None => ()
        }
    }

    /**
     * 断开 HTTP transport（停止轮询循环，销毁当前 HttpRequest）。
     */
    public func disconnect(): Unit {
        var shouldNotify = false
        synchronized(_mutex) {
            if (this._state != TransportState.Disconnected) {
                this._running = false
                this._state = TransportState.Disconnected
                destroyCurrentRequest()
                shouldNotify = true
                Hilog.info(0, "CjTelegram", "[HTTPTransport] disconnected")
            }
        }
        if (shouldNotify) {
            let cb = getCb()
            match (cb) {
                case Some(c) => c.onDisconnected()
                case None => ()
            }
        }
    }

    /**
     * 发送已加密的 MTProto 报文（入队，轮询循环下次携带它 POST）。
     *
     * 与 TCPTransport.send() 签名一致；HTTP 层不再套 TCP framing / obfuscation，
     * 直接把 data（已经是 MTProto 加密后的字节）作为 POST body。
     */
    public func send(data: Array<Byte>): Unit {
        synchronized(_mutex) {
            if (this._state != TransportState.Connected) {
                Hilog.info(0, "CjTelegram", "[HTTPTransport] send() called but not connected, dropping")
                return
            }
            this._pendingToSend.add(data)
            Hilog.info(0, "CjTelegram",
                "[HTTPTransport] enqueued ${data.size} bytes (queue depth: ${this._pendingToSend.size})")
        }
    }

    /**
     * 长轮询主循环（在 spawn 线程中调用，对应 TCPTransport.startReceiveLoop()）。
     *
     * 语义（对照 iOS MTHttpTransport）：
     *   1. 从队列取出待发 payload（无则发空 body = 保活轮询）。
     *   2. HTTP POST 到 /api，readTimeout=120s（长轮询，挂起直到有数据或超时）。
     *   3. 响应非空 → onData 回灌；响应空 → 继续下一轮。
     *   4. 网络错误 → onError + 退出循环。
     *
     * 用 Monitor 把 AsyncCallback<HttpResponse> 转同步等待，保持顺序语义。
     */
    public func startReceiveLoop(): Unit {
        Hilog.info(0, "CjTelegram", "[HTTPTransport] long-poll loop started on ${this._httpUrl}")
        while (shouldRun()) {
            let payload = dequeuePending()
            let keepGoing = doSinglePoll(payload)
            if (!keepGoing) {
                break
            }
        }
        Hilog.info(0, "CjTelegram", "[HTTPTransport] long-poll loop exited")
    }

    // =========================================================================
    // 内部实现
    // =========================================================================

    /**
     * 执行单次 HTTP POST 并同步等待响应（Monitor 把 AsyncCallback 转同步）。
     *
     * @return true = 继续循环；false = 退出
     */
    private func doSinglePoll(payload: Array<Byte>): Bool {
        let httpRequest = createHttp()
        synchronized(_mutex) {
            this._currentHttpRequest = Some(httpRequest)
        }

        // HttpRequestOptions：POST 带原始加密字节 body
        let opts = HttpRequestOptions(
            method: RequestMethod.Post,
            extraData: HttpData.ArrayData(payload),
            header: HashMap<String, String>([("Content-Type", "application/x-www-form-urlencoded")]),
            connectTimeout: this._connectTimeoutMs,
            readTimeout: this._pollTimeoutMs,
            usingCache: false
        )

        // 用 Monitor + Box 把 AsyncCallback 转同步
        // （仓颉 lambda 不能捕获 var；用 class Box 绕过）
        let pollMon = Monitor()
        let resultBox = HttpPollResultBox()

        // AsyncCallback<HttpResponse>：参数是 (err: Option<BusinessException>, resp: Option<HttpResponse>)
        httpRequest.request(this._httpUrl, opts, {err, resp =>
            synchronized(pollMon) {
                if (let Some(_e) <- err) {
                    Hilog.info(0, "CjTelegram", "[HTTPTransport] poll HTTP error")
                    resultBox.value = Some(None<Array<Byte>>)
                } else {
                    // resp 是 Option<HttpResponse>，先解包
                    match (resp) {
                        case Some(httpResp) =>
                            // S-010: 同时处理 StringData 和 ArrayData
                            let bytes: Array<Byte> = match (httpResp.result) {
                                case HttpData.ArrayData(b) => b
                                case HttpData.StringData(s) =>
                                    if (s.isEmpty()) {
                                        Array<Byte>(0, repeat: 0)
                                    } else {
                                        ByteUtils.stringToBytes(s)
                                    }
                                case _ => Array<Byte>(0, repeat: 0)
                            }
                            resultBox.value = Some(Some(bytes))
                        case None =>
                            // 无响应对象 = 视为空响应，继续轮询
                            resultBox.value = Some(Some(Array<Byte>(0, repeat: 0)))
                    }
                }
                pollMon.notifyAll()
            }
        })

        // 等待回调（最多 pollTimeout + 5s 宽限）
        let waitLimitMs: Int64 = Int64(this._pollTimeoutMs) + 5000
        let deadlineMs = mtprotoMonotonicNowMs() + waitLimitMs
        synchronized(pollMon) {
            while (true) {
                match (resultBox.value) {
                    case Some(_) => break
                    case None =>
                        let rem = deadlineMs - mtprotoMonotonicNowMs()
                        if (rem <= 0) {
                            resultBox.value = Some(None<Array<Byte>>)
                            break
                        }
                        let _ = pollMon.wait(timeout: Duration.millisecond * rem)
                }
            }
        }

        // 清理 HttpRequest 资源
        synchronized(_mutex) {
            match (this._currentHttpRequest) {
                case Some(req) =>
                    try { req.destroy() } catch (_e: Exception) { () }
                    this._currentHttpRequest = None
                case None => ()
            }
        }

        if (!shouldRun()) {
            return false
        }

        // 分发结果
        match (resultBox.value) {
            case Some(Some(bytes)) =>
                if (bytes.size > 0) {
                    Hilog.info(0, "CjTelegram",
                        "[HTTPTransport] received ${bytes.size} bytes from server")
                    let cb = getCb()
                    match (cb) {
                        case Some(c) =>
                            try {
                                c.onData(bytes)
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram", "[HTTPTransport] onData error, continuing poll")
                            }
                        case None => ()
                    }
                } else {
                    Hilog.info(0, "CjTelegram", "[HTTPTransport] empty response, continuing poll")
                }
                return true
            case Some(None) =>
                Hilog.info(0, "CjTelegram", "[HTTPTransport] poll failed, exiting loop")
                setErrorState()
                let cb = getCb()
                match (cb) {
                    case Some(c) =>
                        try { c.onError("HTTP poll failed") } catch (_e: Exception) { () }
                    case None => ()
                }
                return false
            case None =>
                // 不应到达
                return shouldRun()
        }
    }

    // ---- 辅助方法 ----

    private func shouldRun(): Bool {
        synchronized(_mutex) {
            return this._running && this._state == TransportState.Connected
        }
    }

    private func getCb(): Option<TransportCallback> {
        synchronized(_mutex) {
            return this._callback
        }
    }

    // 从队列取第一个 payload（用 toArray 重建，避免 remove 签名问题）
    private func dequeuePending(): Array<Byte> {
        synchronized(_mutex) {
            if (this._pendingToSend.size > 0) {
                let payload = this._pendingToSend[0]
                // 重建队列（去掉首个元素）
                let newList = ArrayList<Array<Byte>>()
                for (i in 1..this._pendingToSend.size) {
                    newList.add(this._pendingToSend[i])
                }
                this._pendingToSend = newList
                return payload
            }
        }
        return Array<Byte>(0, repeat: 0)
    }

    private func destroyCurrentRequest(): Unit {
        match (this._currentHttpRequest) {
            case Some(req) =>
                try { req.destroy() } catch (_e: Exception) { () }
                this._currentHttpRequest = None
            case None => ()
        }
    }

    private func setErrorState(): Unit {
        synchronized(_mutex) {
            this._running = false
            this._state = TransportState.Error_
        }
    }

    // =========================================================================
    // selfCheck — 无网络纯逻辑断言：
    //   1. connect() → isConnected() == true
    //   2. send() 在已连接时入队；未连接时丢弃
    //   3. dequeuePending() 正确取出并清空
    //   4. disconnect() → isConnected() == false
    //   5. URL 构造：port 80 + /api
    // =========================================================================
    public static func selfCheck(): Unit {
        let fakeDc = DataCenter(1, "149.154.175.53", 443)
        let t = HTTPTransport(fakeDc)

        // 1. 初始 Disconnected
        if (t.isConnected()) {
            throw Exception("[HTTPTransport] selfCheck FAIL: initial state must be Disconnected")
        }

        // 2. connect → Connected
        t.connect()
        if (!t.isConnected()) {
            throw Exception("[HTTPTransport] selfCheck FAIL: after connect() must be Connected")
        }

        // 3. send() 入队
        let testPayload = Array<Byte>(8, repeat: 0xABu8)
        t.send(testPayload)
        synchronized(t._mutex) {
            if (t._pendingToSend.size != 1) {
                throw Exception("[HTTPTransport] selfCheck FAIL: send() must enqueue, size=${t._pendingToSend.size}")
            }
        }

        // 4. dequeuePending 取出后队列清空
        let dequeued = t.dequeuePending()
        if (dequeued.size != 8) {
            throw Exception("[HTTPTransport] selfCheck FAIL: dequeued size must be 8, got ${dequeued.size}")
        }
        synchronized(t._mutex) {
            if (t._pendingToSend.size != 0) {
                throw Exception("[HTTPTransport] selfCheck FAIL: queue must be empty after dequeue")
            }
        }

        // 5. 未连接时 send() 丢弃
        let t2 = HTTPTransport(fakeDc)
        t2.send(testPayload)
        synchronized(t2._mutex) {
            if (t2._pendingToSend.size != 0) {
                throw Exception("[HTTPTransport] selfCheck FAIL: send() while Disconnected must be no-op")
            }
        }

        // 6. disconnect → Disconnected
        t.disconnect()
        if (t.isConnected()) {
            throw Exception("[HTTPTransport] selfCheck FAIL: after disconnect() must be Disconnected")
        }

        // 7. URL port 80 /api
        if (!t._httpUrl.endsWith(":80/api")) {
            throw Exception("[HTTPTransport] selfCheck FAIL: HTTP URL must end with :80/api, got ${t._httpUrl}")
        }

        Hilog.info(0, "CjTelegram",
            "[HTTPTransport] selfCheck PASS: connect/disconnect/send-enqueue/dequeue/disconnected-drop/url verified")
    }
}
