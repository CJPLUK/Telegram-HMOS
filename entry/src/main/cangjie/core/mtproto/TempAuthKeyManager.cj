package ohos_app_cangjie_entry.core.mtproto

import kit.PerformanceAnalysisKit.Hilog
import std.sync.ReentrantMutex
internal import std.time.*

/**
 * 临时认证密钥（Perfect Forward Secrecy）
 *
 * 对应 iOS MtProtoKit 的 MTDatacenterAuthKey(notBound/temp)。
 * 临时密钥与永久密钥的 DH 握手完全相同，区别在于：
 *   - 生成时 p_q_inner_data 携带非 0 的 expires_in（见 AuthKeyCreator.createTempAuthKey）
 *   - 必须用 auth.bindTempAuthKey 绑定到永久密钥后才能用于会话加密
 *   - 带过期时间 expiresAt，过期后需重新生成 + 重新绑定
 */
public class TempAuthKey {
    public var authKey: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var authKeyId: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var serverSalt: Array<Byte> = Array<Byte>(0, repeat: 0)
    // Unix 秒；服务器时间口径（已含 timeOffset 校正）
    public var expiresAt: Int64 = 0
    // 是否已成功 bindTempAuthKey 绑定到永久密钥
    public var bound: Bool = false

    public init() {}

    public init(authKey!: Array<Byte>, authKeyId!: Array<Byte>, serverSalt!: Array<Byte>, expiresAt!: Int64) {
        this.authKey = authKey
        this.authKeyId = authKeyId
        this.serverSalt = serverSalt
        this.expiresAt = expiresAt
    }

    public func isValid(): Bool {
        return this.authKey.size > 0 && this.authKeyId.size == 8
    }

    /**
     * 临时密钥是否已过期。
     * @param nowUnixSec 当前服务器时间（Unix 秒，调用方应已加 timeOffset 校正）
     */
    public func isExpired(nowUnixSec: Int64): Bool {
        if (this.expiresAt == 0) {
            return false
        }
        return nowUnixSec >= this.expiresAt
    }
}

/**
 * 临时认证密钥管理器（Perfect Forward Secrecy）
 *
 * 职责：
 *   1. generateTempAuthKey —— 走 DH 握手生成带过期时间的临时密钥（复用 AuthKeyCreator）
 *   2. bindTempAuthKey      —— 用永久密钥加密 bind_auth_key_inner，
 *                              以临时密钥的会话发 auth.bindTempAuthKey RPC，
 *                              成功后临时密钥可用于会话加密
 *
 * 协议字段严格对照 iOS：
 *   - MTBindKeyMessageService.m （bind_auth_key_inner / auth.bindTempAuthKey 字段顺序）
 *   - MTProto._manuallyEncryptedMessage （永久密钥 MTProto v1 加密 bind_auth_key_inner）
 *   - MTMessageEncryptionKey.messageEncryptionKeyForAuthKey （v1 SHA1 密钥派生）
 *   - MTDatacenterAuthMessageService.m （p_q_inner_data_temp 的 expires_in）
 */
public class TempAuthKeyManager {
    // bind_auth_key_inner#75a3f765 nonce:long temp_auth_key_id:long perm_auth_key_id:long temp_session_id:long expires_at:int = BindAuthKeyInner
    private static let BIND_AUTH_KEY_INNER: UInt32 = 0x75a3f765
    // auth.bindTempAuthKey#cdd42a05 perm_auth_key_id:long nonce:long expires_at:int encrypted_message:bytes = Bool
    private static let AUTH_BIND_TEMP_AUTH_KEY: UInt32 = 0xcdd42a05
    // boolTrue#997275b5 = Bool
    private static let BOOL_TRUE: UInt32 = 0x997275b5

    /**
     * 生成临时认证密钥（带过期时间）。
     *
     * 走与永久密钥相同的 DH 握手，但 expires_in 设为非 0
     * （由 AuthKeyCreator.createTempAuthKey 注入 p_q_inner_data_temp.expires_in）。
     *
     * @param transport  与目标 DC 的 TCP 传输（未加密握手通道）
     * @param expiresInSec 临时密钥有效期（秒），如 86400（24h）
     * @return Some(TempAuthKey) 成功；None 失败
     */
    public static func generateTempAuthKey(transport: TCPTransport, expiresInSec: Int32): Option<TempAuthKey> {
        Hilog.info(0, "CjTelegram", "[TempAuthKey] generateTempAuthKey expires_in=${expiresInSec}s")
        let creator = AuthKeyCreator(transport)
        let result = creator.createTempAuthKey(expiresInSec)
        if (result.authKey.size == 0 || result.authKeyId.size != 8) {
            Hilog.info(0, "CjTelegram", "[TempAuthKey] generateTempAuthKey FAILED")
            return None
        }
        let key = TempAuthKey(
            authKey: result.authKey,
            authKeyId: result.authKeyId,
            serverSalt: result.serverSalt,
            expiresAt: result.expiresAt
        )
        return Some(key)
    }

    /**
     * 绑定临时密钥到永久密钥（auth.bindTempAuthKey）。
     *
     * 对照 iOS MTBindKeyMessageService.mtProtoMessageTransaction：
     *   1. 构造 bind_auth_key_inner（nonce/temp_auth_key_id/perm_auth_key_id/temp_session_id/expires_at）
     *   2. 用**永久密钥**把 bind_auth_key_inner 加密成 encrypted_message
     *      （MTProto v1 手工加密，messageId 用 bindingMessageId）
     *   3. 以**临时密钥的会话**发 auth.bindTempAuthKey(perm_auth_key_id, nonce, expires_at, encrypted_message)
     *   4. 服务器返回 boolTrue 即绑定成功
     *
     * @param tempSession  使用临时密钥的会话（authKey/authKeyId/sessionId 已置为临时密钥）
     * @param transport    临时密钥会话所在 DC 的传输
     * @param permanentKey 永久密钥（用于加密 inner message）
     * @param permanentKeyId 永久密钥的 authKeyId（8 字节，LE）
     * @param tempKey      待绑定的临时密钥
     * @return true 绑定成功
     */
    public static func bindTempAuthKey(
        tempSession: SessionInfo,
        transport: TCPTransport,
        permanentKey: Array<Byte>,
        permanentKeyId: Array<Byte>,
        tempKey: TempAuthKey
    ): Bool {
        if (!tempKey.isValid() || permanentKey.size == 0 || permanentKeyId.size != 8) {
            Hilog.info(0, "CjTelegram", "[TempAuthKey] bindTempAuthKey: invalid keys")
            return false
        }

        // 确保临时会话有 session_id
        let tempSessionId = match (tempSession.sessionId) {
            case Some(sid) where sid.size == 8 => sid
            case _ =>
                tempSession.generateSessionId()
                match (tempSession.sessionId) {
                    case Some(sid) => sid
                    case None => Array<Byte>(8, repeat: 0)
                }
        }

        // nonce / temp_auth_key_id / perm_auth_key_id 均为 int64（小端）
        let nonceBytes = ByteUtils.randomBytes(8)
        let nonce = ByteUtils.bytesToInt64(nonceBytes)
        let tempAuthKeyId = ByteUtils.bytesToInt64(tempKey.authKeyId)
        let permAuthKeyId = ByteUtils.bytesToInt64(permanentKeyId)
        let tempSessionIdInt = ByteUtils.bytesToInt64(tempSessionId)
        let expiresAt = Int32(tempKey.expiresAt)

        // binding 消息的 message_id（用临时会话的时钟）
        let bindingMessageId = tempSession.generateMessageId()
        let bindingSeqNo = tempSession.getNextSeqNo(true)

        // ---- 1. bind_auth_key_inner ----
        // bind_auth_key_inner#75a3f765 nonce:long temp_auth_key_id:long perm_auth_key_id:long temp_session_id:long expires_at:int
        let innerSer = TLSerializer()
        innerSer.writeUInt32(BIND_AUTH_KEY_INNER)
        innerSer.writeInt64(nonce)
        innerSer.writeInt64(tempAuthKeyId)
        innerSer.writeInt64(permAuthKeyId)
        innerSer.writeInt64(tempSessionIdInt)
        innerSer.writeInt32(expiresAt)
        let bindInnerData = innerSer.getBytes()

        // ---- 2. 用永久密钥手工加密（MTProto v1）----
        let encryptedMessage = manuallyEncryptWithPermanentKey(
            bindInnerData, bindingMessageId, permanentKey, permanentKeyId
        )
        if (encryptedMessage.size == 0) {
            Hilog.info(0, "CjTelegram", "[TempAuthKey] bindTempAuthKey: manual encrypt failed")
            return false
        }

        // ---- 3. auth.bindTempAuthKey ----
        // auth.bindTempAuthKey#cdd42a05 perm_auth_key_id:long nonce:long expires_at:int encrypted_message:bytes = Bool
        let bindSer = TLSerializer()
        bindSer.writeUInt32(AUTH_BIND_TEMP_AUTH_KEY)
        bindSer.writeInt64(permAuthKeyId)
        bindSer.writeInt64(nonce)
        bindSer.writeInt32(expiresAt)
        bindSer.writeBytes(encryptedMessage)
        let bindRequestData = bindSer.getBytes()

        Hilog.info(0, "CjTelegram",
            "[TempAuthKey] Binding temp ${ByteUtils.toHex(tempKey.authKeyId)} to perm ${ByteUtils.toHex(permanentKeyId)}")

        // ---- 发送 RPC（临时密钥会话加密 + 临时密钥的 message_id/seq_no）----
        let response = sendBindRpc(
            tempSession, transport, tempKey,
            bindRequestData, bindingMessageId, bindingSeqNo
        )

        // ---- 4. 解析结果（boolTrue 即成功）----
        if (response.size >= 4) {
            let signature = ByteUtils.bytesToUInt32(response)
            if (signature == BOOL_TRUE) {
                tempKey.bound = true
                Hilog.info(0, "CjTelegram", "[TempAuthKey] bindTempAuthKey SUCCESS")
                return true
            }
            Hilog.info(0, "CjTelegram",
                "[TempAuthKey] bindTempAuthKey response constructor 0x${ByteUtils.toHex(ByteUtils.uint32ToBytes(signature))}")
        }
        Hilog.info(0, "CjTelegram", "[TempAuthKey] bindTempAuthKey FAILED")
        return false
    }

    /**
     * MTProto v1 手工加密（对应 iOS MTProto._manuallyEncryptedMessage）。
     *
     * 明文布局：
     *   random1(8) || random2(8) || message_id(8) || seq_no=0(4) || length(4) || data
     * paddedDataV1：追加随机字节直到 (length % 16 == 0)。
     * msg_key = SHA1(decrypted[0 : 32 + data.size])[-16:]。
     * key/iv = v1 SHA1 派生（toClient=false → x=0）。
     * 密文 = auth_key_id(8) || msg_key(16) || AES-IGE(paddedData, key, iv)。
     */
    private static func manuallyEncryptWithPermanentKey(
        data: Array<Byte>,
        messageId: Int64,
        authKey: Array<Byte>,
        authKeyId: Array<Byte>
    ): Array<Byte> {
        // 明文头部
        let ser = TLSerializer()
        let random1 = ByteUtils.randomBytes(8)
        let random2 = ByteUtils.randomBytes(8)
        ser.writeRawBytes(random1)
        ser.writeRawBytes(random2)
        ser.writeInt64(messageId)
        ser.writeInt32(0) // seq_no = 0
        ser.writeInt32(Int32(data.size))
        ser.writeRawBytes(data)
        let plain = ser.getBytes()

        // paddedDataV1：补随机字节直到 16 对齐
        let padNeeded = (16 - (plain.size % 16)) % 16
        let decryptedData = if (padNeeded == 0) {
            plain
        } else {
            ByteUtils.concat2(plain, ByteUtils.randomBytes(padNeeded))
        }

        // msg_key = SHA1(decrypted[0 : 32 + data.size]) 取末 16 字节
        // 头部固定 32 字节（random1+random2+message_id+seq_no+length），其后是 data
        let msgKeyRange = 32 + data.size
        let msgKeyFull = SHA1.hash(ByteUtils.slice(decryptedData, 0, msgKeyRange))
        let msgKey = ByteUtils.slice(msgKeyFull, msgKeyFull.size - 16, msgKeyFull.size)

        // v1 SHA1 密钥派生（toClient=false → x=0）
        let keyIv = deriveV1KeyIv(authKey, msgKey)

        // AES-IGE 加密
        let encrypted = AESIGE.encrypt(decryptedData, keyIv.key, keyIv.iv)

        // auth_key_id(8) || msg_key(16) || encrypted
        return ByteUtils.concat3(authKeyId, msgKey, encrypted)
    }

    /**
     * MTProto v1 AES key/iv 派生
     * 对应 iOS MTMessageEncryptionKey.messageEncryptionKeyForAuthKey: toClient:false（x=0）。
     *
     *   sha1_a = SHA1(msg_key || authKey[x   : x+32])
     *   sha1_b = SHA1(authKey[x+32 : x+48] || msg_key || authKey[x+48 : x+64])
     *   sha1_c = SHA1(authKey[x+64 : x+96] || msg_key)
     *   sha1_d = SHA1(msg_key || authKey[x+96 : x+128])
     *   aes_key = sha1_a[0:8]  || sha1_b[8:20] || sha1_c[4:16]
     *   aes_iv  = sha1_a[8:20] || sha1_b[0:8]  || sha1_c[16:20] || sha1_d[0:8]
     */
    private static func deriveV1KeyIv(authKey: Array<Byte>, msgKey: Array<Byte>): AesKeyIv {
        let x = 0

        let sha1a = SHA1.hash(ByteUtils.concat2(
            msgKey,
            ByteUtils.slice(authKey, x, x + 32)
        ))
        let sha1b = SHA1.hash(ByteUtils.concat3(
            ByteUtils.slice(authKey, x + 32, x + 48),
            msgKey,
            ByteUtils.slice(authKey, x + 48, x + 64)
        ))
        let sha1c = SHA1.hash(ByteUtils.concat2(
            ByteUtils.slice(authKey, x + 64, x + 96),
            msgKey
        ))
        let sha1d = SHA1.hash(ByteUtils.concat2(
            msgKey,
            ByteUtils.slice(authKey, x + 96, x + 128)
        ))

        let aesKey = ByteUtils.concat3(
            ByteUtils.slice(sha1a, 0, 8),
            ByteUtils.slice(sha1b, 8, 20),
            ByteUtils.slice(sha1c, 4, 16)
        )

        // aes_iv = sha1_a[8:20] || sha1_b[0:8] || sha1_c[16:20] || sha1_d[0:8]
        let aesIv = ByteUtils.concat2(
            ByteUtils.concat3(
                ByteUtils.slice(sha1a, 8, 20),
                ByteUtils.slice(sha1b, 0, 8),
                ByteUtils.slice(sha1c, 16, 20)
            ),
            ByteUtils.slice(sha1d, 0, 8)
        )

        let r = AesKeyIv()
        r.key = aesKey
        r.iv = aesIv
        return r
    }

    /**
     * 用临时密钥的会话发送 auth.bindTempAuthKey RPC，阻塞等待 RPC 结果。
     *
     * 外层用临时密钥（MTProto 2.0）加密；inner encrypted_message 已用永久密钥加密。
     * binding 消息使用调用方已生成的 bindingMessageId / bindingSeqNo（与 inner 加密所用 message_id 一致）。
     */
    private static func sendBindRpc(
        session: SessionInfo,
        transport: TCPTransport,
        tempKey: TempAuthKey,
        requestData: Array<Byte>,
        messageId: Int64,
        seqNo: Int32
    ): Array<Byte> {
        // 构建明文消息：server_salt(8) || session_id(8) || msg_id(8) || seq_no(4) || length(4) || data
        let ser = TLSerializer()
        let salt = match (session.serverSalt) {
            case Some(s) where s.size == 8 => s
            case _ => tempKey.serverSalt
        }
        if (salt.size == 8) {
            ser.writeRawBytes(salt)
        } else {
            ser.writeInt64(0)
        }
        match (session.sessionId) {
            case Some(sid) where sid.size == 8 => ser.writeRawBytes(sid)
            case _ => ser.writeInt64(0)
        }
        ser.writeInt64(messageId)
        ser.writeInt32(seqNo)
        ser.writeInt32(Int32(requestData.size))
        ser.writeRawBytes(requestData)
        let message = ser.getBytes()

        // 临时密钥 MTProto 2.0 加密外层
        let encrypted = MTProtoCrypto.encryptMessage(tempKey.authKey, tempKey.authKeyId, message, true)
        let packet = encrypted.toBytes()

        let collector = BindResponseCollector(messageId)
        transport.setCallback(collector)

        if (!transport.isConnected()) {
            transport.connect()
        }
        transport.send(packet)

        // 阻塞等待响应（最多 30 秒）
        var waited: Int64 = 0
        let maxWait: Int64 = 30000
        while (waited < maxWait) {
            if (collector.hasResult()) {
                break
            }
            unsafe {
                let _ = LibC.usleep(10000)
            }
            waited += 10
        }

        return collector.takeResult(tempKey.authKey)
    }
}

/**
 * 临时回调：收集 auth.bindTempAuthKey 的响应。
 *
 * 收到加密响应后用临时密钥解密，剥离 MTProto 头，定位到 rpc_result 中
 * requestMessageId == 我们的 bindingMessageId 的结果体。
 */
class BindResponseCollector <: TransportCallback {
    private let expectedMsgId: Int64
    private var rawResponse: Option<Array<Byte>> = None
    private let mutex = ReentrantMutex()

    init(expectedMsgId: Int64) {
        this.expectedMsgId = expectedMsgId
    }

    public func hasResult(): Bool {
        mutex.lock()
        let r = !this.rawResponse.isNone()
        mutex.unlock()
        return r
    }

    public func onConnected(): Unit {}
    public func onDisconnected(): Unit {
        Hilog.info(0, "CjTelegram", "[TempAuthKey] bind transport disconnected")
    }
    public func onError(error: String): Unit {
        Hilog.info(0, "CjTelegram", "[TempAuthKey] bind transport error: ${error}")
    }

    public func onData(data: Array<Byte>): Unit {
        mutex.lock()
        if (this.rawResponse.isNone() && data.size >= 24) {
            this.rawResponse = Some(data)
        }
        mutex.unlock()
    }

    /**
     * 用临时密钥解密响应并抽取 rpc_result 中对应 bindingMessageId 的结果体。
     * 失败返回空数组。
     */
    public func takeResult(authKey: Array<Byte>): Array<Byte> {
        mutex.lock()
        let raw = this.rawResponse
        mutex.unlock()

        let data = match (raw) {
            case Some(d) => d
            case None => return Array<Byte>(0, repeat: 0)
        }
        if (data.size < 24) {
            return Array<Byte>(0, repeat: 0)
        }

        // 未加密 / 错误码（auth_key_id == 0 的短包）
        let authKeyId = ByteUtils.slice(data, 0, 8)
        if (ByteUtils.isZero(authKeyId)) {
            return Array<Byte>(0, repeat: 0)
        }

        // msg_key(16) @ [8:24]，密文 @ [24:]
        let msgKey = ByteUtils.slice(data, 8, 24)
        let encryptedData = ByteUtils.slice(data, 24, data.size)
        let decrypted = MTProtoCrypto.decryptMessage(authKey, msgKey, encryptedData, false)

        // 跳过 server_salt(8) + session_id(8) = 16
        if (decrypted.size < 32) {
            return Array<Byte>(0, repeat: 0)
        }
        let d = TLDeserializer(ByteUtils.slice(decrypted, 16, decrypted.size))
        let _msgId = d.readInt64()
        let _seqNo = d.readInt32()
        let length = d.readInt32()
        if (length <= 0 || Int64(length) > d.remaining()) {
            return Array<Byte>(0, repeat: 0)
        }
        let body = d.readRawBytes(Int64(length))
        return extractRpcResult(body)
    }

    /**
     * 从消息体中找到 requestMessageId == expectedMsgId 的 rpc_result，返回其结果体。
     * 处理 msg_container 包裹的情况。
     */
    private func extractRpcResult(body: Array<Byte>): Array<Byte> {
        if (body.size < 4) {
            return Array<Byte>(0, repeat: 0)
        }
        let d = TLDeserializer(body)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_RESULT) {
            let reqMsgId = d.readInt64()
            if (reqMsgId == this.expectedMsgId) {
                let remaining = d.remaining()
                return d.readRawBytes(remaining)
            }
            return Array<Byte>(0, repeat: 0)
        } else if (constructor == TLConstructors.MSG_CONTAINER) {
            let count = d.readInt32()
            for (_i in 0..Int64(count)) {
                let _innerMsgId = d.readInt64()
                let _innerSeqNo = d.readInt32()
                let innerLen = d.readInt32()
                if (innerLen <= 0 || Int64(innerLen) > d.remaining()) {
                    break
                }
                let innerBody = d.readRawBytes(Int64(innerLen))
                let r = extractRpcResult(innerBody)
                if (r.size > 0) {
                    return r
                }
            }
        }
        return Array<Byte>(0, repeat: 0)
    }
}
