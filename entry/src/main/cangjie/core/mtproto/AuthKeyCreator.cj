package ohos_app_cangjie_entry.core.mtproto

import std.collection.ArrayList
import std.sync.ReentrantMutex
import kit.PerformanceAnalysisKit.Hilog
/**
 * TL 构造器 ID（密钥交换用）
 */
public class AuthKeyConstructors {
    public static let REQ_PQ_MULTI: UInt32 = 0xbe7e8ef1
    public static let REQ_DH_PARAMS: UInt32 = 0xd712e4be
    public static let SET_CLIENT_DH_PARAMS: UInt32 = 0xf5045f1f
    public static let RES_PQ: UInt32 = 0x05162463
    public static let SERVER_DH_PARAMS_OK: UInt32 = 0xd0e8075c
    public static let SERVER_DH_PARAMS_FAIL: UInt32 = 0x79cb045d
    public static let DH_GEN_OK: UInt32 = 0x3bcbf734
    public static let DH_GEN_RETRY: UInt32 = 0x46dc1fb9
    public static let DH_GEN_FAIL: UInt32 = 0xa69dae02
    public static let P_Q_INNER_DATA: UInt32 = 0x83c95aec
    // p_q_inner_data_temp#3c6a84d4 pq:string p:string q:string nonce:int128 server_nonce:int128 new_nonce:int256 expires_in:int = P_Q_inner_data
    // 与 P_Q_INNER_DATA 字段相同，仅在末尾追加 expires_in（临时密钥 / PFS 用）
    public static let P_Q_INNER_DATA_TEMP: UInt32 = 0x3c6a84d4
    public static let CLIENT_DH_INNER_DATA: UInt32 = 0x6643b654
}

/**
 * ResPQ 响应
 */
public class ResPQ {
    public var nonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var serverNonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var pq: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var serverPublicKeyFingerprints: ArrayList<Int64> = ArrayList<Int64>()

    public static func deserialize(data: Array<Byte>): ResPQ {
        let r = ResPQ()
        let d = TLDeserializer(data)
        let _ = d.readUInt32() // constructor
        r.nonce = d.readRawBytes(16)
        r.serverNonce = d.readRawBytes(16)
        r.pq = d.readBytes()
        let _ = d.readUInt32() // vector id
        let count = d.readInt32()
        for (_i in 0..Int64(count)) {
            r.serverPublicKeyFingerprints.add(d.readInt64())
        }
        return r
    }
}

/**
 * Server DH Params
 */
public class ServerDHParams {
    public var nonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var serverNonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var encryptedAnswer: Array<Byte> = Array<Byte>(0, repeat: 0)

    public static func deserialize(data: Array<Byte>): ServerDHParams {
        let r = ServerDHParams()
        let d = TLDeserializer(data)
        let _ = d.readUInt32()
        r.nonce = d.readRawBytes(16)
        r.serverNonce = d.readRawBytes(16)
        r.encryptedAnswer = d.readBytes()
        return r
    }
}

/**
 * Server DH Inner Data
 */
public class ServerDHInnerData {
    public var nonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var serverNonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var g: Int32 = 0
    public var dhPrime: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var gA: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var serverTime: Int32 = 0

    public static func deserialize(data: Array<Byte>): ServerDHInnerData {
        let r = ServerDHInnerData()
        let d = TLDeserializer(data)
        let _ = d.readUInt32()
        r.nonce = d.readRawBytes(16)
        r.serverNonce = d.readRawBytes(16)
        r.g = d.readInt32()
        r.dhPrime = d.readBytes()
        r.gA = d.readBytes()
        r.serverTime = d.readInt32()
        return r
    }
}

/**
 * DH Gen 结果
 */
public class DHGenResult {
    public var nonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var serverNonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var newNonceHash: Array<Byte> = Array<Byte>(16, repeat: 0)
    public var success: Bool = false

    public static func deserialize(data: Array<Byte>): DHGenResult {
        let r = DHGenResult()
        let d = TLDeserializer(data)
        let constructor = d.readUInt32()
        r.success = (constructor == AuthKeyConstructors.DH_GEN_OK)
        r.nonce = d.readRawBytes(16)
        r.serverNonce = d.readRawBytes(16)
        r.newNonceHash = d.readRawBytes(16)
        return r
    }
}

/**
 * 认证密钥创建结果
 */
public class AuthKeyResult {
    public var authKey: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var authKeyId: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var serverSalt: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var timeOffset: Int64 = 0
    // 临时密钥（PFS）过期时间点（Unix 秒）。永久密钥为 0（永不过期）。
    public var expiresAt: Int64 = 0
}

/**
 * 客户端 DH 数据
 */
public class ClientDHData {
    public var b: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var gB: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var gA: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var dhPrime: Array<Byte> = Array<Byte>(0, repeat: 0)
}

/**
 * 认证密钥创建器
 * 
 * 对应 TelegramHarmony 的 AuthKeyCreator.ets
 * 实现完整的 Diffie-Hellman 密钥交换
 * 
 * 流程:
 * 1. req_pq_multi → 获取 PQ 和服务器指纹
 * 2. 分解 PQ → P, Q
 * 3. req_DH_params → RSA 加密 inner data
 * 4. 解密 DH 参数 → 获取 g, dh_prime, g_a
 * 5. 生成客户端 DH → 随机 b, 计算 g_b
 * 6. set_client_DH_params → 发送 g_b
 * 7. 计算 auth_key → g_a^b mod dh_prime
 */
public class AuthKeyCreator {
    private let transport: TCPTransport
    private var nonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    private var serverNonce: Array<Byte> = Array<Byte>(16, repeat: 0)
    private var newNonce: Array<Byte> = Array<Byte>(32, repeat: 0)
    private var tmpAesKey: Array<Byte> = Array<Byte>(32, repeat: 0)
    private var tmpAesIv: Array<Byte> = Array<Byte>(32, repeat: 0)

    // expires_in（秒）：0 = 永久密钥（默认，保持既有永久握手行为不变）；
    // 非 0 = 临时密钥（Perfect Forward Secrecy），走 p_q_inner_data_temp 分支。
    private var expiresIn: Int32 = 0

    // 用于同步收发的响应缓冲
    private var responseData: Option<Array<Byte>> = None
    private let responseMutex = ReentrantMutex()

    public init(transport: TCPTransport) {
        this.transport = transport
    }

    /**
     * 创建认证密钥（阻塞操作，应在 spawn 中调用）
     */
    public func createAuthKey(): AuthKeyResult {
        Hilog.info(0, "CjTelegram", "[AuthKey] Starting auth key creation...")

        // Step 1: req_pq_multi
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 1: Sending req_pq_multi...")
        let resPQ = reqPQMulti()
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 1 COMPLETED")

        // Step 2: 分解 PQ
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 2: Factorizing PQ...")
        let factors = BigIntMath.factorizePQ(resPQ.pq)
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 2 COMPLETED - P: ${ByteUtils.toHex(factors.p)}, Q: ${ByteUtils.toHex(factors.q)}")

        // Step 3: req_DH_params
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 3: Sending req_DH_params...")
        let dhParams = reqDHParams(resPQ, factors)
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 3 COMPLETED")

        // Step 4: 解密 DH 参数
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 4: Decrypting DH params...")
        let dhInner = decryptDHParams(dhParams)
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 4 COMPLETED")

        // Step 5: 生成客户端 DH 参数
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 5: Generating client DH params...")
        let clientDH = generateClientDH(dhInner)
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 5 COMPLETED")

        // Step 6: set_client_DH_params
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 6: Sending set_client_DH_params...")
        let dhGenResult = setClientDHParams(dhInner, clientDH)
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 6 COMPLETED - success: ${dhGenResult.success}")

        if (!dhGenResult.success) {
            Hilog.info(0, "CjTelegram", "[AuthKey] DH key exchange failed!")
            return AuthKeyResult()
        }

        // Step 7: 计算最终密钥
        Hilog.info(0, "CjTelegram", "[AuthKey] Step 7: Computing auth key...")
        let result = computeAuthKey(dhInner, clientDH)
        Hilog.info(0, "CjTelegram", "[AuthKey] Auth key created successfully!")
        Hilog.info(0, "CjTelegram", "[AuthKey] Auth key ID: ${ByteUtils.toHex(result.authKeyId)}")

        return result
    }

    /**
     * 创建临时认证密钥（Perfect Forward Secrecy）
     *
     * 与 createAuthKey() 走完全相同的 DH 握手流程，唯一区别：
     *   req_DH_params 阶段的 inner data 使用 p_q_inner_data_temp（构造器 0x3c6a84d4），
     *   并在末尾追加 expires_in（非 0，单位秒）。
     * 服务器据此返回一个带过期时间的临时 auth_key（DH 与永久密钥完全一致）。
     *
     * 不影响永久密钥路径：仅当 expiresInSec != 0 时本方法才被使用，
     * createAuthKey() 仍走 expiresIn = 0 的原始分支。
     *
     * @param expiresInSec 临时密钥有效期（秒），例如 24h = 86400
     * @return AuthKeyResult，含 authKey / authKeyId / serverSalt / timeOffset / expiresAt
     */
    public func createTempAuthKey(expiresInSec: Int32): AuthKeyResult {
        if (expiresInSec == 0) {
            Hilog.info(0, "CjTelegram", "[TempAuthKey] expiresInSec must be non-zero for temp key")
            return AuthKeyResult()
        }
        this.expiresIn = expiresInSec
        Hilog.info(0, "CjTelegram", "[TempAuthKey] Creating temp auth key, expires_in=${expiresInSec}s")
        let result = createAuthKey()
        if (result.authKey.size == 0) {
            return result
        }
        // expires_at = serverTime + expires_in。serverTime ≈ localNow + timeOffset。
        let now = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        result.expiresAt = now + result.timeOffset + Int64(expiresInSec)
        Hilog.info(0, "CjTelegram", "[TempAuthKey] Temp auth key created, expiresAt=${result.expiresAt}")
        return result
    }

    /**
     * Step 1: 发送 req_pq_multi
     */
    private func reqPQMulti(): ResPQ {
        this.nonce = ByteUtils.randomBytes(16)

        let serializer = TLSerializer()
        serializer.writeUInt32(AuthKeyConstructors.REQ_PQ_MULTI)
        serializer.writeRawBytes(this.nonce)

        let response = sendUnencrypted(serializer.getBytes())
        let resPQ = ResPQ.deserialize(response)

        this.serverNonce = resPQ.serverNonce

        if (!ByteUtils.equals(resPQ.nonce, this.nonce)) {
            Hilog.info(0, "CjTelegram", "[AuthKey] WARNING: Nonce mismatch in resPQ!")
        }

        Hilog.info(0, "CjTelegram", "[AuthKey] Received PQ: ${ByteUtils.toHex(resPQ.pq)}")
        Hilog.info(0, "CjTelegram", "[AuthKey] Server fingerprints count: ${resPQ.serverPublicKeyFingerprints.size}")

        return resPQ
    }

    /**
     * Step 3: 发送 req_DH_params
     */
    private func reqDHParams(resPQ: ResPQ, factors: FactorResult): ServerDHParams {
        // 选择匹配的 RSA 密钥
        let selectedKey = match (RSAPublicKey.selectKey(resPQ.serverPublicKeyFingerprints)) {
            case Some(key) => key
            case None => RSAPublicKey.RSA_KEYS[0]
        }

        // 生成 new_nonce
        this.newNonce = ByteUtils.randomBytes(32)

        // 构建 p_q_inner_data（永久密钥）或 p_q_inner_data_temp（临时密钥 / PFS）
        // 临时变体字段与永久完全相同，仅构造器不同且末尾追加 expires_in。
        let innerSerializer = TLSerializer()
        let isTemp = this.expiresIn != 0
        if (isTemp) {
            innerSerializer.writeUInt32(AuthKeyConstructors.P_Q_INNER_DATA_TEMP)
        } else {
            innerSerializer.writeUInt32(AuthKeyConstructors.P_Q_INNER_DATA)
        }
        innerSerializer.writeBytes(resPQ.pq)
        innerSerializer.writeBytes(factors.p)
        innerSerializer.writeBytes(factors.q)
        innerSerializer.writeRawBytes(this.nonce)
        innerSerializer.writeRawBytes(this.serverNonce)
        innerSerializer.writeRawBytes(this.newNonce)
        if (isTemp) {
            innerSerializer.writeInt32(this.expiresIn)
        }

        let innerData = innerSerializer.getBytes()
        Hilog.info(0, "CjTelegram", "[AuthKey] Inner data size: ${innerData.size}")

        // RSA 加密（现代填充方案）
        let encryptedData = RSAPublicKey.encryptWithKey(innerData, selectedKey)
        Hilog.info(0, "CjTelegram", "[AuthKey] Encrypted data size: ${encryptedData.size}")

        // 构建请求
        let serializer = TLSerializer()
        serializer.writeUInt32(AuthKeyConstructors.REQ_DH_PARAMS)
        serializer.writeRawBytes(this.nonce)
        serializer.writeRawBytes(this.serverNonce)
        serializer.writeBytes(factors.p)
        serializer.writeBytes(factors.q)
        serializer.writeInt64(selectedKey.fingerprint)
        serializer.writeBytes(encryptedData)

        let response = sendUnencrypted(serializer.getBytes())

        // 检查响应类型
        let constructor = ByteUtils.bytesToUInt32(response)
        Hilog.info(0, "CjTelegram", "[AuthKey] req_DH_params response: 0x${ByteUtils.toHex(ByteUtils.uint32ToBytes(constructor))}")

        if (constructor == AuthKeyConstructors.SERVER_DH_PARAMS_FAIL) {
            Hilog.info(0, "CjTelegram", "[AuthKey] Server DH params FAILED!")
        }

        return ServerDHParams.deserialize(response)
    }

    /**
     * Step 4: 解密 DH 参数
     */
    private func decryptDHParams(dhParams: ServerDHParams): ServerDHInnerData {
        computeTmpAesKeyIv()

        // AES-IGE 解密
        let decryptedAnswer = AESIGE.decrypt(
            dhParams.encryptedAnswer,
            this.tmpAesKey,
            this.tmpAesIv
        )

        // 跳过 SHA1 哈希（前 20 字节）
        let answerData = ByteUtils.slice(decryptedAnswer, 20, decryptedAnswer.size)

        let innerData = ServerDHInnerData.deserialize(answerData)

        if (!ByteUtils.equals(innerData.nonce, this.nonce)) {
            Hilog.info(0, "CjTelegram", "[AuthKey] WARNING: Nonce mismatch in DH params!")
        }

        Hilog.info(0, "CjTelegram", "[AuthKey] DH params: g=${innerData.g}, server_time=${innerData.serverTime}")
        return innerData
    }

    /**
     * 计算临时 AES 密钥和 IV
     */
    private func computeTmpAesKeyIv() {
        // tmp_aes_key = SHA1(new_nonce + server_nonce) + substr(SHA1(server_nonce + new_nonce), 0, 12)
        let hash1 = SHA1.hash(ByteUtils.concat2(this.newNonce, this.serverNonce))
        let hash2 = SHA1.hash(ByteUtils.concat2(this.serverNonce, this.newNonce))

        this.tmpAesKey = ByteUtils.concat2(hash1, ByteUtils.slice(hash2, 0, 12))

        // tmp_aes_iv = substr(SHA1(server_nonce + new_nonce), 12, 8) + SHA1(new_nonce + new_nonce) + substr(new_nonce, 0, 4)
        let hash3 = SHA1.hash(ByteUtils.concat2(this.newNonce, this.newNonce))

        this.tmpAesIv = ByteUtils.concat3(
            ByteUtils.slice(hash2, 12, 20),
            hash3,
            ByteUtils.slice(this.newNonce, 0, 4)
        )
    }

    /**
     * Step 5: 生成客户端 DH 参数
     */
    private func generateClientDH(dhInner: ServerDHInnerData): ClientDHData {
        let result = ClientDHData()

        // 随机 b (256 字节)
        result.b = ByteUtils.randomBytes(256)

        // g_b = g^b mod dh_prime
        let gBytes = Array<Byte>(256, repeat: 0)
        gBytes[255] = UInt8(dhInner.g & 0xFF)
        result.gB = BigIntMath.modPow(gBytes, result.b, dhInner.dhPrime)

        result.gA = dhInner.gA
        result.dhPrime = dhInner.dhPrime

        return result
    }

    /**
     * Step 6: 发送 set_client_DH_params
     */
    private func setClientDHParams(dhInner: ServerDHInnerData, clientDH: ClientDHData): DHGenResult {
        let innerSerializer = TLSerializer()
        innerSerializer.writeUInt32(AuthKeyConstructors.CLIENT_DH_INNER_DATA)
        innerSerializer.writeRawBytes(this.nonce)
        innerSerializer.writeRawBytes(this.serverNonce)
        innerSerializer.writeInt64(0) // retry_id
        innerSerializer.writeBytes(clientDH.gB)

        let innerData = innerSerializer.getBytes()

        // SHA1 + data + padding
        let dataHash = SHA1.hash(innerData)
        let paddingLen = (16 - ((dataHash.size + innerData.size) % 16)) % 16
        let padding = ByteUtils.randomBytes(paddingLen)

        let dataWithHash = ByteUtils.concat3(dataHash, innerData, padding)

        // AES-IGE 加密
        let encryptedData = AESIGE.encrypt(dataWithHash, this.tmpAesKey, this.tmpAesIv)

        // 构建请求
        let serializer = TLSerializer()
        serializer.writeUInt32(AuthKeyConstructors.SET_CLIENT_DH_PARAMS)
        serializer.writeRawBytes(this.nonce)
        serializer.writeRawBytes(this.serverNonce)
        serializer.writeBytes(encryptedData)

        let response = sendUnencrypted(serializer.getBytes())
        return DHGenResult.deserialize(response)
    }

    /**
     * Step 7: 计算最终认证密钥
     */
    private func computeAuthKey(dhInner: ServerDHInnerData, clientDH: ClientDHData): AuthKeyResult {
        let result = AuthKeyResult()

        // auth_key = g_a^b mod dh_prime
        var authKey = BigIntMath.modPow(clientDH.gA, clientDH.b, clientDH.dhPrime)

        // 确保 256 字节
        if (authKey.size < 256) {
            let padded = Array<Byte>(256, repeat: 0)
            let offset = 256 - authKey.size
            for (i in 0..authKey.size) {
                padded[offset + i] = authKey[i]
            }
            authKey = padded
        } else if (authKey.size > 256) {
            authKey = ByteUtils.slice(authKey, authKey.size - 256, authKey.size)
        }
        result.authKey = authKey

        // auth_key_id = SHA1(auth_key)[12:20]
        let authKeySha1 = SHA1.hash(result.authKey)
        result.authKeyId = ByteUtils.slice(authKeySha1, 12, 20)

        // server_salt = new_nonce[0:8] XOR server_nonce[0:8]
        result.serverSalt = ByteUtils.xor(
            ByteUtils.slice(this.newNonce, 0, 8),
            ByteUtils.slice(this.serverNonce, 0, 8)
        )

        // 时间偏移
        let now = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        result.timeOffset = Int64(dhInner.serverTime) - now

        return result
    }

    /**
     * 发送未加密消息并等待响应（阻塞）
     * 
     * 在 AuthKey 创建期间使用未加密通信
     */
    private func sendUnencrypted(data: Array<Byte>): Array<Byte> {
        let serializer = TLSerializer()

        // auth_key_id = 0 (8 bytes)
        serializer.writeInt64(0)

        // message_id (8 bytes)
        let now = DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
        let msgId = now << 32
        serializer.writeInt64(msgId)

        // message_data_length
        serializer.writeInt32(Int32(data.size))

        // message_data
        serializer.writeRawBytes(data)

        let packet = serializer.getBytes()

        // 设置临时回调接收响应
        this.responseData = None
        let self_ = this

        let tempCallback = TempAuthCallback(self_)
        this.transport.setCallback(tempCallback)

        // 发送
        this.transport.send(packet)

        // 阻塞等待响应（最多30秒）
        var waited: Int64 = 0
        let maxWait: Int64 = 30000
        while (waited < maxWait) {
            responseMutex.lock()
            let hasResponse = !self_.responseData.isNone()
            responseMutex.unlock()

            if (hasResponse) {
                break
            }

            // sleep 10ms
            unsafe {
                let _ = LibC.usleep(10000)
            }
            waited += 10
        }

        match (self_.responseData) {
            case Some(resp) => return resp
            case None =>
                Hilog.info(0, "CjTelegram", "[AuthKey] Timeout waiting for response!")
                return Array<Byte>(0, repeat: 0)
        }
    }

    /**
     * 由临时回调调用，传递响应数据
     */
    public func onResponseReceived(data: Array<Byte>) {
        // 跳过 auth_key_id (8) + message_id (8) + message_length (4) = 20 字节
        if (data.size < 20) {
            Hilog.info(0, "CjTelegram", "[AuthKey] Response too short: ${data.size} bytes")
            responseMutex.lock()
            this.responseData = Some(Array<Byte>(0, repeat: 0))
            responseMutex.unlock()
            return
        }

        // 检查 4 字节错误码
        if (data.size == 4) {
            let errorCode = ByteUtils.bytesToInt32(data)
            Hilog.info(0, "CjTelegram", "[AuthKey] Server error code: ${errorCode}")
            responseMutex.lock()
            this.responseData = Some(Array<Byte>(0, repeat: 0))
            responseMutex.unlock()
            return
        }

        let messageData = ByteUtils.slice(data, 20, data.size)
        responseMutex.lock()
        this.responseData = Some(messageData)
        responseMutex.unlock()
    }
}

/**
 * 临时传输回调（密钥交换期间使用）
 */
class TempAuthCallback <: TransportCallback {
    private let creator: AuthKeyCreator

    init(creator: AuthKeyCreator) {
        this.creator = creator
    }

    public func onConnected() {}
    public func onDisconnected() {
        Hilog.info(0, "CjTelegram", "[AuthKey] Disconnected during auth key creation!")
    }
    public func onData(data: Array<Byte>) {
        creator.onResponseReceived(data)
    }
    public func onError(error: String) {
        Hilog.info(0, "CjTelegram", "[AuthKey] Transport error during auth: ${error}")
    }
}

// LibC 接口（用于 usleep）
@C
foreign func usleep(usec: UInt32): Int32

class LibC {
    public static func usleep(usec: UInt32): Int32 {
        return unsafe{foreign_usleep(usec)}
    }
}

@C
func foreign_usleep(usec: UInt32): Int32 {
    return unsafe{usleep(usec)}
}
