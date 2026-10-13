package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import kit.ArkUI.{AppStorage, launch}
import std.sync.ReentrantMutex
import std.time.DateTime
import ohos_app_cangjie_entry.core.mtproto.ProxySettings
import ohos_app_cangjie_entry.core.mtproto.getMTProtoClient
import ohos_app_cangjie_entry.core.mtproto.{TCPTransport, DataCenter, MTProtoConfig, TransportCallback, AuthKeyConstructors, TLSerializer, ByteUtils, Base64}
import ohos_app_cangjie_entry.utils.percentEncode

/**
 * ProxyService — Proxy configuration CRUD + enable/disable
 *
 * iOS references:
 *   TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift
 *     ProxySettings { enabled, servers: [ProxyServerSettings], activeServer, useForCalls }
 *     ProxyServerSettings { host, port, connection: .socks5(user,pass) | .mtp(secret) }
 *   SettingsUI/.../ProxyListSettingsController.swift
 *     toggleEnabled / addNewServer / activateServer / removeServer / toggleUseForCalls
 *
 * ProxyConfig (this file) = UI/persistence model, mirrors ProxyServerSettings.
 * ProxySettings (core.mtproto.Socks5Proxy) = transport model.
 *
 * Persistence: own Preferences store "telegram_proxy" via getGlobalAbilityContext().
 */

// ==================== Storage keys ====================

let PROXY_STORE_NAME = "telegram_proxy"
public let PROXY_SETTINGS_VERSION_KEY = "proxySettingsVersion"
let KEY_PROXY_ENABLED = "proxy_enabled"
let KEY_PROXY_USE_FOR_CALLS = "proxy_use_for_calls"
let KEY_PROXY_COUNT = "proxy_count"
let KEY_PROXY_ACTIVE_IDX = "proxy_active_idx"

private func proxyKey(idx: Int32, field: String): String {
    return "px_${idx}_${field}"
}

// ==================== ProxyType ====================

public enum ProxyType {
    | SOCKS5
    | MTProto

    public func toInt(): Int32 {
        match (this) {
            case SOCKS5 => 0
            case MTProto => 1
        }
    }

    public static func fromInt(v: Int32): ProxyType {
        if (v == 1) { return ProxyType.MTProto }
        return ProxyType.SOCKS5
    }

    public func displayName(): String {
        match (this) {
            case SOCKS5 => "SOCKS5"
            case MTProto => "MTProto"
        }
    }
}

// ==================== ProxyConfig ====================

public class ProxyConfig {
    public var host: String = ""
    public var port: String = "1080"
    public var proxyType: ProxyType = ProxyType.SOCKS5
    public var username: String = ""
    public var password: String = ""
    public var secret: String = ""

    public init(
        host: String,
        port!: String = "1080",
        proxyType!: ProxyType = ProxyType.SOCKS5,
        username!: String = "",
        password!: String = "",
        secret!: String = ""
    ) {
        this.host = host
        this.port = port
        this.proxyType = proxyType
        this.username = username
        this.password = password
        this.secret = secret
    }

    public func displayAddress(): String {
        return "${this.host}:${this.port}"
    }

    /**
     * structurallyEquals — 值语义比较，对齐 iOS ProxyServerSettings（Equatable/Hashable 值类型）。
     * 用于 TC-0433 F3 保存去重：新增前扫描既有列表，命中相等项则不追加。
     */
    public func structurallyEquals(other: ProxyConfig): Bool {
        return this.host == other.host &&
            this.port == other.port &&
            this.proxyType.toInt() == other.proxyType.toInt() &&
            this.username == other.username &&
            this.password == other.password &&
            this.secret == other.secret
    }

    public func toTransportSettings(): Option<ProxySettings> {
        if (this.host.isEmpty()) { return Option<ProxySettings>.None }
        let portNum = parsePortNumber(this.port)
        if (portNum <= 0 || portNum > 65535) { return Option<ProxySettings>.None }
        let ps = ProxySettings(this.host, UInt16(portNum), username: this.username, password: this.password, secret: this.secret)
        return Option<ProxySettings>.Some(ps)
    }
}

private func parsePortNumber(portStr: String): Int64 {
    if (portStr.isEmpty()) { return 0 }
    var val: Int64 = 0
    let bytes = portStr.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        let c = Int64(bytes[i])
        if (c < 48 || c > 57) { return 0 }
        val = val * 10 + c - 48
        if (val > 65535) { return 0 }
        i = i + 1
    }
    return val
}

/**
 * canParseAsInteger — 只判断字符串能否解析为整数（对齐 iOS `Int(self.port) == nil` 判据），
 * 不做范围/合法端口校验。TC-0433 修法 1 明确：不得复用 parsePortNumber()（它对越界值静默
 * 返回 0，会把"能解析但越界"误判成"不能解析"），也不得加源侧没有的范围校验（case B5：
 * 0/99999/-5 必须仍可提交）。
 */
public func canParseAsInteger(s: String): Bool {
    if (s.isEmpty()) { return false }
    let bytes = s.toArray()
    var i: Int64 = 0
    if (bytes[0] == 45u8) { // '-'
        i = 1
        if (bytes.size == 1) { return false }
    }
    while (i < bytes.size) {
        let c = bytes[i]
        if (c < 48u8 || c > 57u8) { return false }
        i += 1
    }
    return true
}

// ==================== MTProxy secret parsing (TC-0433 修法 2) ====================

/**
 * ProxySecretKind — 复刻 iOS MTProxySecret 的三种类型（MtProtoKit/Sources/MTApiEnvironment.m
 * parse:/parseData:）。
 */
public enum ProxySecretKind {
    | Type0
    | Type1
    | Type2
}

public class ProxySecret {
    public let kind: ProxySecretKind
    public let secretBytes: Array<Byte>
    public let domain: String

    public init(kind: ProxySecretKind, secretBytes: Array<Byte>, domain!: String = "") {
        this.kind = kind
        this.secretBytes = secretBytes
        this.domain = domain
    }

    /** 复刻各分支的字符串序列化，供 `Share Proxy List` 的 secret= 段使用。 */
    public func serializeToString(): String {
        match (this.kind) {
            case ProxySecretKind.Type0 => return ByteUtils.toHex(this.secretBytes)
            case ProxySecretKind.Type1 => return "dd" + ByteUtils.toHex(this.secretBytes)
            case ProxySecretKind.Type2 =>
                return "ee" + ByteUtils.toHex(this.secretBytes) + ByteUtils.toHex(ByteUtils.stringToBytes(this.domain))
        }
    }
}

private func isValidHexString(s: String): Bool {
    if (s.isEmpty() || s.size % 2 != 0) { return false }
    let chars = s.toRuneArray()
    var i: Int64 = 0
    while (i < chars.size) {
        let code = UInt32(chars[i])
        let isDigit = code >= 48 && code <= 57
        let isLower = code >= 97 && code <= 102
        let isUpper = code >= 65 && code <= 70
        if (!isDigit && !isLower && !isUpper) { return false }
        i += 1
    }
    return true
}

/**
 * parseProxySecret — 复刻 iOS MTProxySecret.parse/parseData 的逐分支判据（见
 * diag-suite_settings_data_storage-TC-0433.md 修法 2）：
 *   先按 hex 解码；失败则按 base64url 归一后解码；两者都失败 ⇒ None。
 *   len<16 ⇒ None；len==16 ⇒ Type0；len==17 且首字节 0xdd ⇒ Type1（否则 None）；
 *   len>=18 且首字节 0xee ⇒ Type2（domain=其余字节按 UTF-8 解码，失败 ⇒ None）；其余 ⇒ None。
 */
public func parseProxySecret(s: String): Option<ProxySecret> {
    if (s.isEmpty()) { return None }
    var bytes = Array<Byte>(0, repeat: 0)
    if (isValidHexString(s)) {
        bytes = ByteUtils.fromHex(s)
    } else {
        try {
            bytes = Base64.decodeBase64Url(s)
        } catch (e: Exception) {
            return None
        }
    }
    let len = bytes.size
    if (len < 16) { return None }
    if (len == 16) {
        return Some(ProxySecret(ProxySecretKind.Type0, bytes))
    }
    if (len == 17) {
        if (bytes[0] != 0xDDu8) { return None }
        return Some(ProxySecret(ProxySecretKind.Type1, ByteUtils.slice(bytes, 1, 17)))
    }
    if (len >= 18 && bytes[0] == 0xEEu8) {
        let secretPart = ByteUtils.slice(bytes, 1, 17)
        let domainBytes = ByteUtils.slice(bytes, 17, len)
        try {
            let domainStr = ByteUtils.bytesToString(domainBytes)
            return Some(ProxySecret(ProxySecretKind.Type2, secretPart, domain: domainStr))
        } catch (e: Exception) {
            return None
        }
    }
    return None
}

// ==================== Proxy probe status (C3/F3 修法：可达性探测) ====================

/**
 * ProxyProbeStatus — 单条代理的可达性探测状态。复刻 iOS ProxyServerStatus
 * （TelegramCore/Sources/Network/ProxyServersStatuses.swift）。
 */
public enum ProxyProbeStatus {
    | Checking
    | NotAvailable
    | Available(Int64) // rttMs
}

/**
 * ProxyProbeContext — 单次探测的响应收集器。spawn/launch 闭包不能捕获 var（R-111），
 * 用带 var 字段的类代替裸局部变量在回调线程与轮询线程间传递结果。
 */
private class ProxyProbeContext {
    var received: Option<Array<Byte>> = None
    let mutex = ReentrantMutex()

    // TC-0432 round10 F-B / RC-1：连接腿超时协作标志。connectFinished / abandoned 都受
    // 同一把 mutex 保护；finishConnect()/abandon() 各自返回"读到的对方标志"，用于决定
    // 由连接 spawn 还是超时轮询方负责 transport.disconnect()（互斥，恰好一次）。
    var connectFinished: Bool = false
    var abandoned: Bool = false

    public func deliver(data: Array<Byte>): Unit {
        this.mutex.lock()
        this.received = Some(data)
        this.mutex.unlock()
    }

    public func peek(): Option<Array<Byte>> {
        this.mutex.lock()
        let v = this.received
        this.mutex.unlock()
        return v
    }

    public func finishConnect(): Bool {
        this.mutex.lock()
        this.connectFinished = true
        let wasAbandoned = this.abandoned
        this.mutex.unlock()
        return wasAbandoned
    }

    public func abandon(): Bool {
        this.mutex.lock()
        this.abandoned = true
        let wasFinished = this.connectFinished
        this.mutex.unlock()
        return wasFinished
    }

    public func isConnectFinished(): Bool {
        this.mutex.lock()
        let v = this.connectFinished
        this.mutex.unlock()
        return v
    }
}

private class ProxyProbeCallback <: TransportCallback {
    private let ctx: ProxyProbeContext

    init(ctx: ProxyProbeContext) {
        this.ctx = ctx
    }

    public func onConnected(): Unit {}
    public func onDisconnected(): Unit {}

    public func onData(data: Array<Byte>): Unit {
        this.ctx.deliver(data)
    }

    public func onError(error: String): Unit {
        this.ctx.deliver(Array<Byte>(0, repeat: 0))
    }
}

/**
 * isValidResPQResponse — 复刻 iOS MTProxyConnectivity `isResponseValid:` 的判据，作用于
 * TCPTransport.onData 交付的原始未加密信封字节（未剥离 auth_key_id/message_id/length 头）：
 * 长度 >= 84、偏移 0..7 全零（未加密 auth_key_id）、偏移 20 起 4 字节等于 RES_PQ 构造子、
 * 偏移 24 起 16 字节等于本次发出的 nonce。
 */
private func isValidResPQResponse(data: Array<Byte>, nonce: Array<Byte>): Bool {
    if (data.size < 84) { return false }
    var i: Int64 = 0
    while (i < 8) {
        if (data[i] != 0u8) { return false }
        i += 1
    }
    let constructor = ByteUtils.bytesToUInt32(data, offset: 20)
    if (constructor != AuthKeyConstructors.RES_PQ) { return false }
    let respNonce = ByteUtils.slice(data, 24, 40)
    return ByteUtils.equals(respNonce, nonce)
}

// ==================== Singleton ====================

private var _proxyServiceInstance: Option<ProxyService> = None

public func getProxyService(): ProxyService {
    match (_proxyServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ProxyService()
            _proxyServiceInstance = Some(inst)
            return inst
    }
}

// ==================== ProxyService ====================

public class ProxyService {

    private var _prefs: Option<Preferences> = None
    private var _enabled: Bool = false
    private var _useForCalls: Bool = false
    private var _activeIdx: Int32 = -1
    private var _proxies: Array<ProxyConfig> = Array<ProxyConfig>()
    private var _loaded: Bool = false

    // ==================== Preferences helpers ====================

    private func ensurePrefs(): Unit {
        match (this._prefs) {
            case Some(_) => ()
            case None =>
                match (getGlobalAbilityContext()) {
                    case None =>
                        Hilog.info(0, "CjTelegram", "[ProxyService] No ability context — in-memory only")
                    case Some(ctx) =>
                        try {
                            let prefs = Preferences.getPreferences(ctx, PROXY_STORE_NAME)
                            this._prefs = Some(prefs)
                        } catch (e: Exception) {
                            Hilog.info(0, "CjTelegram", "[ProxyService] Prefs open failed: ${e}")
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
                    Hilog.info(0, "CjTelegram", "[ProxyService] writeBool(${key}) err: ${e}")
                }
        }
    }

    private func readInt(key: String, fallback: Int32): Int32 {
        this.ensurePrefs()
        match (this._prefs) {
            case None => return fallback
            case Some(prefs) =>
                try {
                    let val = prefs.get(key, PreferencesValueType.Integer(Int64(fallback)))
                    match (val) {
                        case PreferencesValueType.Integer(n) => return Int32(n)
                        case _ => return fallback
                    }
                } catch (e: Exception) { return fallback }
        }
    }

    private func writeInt(key: String, value: Int32): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    prefs.put(key, PreferencesValueType.Integer(Int64(value)))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ProxyService] writeInt(${key}) err: ${e}")
                }
        }
    }

    private func readStr(key: String, fallback: String): String {
        this.ensurePrefs()
        match (this._prefs) {
            case None => return fallback
            case Some(prefs) =>
                try {
                    let val = prefs.get(key, PreferencesValueType.StringData(fallback))
                    match (val) {
                        case PreferencesValueType.StringData(s) => return s
                        case _ => return fallback
                    }
                } catch (e: Exception) { return fallback }
        }
    }

    private func writeStr(key: String, value: String): Unit {
        this.ensurePrefs()
        match (this._prefs) {
            case None => ()
            case Some(prefs) =>
                try {
                    prefs.put(key, PreferencesValueType.StringData(value))
                    prefs.flush()
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[ProxyService] writeStr(${key}) err: ${e}")
                }
        }
    }

    // ==================== Load / Save ====================

    private func ensureLoaded(): Unit {
        if (this._loaded) { return }
        this.loadFromStorage()
    }

    private func loadFromStorage(): Unit {
        this._enabled = this.readBool(KEY_PROXY_ENABLED, false)
        this._useForCalls = this.readBool(KEY_PROXY_USE_FOR_CALLS, false)
        this._activeIdx = this.readInt(KEY_PROXY_ACTIVE_IDX, -1)
        let count = this.readInt(KEY_PROXY_COUNT, 0)
        var list = Array<ProxyConfig>()
        var idx: Int32 = 0
        while (idx < count) {
            let host = this.readStr(proxyKey(idx, "host"), "")
            let port = this.readStr(proxyKey(idx, "port"), "1080")
            let typeInt = this.readInt(proxyKey(idx, "type"), 0)
            let username = this.readStr(proxyKey(idx, "user"), "")
            let password = this.readStr(proxyKey(idx, "pass"), "")
            let secret = this.readStr(proxyKey(idx, "secret"), "")
            if (!host.isEmpty()) {
                let cfg = ProxyConfig(host, port: port, proxyType: ProxyType.fromInt(typeInt), username: username, password: password, secret: secret)
                list = appendProxyConfig(list, cfg)
            }
            idx = idx + 1
        }
        this._proxies = list
        this._loaded = true
        Hilog.info(0, "CjTelegram", "[ProxyService] Loaded: enabled=${this._enabled} count=${this._proxies.size}")
    }

    private func saveToStorage(): Unit {
        this.writeBool(KEY_PROXY_ENABLED, this._enabled)
        this.writeBool(KEY_PROXY_USE_FOR_CALLS, this._useForCalls)
        this.writeInt(KEY_PROXY_ACTIVE_IDX, this._activeIdx)
        this.writeInt(KEY_PROXY_COUNT, Int32(this._proxies.size))
        var idx: Int32 = 0
        while (idx < Int32(this._proxies.size)) {
            let cfg = this._proxies[Int64(idx)]
            this.writeStr(proxyKey(idx, "host"), cfg.host)
            this.writeStr(proxyKey(idx, "port"), cfg.port)
            this.writeInt(proxyKey(idx, "type"), cfg.proxyType.toInt())
            this.writeStr(proxyKey(idx, "user"), cfg.username)
            this.writeStr(proxyKey(idx, "pass"), cfg.password)
            this.writeStr(proxyKey(idx, "secret"), cfg.secret)
            idx = idx + 1
        }
        Hilog.info(0, "CjTelegram", "[ProxyService] Saved ${this._proxies.size} proxies")
        // S7-18: lets the Settings root re-evaluate its Proxy row (iOS observes proxySettings).
        let stamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
        launch {
            let _ = AppStorage.setOrCreate<Int64>(PROXY_SETTINGS_VERSION_KEY, stamp)
        }
    }

    // ==================== Accessors ====================

    public func isEnabled(): Bool {
        this.ensureLoaded()
        return this._enabled
    }

    public func isUseForCalls(): Bool {
        this.ensureLoaded()
        return this._useForCalls
    }

    public func getActiveIdx(): Int32 {
        this.ensureLoaded()
        return this._activeIdx
    }

    public func getProxies(): Array<ProxyConfig> {
        this.ensureLoaded()
        return this._proxies
    }

    public func getActiveProxy(): Option<ProxyConfig> {
        this.ensureLoaded()
        let idx = Int64(this._activeIdx)
        if (this._activeIdx >= 0 && idx < this._proxies.size) {
            return Some(this._proxies[idx])
        }
        return None
    }

    // ==================== Mutations ====================

    public func setEnabled(enabled: Bool): Unit {
        this.ensureLoaded()
        this._enabled = enabled
        this.saveToStorage()
        this.applyProxyToTransport()
        Hilog.info(0, "CjTelegram", "[ProxyService] setEnabled=${enabled}")
    }

    public func setUseForCalls(enabled: Bool): Unit {
        this.ensureLoaded()
        this._useForCalls = enabled
        this.saveToStorage()
        Hilog.info(0, "CjTelegram", "[ProxyService] setUseForCalls=${enabled}")
    }

    /**
     * setActiveProxy — 复刻 iOS `activateServer`（ProxyListSettingsController.swift:373-381）：
     * 两路副作用（激活 + 打开总开关）在同一次调用内完成；点已激活行无副作用（对齐
     * `if current.activeServer != server` 前置判断）。见
     * diag-suite_settings_data_storage-TC-0432.md 修法 2 / TC-0434 修法 3。
     */
    public func setActiveProxy(idx: Int32): Unit {
        this.ensureLoaded()
        if (idx < 0 || Int64(idx) >= this._proxies.size) { return }
        if (idx == this._activeIdx) { return }
        this._activeIdx = idx
        this._enabled = true
        this.saveToStorage()
        this.applyProxyToTransport()
    }

    /**
     * addProxy — 复刻 iOS 保存去重（ProxyServerSettingsController.swift:340-347）：
     * `ProxyServerSettings` 是值类型，`contains` 即结构相等去重，命中时静默什么都不做。
     * 见 diag-suite_settings_data_storage-TC-0433.md 修法 4。
     */
    public func addProxy(config: ProxyConfig): Int32 {
        this.ensureLoaded()
        var i: Int64 = 0
        while (i < this._proxies.size) {
            if (this._proxies[i].structurallyEquals(config)) {
                return Int32(i)
            }
            i += 1
        }
        this._proxies = appendProxyConfig(this._proxies, config)
        let newIdx = Int32(this._proxies.size) - 1
        if (this._activeIdx < 0) {
            this._activeIdx = newIdx
        }
        this.saveToStorage()
        Hilog.info(0, "CjTelegram", "[ProxyService] Added proxy ${config.host}:${config.port}")
        return newIdx
    }

    public func updateProxy(idx: Int32, config: ProxyConfig): Unit {
        this.ensureLoaded()
        if (idx >= 0 && Int64(idx) < this._proxies.size) {
            this._proxies[Int64(idx)] = config
            this.saveToStorage()
            if (this._enabled && this._activeIdx == idx) {
                this.applyProxyToTransport()
            }
        }
    }

    /**
     * removeProxy — 复刻 iOS `removeServer`（ProxyListSettingsController.swift:385-395）：
     * 移除 / 清空 activeServer / 关闭总开关三路在同一次事务内完成，只在删的是活跃那条时
     * 才触发后两路。见 diag-suite_settings_data_storage-TC-0434.md 修法 2。
     */
    public func removeProxy(idx: Int32): Unit {
        this.ensureLoaded()
        let count = Int32(this._proxies.size)
        if (idx < 0 || idx >= count) { return }
        var newList = Array<ProxyConfig>()
        var i: Int32 = 0
        while (i < count) {
            if (i != idx) {
                newList = appendProxyConfig(newList, this._proxies[Int64(i)])
            }
            i = i + 1
        }
        this._proxies = newList
        if (this._activeIdx == idx) {
            // 无条件清空（对齐源侧 activeServer = nil / enabled = false），不看剩余条数。
            this._activeIdx = -1
            this._enabled = false
        } else if (this._activeIdx > idx) {
            this._activeIdx = this._activeIdx - 1
        }
        this.saveToStorage()
        // 无条件调用（不再由 _enabled 门控）：_enabled 刚变 false 的这一次也要把代理从
        // transport 上摘掉，applyProxyToTransport() 内部的 !_enabled 分支负责清空。
        this.applyProxyToTransport()
    }

    /**
     * reorderProxy — tap-to-pick-and-place 重排（HarmonyOS ListItem 无 onDragStart/onDrop，
     * 同 StickersSettingsPage/ChatFoldersPage 已验证方案）。把 fromIdx 条目移到 toIdx 的位置，
     * `_activeIdx` 跟随其指向的那条代理的新下标（对齐源侧 D3：activeServer 是值引用，重排
     * 后仍指同一条；目标侧是下标存储，必须显式跟着搬）。
     */
    public func reorderProxy(fromIdx: Int32, toIdx: Int32): Unit {
        this.ensureLoaded()
        let count = Int32(this._proxies.size)
        if (fromIdx < 0 || fromIdx >= count || toIdx < 0 || toIdx >= count || fromIdx == toIdx) { return }

        var activeConfig: Option<ProxyConfig> = None
        if (this._activeIdx >= 0 && Int64(this._activeIdx) < this._proxies.size) {
            activeConfig = Some(this._proxies[Int64(this._activeIdx)])
        }

        let moved = this._proxies[Int64(fromIdx)]
        var withoutMoved = Array<ProxyConfig>()
        var i: Int32 = 0
        while (i < count) {
            if (i != fromIdx) {
                withoutMoved = appendProxyConfig(withoutMoved, this._proxies[Int64(i)])
            }
            i += 1
        }

        let insertAt: Int32 = toIdx
        var newList = Array<ProxyConfig>()
        var j: Int32 = 0
        var inserted = false
        while (j < Int32(withoutMoved.size)) {
            if (j == insertAt) {
                newList = appendProxyConfig(newList, moved)
                inserted = true
            }
            newList = appendProxyConfig(newList, withoutMoved[Int64(j)])
            j += 1
        }
        if (!inserted) {
            newList = appendProxyConfig(newList, moved)
        }

        this._proxies = newList

        match (activeConfig) {
            case None => ()
            case Some(cfg) =>
                var newActiveIdx: Int32 = -1
                var k: Int32 = 0
                while (k < Int32(this._proxies.size)) {
                    if (this._proxies[Int64(k)].structurallyEquals(cfg)) {
                        newActiveIdx = k
                        break
                    }
                    k += 1
                }
                this._activeIdx = newActiveIdx
        }

        this.saveToStorage()
    }

    /**
     * buildProxyListShareText — 复刻 iOS `shareProxyListImpl`
     * （ProxyListSettingsController.swift:530-560）：遍历全部代理（不只活跃那条），逐条拼
     * t.me 深链，`\n\n` 连接。见 diag-suite_settings_data_storage-TC-0432.md 修法 4。
     */
    public func buildProxyListShareText(): String {
        this.ensureLoaded()
        var result = ""
        var i: Int64 = 0
        while (i < this._proxies.size) {
            let cfg = this._proxies[i]
            if (!result.isEmpty()) {
                result += "\n\n"
            }
            result += this.buildProxyShareLink(cfg)
            i += 1
        }
        return result
    }

    /**
     * buildShareLinkFor — 单条代理（通常是表单里尚未保存的那条）的分享链接，供表单页的
     * `Share` 行（TC-0433 D 组，见该报告"结论与后续动作"的接线依赖说明）使用。
     */
    public func buildShareLinkFor(cfg: ProxyConfig): String {
        return this.buildProxyShareLink(cfg)
    }

    private func buildProxyShareLink(cfg: ProxyConfig): String {
        match (cfg.proxyType) {
            case ProxyType.MTProto =>
                var secretStr = ""
                match (parseProxySecret(cfg.secret)) {
                    case Some(secret) => secretStr = secret.serializeToString()
                    case None => secretStr = ""
                }
                var link = "https://t.me/proxy?server=${percentEncode(cfg.host)}&port=${cfg.port}"
                link += "&secret=${percentEncode(secretStr)}"
                return link
            case ProxyType.SOCKS5 =>
                var link = "https://t.me/socks?server=${percentEncode(cfg.host)}&port=${cfg.port}"
                if (!cfg.username.isEmpty() && !cfg.password.isEmpty()) {
                    link += "&user=${percentEncode(cfg.username)}&pass=${percentEncode(cfg.password)}"
                }
                return link
        }
    }

    /**
     * probeProxyStatus — 对一条代理做一次可达性探测（阻塞，调用方须在 spawn 中调用）。复刻
     * iOS `MTProxyConnectivity.pingProxy` 的逻辑：TCP 连到代理走 SOCKS5 隧道（TCPTransport
     * 内建，proxy 非 None 时 connect() 自动走隧道路径）到当前 DC，发一个 req_pq_multi，按
     * isValidResPQResponse 判定响应是否合法；隧道建成到收到有效响应的耗时即 rtt。
     *
     * 仅覆盖 SOCKS5 代理：MTProto 类型代理本身即终点、走 obfuscated 传输，是另一套机制，
     * 不在本探测覆盖范围（不影响 C3/F3 覆盖的 SOCKS5 场景）。
     */
    public func probeProxyStatus(cfg: ProxyConfig): ProxyProbeStatus {
        var isSocks5 = false
        match (cfg.proxyType) {
            case ProxyType.SOCKS5 => isSocks5 = true
            case ProxyType.MTProto => isSocks5 = false
        }
        if (!isSocks5) {
            return ProxyProbeStatus.NotAvailable
        }

        let proxySettingsOpt = cfg.toTransportSettings()
        if (proxySettingsOpt.isNone()) {
            return ProxyProbeStatus.NotAvailable
        }
        let proxySettings = proxySettingsOpt.getOrThrow()

        let dc = MTProtoConfig.getDefaultDC()
        let transport = TCPTransport(dc)
        transport.setProxy(Some(proxySettings))

        let ctx = ProxyProbeContext()
        let callback = ProxyProbeCallback(ctx)
        transport.setCallback(callback)

        let startMs = DateTime.now().toUnixTimeStamp().toMilliseconds()

        // TC-0432 round10 F-B / RC-1：连接腿加 12 s 时限，调用线程不再被内核阻塞。
        // transport.connect() 放进 spawn；本线程以 100 ms 步长轮询 isConnectFinished()。
        // 超时与正常结束两条路径各自负责 disconnect()，由 finishConnect()/abandon() 的
        // 返回值（读到的对方标志）决定，二者互斥，恰好一次，不会双重 disconnect 也不会泄漏。
        let transportRef = transport
        let _ = spawn {
            transportRef.connect()
            let alreadyAbandoned = ctx.finishConnect()
            if (alreadyAbandoned) {
                transportRef.disconnect()
            }
        }

        var connectWaitedMs: Int64 = 0
        let connectTimeoutMs: Int64 = 12000
        while (connectWaitedMs < connectTimeoutMs) {
            if (ctx.isConnectFinished()) { break }
            sleep(Duration.millisecond * 100)
            connectWaitedMs += 100
        }

        if (!ctx.isConnectFinished()) {
            // 未在时限内完成：本线程负责放弃。abandon() 返回 true 表示连接其实已经
            // 在此刻之前完成（罕见的边界竞态），此时由本线程 disconnect()；返回
            // false 表示连接仍卡在内核阻塞的 connect() 里，disconnect() 无意义
            // （tcpSocket 尚未被赋值），留给日后完成的 spawn 自己收尾。
            let alreadyFinished = ctx.abandon()
            if (alreadyFinished) {
                transport.disconnect()
            }
            return ProxyProbeStatus.NotAvailable
        }

        if (!transport.isConnected()) {
            return ProxyProbeStatus.NotAvailable
        }

        let _ = spawn {
            transportRef.startReceiveLoop()
        }

        let nonce = ByteUtils.randomBytes(16)
        let body = TLSerializer()
        body.writeUInt32(AuthKeyConstructors.REQ_PQ_MULTI)
        body.writeRawBytes(nonce)
        let bodyBytes = body.getBytes()

        let envelope = TLSerializer()
        envelope.writeInt64(0)
        let msgId = (DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000) << 32
        envelope.writeInt64(msgId)
        envelope.writeInt32(Int32(bodyBytes.size))
        envelope.writeRawBytes(bodyBytes)

        transport.send(envelope.getBytes())

        var waitedMs: Int64 = 0
        let maxWaitMs: Int64 = 9000
        while (waitedMs < maxWaitMs) {
            if (ctx.peek().isSome()) { break }
            sleep(Duration.millisecond * 100)
            waitedMs += 100
        }

        let finalData = ctx.peek()
        transport.disconnect()

        if (finalData.isNone()) {
            return ProxyProbeStatus.NotAvailable
        }
        let data = finalData.getOrThrow()
        if (data.size == 0 || !isValidResPQResponse(data, nonce)) {
            return ProxyProbeStatus.NotAvailable
        }
        let elapsedMs = DateTime.now().toUnixTimeStamp().toMilliseconds() - startMs
        return ProxyProbeStatus.Available(elapsedMs)
    }

    // ==================== Transport wiring ====================

    private func applyProxyToTransport(): Unit {
        if (!this._enabled) {
            getProxyStateStore().setCurrentProxy(Option<ProxySettings>.None)
        } else {
            match (this.getActiveProxy()) {
                case None =>
                    getProxyStateStore().setCurrentProxy(Option<ProxySettings>.None)
                case Some(cfg) =>
                    match (cfg.toTransportSettings()) {
                        case None =>
                            getProxyStateStore().setCurrentProxy(Option<ProxySettings>.None)
                        case Some(ps) =>
                            getProxyStateStore().setCurrentProxy(Option<ProxySettings>.Some(ps))
                            Hilog.info(0, "CjTelegram", "[ProxyService] Transport proxy set ${ps.server}:${ps.port}")
                    }
            }
        }
        // P2-324 r1：将代理提供者注入 MTProtoClient.transportManager，令后续所有新建
        // TCPTransport 在 connect() 前都读取当前活跃代理（ProxyStateStore.getCurrentProxy）。
        // 不破坏直连：provider() 返回 None 时 TCPTransport.setProxy(None) 仍走原直连路径。
        getMTProtoClient().setProxyProvider { getProxyStateStore().getCurrentProxy() }
    }
}

// ==================== Array helper ====================

private func appendProxyConfig(arr: Array<ProxyConfig>, item: ProxyConfig): Array<ProxyConfig> {
    let sz = arr.size
    let newArr = Array<ProxyConfig>(sz + 1, repeat: item)
    var i: Int64 = 0
    while (i < sz) {
        newArr[i] = arr[i]
        i = i + 1
    }
    newArr[sz] = item
    return newArr
}

// ==================== ProxyStateStore ====================

private var _proxyStateStoreInstance: Option<ProxyStateStore> = None

public func getProxyStateStore(): ProxyStateStore {
    match (_proxyStateStoreInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ProxyStateStore()
            _proxyStateStoreInstance = Some(inst)
            return inst
    }
}

/**
 * Singleton holding the active transport-level proxy.
 * MTProtoTransport reads this at connect() time to know which proxy to use.
 */
public class ProxyStateStore {
    private var _current: Option<ProxySettings> = None

    public func getCurrentProxy(): Option<ProxySettings> {
        return this._current
    }

    public func setCurrentProxy(proxy: Option<ProxySettings>): Unit {
        this._current = proxy
    }
}
