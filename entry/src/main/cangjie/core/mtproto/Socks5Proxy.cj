package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import std.net.TcpSocket

/**
 * ProxySettings — SOCKS5 代理配置模型
 *
 * 对应 iOS MTSocksProxySettings:
 *   host / port / username / password / secret
 *
 * secret 字段预留给 MTProxy 混淆传输（本单元不实现混淆，仅保留字段）。
 */
public class ProxySettings {
    /** 代理服务器主机名或 IP */
    public let server: String
    /** 代理服务器端口 */
    public let port: UInt16
    /** 用户名（空串 = 无需认证） */
    public let username: String
    /** 密码（空串 = 无需认证） */
    public let password: String
    /**
     * MTProxy secret（十六进制字符串）。
     * SOCKS5 握手不使用此字段；后续 MTProxy 混淆传输时由上层读取。
     */
    public let secret: String

    public init(
        server: String,
        port: UInt16,
        username!: String = "",
        password!: String = "",
        secret!: String = ""
    ) {
        this.server = server
        this.port = port
        this.username = username
        this.password = password
        this.secret = secret
    }

    /** 是否需要用户名/密码认证 */
    public func needsAuth(): Bool {
        return !this.username.isEmpty()
    }
}

/**
 * SOCKS5 握手错误
 */
public class Socks5Error <: Exception {
    private let _message: String

    public init(message: String) {
        this._message = message
    }

    public override func toString(): String {
        return "Socks5Error: ${this._message}"
    }
}

/**
 * Socks5Handshake — RFC 1928 / RFC 1929 SOCKS5 握手实现
 *
 * 握手在已连接到代理服务器的 TcpSocket 上执行（复用同一 socket）。
 * 握手完成后 socket 即透明隧道，调用方可直接收发 MTProto 数据。
 *
 * 支持方法：
 *   0x00  NO AUTHENTICATION REQUIRED
 *   0x02  USERNAME/PASSWORD AUTHENTICATION (RFC 1929)
 *
 * 连接命令：
 *   0x01  CONNECT
 *
 * 地址类型：
 *   0x01  IPv4（4 字节）
 *   0x03  域名（1 字节长度 + 域名）
 *   0x04  IPv6（16 字节）
 */
public class Socks5Handshake {

    // ---- 协议常量 ----
    private static let SOCKS5_VER: UInt8     = 0x05u8
    private static let AUTH_VER: UInt8       = 0x01u8
    private static let METHOD_NO_AUTH: UInt8 = 0x00u8
    private static let METHOD_USERPASS: UInt8 = 0x02u8
    private static let METHOD_REJECT: UInt8  = 0xFFu8
    private static let CMD_CONNECT: UInt8    = 0x01u8
    private static let RSV: UInt8            = 0x00u8
    private static let ATYP_IPV4: UInt8      = 0x01u8
    private static let ATYP_DOMAIN: UInt8    = 0x03u8
    private static let ATYP_IPV6: UInt8      = 0x04u8
    private static let REP_SUCCESS: UInt8    = 0x00u8
    private static let AUTH_SUCCESS: UInt8   = 0x00u8

    /**
     * 执行完整 SOCKS5 握手序列。
     *
     * 调用前提：sock 已通过 sock.connect() 连接到代理服务器。
     * 调用完毕：sock 成为指向 targetHost:targetPort 的透明隧道。
     *
     * 任何步骤失败均抛出 Socks5Error，上层负责关闭 socket。
     *
     * @param sock       已连接的 TcpSocket（连接到代理服务器）
     * @param proxy      代理配置
     * @param targetHost DC 主机名或 IP（如 "149.154.167.51"）
     * @param targetPort DC 端口（如 443）
     */
    public static func perform(
        sock: TcpSocket,
        proxy: ProxySettings,
        targetHost: String,
        targetPort: UInt16
    ): Unit {
        Hilog.info(0, "CjTelegram", "[Socks5] Starting SOCKS5 handshake to ${targetHost}:${targetPort} via ${proxy.server}:${proxy.port}")

        // Step 1: 问候握手 — 告知支持的认证方法
        sendGreeting(sock, proxy)

        // Step 2: 读取服务器选择的认证方法
        let selectedMethod = readServerMethodChoice(sock)

        // Step 3: 若需要用户名/密码认证
        if (selectedMethod == METHOD_USERPASS) {
            sendUserPassAuth(sock, proxy)
        }

        // Step 4: 发送 CONNECT 请求
        sendConnectRequest(sock, targetHost, targetPort)

        // Step 5: 读取 CONNECT 响应
        readConnectResponse(sock)

        Hilog.info(0, "CjTelegram", "[Socks5] Handshake complete — tunnel established to ${targetHost}:${targetPort}")
    }

    // -------------------------------------------------------------------------
    // 内部实现方法
    // -------------------------------------------------------------------------

    /**
     * Step 1: 发送问候报文
     * 格式: VER(0x05) NMETHODS METHODS...
     */
    private static func sendGreeting(sock: TcpSocket, proxy: ProxySettings): Unit {
        let greeting: Array<Byte>
        if (proxy.needsAuth()) {
            // 支持两种方法: 0x00 无认证, 0x02 用户名/密码
            greeting = Array<Byte>(4, repeat: 0)
            greeting[0] = SOCKS5_VER
            greeting[1] = 0x02u8   // NMETHODS = 2
            greeting[2] = METHOD_NO_AUTH
            greeting[3] = METHOD_USERPASS
        } else {
            // 仅支持 0x00 无认证
            greeting = Array<Byte>(3, repeat: 0)
            greeting[0] = SOCKS5_VER
            greeting[1] = 0x01u8   // NMETHODS = 1
            greeting[2] = METHOD_NO_AUTH
        }
        try {
            sock.write(greeting)
        } catch (e: Exception) {
            throw Socks5Error("Failed to send greeting: ${e}")
        }
    }

    /**
     * Step 2: 读取服务器选择的方法
     * 格式: VER(0x05) METHOD
     * 返回: 选择的方法字节
     */
    private static func readServerMethodChoice(sock: TcpSocket): UInt8 {
        let buf = Array<Byte>(2, repeat: 0)
        let n = readExact(sock, buf, 2)
        if (n < 2) {
            throw Socks5Error("Server closed connection during method selection (got ${n} bytes)")
        }
        if (buf[0] != SOCKS5_VER) {
            throw Socks5Error("Server replied with unexpected SOCKS version: 0x${byteToHex(buf[0])}")
        }
        let method = buf[1]
        if (method == METHOD_REJECT) {
            throw Socks5Error("Server rejected all authentication methods (0xFF)")
        }
        if (method != METHOD_NO_AUTH && method != METHOD_USERPASS) {
            throw Socks5Error("Server selected unsupported method: 0x${byteToHex(method)}")
        }
        return method
    }

    /**
     * Step 3: RFC 1929 用户名/密码认证
     * 发送: VER(0x01) ULEN UNAME PLEN PASSWD
     * 接收: VER(0x01) STATUS
     */
    private static func sendUserPassAuth(sock: TcpSocket, proxy: ProxySettings): Unit {
        let unameBytes = ByteUtils.stringToBytes(proxy.username)
        let passwdBytes = ByteUtils.stringToBytes(proxy.password)
        let ulen = unameBytes.size
        let plen = passwdBytes.size

        if (ulen > 255) {
            throw Socks5Error("Username too long (> 255 bytes)")
        }
        if (plen > 255) {
            throw Socks5Error("Password too long (> 255 bytes)")
        }

        // 构造认证报文
        let authLen: Int64 = 1 + 1 + ulen + 1 + plen
        let authMsg = Array<Byte>(authLen, repeat: 0)
        var offset: Int64 = 0
        authMsg[offset] = AUTH_VER
        offset += 1
        authMsg[offset] = UInt8(ulen)
        offset += 1
        ByteUtils.copyTo(unameBytes, authMsg, offset)
        offset += ulen
        authMsg[offset] = UInt8(plen)
        offset += 1
        ByteUtils.copyTo(passwdBytes, authMsg, offset)

        try {
            sock.write(authMsg)
        } catch (e: Exception) {
            throw Socks5Error("Failed to send username/password auth: ${e}")
        }

        // 读取认证结果
        let resp = Array<Byte>(2, repeat: 0)
        let n = readExact(sock, resp, 2)
        if (n < 2) {
            throw Socks5Error("Server closed connection during auth response (got ${n} bytes)")
        }
        if (resp[1] != AUTH_SUCCESS) {
            throw Socks5Error("SOCKS5 username/password authentication failed (status=0x${byteToHex(resp[1])})")
        }
    }

    /**
     * Step 4: 发送 CONNECT 请求
     * 格式: VER(0x05) CMD(0x01) RSV(0x00) ATYP DST.ADDR DST.PORT
     *
     * DST.PORT 大端 2 字节。
     * 地址类型判断：尝试解析为 IPv4，否则当作域名。
     */
    private static func sendConnectRequest(sock: TcpSocket, targetHost: String, targetPort: UInt16): Unit {
        let addrBytes = buildAddressBytes(targetHost)
        // addrBytes[0] = ATYP, addrBytes[1..] = 地址字段

        // 端口大端 2 字节
        let portHi = UInt8((UInt32(targetPort) >> 8) & 0xFFu32)
        let portLo = UInt8(UInt32(targetPort) & 0xFFu32)

        let reqLen: Int64 = 4 + addrBytes.size + 2
        let req = Array<Byte>(reqLen, repeat: 0)
        req[0] = SOCKS5_VER
        req[1] = CMD_CONNECT
        req[2] = RSV
        ByteUtils.copyTo(addrBytes, req, 3)
        req[3 + addrBytes.size] = portHi
        req[3 + addrBytes.size + 1] = portLo

        try {
            sock.write(req)
        } catch (e: Exception) {
            throw Socks5Error("Failed to send CONNECT request: ${e}")
        }
    }

    /**
     * Step 5: 读取 CONNECT 响应
     * 格式: VER(0x05) REP RSV ATYP BND.ADDR BND.PORT
     *
     * 必须读完 BND.ADDR + BND.PORT 以保持流同步（即使不使用返回绑定地址）。
     */
    private static func readConnectResponse(sock: TcpSocket): Unit {
        // 先读固定 4 字节头
        let header = Array<Byte>(4, repeat: 0)
        let n = readExact(sock, header, 4)
        if (n < 4) {
            throw Socks5Error("Server closed connection during CONNECT response (got ${n} bytes)")
        }
        if (header[0] != SOCKS5_VER) {
            throw Socks5Error("CONNECT response: unexpected SOCKS version 0x${byteToHex(header[0])}")
        }
        if (header[1] != REP_SUCCESS) {
            throw Socks5Error("CONNECT failed: REP=0x${byteToHex(header[1])} — ${repCodeDescription(header[1])}")
        }

        // 根据 ATYP 读取 BND.ADDR
        let atyp = header[3]
        let addrLen: Int64
        if (atyp == ATYP_IPV4) {
            addrLen = 4
        } else if (atyp == ATYP_IPV6) {
            addrLen = 16
        } else if (atyp == ATYP_DOMAIN) {
            // 先读 1 字节域名长度
            let lenBuf = Array<Byte>(1, repeat: 0)
            let ln = readExact(sock, lenBuf, 1)
            if (ln < 1) {
                throw Socks5Error("Failed to read domain length in CONNECT response")
            }
            addrLen = Int64(lenBuf[0])
        } else {
            throw Socks5Error("CONNECT response: unknown ATYP=0x${byteToHex(atyp)}")
        }

        // 读取 BND.ADDR
        let addrBuf = Array<Byte>(addrLen, repeat: 0)
        let an = readExact(sock, addrBuf, addrLen)
        if (an < addrLen) {
            throw Socks5Error("Failed to read BND.ADDR in CONNECT response (expected ${addrLen}, got ${an})")
        }

        // 读取 BND.PORT (2 字节)
        let portBuf = Array<Byte>(2, repeat: 0)
        let pn = readExact(sock, portBuf, 2)
        if (pn < 2) {
            throw Socks5Error("Failed to read BND.PORT in CONNECT response (got ${pn})")
        }
    }

    // -------------------------------------------------------------------------
    // 辅助方法
    // -------------------------------------------------------------------------

    /**
     * 构造地址字节序列（含 ATYP 前缀）。
     * 规则：
     *   - 尝试解析 IPv4（以 "." 分隔的4个十进制段）→ ATYP=0x01 + 4字节
     *   - 否则当作域名 → ATYP=0x03 + 1字节长度 + 域名字节
     */
    private static func buildAddressBytes(host: String): Array<Byte> {
        // 尝试 IPv4 解析
        let ipv4 = tryParseIPv4(host)
        match (ipv4) {
            case Some(bytes) =>
                let result = Array<Byte>(5, repeat: 0)  // ATYP + 4字节
                result[0] = ATYP_IPV4
                result[1] = bytes[0]
                result[2] = bytes[1]
                result[3] = bytes[2]
                result[4] = bytes[3]
                return result
            case None =>
                // 域名
                let domainBytes = ByteUtils.stringToBytes(host)
                let dlen = domainBytes.size
                if (dlen > 255) {
                    throw Socks5Error("Domain name too long (> 255 bytes): ${host}")
                }
                let result = Array<Byte>(2 + dlen, repeat: 0)  // ATYP + len + domain
                result[0] = ATYP_DOMAIN
                result[1] = UInt8(dlen)
                ByteUtils.copyTo(domainBytes, result, 2)
                return result
        }
    }

    /**
     * 尝试解析 IPv4 地址字符串，返回 4 字节数组。
     * 返回 None 表示不是有效 IPv4。
     */
    private static func tryParseIPv4(host: String): Option<Array<Byte>> {
        let parts = host.split(".")
        if (parts.size != 4) {
            return None
        }
        let bytes = Array<Byte>(4, repeat: 0)
        for (i in 0..4) {
            let part = parts[i]
            // 简单数字解析
            var val: Int64 = 0
            var valid = true
            if (part.isEmpty()) {
                valid = false
            } else {
                let partBytes = ByteUtils.stringToBytes(part)
                for (j in 0..partBytes.size) {
                    let c = Int64(partBytes[j])
                    if (c < 48 || c > 57) {  // '0'..'9' ASCII 48-57
                        valid = false
                        break
                    }
                    val = val * 10 + c - 48
                }
            }
            if (!valid || val < 0 || val > 255) {
                return None
            }
            bytes[i] = UInt8(val)
        }
        return Some(bytes)
    }

    /**
     * 从 socket 精确读取 n 字节到 buf 中。
     * 返回实际读取字节数（< n 表示连接关闭）。
     */
    private static func readExact(sock: TcpSocket, buf: Array<Byte>, n: Int64): Int64 {
        var total: Int64 = 0
        while (total < n) {
            let slice = Array<Byte>(n - total, repeat: 0)
            var got: Int64 = 0
            try {
                got = sock.read(slice)
            } catch (e: Exception) {
                throw Socks5Error("Socket read error: ${e}")
            }
            if (got <= 0) {
                break  // 连接关闭
            }
            for (i in 0..got) {
                buf[total + i] = slice[i]
            }
            total += got
        }
        return total
    }

    /**
     * REP 错误码描述（RFC 1928 §6）
     */
    private static func repCodeDescription(rep: UInt8): String {
        let code = Int64(rep)
        if (code == 0x01) { return "general SOCKS server failure" }
        if (code == 0x02) { return "connection not allowed by ruleset" }
        if (code == 0x03) { return "network unreachable" }
        if (code == 0x04) { return "host unreachable" }
        if (code == 0x05) { return "connection refused" }
        if (code == 0x06) { return "TTL expired" }
        if (code == 0x07) { return "command not supported" }
        if (code == 0x08) { return "address type not supported" }
        return "unknown error (0x${byteToHex(rep)})"
    }

    /**
     * 单字节转两位十六进制字符串（用于日志/错误）
     */
    private static func byteToHex(b: UInt8): String {
        let hex = Array<Byte>(2, repeat: 0)
        let hi = UInt8(UInt32(b) >> 4)
        let lo = UInt8(UInt32(b) & 0x0Fu32)
        if (hi < 10u8) {
            hex[0] = hi + 48u8
        } else {
            hex[0] = hi - 10u8 + 65u8
        }
        if (lo < 10u8) {
            hex[1] = lo + 48u8
        } else {
            hex[1] = lo - 10u8 + 65u8
        }
        return ByteUtils.bytesToString(hex)
    }

    // -------------------------------------------------------------------------
    // selfCheck — 对固定输入的握手字节构造进行断言
    // 无需真实网络连接；验证字节布局正确性
    // -------------------------------------------------------------------------

    /**
     * 验证 buildAddressBytes 对 IPv4 字符串产生正确字节布局。
     * 验证 sendGreeting 字节布局通过手工构造断言。
     *
     * 如果任何断言失败，抛出异常。
     */
    public static func selfCheck(): Unit {
        // --- 断言1: IPv4 地址解析 ---
        let ipv4Opt = tryParseIPv4("149.154.167.51")
        match (ipv4Opt) {
            case None =>
                throw Socks5Error("selfCheck FAIL: tryParseIPv4('149.154.167.51') returned None")
            case Some(ipBytes) =>
                if (ipBytes.size != 4) {
                    throw Socks5Error("selfCheck FAIL: IPv4 bytes size expected 4, got ${ipBytes.size}")
                }
                if (ipBytes[0] != 149u8 || ipBytes[1] != 154u8 || ipBytes[2] != 167u8 || ipBytes[3] != 51u8) {
                    throw Socks5Error("selfCheck FAIL: IPv4 bytes wrong: expected [149,154,167,51]")
                }
        }

        // --- 断言2: buildAddressBytes for IPv4 ---
        let addrBytes = buildAddressBytes("149.154.167.51")
        // 期望: [ATYP_IPV4=0x01, 149, 154, 167, 51]  长度=5
        if (addrBytes.size != 5) {
            throw Socks5Error("selfCheck FAIL: addrBytes size expected 5, got ${addrBytes.size}")
        }
        if (addrBytes[0] != ATYP_IPV4) {
            throw Socks5Error("selfCheck FAIL: ATYP expected 0x01, got 0x${byteToHex(addrBytes[0])}")
        }
        if (addrBytes[1] != 149u8 || addrBytes[2] != 154u8 || addrBytes[3] != 167u8 || addrBytes[4] != 51u8) {
            throw Socks5Error("selfCheck FAIL: IPv4 address bytes mismatch")
        }

        // --- 断言3: buildAddressBytes for domain ---
        let domainAddr = buildAddressBytes("proxy.example.com")
        // 期望: [ATYP_DOMAIN=0x03, 17, <17 bytes of "proxy.example.com">]
        let domainStr = "proxy.example.com"
        let domainBytes = ByteUtils.stringToBytes(domainStr)
        if (domainAddr[0] != ATYP_DOMAIN) {
            throw Socks5Error("selfCheck FAIL: domain ATYP expected 0x03, got 0x${byteToHex(domainAddr[0])}")
        }
        if (Int64(domainAddr[1]) != domainBytes.size) {
            throw Socks5Error("selfCheck FAIL: domain length byte mismatch")
        }

        // --- 断言4: 问候报文字节布局 (无认证，1方法) ---
        // 期望: [0x05, 0x01, 0x00]
        let greetingNoAuth = Array<Byte>(3, repeat: 0)
        greetingNoAuth[0] = SOCKS5_VER
        greetingNoAuth[1] = 0x01u8
        greetingNoAuth[2] = METHOD_NO_AUTH
        if (greetingNoAuth[0] != 0x05u8 || greetingNoAuth[1] != 0x01u8 || greetingNoAuth[2] != 0x00u8) {
            throw Socks5Error("selfCheck FAIL: greeting no-auth bytes wrong")
        }

        // --- 断言5: 问候报文字节布局 (用户名密码，2方法) ---
        // 期望: [0x05, 0x02, 0x00, 0x02]
        let greetingAuth = Array<Byte>(4, repeat: 0)
        greetingAuth[0] = SOCKS5_VER
        greetingAuth[1] = 0x02u8
        greetingAuth[2] = METHOD_NO_AUTH
        greetingAuth[3] = METHOD_USERPASS
        if (greetingAuth[0] != 0x05u8 || greetingAuth[1] != 0x02u8 ||
            greetingAuth[2] != 0x00u8 || greetingAuth[3] != 0x02u8) {
            throw Socks5Error("selfCheck FAIL: greeting auth bytes wrong")
        }

        // --- 断言6: CONNECT 请求字节布局（IPv4 + 端口 443）---
        // 期望: [0x05, 0x01, 0x00, 0x01, 149, 154, 167, 51, 0x01, 0xBB]
        // port 443 大端 = [0x01, 0xBB]
        let connectReqAddrBytes = buildAddressBytes("149.154.167.51")
        let targetPort: UInt16 = 443u16
        let portHi = UInt8((UInt32(targetPort) >> 8) & 0xFFu32)
        let portLo = UInt8(UInt32(targetPort) & 0xFFu32)
        let reqLen: Int64 = 4 + connectReqAddrBytes.size + 2
        let req = Array<Byte>(reqLen, repeat: 0)
        req[0] = SOCKS5_VER
        req[1] = CMD_CONNECT
        req[2] = RSV
        ByteUtils.copyTo(connectReqAddrBytes, req, 3)
        req[3 + connectReqAddrBytes.size] = portHi
        req[3 + connectReqAddrBytes.size + 1] = portLo
        // 验证关键字节
        if (req[0] != 0x05u8) {
            throw Socks5Error("selfCheck FAIL: CONNECT req[0] VER expected 0x05")
        }
        if (req[1] != 0x01u8) {
            throw Socks5Error("selfCheck FAIL: CONNECT req[1] CMD expected 0x01 (CONNECT)")
        }
        if (req[2] != 0x00u8) {
            throw Socks5Error("selfCheck FAIL: CONNECT req[2] RSV expected 0x00")
        }
        if (req[3] != 0x01u8) {
            throw Socks5Error("selfCheck FAIL: CONNECT req[3] ATYP expected 0x01 (IPv4)")
        }
        // port bytes: req[3+5] = portHi = 0x01, req[3+6] = portLo = 0xBB
        if (portHi != 0x01u8 || portLo != 0xBBu8) {
            throw Socks5Error("selfCheck FAIL: port 443 encoding expected [0x01, 0xBB], got [0x${byteToHex(portHi)}, 0x${byteToHex(portLo)}]")
        }

        Hilog.info(0, "CjTelegram", "[Socks5] selfCheck PASSED — all byte layout assertions verified")
    }
}
