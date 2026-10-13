package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap
import std.net.TcpSocket
import std.sync.*
internal import std.time.*
import kit.BasicServicesKit.*
import ohos.business_exception.BusinessException

// Socks5Proxy (ProxySettings, Socks5Handshake, Socks5Error) is defined in Socks5Proxy.cj
//
// 单调时钟（毫秒）本地辅助：与 utils/MonotonicTimeUtils.cj 同口径
// （SystemDateTime.getUptime(TimeType.Startup)，含深度睡眠、不受墙钟回拨影响）。
// 此处本地内联而非 import utils —— core.mtproto 与 utils 之间已存在
// (utils → bindings → core.mtproto) 依赖链，跨包引用 utils 会形成包级循环依赖。
// getUptime 抛 BusinessException 时回退 0（极端环境保护），正常设备恒返回非负单调值。
func mtprotoMonotonicNowMs(): Int64 {
    try {
        return SystemDateTime.getUptime(TimeType.Startup)
    } catch (e: BusinessException) {
        return 0
    }
}
/**
 * 传输状态
 */
public enum TransportState {
    | Disconnected
    | Connecting
    | Connected
    | Error_

    public func ordinal(): Int32 {
        match (this) {
            case Disconnected => 0
            case Connecting => 1
            case Connected => 2
            case Error_ => 3
        }
    }

    public operator func ==(right: TransportState): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: TransportState): Bool {
        return this.ordinal() != right.ordinal()
    }
}

/**
 * Semantic category carried with every metered transport operation.
 * Callers select it before bytes reach the statistics service.
 */
public enum TransportUsageCategory {
    | Generic
    | Image
    | Video
    | Audio
    | File
    | Call
    | Stickers
    | VoiceMessages

    public func ordinal(): Int32 {
        match (this) {
            case Generic => 0
            case Image => 1
            case Video => 2
            case Audio => 3
            case File => 4
            case Call => 5
            case Stickers => 6
            case VoiceMessages => 7
        }
    }
}

/** Source-side user-content type used to resolve a media fetch tag. */
public enum MediaUsageContentType {
    | File
    | Image
    | Video
    | Audio
    | Sticker
    | AudioVideoMessage
    | Other
}

/**
 * Exact equivalent of TelegramMediaResourceFetchTag.statsCategory resolution:
 * a concrete user-content type wins, otherwise the supplied semantic fallback
 * is retained.
 */
public func categoryForMediaFetch(
    statsCategory: TransportUsageCategory,
    contentType: MediaUsageContentType
): TransportUsageCategory {
    match (contentType) {
        case File => TransportUsageCategory.File
        case Image => TransportUsageCategory.Image
        case Video => TransportUsageCategory.Video
        case Audio => TransportUsageCategory.Audio
        case Sticker => TransportUsageCategory.Stickers
        case AudioVideoMessage => TransportUsageCategory.VoiceMessages
        case Other => statsCategory
    }
}

/**
 * MTProto TCP 传输帧模式（transport scheme）
 *
 * 三种官方 TCP framing：
 *   - Abridged           连接首发 0xef（1 字节）；每包变长长度头（len = payload/4，<0x7f 用 1 字节，否则 0x7f+3 字节小端 *4）
 *   - Intermediate       连接首发 0xee 0xee 0xee 0xee（4 字节）；每包 4 字节小端 = payload 字节长度 + payload
 *   - PaddedIntermediate 连接首发 0xdd 0xdd 0xdd 0xdd（4 字节）；每包对 payload 追加 0~15 随机 padding，
 *                        4 字节小端 = (payload+padding) 字节长度 + payload + padding（上层按内部 length 解析，尾部 padding 透传忽略）
 *
 * 默认 Abridged（回归安全：字节级与改动前完全一致）。
 */
public enum TransportScheme {
    | Abridged
    | Intermediate
    | PaddedIntermediate

    public func ordinal(): Int32 {
        match (this) {
            case Abridged => 0
            case Intermediate => 1
            case PaddedIntermediate => 2
        }
    }

    public operator func ==(right: TransportScheme): Bool {
        return this.ordinal() == right.ordinal()
    }

    public operator func !=(right: TransportScheme): Bool {
        return this.ordinal() != right.ordinal()
    }
}

/**
 * 传输回调接口
 *
 * 对应 TelegramHarmony 的 MTProtoTransport.ets TransportCallback
 */
public interface TransportCallback {
    func onConnected(): Unit
    func onDisconnected(): Unit
    func onData(data: Array<Byte>): Unit
    func onError(error: String): Unit
}

/**
 * TCP 传输类（Abridged 协议）
 * 
 * 对应 TelegramHarmony 的 MTProtoTransport.ets TCPTransport
 * 使用 Cangjie 标准库 std.net.TcpSocket
 */
public class TCPTransport {
    private var tcpSocket: Option<TcpSocket> = None
    private let dc: DataCenter
    private var state: TransportState = TransportState.Disconnected
    private var callback: Option<TransportCallback> = None
    private var receiveBuffer: Array<Byte> = Array<Byte>(0, repeat: 0)
    private let mutex = ReentrantMutex()
    // TcpSocket.write() does not permit concurrent writers. MTProtoClient intentionally
    // allows several RPCs to be in flight, so every outbound path (history, send,
    // ACK, sticker metadata, etc.) can reach this transport from a different spawn.
    //
    // Serialize only frame construction / obfuscation CTR advancement / socket write;
    // response waiting remains concurrent in MTProtoClient.pendingRPCs. This mirrors
    // iOS MTProto's transport transaction queue without reducing the connection to a
    // single in-flight RPC.
    private let sendMutex = ReentrantMutex()
    // connect() 可能由初始化线程执行，同时 RPC 线程已经准备发送首包。
    // 后者必须等待 Connecting 收口，不能让 send() 在尚未 Connected 时静默丢包。
    private let connectionMonitor = Monitor()
    private var running: Bool = false
    private var _consecutiveReadErrors: Int64 = 0

    /**
     * 可选 SOCKS5 代理配置。
     * None  → 直连 DC（原路径，字节不变）
     * Some  → 先连代理服务器，握手后透明转发到 DC
     */
    private var _proxy: Option<ProxySettings> = None

    /**
     * 当前 TCP 帧模式（默认 Abridged，字节级回归安全）。
     * 必须在 connect() 之前通过 setScheme() 切换，连接建立后切换无意义（首发标识已发出）。
     */
    private var _scheme: TransportScheme = TransportScheme.Abridged

    /**
     * 设置 TCP 帧模式（可选，在 connect() 之前调用）。
     * 不调用 → 默认 Abridged（行为字节不变）。
     */
    public func setScheme(scheme: TransportScheme): Unit {
        this._scheme = scheme
    }

    public func getScheme(): TransportScheme {
        return this._scheme
    }

    /**
     * P2-241b obfuscated2 混淆层（可选 anti-DPI scheme）。
     *
     * None  → 不启用，帧层直连 socket（字节级与改动前完全一致，回归安全）。
     * Some  → 启用：连接建立后先发 64B 混淆握手前缀（内嵌 frame tag），
     *         之后所有出站帧字节经发送 CTR 加密、入站 socket 字节经接收 CTR 解密。
     *
     * 必须在 connect() 之前通过 enableObfuscation() 开启；连接建立后开启无意义。
     */
    private var _obfuscation: Option<MTProtoObfuscation> = None

    /**
     * 开启 obfuscated2 混淆层（可选，在 connect() 之前调用）。
     * 内层 frame tag 取自当前 _scheme（Abridged→0xefefefef / Intermediate→0xeeeeeeee / Padded→0xdddddddd）。
     * 不调用 → 不启用（默认行为，帧层字节直连 socket）。
     */
    public func enableObfuscation(): Unit {
        let tag = MTProtoObfuscation.tagForScheme(this._scheme)
        this._obfuscation = Some(MTProtoObfuscation(tag))
    }

    public func isObfuscationEnabled(): Bool {
        match (this._obfuscation) {
            case Some(_) => return true
            case None => return false
        }
    }

    /**
     * P2-253a 计量钩子（可选注入）。
     * 外层 services 在构造后通过 setMeteringHooks 注入，避免 core.mtproto ↔ services 循环依赖。
     * 钩子签名：(category: TransportUsageCategory, bytes: Int64) -> Unit
     */
    private var _onBytesSent: Option<(TransportUsageCategory, Int64) -> Unit> =
        None<(TransportUsageCategory, Int64) -> Unit>
    private var _onBytesReceived: Option<(TransportUsageCategory, Int64) -> Unit> =
        None<(TransportUsageCategory, Int64) -> Unit>

    /**
     * 注入计量钩子（由 services 层在构造 TCPTransport 后调用）。
     */
    public func setMeteringHooks(
        onSent: (TransportUsageCategory, Int64) -> Unit,
        onReceived: (TransportUsageCategory, Int64) -> Unit
    ): Unit {
        this._onBytesSent = Some(onSent)
        this._onBytesReceived = Some(onReceived)
    }

    /**
     * Records a decoded inbound RPC using the category retained by its pending
     * request. A raw connection read cannot safely infer a category while
     * several differently categorized RPCs are in flight.
     */
    public func meterIncoming(category: TransportUsageCategory, bytes: Int64): Unit {
        if (bytes <= 0) { return }
        match (this._onBytesReceived) {
            case Some(hook) =>
                try {
                    hook(category, bytes)
                } catch (_me: Exception) {
                    Hilog.error(0, "CjTelegram", "[Transport] metering onBytesReceived swallowed")
                }
            case None => ()
        }
    }

    /**
     * 设置 SOCKS5 代理（可选，在 connect() 之前调用）。
     * 传入 None 等同于无代理直连（默认行为）。
     */
    public func setProxy(proxy: Option<ProxySettings>): Unit {
        this._proxy = proxy
    }

    public init(dc: DataCenter) {
        this.dc = dc
    }

    public func setCallback(callback: TransportCallback) {
        this.callback = Some(callback)
    }

    public func getState(): TransportState {
        var result = TransportState.Disconnected
        synchronized(this.connectionMonitor) {
            result = this.state
        }
        return result
    }

    public func isConnected(): Bool {
        return this.getState() == TransportState.Connected
    }

    /**
     * 等待其它线程正在执行的 connect() 完成。
     * 只等待连接阶段，不占用 sendMutex，也不做轮询；连接失败或超时返回 false。
     */
    public func waitUntilConnected(timeoutMs!: Int64 = 5000): Bool {
        let deadline = mtprotoMonotonicNowMs() + timeoutMs
        synchronized(this.connectionMonitor) {
            while (this.state == TransportState.Connecting) {
                let remaining = deadline - mtprotoMonotonicNowMs()
                if (remaining <= 0) { break }
                let _ = this.connectionMonitor.wait(timeout: Duration.millisecond * remaining)
            }
            return this.state == TransportState.Connected
        }
    }

    /**
     * 连接到服务器
     *
     * 路径选择：
     *   - _proxy == None → 直连 DC（原路径不变，字节不变）
     *   - _proxy == Some → 先连代理服务器，执行 SOCKS5 握手，再透明转发到 DC
     *
     * 代理握手任何步骤失败 → 明确抛错（状态设为 Error_），不静默继续；
     * 无代理时原直连路径完全不受影响（安全回退）。
     */
    public func connect() {
        var shouldConnect = false
        synchronized(this.connectionMonitor) {
            if (this.state != TransportState.Connecting && this.state != TransportState.Connected) {
                this.state = TransportState.Connecting
                shouldConnect = true
            }
        }
        if (!shouldConnect) {
            return
        }

        match (this._proxy) {
            case None =>
                // ---- 直连路径（原有逻辑，完整保留） ----
                Hilog.info(0, "CjTelegram", "[Transport] Connecting to DC${this.dc.id}: ${this.dc.host}:${this.dc.port}")
                try {
                    let sock = TcpSocket(this.dc.host, this.dc.port)
                    sock.connect()
                    this.tcpSocket = Some(sock)
                    Hilog.info(0, "CjTelegram", "[Transport] Connected to DC${this.dc.id} successfully!")

                    // 发送连接首发标识：
                    //   - obfuscated2 启用 → 发 64B 混淆握手前缀（frame tag 已内嵌进加密 init，不再发明文标识）
                    //   - 未启用 → 发明文帧模式标识（Abridged=0xef / Intermediate=0xeeeeeeee / Padded=0xdddddddd，字节不变）
                    let initId = buildConnectionPrefix()
                    sock.write(initId)
                    Hilog.info(0, "CjTelegram", "[Transport] Connection prefix sent (scheme=${this._scheme.ordinal()}, obfuscated=${this.isObfuscationEnabled()})")

                    this.running = true
                    synchronized(this.connectionMonitor) {
                        this.state = TransportState.Connected
                        this.connectionMonitor.notifyAll()
                    }

                    match (this.callback) {
                        case Some(cb) => cb.onConnected()
                        case None => ()
                    }

                    // 启动接收循环（由调用者在 spawn 中调用 startReceiveLoop）
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[Transport] Connection failed: ${e}")
                    synchronized(this.connectionMonitor) {
                        this.state = TransportState.Error_
                        this.connectionMonitor.notifyAll()
                    }
                    match (this.callback) {
                        case Some(cb) => cb.onError("Connection failed: ${e}")
                        case None => ()
                    }
                }

            case Some(proxy) =>
                // ---- 代理路径：SOCKS5 握手后再发 Abridged 标识 ----
                Hilog.info(0, "CjTelegram", "[Transport] Connecting via SOCKS5 proxy ${proxy.server}:${proxy.port} → DC${this.dc.id}: ${this.dc.host}:${this.dc.port}")
                try {
                    // 1. 连接代理服务器
                    let sock = TcpSocket(proxy.server, proxy.port)
                    sock.connect()
                    Hilog.info(0, "CjTelegram", "[Transport] TCP connected to proxy ${proxy.server}:${proxy.port}")

                    // 2. SOCKS5 握手（连代理→握手→建立到 DC 的隧道）
                    //    握手内部任意步骤失败会抛出 Socks5Error
                    Socks5Handshake.perform(sock, proxy, this.dc.host, this.dc.port)

                    // 3. 握手成功：socket 现在是透明隧道，后续与直连无差别
                    this.tcpSocket = Some(sock)
                    Hilog.info(0, "CjTelegram", "[Transport] SOCKS5 tunnel established to DC${this.dc.id}")

                    // 4. 发送连接首发标识（通过隧道，透明转发到 DC；与直连共用 buildConnectionPrefix）
                    //    obfuscated2 启用时这里发 64B 混淆握手前缀（隧道之上再叠混淆，规避 DPI）。
                    let initId = buildConnectionPrefix()
                    sock.write(initId)
                    Hilog.info(0, "CjTelegram", "[Transport] Connection prefix sent via proxy tunnel (scheme=${this._scheme.ordinal()}, obfuscated=${this.isObfuscationEnabled()})")

                    this.running = true
                    synchronized(this.connectionMonitor) {
                        this.state = TransportState.Connected
                        this.connectionMonitor.notifyAll()
                    }

                    match (this.callback) {
                        case Some(cb) => cb.onConnected()
                        case None => ()
                    }
                } catch (e: Exception) {
                    // 代理握手失败或 TCP 连接失败 → 明确上报错误，不静默
                    Hilog.info(0, "CjTelegram", "[Transport] Proxy connection failed: ${e}")
                    // 若 socket 已创建但握手失败，确保关闭
                    match (this.tcpSocket) {
                        case Some(s) =>
                            try { s.close() } catch (_ce: Exception) { () }
                            this.tcpSocket = None
                        case None => ()
                    }
                    synchronized(this.connectionMonitor) {
                        this.state = TransportState.Error_
                        this.connectionMonitor.notifyAll()
                    }
                    match (this.callback) {
                        case Some(cb) => cb.onError("Proxy connection failed: ${e}")
                        case None => ()
                    }
                }
        }
    }

    /**
     * 启动接收循环（在 spawn 中调用）
     * 
     * 关键修复：将 socket I/O 错误与消息处理错误分离
     * - socket 错误 → 退出循环（连接已断）
     * - 消息处理错误 → 日志记录但继续循环（不丢失后续消息）
     */
    public func startReceiveLoop() {
        let buf = Array<Byte>(8192, repeat: 0)
        while (this.running) {
            match (this.tcpSocket) {
                case Some(sock) =>
                    // Step 1: 读取 socket 数据（I/O 层）
                    var bytesRead: Int64 = 0
                    var readError = false
                    try {
                        bytesRead = sock.read(buf)
                    } catch (e: Exception) {
                        if (this.running) {
                            Hilog.info(0, "CjTelegram", "[Transport] Socket read error, will retry")
                            // 不立即退出 — 可能是临时超时
                            // 等待短暂时间后重试
                            readError = true
                        }
                    }

                    if (readError) {
                        // 检查 socket 是否仍然有效
                        if (!this.running) { break }
                        // 计数连续错误，超过阈值则退出
                        _consecutiveReadErrors += 1
                        if (_consecutiveReadErrors > 30) {
                            Hilog.info(0, "CjTelegram", "[Transport] Too many consecutive read errors, exiting loop")
                            this.running = false
                            synchronized(this.connectionMonitor) {
                                this.state = TransportState.Error_
                                this.connectionMonitor.notifyAll()
                            }
                            match (this.callback) {
                                case Some(cb) => cb.onError("Too many read errors")
                                case None => ()
                            }
                            break
                        }
                        continue
                    }
                    // 读取成功，重置连续错误计数
                    _consecutiveReadErrors = 0

                    if (bytesRead > 0) {
                        let rawData = ByteUtils.slice(buf, 0, bytesRead)
                        // obfuscated2 启用时先对入站 socket 字节做接收 CTR 解密（连续流），
                        // 再喂给帧层 processBuffer → tryParseFrame；未启用时透传（字节不变）。
                        let newData = match (this._obfuscation) {
                            case Some(obf) => obf.decryptIncoming(rawData)
                            case None => rawData
                        }
                        mutex.lock()
                        this.receiveBuffer = ByteUtils.concat2(this.receiveBuffer, newData)
                        mutex.unlock()

                        // Step 2: 处理缓冲区（消息处理层）
                        // 单独 try-catch — 处理错误不杀循环!
                        try {
                            processBuffer()
                        } catch (_e: Exception) {
                            Hilog.info(0, "CjTelegram", "[Transport] processBuffer error, continuing receive loop")
                            // 清理可能损坏的缓冲区
                            mutex.lock()
                            this.receiveBuffer = Array<Byte>(0, repeat: 0)
                            mutex.unlock()
                        }
                    } else if (bytesRead == 0) {
                        // 连接被远端关闭
                        this.running = false
                        synchronized(this.connectionMonitor) {
                            this.state = TransportState.Disconnected
                            this.connectionMonitor.notifyAll()
                        }
                        match (this.callback) {
                            case Some(cb) => cb.onDisconnected()
                            case None => ()
                        }
                    }
                case None =>
                    this.running = false
            }
        }
    }

    /**
     * 断开连接
     */
    public func disconnect() {
        this.running = false
        match (this.tcpSocket) {
            case Some(sock) =>
                try {
                    sock.close()
                } catch (_e: Exception) {
                    // 忽略关闭错误
                }
                this.tcpSocket = None
            case None => ()
        }
        synchronized(this.connectionMonitor) {
            this.state = TransportState.Disconnected
            this.connectionMonitor.notifyAll()
        }
        this.receiveBuffer = Array<Byte>(0, repeat: 0)
    }

    /**
     * 发送数据（Abridged 格式封装）
     */
    public func send(
        data: Array<Byte>,
        category!: TransportUsageCategory = TransportUsageCategory.Generic
    ) {
        synchronized(this.sendMutex) {
            if (this.state != TransportState.Connected) {
                return
            }

            // Framing and obfuscated2 CTR mutation belong to the same critical section
            // as write: two packets must advance the stream and reach TCP in that order.
            let framed = wrapFrame(data)
            let packet = match (this._obfuscation) {
                case Some(obf) => obf.encryptOutgoing(framed)
                case None => framed
            }
            match (this.tcpSocket) {
                case Some(sock) =>
                    try {
                        sock.write(packet)
                        // P2-253a 计量钩子：旁路记录发送字节数，绝不影响控制流
                        match (this._onBytesSent) {
                            case Some(hook) =>
                                try {
                                    hook(category, Int64(data.size))
                                } catch (_me: Exception) {
                                    Hilog.error(0, "CjTelegram", "[Transport] metering onBytesSent swallowed")
                                }
                            case None => ()
                        }
                    } catch (e: Exception) {
                        Hilog.info(0, "CjTelegram", "[Transport] Send failed: ${e}")
                        synchronized(this.connectionMonitor) {
                            this.state = TransportState.Disconnected
                            this.connectionMonitor.notifyAll()
                        }
                    }
                case None => ()
            }
        }
    }

    /**
     * 构造连接首发字节（统一入口，连接两路径共用）。
     *   - obfuscated2 启用 → 返回 64B 混淆握手前缀（initObfuscationHandshake 内嵌 frame tag，
     *     并初始化双向 CTR；此后 send/receive 走 CTR 流）。
     *   - 未启用 → 返回明文帧模式标识 buildInitIdentifier()（字节级回归不变）。
     */
    private func buildConnectionPrefix(): Array<Byte> {
        match (this._obfuscation) {
            case Some(obf) =>
                // 构造 64B 握手前缀（同时把双向 CTR 初始化好）
                let prefix = obf.handshakeBytes()
                Hilog.info(0, "CjTelegram", "[Transport] obfuscated2 handshake prefix built (64B), CTR ready")
                return prefix
            case None =>
                return buildInitIdentifier()
        }
    }

    /**
     * 构造连接首发的帧模式标识字节（按当前 _scheme，明文路径）。
     *   Abridged           → [0xef]                       （1 字节）
     *   Intermediate       → [0xee,0xee,0xee,0xee]        （4 字节）
     *   PaddedIntermediate → [0xdd,0xdd,0xdd,0xdd]        （4 字节）
     */
    private func buildInitIdentifier(): Array<Byte> {
        match (this._scheme) {
            case Abridged =>
                let id = Array<Byte>(1, repeat: 0)
                id[0] = UInt8(0xEFu8)
                return id
            case Intermediate =>
                let id = Array<Byte>(4, repeat: 0)
                id[0] = UInt8(0xEEu8)
                id[1] = UInt8(0xEEu8)
                id[2] = UInt8(0xEEu8)
                id[3] = UInt8(0xEEu8)
                return id
            case PaddedIntermediate =>
                let id = Array<Byte>(4, repeat: 0)
                id[0] = UInt8(0xDDu8)
                id[1] = UInt8(0xDDu8)
                id[2] = UInt8(0xDDu8)
                id[3] = UInt8(0xDDu8)
                return id
        }
    }

    /**
     * 按当前 _scheme 给 payload 加帧（发送侧统一入口）。
     * 直连与代理两路径都经由 send() → wrapFrame()，共用同一加帧逻辑。
     */
    private func wrapFrame(data: Array<Byte>): Array<Byte> {
        match (this._scheme) {
            case Abridged => return wrapAbridged(data)
            case Intermediate => return wrapIntermediate(data)
            case PaddedIntermediate => return wrapPaddedIntermediate(data)
        }
    }

    /**
     * Intermediate 格式封装：4 字节小端 = payload 字节长度 + payload。
     * 注意：长度是字节数本身，不做 /4。
     */
    private func wrapIntermediate(data: Array<Byte>): Array<Byte> {
        let len = data.size
        let result = Array<Byte>(4 + len, repeat: 0)
        result[0] = UInt8(len & 0xFF)
        result[1] = UInt8((len >> 8) & 0xFF)
        result[2] = UInt8((len >> 16) & 0xFF)
        result[3] = UInt8((len >> 24) & 0xFF)
        ByteUtils.copyTo(data, result, 4)
        return result
    }

    /**
     * Padded-Intermediate 格式封装：追加 0~15 随机 padding，
     * 4 字节小端 = (payload+padding) 字节长度 + payload + padding。
     * 上层 MTProto 按内部 length 字段解析，尾部 padding 透传被忽略。
     */
    private func wrapPaddedIntermediate(data: Array<Byte>): Array<Byte> {
        // 0~15 字节随机 padding（与 MTProto crypto 层 padding 同源：ByteUtils.randomBytes）
        let padLen = Int64(ByteUtils.randomBytes(1)[0]) % 16
        let padding = ByteUtils.randomBytes(padLen)
        let total = data.size + padLen
        let result = Array<Byte>(4 + total, repeat: 0)
        result[0] = UInt8(total & 0xFF)
        result[1] = UInt8((total >> 8) & 0xFF)
        result[2] = UInt8((total >> 16) & 0xFF)
        result[3] = UInt8((total >> 24) & 0xFF)
        ByteUtils.copyTo(data, result, 4)
        ByteUtils.copyTo(padding, result, 4 + data.size)
        return result
    }

    /**
     * Abridged 格式封装
     *
     * 如果 length/4 < 127: 1字节长度头
     * 如果 length/4 >= 127: 4字节长度头（0x7F + 3字节长度）
     */
    private func wrapAbridged(data: Array<Byte>): Array<Byte> {
        let length = data.size / 4

        if (length < 127) {
            let result = Array<Byte>(1 + data.size, repeat: 0)
            result[0] = UInt8(length)
            ByteUtils.copyTo(data, result, 1)
            return result
        } else {
            let result = Array<Byte>(4 + data.size, repeat: 0)
            result[0] = 127
            result[1] = UInt8(length & 0xFF)
            result[2] = UInt8((length >> 8) & 0xFF)
            result[3] = UInt8((length >> 16) & 0xFF)
            ByteUtils.copyTo(data, result, 4)
            return result
        }
    }

    /**
     * 处理接收缓冲区
     * 
     * 关键修复：每个消息的处理独立 try-catch
     * 一条消息解析失败不影响后续消息的接收
     */
    private func processBuffer() {
        while (true) {
            mutex.lock()
            let bufLen = this.receiveBuffer.size
            mutex.unlock()

            if (bufLen == 0) {
                break
            }

            let parsed = tryParseFrame()
            match (parsed) {
                case Some(data) =>
                    match (this.callback) {
                        case Some(cb) =>
                            // 每条消息独立 try-catch — 保护接收循环
                            try {
                                cb.onData(data)
                            } catch (_e: Exception) {
                                Hilog.info(0, "CjTelegram", "[Transport] Message processing error, skipping message")
                            }
                        case None => ()
                    }
                case None => break  // 数据不完整
            }
        }
    }

    /**
     * 按当前 _scheme 拆帧（接收侧统一入口）。
     * 直连与代理两路径都经由同一接收循环 → processBuffer() → tryParseFrame()，共用同一拆帧逻辑。
     */
    private func tryParseFrame(): Option<Array<Byte>> {
        match (this._scheme) {
            case Abridged => return tryParseAbridged()
            // Intermediate 与 Padded-Intermediate 的线上拆帧完全相同：
            // 读 4 字节小端长度 → 收齐该长度字节并整块交付。
            // Padded 多出的尾部 padding 由上层 MTProto 按内部 length 字段忽略（透传）。
            case Intermediate => return tryParseIntermediate()
            case PaddedIntermediate => return tryParseIntermediate()
        }
    }

    /**
     * 尝试解析 Intermediate / Padded-Intermediate 格式的消息。
     * 帧头：4 字节小端 = 紧随的数据块字节长度（Padded 模式下含 padding）。
     * 按声明长度收齐整块后原样交付上层；不在帧层剥离 padding。
     */
    private func tryParseIntermediate(): Option<Array<Byte>> {
        mutex.lock()
        if (this.receiveBuffer.size < 4) {
            mutex.unlock()
            return None
        }

        let b0 = Int64(UInt8(this.receiveBuffer[0]))
        let b1 = Int64(UInt8(this.receiveBuffer[1]))
        let b2 = Int64(UInt8(this.receiveBuffer[2]))
        let b3 = Int64(UInt8(this.receiveBuffer[3]))
        let dataLength = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

        let totalLength = 4 + dataLength
        if (this.receiveBuffer.size < totalLength) {
            mutex.unlock()
            return None
        }

        let data = ByteUtils.slice(this.receiveBuffer, 4, totalLength)
        this.receiveBuffer = ByteUtils.slice(this.receiveBuffer, totalLength, this.receiveBuffer.size)
        mutex.unlock()

        return Some(data)
    }

    /**
     * 尝试解析 Abridged 格式的消息
     */
    private func tryParseAbridged(): Option<Array<Byte>> {
        mutex.lock()
        if (this.receiveBuffer.size < 1) {
            mutex.unlock()
            return None
        }

        let firstByte = UInt8(this.receiveBuffer[0])

        // Quick ACK (最高位为 1)
        if ((firstByte & 0x80) != 0) {
            if (this.receiveBuffer.size < 4) {
                mutex.unlock()
                return None
            }
            // 跳过 4 字节 Quick ACK
            this.receiveBuffer = ByteUtils.slice(this.receiveBuffer, 4, this.receiveBuffer.size)
            mutex.unlock()
            return None
        }

        var headerLength: Int64 = 0
        var dataLength: Int64 = 0

        if (Int64(firstByte) < 127) {
            headerLength = 1
            dataLength = Int64(firstByte) * 4
        } else if (Int64(firstByte) == 127) {
            if (this.receiveBuffer.size < 4) {
                mutex.unlock()
                return None
            }
            headerLength = 4
            let b1 = Int64(UInt8(this.receiveBuffer[1]))
            let b2 = Int64(UInt8(this.receiveBuffer[2]))
            let b3 = Int64(UInt8(this.receiveBuffer[3]))
            dataLength = (b1 | (b2 << 8) | (b3 << 16)) * 4
        } else {
            // 不应到达
            this.receiveBuffer = Array<Byte>(0, repeat: 0)
            mutex.unlock()
            return None
        }

        let totalLength = headerLength + dataLength
        if (this.receiveBuffer.size < totalLength) {
            mutex.unlock()
            return None
        }

        let data = ByteUtils.slice(this.receiveBuffer, headerLength, totalLength)
        this.receiveBuffer = ByteUtils.slice(this.receiveBuffer, totalLength, this.receiveBuffer.size)
        mutex.unlock()

        return Some(data)
    }

    // -------------------------------------------------------------------------
    // selfCheck — 对三种帧模式的「加帧」与「连接首发标识」做真断言。
    // 无需真实网络；纯字节布局验证。任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheck(): Unit {
        let t = TCPTransport(MTProtoConfig.getDefaultDC())

        // 固定 payload：8 字节，长度 8 不是 4 的整数倍以暴露 /4 与字节长度的差异
        let payload = Array<Byte>(8, repeat: 0)
        for (i in 0..8) {
            payload[i] = UInt8(i + 1)  // [1,2,3,4,5,6,7,8]
        }

        // ===== Abridged：默认模式，回归断言（字节级不变） =====
        t.setScheme(TransportScheme.Abridged)
        let abInit = t.buildInitIdentifier()
        if (abInit.size != 1 || abInit[0] != 0xEFu8) {
            throw Exception("selfCheck FAIL: Abridged init id expected [0xef], got size=${abInit.size}")
        }
        let abFrame = t.wrapFrame(payload)
        // len = 8/4 = 2 (<127) → 1 字节长度头 [0x02] + payload
        if (abFrame.size != 1 + 8) {
            throw Exception("selfCheck FAIL: Abridged frame size expected 9, got ${abFrame.size}")
        }
        if (abFrame[0] != 0x02u8) {
            throw Exception("selfCheck FAIL: Abridged length header expected 0x02, got ${abFrame[0]}")
        }
        for (i in 0..8) {
            if (abFrame[1 + i] != payload[i]) {
                throw Exception("selfCheck FAIL: Abridged payload byte ${i} mismatch")
            }
        }

        // ===== Intermediate：0xeeeeeeee 首发 + 4 字节小端字节长度 =====
        t.setScheme(TransportScheme.Intermediate)
        let imInit = t.buildInitIdentifier()
        if (imInit.size != 4 || imInit[0] != 0xEEu8 || imInit[1] != 0xEEu8 || imInit[2] != 0xEEu8 || imInit[3] != 0xEEu8) {
            throw Exception("selfCheck FAIL: Intermediate init id expected [0xee x4], got size=${imInit.size}")
        }
        let imFrame = t.wrapFrame(payload)
        // 4 字节小端长度 = 8 → [0x08,0x00,0x00,0x00] + payload，总长 12
        if (imFrame.size != 4 + 8) {
            throw Exception("selfCheck FAIL: Intermediate frame size expected 12, got ${imFrame.size}")
        }
        if (imFrame[0] != 0x08u8 || imFrame[1] != 0x00u8 || imFrame[2] != 0x00u8 || imFrame[3] != 0x00u8) {
            throw Exception("selfCheck FAIL: Intermediate LE length header expected [08,00,00,00]")
        }
        for (i in 0..8) {
            if (imFrame[4 + i] != payload[i]) {
                throw Exception("selfCheck FAIL: Intermediate payload byte ${i} mismatch")
            }
        }

        // ===== Padded-Intermediate：0xdddddddd 首发 + 4 字节小端 (payload+padding) 长度 =====
        t.setScheme(TransportScheme.PaddedIntermediate)
        let pdInit = t.buildInitIdentifier()
        if (pdInit.size != 4 || pdInit[0] != 0xDDu8 || pdInit[1] != 0xDDu8 || pdInit[2] != 0xDDu8 || pdInit[3] != 0xDDu8) {
            throw Exception("selfCheck FAIL: Padded init id expected [0xdd x4], got size=${pdInit.size}")
        }
        // padding 随机 0~15，断言不依赖具体随机值：声明长度 == 实际数据块长度，且 payload 部分原样保留
        let pdFrame = t.wrapFrame(payload)
        if (pdFrame.size < 4 + 8) {
            throw Exception("selfCheck FAIL: Padded frame too short: ${pdFrame.size}")
        }
        let declared = Int64(UInt8(pdFrame[0])) | (Int64(UInt8(pdFrame[1])) << 8) | (Int64(UInt8(pdFrame[2])) << 16) | (Int64(UInt8(pdFrame[3])) << 24)
        let actualBlock = pdFrame.size - 4
        if (declared != actualBlock) {
            throw Exception("selfCheck FAIL: Padded declared length ${declared} != actual block ${actualBlock}")
        }
        let padLen = declared - 8
        if (padLen < 0 || padLen > 15) {
            throw Exception("selfCheck FAIL: Padded padding length out of 0..15 range: ${padLen}")
        }
        for (i in 0..8) {
            if (pdFrame[4 + i] != payload[i]) {
                throw Exception("selfCheck FAIL: Padded payload byte ${i} mismatch (payload must be verbatim)")
            }
        }

        // ===== obfuscated2 混淆层断言（CTR keystream/往返/连续性、init 约束、握手布局） =====
        MTProtoObfuscation.selfCheck()

        // ===== P2-241c：每 DC 多 scheme RTT 择优断言（注入假 RTT，不连网） =====
        SchemeSelector.selfCheck()

        // ===== P2-241d：指数退避 + 备用 scheme failover + 可达性立即重连断言（无网络） =====
        ReconnectController.selfCheck()

        Hilog.info(0, "CjTelegram", "[Transport] selfCheck PASS: Abridged/Intermediate/PaddedIntermediate framing + obfuscated2 + multi-scheme RTT selection + reconnect backoff/failover verified")
    }
}

/**
 * 单个 scheme 的 RTT 探测结果（P2-241c）。
 *
 * - scheme     被探测的端点 scheme
 * - available  TCP connect 是否成功（false → 该 scheme 本轮不可用，选择时跳过）
 * - rttMs      connect 成功耗时（毫秒，单调时钟测量）；不可用时为 -1
 */
public class SchemeProbeResult {
    public let scheme: DcTransportScheme
    public let available: Bool
    public let rttMs: Int64

    public init(scheme: DcTransportScheme, available: Bool, rttMs: Int64) {
        this.scheme = scheme
        this.available = available
        this.rttMs = rttMs
    }
}

/**
 * 每 DC 多 scheme 的 RTT 探测与择优（P2-241c）。
 *
 * 对应 iOS MtProtoKit：context chooseTransportSchemeForConnectionToDatacenterId（按 scheme 统计择优）。
 *
 * 职责拆分（便于无网络 selfCheck）：
 *   1. probeScheme()    —— 真实 TCP connect 探测单个 scheme，用单调时钟测 connect 耗时（不写死）。
 *   2. selectBest()     —— 纯函数：在一组已知 (available, rttMs, priority) 的探测结果里择优。
 *                          可注入假 RTT 验证选择逻辑，不真连网。
 *
 * 择优规则（对齐 iOS：先排除不可用，再 RTT 最小，RTT 同则 priority 小者优先）：
 *   - 仅在 available==true 的候选里选；
 *   - 普通请求跳过 isMediaOnly 的 scheme（forMedia=false）；媒体请求（forMedia=true）才纳入 media-only；
 *   - 在候选里取 (rttMs 最小)；rttMs 相等时取 priority 更小者；仍相等取先出现者（稳定）。
 *
 * 回归安全：候选只有一个可用 scheme（单 scheme 退化）→ 直接返回它，RTT 比较无副作用。
 */
public class SchemeSelector {

    /**
     * 真实探测单个 scheme 的连通性与 RTT。
     * 用单调时钟测 TcpSocket.connect 成功耗时（毫秒）；任何异常 → 标记不可用（rttMs=-1）。
     * 探测 socket 测完立即关闭，绝不泄漏（成功/失败两路都在 finally 关）。
     */
    public static func probeScheme(scheme: DcTransportScheme): SchemeProbeResult {
        var sock: Option<TcpSocket> = None
        let start = mtprotoMonotonicNowMs()
        try {
            let s = TcpSocket(scheme.host, scheme.port)
            sock = Some(s)
            s.connect()
            let elapsed = mtprotoMonotonicNowMs() - start
            // 单调时钟极端环境可能返回 0；connect 成功时 RTT 至少记 0（非负），不写死正数。
            let rtt = if (elapsed < 0) { 0 } else { elapsed }
            Hilog.info(0, "CjTelegram", "[SchemeProbe] ${scheme.describe()} connect OK rtt=${rtt}ms")
            return SchemeProbeResult(scheme, true, rtt)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[SchemeProbe] ${scheme.describe()} connect FAILED: ${e}")
            return SchemeProbeResult(scheme, false, -1)
        } finally {
            // 探测 socket 资源清理：无论成功失败都关闭，避免句柄泄漏。
            match (sock) {
                case Some(s) =>
                    try { s.close() } catch (_ce: Exception) { () }
                case None => ()
            }
        }
    }

    /**
     * 顺序探测一组 scheme（每个独立 connect/close，资源即用即清）。
     * 顺序探测而非并发：避免一次开多 socket 的句柄压力；每个探测 socket 测完立即释放。
     */
    public static func probeSchemes(schemes: Array<DcTransportScheme>): Array<SchemeProbeResult> {
        let results = ArrayList<SchemeProbeResult>()
        for (sc in schemes) {
            results.add(probeScheme(sc))
        }
        return results.toArray()
    }

    /**
     * 纯择优函数：在探测结果里选最优 scheme。
     *
     * @param results  已探测结果（available + rttMs 已知；可注入假值用于 selfCheck）。
     * @param forMedia 是否为媒体请求。false → 跳过 media-only scheme；true → 仅纳入 media-only。
     * @return 选中的 scheme；无任何可用候选时返回 None。
     */
    public static func selectBest(results: Array<SchemeProbeResult>, forMedia!: Bool = false): Option<DcTransportScheme> {
        var best: Option<SchemeProbeResult> = None
        for (r in results) {
            if (!r.available) {
                continue
            }
            // 媒体路由：普通请求跳过 media-only；媒体请求只要 media-only。
            if (forMedia) {
                if (!r.scheme.isMediaOnly) {
                    continue
                }
            } else {
                if (r.scheme.isMediaOnly) {
                    continue
                }
            }
            match (best) {
                case None => best = Some(r)
                case Some(b) =>
                    // RTT 最小优先；RTT 相等时 priority 小者优先（稳定：先出现者保留）。
                    if (r.rttMs < b.rttMs) {
                        best = Some(r)
                    } else if (r.rttMs == b.rttMs && r.scheme.priority < b.scheme.priority) {
                        best = Some(r)
                    }
            }
        }
        match (best) {
            case Some(b) => return Some(b.scheme)
            case None => return None
        }
    }

    /**
     * 端到端择优：取某 DC 的候选 scheme → 真实探测 RTT → 选最优。
     * 普通（非媒体）请求路径。无任何可用 scheme 时返回 None（调用方回退现有单连逻辑）。
     */
    public static func chooseSchemeForDC(dcId: Int64, forMedia!: Bool = false): Option<DcTransportScheme> {
        let schemes = MTProtoConfig.getSchemesForDC(dcId)
        let results = probeSchemes(schemes)
        return selectBest(results, forMedia: forMedia)
    }

    // -------------------------------------------------------------------------
    // selfCheck — 注入假 RTT 验证择优逻辑，绝不真连网。
    // 覆盖：多 scheme 按 RTT 升序择优、RTT 相等按 priority、不可用 scheme 跳过、
    //       单 scheme 退化、media-only 路由、全不可用返回 None。
    // 任何断言失败抛 Exception。
    // -------------------------------------------------------------------------
    public static func selfCheck(): Unit {
        // 构造一组带假 RTT 的候选（host/port 仅占位，selectBest 不连网）。
        let sA = DcTransportScheme("10.0.0.1", 443, priority: 0)              // 主
        let sB = DcTransportScheme("10.0.0.2", 443, priority: 1)             // 备
        let sC = DcTransportScheme("10.0.0.3", 443, priority: 2)             // 备
        let sMedia = DcTransportScheme("10.0.0.9", 443, isMediaOnly: true, priority: 0)

        // ===== 1. 多 scheme 按 RTT 升序择优：B 的 RTT 最小应被选中 =====
        let r1 = [
            SchemeProbeResult(sA, true, 120),
            SchemeProbeResult(sB, true, 40),
            SchemeProbeResult(sC, true, 80)
        ]
        match (SchemeSelector.selectBest(r1)) {
            case Some(chosen) =>
                if (chosen.host != sB.host) {
                    throw Exception("selfCheck FAIL: expected lowest-RTT scheme B(${sB.host}), got ${chosen.host}")
                }
            case None => throw Exception("selfCheck FAIL: selectBest returned None for available candidates")
        }

        // ===== 2. 不可用 scheme 跳过：最低 RTT 的 B 标记不可用 → 应退而选次低 C =====
        let r2 = [
            SchemeProbeResult(sA, true, 120),
            SchemeProbeResult(sB, false, -1),
            SchemeProbeResult(sC, true, 80)
        ]
        match (SchemeSelector.selectBest(r2)) {
            case Some(chosen) =>
                if (chosen.host != sC.host) {
                    throw Exception("selfCheck FAIL: with B unavailable expected C(${sC.host}), got ${chosen.host}")
                }
            case None => throw Exception("selfCheck FAIL: selectBest None while C available")
        }

        // ===== 3. RTT 相等按 priority：A(prio0) 与 C(prio2) 同 RTT → 选 priority 更小的 A =====
        let r3 = [
            SchemeProbeResult(sC, true, 50),
            SchemeProbeResult(sA, true, 50)
        ]
        match (SchemeSelector.selectBest(r3)) {
            case Some(chosen) =>
                if (chosen.host != sA.host) {
                    throw Exception("selfCheck FAIL: RTT tie expected lower-priority A(${sA.host}), got ${chosen.host}")
                }
            case None => throw Exception("selfCheck FAIL: selectBest None on RTT tie")
        }

        // ===== 4. 单 scheme 退化：仅一个可用候选 → 直接选它（RTT 比较无副作用） =====
        let r4 = [SchemeProbeResult(sA, true, 999)]
        match (SchemeSelector.selectBest(r4)) {
            case Some(chosen) =>
                if (chosen.host != sA.host) {
                    throw Exception("selfCheck FAIL: single-scheme degenerate expected A, got ${chosen.host}")
                }
            case None => throw Exception("selfCheck FAIL: single-scheme returned None")
        }

        // ===== 5. media-only 路由：普通请求跳过 media-only =====
        let r5 = [SchemeProbeResult(sMedia, true, 10)]
        match (SchemeSelector.selectBest(r5, forMedia: false)) {
            case Some(_) => throw Exception("selfCheck FAIL: non-media request must skip media-only scheme")
            case None => ()
        }
        // 媒体请求才纳入 media-only
        match (SchemeSelector.selectBest(r5, forMedia: true)) {
            case Some(chosen) =>
                if (chosen.host != sMedia.host) {
                    throw Exception("selfCheck FAIL: media request expected media-only scheme")
                }
            case None => throw Exception("selfCheck FAIL: media request found no media scheme")
        }
        // 普通择优里 media-only 不应混入：A(120) vs media(10) 普通请求仍选 A
        let r5b = [SchemeProbeResult(sA, true, 120), SchemeProbeResult(sMedia, true, 10)]
        match (SchemeSelector.selectBest(r5b, forMedia: false)) {
            case Some(chosen) =>
                if (chosen.host != sA.host) {
                    throw Exception("selfCheck FAIL: non-media must ignore faster media-only scheme")
                }
            case None => throw Exception("selfCheck FAIL: non-media selection None with A available")
        }

        // ===== 6. 全不可用 → None =====
        let r6 = [
            SchemeProbeResult(sA, false, -1),
            SchemeProbeResult(sB, false, -1)
        ]
        match (SchemeSelector.selectBest(r6)) {
            case Some(_) => throw Exception("selfCheck FAIL: all-unavailable must yield None")
            case None => ()
        }

        // ===== 7. getSchemesForDC 单 scheme 退化：无覆盖时每 DC 恰一个由 DataCenter 派生的默认 scheme =====
        MTProtoConfig.clearSchemeOverrides()
        let defDc = MTProtoConfig.getDefaultDC()
        let single = MTProtoConfig.getSchemesForDC(defDc.id)
        if (single.size != 1) {
            throw Exception("selfCheck FAIL: no-override DC expected exactly 1 default scheme, got ${single.size}")
        }
        if (single[0].host != defDc.host || single[0].port != defDc.port) {
            throw Exception("selfCheck FAIL: default scheme host/port must match DataCenter (regression-safe)")
        }
        if (single[0].isObfuscated || single[0].isMediaOnly) {
            throw Exception("selfCheck FAIL: default scheme must be plain (no obfuscation/media), regression-safe")
        }

        // ===== 8. 多 scheme 覆盖注入后能取回；清除后回退单 scheme =====
        MTProtoConfig.setSchemesForDC(defDc.id, [sA, sB, sMedia])
        let multi = MTProtoConfig.getSchemesForDC(defDc.id)
        if (multi.size != 3) {
            throw Exception("selfCheck FAIL: override expected 3 schemes, got ${multi.size}")
        }
        MTProtoConfig.clearSchemeOverrides()
        if (MTProtoConfig.getSchemesForDC(defDc.id).size != 1) {
            throw Exception("selfCheck FAIL: after clear override must degenerate back to 1 default scheme")
        }

        Hilog.info(0, "CjTelegram", "[SchemeSelector] selfCheck PASS: RTT-ordered selection / unavailable-skip / priority-tiebreak / single-scheme degenerate / media routing / all-unavailable None / override roundtrip")
    }
}

/**
 * 传输管理器 - 管理多个数据中心的连接
 *
 * 对应 TelegramHarmony 的 MTProtoTransport.ets TransportManager
 */
public class TransportManager {
    private var transports = HashMap<Int64, TCPTransport>()

    /**
     * P2-324 代理注入钩子（可选，由外层 services 在 connect 前注入，避免 core.mtproto ↔ services 循环依赖）。
     * 签名：() -> Option<ProxySettings>
     * None  → 不注入代理（默认行为，直连，字节不变）。
     * Some  → 每次构造 TCPTransport 时读取当前活跃代理并写入 transport._proxy。
     *         setProxy(None) 分支仍走直连（TCPTransport.connect() None 分支完全保留）。
     */
    private var _proxyProvider: Option<() -> Option<ProxySettings>> = None<() -> Option<ProxySettings>>

    /**
     * 由外层 services（ProxyService）在 applyProxyToTransport() 时注入代理提供者。
     * 不破坏直连：_proxyProvider 为 None 或 provider() 返回 None 时，transport.setProxy(None) 仍走直连原路径。
     */
    public func setProxyProvider(provider: () -> Option<ProxySettings>): Unit {
        this._proxyProvider = Some(provider)
    }

    /**
     * 将当前代理状态注入给定 transport（getTransport/rebuildTransport 共用）。
     * _proxyProvider 未设置 → setProxy(None)（直连，与改动前完全一致）。
     */
    private func applyProxyIfSet(transport: TCPTransport): Unit {
        match (this._proxyProvider) {
            case Some(provider) =>
                let proxy = provider()
                transport.setProxy(proxy)
            case None =>
                transport.setProxy(Option<ProxySettings>.None)
        }
    }

    /**
     * P2-320b 计量注册钩子（可选，由外层 services 在构造 TransportManager 后注入，
     * 避免 core.mtproto ↔ services 循环依赖——services 已 import core.mtproto.TCPTransport）。
     * 签名：(TCPTransport) -> Unit
     * None  → 不注入计量钩子（默认行为，不影响传输字节/连接逻辑，回归安全）。
     * Some  → 每次 vend 新 TCPTransport 时调用一次，令 NetworkUsageService.registerTransport 写入
     *         setMeteringHooks，后续 send/recv 字节自动累计到用量统计。
     * 同一 transport 实例只在 vend 时注册一次（getTransport/rebuildTransport 各自持有独立实例），
     * 不存在重复注册同一实例的情况。
     */
    private var _meteringRegistrar: Option<(TCPTransport) -> Unit> = None<(TCPTransport) -> Unit>

    /**
     * 由外层 services（通过 MTProtoClient.setMeteringRegistrar 委托）注入计量注册回调。
     * 典型用法：setMeteringRegistrar { t => getNetworkUsageService().registerTransport(t) }
     * 不调用 → _meteringRegistrar 保持 None，所有 transport 不注册计量钩子（零副作用，回归安全）。
     * retroactive：注入时对已缓存的 transports 补调 applyMeteringIfSet，修复注入时序倒置
     * （initializeClient 在 setMeteringRegistrar 之前 vend 主 DC transport 导致计量永久失效）。
     * setMeteringHooks 覆盖旧 hook 是幂等的，重复 apply 安全，不影响连接状态。
     */
    public func setMeteringRegistrar(registrar: (TCPTransport) -> Unit): Unit {
        this._meteringRegistrar = Some(registrar)
        for ((_, t) in this.transports) {
            applyMeteringIfSet(t)
        }
    }

    /**
     * 对新建 transport 调用计量注册回调（getTransport/rebuildTransport 共用）。
     * _meteringRegistrar 为 None → 无操作（默认行为，不影响传输逻辑）。
     * 异常全部吞掉：计量注册失败绝不影响网络连接主路径。
     */
    private func applyMeteringIfSet(transport: TCPTransport): Unit {
        match (this._meteringRegistrar) {
            case Some(registrar) =>
                try {
                    registrar(transport)
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[TransportManager] metering registrar error (swallowed): ${e}")
                }
            case None => ()
        }
    }

    public func getTransport(dcId: Int64): TCPTransport {
        if (transports.contains(dcId)) {
            return transports[dcId]
        }
        let dc = match (MTProtoConfig.getDCById(dcId)) {
            case Some(d) => d
            case None => MTProtoConfig.getDefaultDC()
        }
        // P2-241c：仅当该 DC 配置了多 scheme 覆盖时才走 RTT 择优；
        // 无覆盖（默认）→ 单 scheme 退化，沿用原 TCPTransport(dc) 路径，host/port/字节完全不变（回归安全）。
        let schemes = MTProtoConfig.getSchemesForDC(dcId)
        let transport = if (schemes.size <= 1) {
            // 单 scheme 退化：行为字节与改动前一致。
            TCPTransport(dc)
        } else {
            buildTransportWithBestScheme(dcId, dc, schemes)
        }
        // P2-324：注入当前活跃代理（ProxyService 已更新 _proxyProvider 时生效；未设置则 setProxy(None) 直连）
        applyProxyIfSet(transport)
        // P2-320b：注入计量钩子（NetworkUsageService 已注入 _meteringRegistrar 时生效；未注入则无操作）
        applyMeteringIfSet(transport)
        transports[dcId] = transport
        return transport
    }

    /**
     * 多 scheme 路径：探测 RTT 择优后用最优 scheme 的端点建 TCPTransport。
     *   - 选中 scheme 含 host/port → 据此构造 DataCenter（保留原 dc.id/isTest）。
     *   - 选中 scheme isObfuscated → 在 connect() 前 enableObfuscation()（对接 P2-241b）。
     *   - 无任何可用 scheme（全探测失败）→ 安全回退原 dc 单连（不让择优失败导致彻底不可连）。
     * media-only scheme 在普通连接里被 selectBest(forMedia=false) 跳过；当前无独立媒体下载链路，
     * media scheme 暂存于覆盖列表中、普通连接不选，接口（forMedia 参数）已预留供未来媒体路由接入。
     */
    private func buildTransportWithBestScheme(dcId: Int64, dc: DataCenter, schemes: Array<DcTransportScheme>): TCPTransport {
        let results = SchemeSelector.probeSchemes(schemes)
        match (SchemeSelector.selectBest(results, forMedia: false)) {
            case Some(best) =>
                Hilog.info(0, "CjTelegram", "[TransportManager] DC${dcId} selected scheme ${best.describe()} by RTT/priority")
                let chosenDc = DataCenter(dc.id, best.host, best.port, isTest: dc.isTest)
                let t = TCPTransport(chosenDc)
                if (best.isObfuscated) {
                    t.enableObfuscation()
                }
                return t
            case None =>
                // 所有候选都不可用 → 回退原 dc 直连（保证可用性不退化）。
                Hilog.info(0, "CjTelegram", "[TransportManager] DC${dcId} no scheme reachable, falling back to default endpoint")
                return TCPTransport(dc)
        }
    }

    /**
     * P2-241d：用指定 scheme 的端点重建某 DC 的 transport（备用 scheme/DC failover 用）。
     *
     * 重连切备用 scheme 时调用：先断开并丢弃该 DC 旧的 transport，再用所选 scheme 的 host/port
     * 构造新 TCPTransport（保留 dc.id / isTest）；scheme.isObfuscated → connect 前 enableObfuscation()
     * （对接 P2-241b）。新 transport 写回缓存并返回，供调用方 setCallback + connect。
     *
     * 回归安全：单 scheme 退化时调用方传入的就是由 DataCenter 派生的默认 scheme，
     *   host/port == 原 DC，重建结果与原直连端点完全一致（字节不变）。
     */
    public func rebuildTransport(dcId: Int64, scheme: DcTransportScheme): TCPTransport {
        // 丢弃旧连接（若有），确保不泄漏 socket。
        if (transports.contains(dcId)) {
            let old = transports[dcId]
            old.disconnect()
            let _ = transports.remove(dcId)
        }
        let baseDc = match (MTProtoConfig.getDCById(dcId)) {
            case Some(d) => d
            case None => MTProtoConfig.getDefaultDC()
        }
        let endpointDc = DataCenter(baseDc.id, scheme.host, scheme.port, isTest: baseDc.isTest)
        let t = TCPTransport(endpointDc)
        if (scheme.isObfuscated) {
            t.enableObfuscation()
        }
        // P2-324：rebuild 也注入代理（保持与 getTransport 一致的代理状态）
        applyProxyIfSet(t)
        // P2-320b：rebuild 也注入计量钩子（保持与 getTransport 一致的计量注册状态）
        applyMeteringIfSet(t)
        transports[dcId] = t
        Hilog.info(0, "CjTelegram", "[TransportManager] rebuilt DC${dcId} transport on scheme ${scheme.describe()}")
        return t
    }

    public func disconnectAll() {
        for ((_, transport) in transports) {
            transport.disconnect()
        }
        transports = HashMap<Int64, TCPTransport>()
    }
}
