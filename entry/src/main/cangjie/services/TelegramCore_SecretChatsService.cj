package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.{HashMap, ArrayList}
import std.sync.ReentrantMutex
import ohos_app_cangjie_entry.core.mtproto.{
    getMTProtoClient,
    BigIntMath,
    ByteUtils,
    SHA1,
    SHA256,
    AESIGE,
    TLSerializer,
    TLDeserializer,
    TLObject,
    MessagesGetDhConfig,
    DhConfigResponse
}

// ==================== Secret Chat State ====================

/**
 * 秘密聊天状态枚举
 */
public class SecretChatStatus {
    public static let PENDING: String = "pending"
    public static let REQUESTED: String = "requested"
    public static let READY: String = "ready"
    public static let DISCARDED: String = "discarded"
}

/**
 * 秘密聊天会话信息
 * 对应 Telegram-iOS SecretChatState / SecretChatSession
 */
public class SecretChatSession {
    public var chatId: Int32 = 0
    public var accessHash: Int64 = 0
    public var peerId: Int64 = 0         // 对方 userId
    public var peerAccessHash: Int64 = 0

    // DH 协商数据
    public var dhG: Int32 = 0
    public var dhP: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var mySecret: Array<Byte> = Array<Byte>(0, repeat: 0)  // a 或 b
    public var peerGKey: Array<Byte> = Array<Byte>(0, repeat: 0)  // gA 或 gB (对方发来的)

    // 派生后的会话密钥 (256 字节)
    public var sessionKey: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var keyFingerprint: Int64 = 0

    // 消息序号
    public var outSeqNo: Int32 = 0
    public var inSeqNo: Int32 = 0

    public var status: String = SecretChatStatus.PENDING
}

// ==================== TL Methods: Secret Chats ====================

/**
 * messages.requestEncryption#f64daf43
 * user_id:InputUser random_id:int g_a:bytes = EncryptedChat
 */
public class MessagesRequestEncryption <: TLObject {
    public var userId: Int64 = 0
    public var userAccessHash: Int64 = 0
    public var randomId: Int32 = 0
    public var gA: Array<Byte> = Array<Byte>(0, repeat: 0)

    public func getConstructorId(): UInt32 { return 0xf64daf43 }

    public func serialize(serializer: TLSerializer) {
        // InputUser#f21158c6 user_id:long access_hash:long
        serializer.writeUInt32(0xf21158c6)
        serializer.writeInt64(this.userId)
        serializer.writeInt64(this.userAccessHash)
        serializer.writeInt32(this.randomId)
        serializer.writeBytes(this.gA)
    }
}

/**
 * messages.acceptEncryption#3dbc0415
 * peer:InputEncryptedChat g_b:bytes key_fingerprint:long = EncryptedChat
 */
public class MessagesAcceptEncryption <: TLObject {
    public var chatId: Int32 = 0
    public var accessHash: Int64 = 0
    public var gB: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var keyFingerprint: Int64 = 0

    public func getConstructorId(): UInt32 { return 0x3dbc0415 }

    public func serialize(serializer: TLSerializer) {
        // InputEncryptedChat#f141b5e1 chat_id:int access_hash:long
        serializer.writeUInt32(0xf141b5e1)
        serializer.writeInt32(this.chatId)
        serializer.writeInt64(this.accessHash)
        serializer.writeBytes(this.gB)
        serializer.writeInt64(this.keyFingerprint)
    }
}

/**
 * messages.discardEncryption#f393aea0
 * flags:# delete_history:flags.0?true chat_id:int = Bool
 */
public class MessagesDiscardEncryption <: TLObject {
    public var chatId: Int32 = 0
    public var deleteHistory: Bool = false

    public func getConstructorId(): UInt32 { return 0xf393aea0 }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = if (this.deleteHistory) { 1 } else { 0 }
        serializer.writeInt32(flags)
        serializer.writeInt32(this.chatId)
    }
}

/**
 * messages.sendEncrypted#44fa7a15
 * flags:# silent:flags.0?true peer:InputEncryptedChat random_id:long data:bytes = messages.SentEncryptedMessage
 */
public class MessagesSendEncrypted <: TLObject {
    public var chatId: Int32 = 0
    public var accessHash: Int64 = 0
    public var randomId: Int64 = 0
    public var data: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var silent: Bool = false

    public func getConstructorId(): UInt32 { return 0x44fa7a15 }

    public func serialize(serializer: TLSerializer) {
        let flags: Int32 = if (this.silent) { 1 } else { 0 }
        serializer.writeInt32(flags)
        // InputEncryptedChat#f141b5e1
        serializer.writeUInt32(0xf141b5e1)
        serializer.writeInt32(this.chatId)
        serializer.writeInt64(this.accessHash)
        serializer.writeInt64(this.randomId)
        serializer.writeBytes(this.data)
    }
}

// ==================== EncryptedChat Response ====================

/**
 * 秘密聊天响应（简化版）
 * encryptedChatRequested / encryptedChat / encryptedChatDiscarded / encryptedChatWaiting
 */
public class EncryptedChatResponse {
    public var isSuccess: Bool = false
    public var chatId: Int32 = 0
    public var accessHash: Int64 = 0
    public var gAOrB: Array<Byte> = Array<Byte>(0, repeat: 0)
    public var keyFingerprint: Int64 = 0
    public var status: String = ""

    public static func deserialize(data: Array<Byte>): EncryptedChatResponse {
        let r = EncryptedChatResponse()
        if (data.size < 4) { return r }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()

        // S8-08：构造器 id 按当前 layer 的 telegram_api.tl:497-501 换算（旧值 62718a82 / fa56ce36 /
        // 3bf703dc / 13d6dd27 是历史 layer，服务端返回的 encryptedChatWaiting#66b25953 从未被识别，
        // requestEncryption 恒判失败）。
        // encryptedChatRequested#48f1d94c flags:# folder_id:flags.0?int id:int access_hash:long date:int admin_id:long participant_id:long g_a:bytes
        if (ctor == 0x48f1d94c) {
            r.isSuccess = true
            r.status = "requested"
            let flags = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readInt32() }  // folder_id
            if (d.remaining() >= 4) { r.chatId = d.readInt32() }
            if (d.remaining() >= 8) { r.accessHash = d.readInt64() }
            if (d.remaining() >= 4) { let _ = d.readInt32() }  // date
            if (d.remaining() >= 8) { let _ = d.readInt64() }  // admin_id
            if (d.remaining() >= 8) { let _ = d.readInt64() }  // participant_id
            if (d.remaining() >= 4) { r.gAOrB = d.readBytes() }
            return r
        }

        // encryptedChat#61f0d4c7 id:int access_hash:long date:int admin_id:long participant_id:long g_a_or_b:bytes key_fingerprint:long
        if (ctor == 0x61f0d4c7) {
            r.isSuccess = true
            r.status = "ready"
            if (d.remaining() >= 4) { r.chatId = d.readInt32() }
            if (d.remaining() >= 8) { r.accessHash = d.readInt64() }
            if (d.remaining() >= 4) { let _ = d.readInt32() }  // date
            if (d.remaining() >= 8) { let _ = d.readInt64() }  // admin_id
            if (d.remaining() >= 8) { let _ = d.readInt64() }  // participant_id
            if (d.remaining() >= 4) { r.gAOrB = d.readBytes() }
            if (d.remaining() >= 8) { r.keyFingerprint = d.readInt64() }
            return r
        }

        // encryptedChatDiscarded#1e1c7c45 flags:# history_deleted:flags.0?true id:int
        if (ctor == 0x1e1c7c45) {
            r.isSuccess = false
            r.status = "discarded"
            if (d.remaining() >= 4) { let _ = d.readInt32() }  // flags
            if (d.remaining() >= 4) { r.chatId = d.readInt32() }
            return r
        }

        // encryptedChatWaiting#66b25953 id:int access_hash:long date:int admin_id:long participant_id:long
        // （messages.requestEncryption 的正常返回：等待对方上线接受）
        if (ctor == 0x66b25953) {
            r.isSuccess = true
            r.status = "waiting"
            if (d.remaining() >= 4) { r.chatId = d.readInt32() }
            if (d.remaining() >= 8) { r.accessHash = d.readInt64() }
            return r
        }

        return r
    }
}

// ==================== Secret Key Derivation ====================

/**
 * MTProto 端到端加密密钥派生
 *
 * Telegram 秘密聊天使用从 DH 密钥派生的 key 和 iv：
 * msgKey = SHA256(key[88:120] || plaintext)[8:24]   (相似于 MTProto 2.0 但 x=0)
 * aesKey + aesIv 使用与 MTProtoCrypto.calcAesKeyIv 相同的推导方式
 */
public class SecretChatCrypto {
    /**
     * 从 DH 共享密钥派生消息密钥 (msgKey)
     * key: 256 字节 DH 共享密钥
     * data: 待加密/解密的明文或密文
     * isOutgoing: 发送方用 x=0，接收方用 x=8
     */
    public static func calcMsgKey(key: Array<Byte>, data: Array<Byte>, isOutgoing: Bool): Array<Byte> {
        let x: Int64 = if (isOutgoing) { 0 } else { 8 }
        let keyPart = ByteUtils.slice(key, 88 + x, 88 + x + 32)
        let combined = ByteUtils.concat2(keyPart, data)
        let hash = SHA256.hash(combined)
        return ByteUtils.slice(hash, 8, 24)
    }

    /**
     * 计算 AES 密钥和 IV (MTProto 2.0 兼容)
     */
    public static func calcAesKeyIv(key: Array<Byte>, msgKey: Array<Byte>, isOutgoing: Bool): (Array<Byte>, Array<Byte>) {
        let x: Int64 = if (isOutgoing) { 0 } else { 8 }
        let sha256a = SHA256.hash(ByteUtils.concat2(msgKey, ByteUtils.slice(key, x, x + 36)))
        let sha256b = SHA256.hash(ByteUtils.concat2(ByteUtils.slice(key, 40 + x, 40 + x + 36), msgKey))
        let aesKey = ByteUtils.concat3(
            ByteUtils.slice(sha256a, 0, 8),
            ByteUtils.slice(sha256b, 8, 24),
            ByteUtils.slice(sha256a, 24, 32)
        )
        let aesIv = ByteUtils.concat3(
            ByteUtils.slice(sha256b, 0, 8),
            ByteUtils.slice(sha256a, 8, 24),
            ByteUtils.slice(sha256b, 24, 32)
        )
        return (aesKey, aesIv)
    }

    /**
     * 加密秘密聊天消息载荷
     * key: 256 字节共享密钥
     * data: 明文消息字节
     * 返回: msgKey(16) || ciphertext
     */
    public static func encrypt(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
        // 填充到 16 字节对齐，最少 12 字节随机填充
        var paddingLen: Int64 = 12
        let lenAfterMin = data.size + paddingLen
        let rem = lenAfterMin % 16
        if (rem != 0) { paddingLen = paddingLen + (16 - rem) }
        let paddedData = ByteUtils.concat2(data, ByteUtils.randomBytes(paddingLen))

        let msgKey = calcMsgKey(key, paddedData, true)
        let (aesKey, aesIv) = calcAesKeyIv(key, msgKey, true)
        let ciphertext = AESIGE.encrypt(paddedData, aesKey, aesIv)
        return ByteUtils.concat2(msgKey, ciphertext)
    }

    /**
     * 解密秘密聊天消息载荷
     * key: 256 字节共享密钥
     * data: msgKey(16) || ciphertext
     * 返回: 解密后的明文（含填充）
     */
    public static func decrypt(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
        if (data.size < 16) { return Array<Byte>(0, repeat: 0) }
        let msgKey = ByteUtils.slice(data, 0, 16)
        let ciphertext = ByteUtils.slice(data, 16, data.size)
        let (aesKey, aesIv) = calcAesKeyIv(key, msgKey, false)
        return AESIGE.decrypt(ciphertext, aesKey, aesIv)
    }

    /**
     * 计算密钥指纹 = lower 64 bits of SHA1(key)
     *
     * W5 S8-08：此前用 SHA256 尾 8 字节，与对端（iOS UpdateSecretChat.swift:43-50 /
     * ManagedSecretChatOutgoingOperations.swift:240-247：`MTSha1(key)` 末 8 字节
     * memcpy 成 Int64，即小端）不一致 → "Key fingerprint mismatch!"。与 MTProto
     * auth_key_id（AuthKeyCreator: SHA1(auth_key)[12:20]）同一规则。
     */
    public static func calcKeyFingerprint(key: Array<Byte>): Int64 {
        let hash = SHA1.hash(key)
        return ByteUtils.bytesToInt64(ByteUtils.slice(hash, 12, 20))
    }
}

// ==================== Service ====================

private var _secretChatsServiceInstance: Option<TelegramCore_SecretChatsService> = None
private let _secretChatsServiceMutex = ReentrantMutex()

public func getTelegramCore_SecretChatsService(): TelegramCore_SecretChatsService {
    _secretChatsServiceMutex.lock()
    match (_secretChatsServiceInstance) {
        case Some(inst) =>
            _secretChatsServiceMutex.unlock()
            return inst
        case None =>
            let inst = TelegramCore_SecretChatsService()
            _secretChatsServiceInstance = Some(inst)
            _secretChatsServiceMutex.unlock()
            return inst
    }
}

/**
 * 秘密聊天核心服务
 *
 * 对应 Telegram-iOS TelegramCore/Sources/SecretChats/
 * 实现端到端加密会话：
 * - requestEncryption: 发起加密会话请求（DH A 方）
 * - acceptEncryption: 接受加密会话请求（DH B 方）
 * - discardEncryption: 丢弃/销毁加密会话
 * - sendEncryptedMessage: 发送加密消息
 * - decryptIncomingMessage: 解密接收到的加密消息
 * - handleEncryptedUpdate: 处理服务器推送的秘密聊天更新
 *
 * DH 密钥协商使用 BigIntMath.modPow (std.math.numeric.BigInt)
 * 消息加解密使用 AESIGE + SecretChatCrypto
 */
public class TelegramCore_SecretChatsService {
    private var sessions: HashMap<Int32, SecretChatSession> = HashMap<Int32, SecretChatSession>()
    private let sessionMutex = ReentrantMutex()
    // S8-08：会话状态订阅（iOS Postbox peer view 对 TelegramSecretChat.embeddedState 变化的通知）。
    // 回调在 updates 线程触发，订阅方自行切 UI 线程。参数：(secretChatId, SecretChatStatus)。
    private var stateSubscribers: HashMap<Int64, (Int32, String) -> Unit> = HashMap<Int64, (Int32, String) -> Unit>()
    private var nextStateToken: Int64 = 0

    public init() {}

    // ==================== 状态订阅 ====================

    public func addStateSubscriber(handler: (Int32, String) -> Unit): Int64 {
        sessionMutex.lock()
        let token = nextStateToken
        nextStateToken += 1
        stateSubscribers[token] = handler
        sessionMutex.unlock()
        return token
    }

    public func removeStateSubscriber(token: Int64): Unit {
        sessionMutex.lock()
        stateSubscribers.remove(token)
        sessionMutex.unlock()
    }

    private func notifyStateChanged(chatId: Int32, status: String): Unit {
        sessionMutex.lock()
        let handlers = ArrayList<(Int32, String) -> Unit>()
        for ((_, h) in stateSubscribers) { handlers.add(h) }
        sessionMutex.unlock()
        for (h in handlers) {
            try { h(chatId, status) } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[SecretChats] state subscriber error: ${e}")
            }
        }
    }

    /**
     * S8-08：updateEncryption#b4a2e88d chat:EncryptedChat date:int（iOS Api0.swift:1228；
     * TelegramCore updateSecretChat → embeddedState .handshake → .active）。
     * 入参 d 已读过 update 构造器，本函数消费完整个 EncryptedChat 与 date。
     * 对端（B 方）接受后服务端推 encryptedChat#61f0d4c7（含 g_b + key_fingerprint）：
     * 完成 DH，会话转 READY 并通知订阅方（聊天页收起 "Waiting for X to get online..."）。
     * @return 是否识别并完整消费；false 表示未知 EncryptedChat 构造器，调用方应回退 getDifference。
     */
    public func handleUpdateEncryption(d: TLDeserializer): Bool {
        let chatCtor = d.readUInt32()
        // encryptedChat#61f0d4c7 id:int access_hash:long date:int admin_id:long participant_id:long g_a_or_b:bytes key_fingerprint:long
        if (chatCtor == 0x61f0d4c7) {
            let chatId = d.readInt32()
            let _ = d.readInt64()  // access_hash
            let _ = d.readInt32()  // date
            let _ = d.readInt64()  // admin_id
            let _ = d.readInt64()  // participant_id
            let gAOrB = d.readBytes()
            let keyFingerprint = d.readInt64()
            let _ = d.readInt32()  // update date
            Hilog.info(0, "CjTelegram", "[SecretChats] updateEncryption: encryptedChat accepted, chatId=${chatId}")
            if (finalizeKeyNegotiation(chatId, gAOrB, keyFingerprint)) {
                notifyStateChanged(chatId, SecretChatStatus.READY)
            }
            return true
        }
        // encryptedChatDiscarded#1e1c7c45 flags:# history_deleted:flags.0?true id:int
        if (chatCtor == 0x1e1c7c45) {
            let _ = d.readInt32()  // flags
            let chatId = d.readInt32()
            let _ = d.readInt32()  // update date
            sessionMutex.lock()
            if (sessions.contains(chatId)) { sessions[chatId].status = SecretChatStatus.DISCARDED }
            sessionMutex.unlock()
            Hilog.info(0, "CjTelegram", "[SecretChats] updateEncryption: encryptedChatDiscarded chatId=${chatId}")
            notifyStateChanged(chatId, SecretChatStatus.DISCARDED)
            return true
        }
        // encryptedChatEmpty#ab7ec0a0 id:int
        if (chatCtor == 0xab7ec0a0) {
            let _ = d.readInt32()  // id
            let _ = d.readInt32()  // update date
            return true
        }
        // encryptedChatWaiting#66b25953 id:int access_hash:long date:int admin_id:long participant_id:long
        if (chatCtor == 0x66b25953) {
            let chatId = d.readInt32()
            let _ = d.readInt64()  // access_hash
            let _ = d.readInt32()  // date
            let _ = d.readInt64()  // admin_id
            let _ = d.readInt64()  // participant_id
            let _ = d.readInt32()  // update date
            Hilog.info(0, "CjTelegram", "[SecretChats] updateEncryption: encryptedChatWaiting chatId=${chatId}")
            return true
        }
        // encryptedChatRequested#48f1d94c flags:# folder_id:flags.0?int id:int access_hash:long date:int admin_id:long participant_id:long g_a:bytes
        // 对端向本端发起的请求（B 方）：本轮只消费字节保住 updates 容器的解析，接受流程走 acceptEncryption。
        if (chatCtor == 0x48f1d94c) {
            let flags = d.readInt32()
            if ((flags & 1) != 0) { let _ = d.readInt32() }  // folder_id
            let chatId = d.readInt32()
            let _ = d.readInt64()  // access_hash
            let _ = d.readInt32()  // date
            let _ = d.readInt64()  // admin_id
            let _ = d.readInt64()  // participant_id
            let _ = d.readBytes()  // g_a
            let _ = d.readInt32()  // update date
            Hilog.info(0, "CjTelegram", "[SecretChats] updateEncryption: encryptedChatRequested chatId=${chatId}")
            return true
        }
        Hilog.info(0, "CjTelegram", "[SecretChats] updateEncryption: unknown EncryptedChat ctor 0x${UInt32ToHex(chatCtor)}")
        return false
    }

    // ==================== DH Config ====================

    /**
     * 获取 DH 配置参数 (g, p)
     * 调用 messages.getDhConfig TL 方法
     */
    public func fetchDhConfig(): DhConfigResponse {
        let req = MessagesGetDhConfig()
        req.version = 0
        req.randomLength = 256
        let client = getMTProtoClient()
        let responseBytes = client.sendRequest(req.toBytes())
        return DhConfigResponse.deserialize(responseBytes)
    }

    // ==================== 请求加密会话 (A 方) ====================

    /**
     * 向指定用户发起秘密聊天请求
     *
     * 流程：
     * 1. 获取 DH 参数 (g, p)
     * 2. 生成随机 a (256 字节)
     * 3. 计算 gA = g^a mod p
     * 4. 发送 messages.requestEncryption
     * 5. 保存会话状态 (chatId, accessHash, a, gA)
     *
     * @param userId    对方用户 ID
     * @param userAccessHash 对方用户 access_hash
     * @return 秘密聊天 chatId（成功时 != 0，失败时 = 0；encryptedChat.id 是 int32，可为负）
     */
    public func requestEncryption(userId: Int64, userAccessHash: Int64): Int32 {
        Hilog.info(0, "CjTelegram", "[SecretChats] requestEncryption for user")

        let dhConfig = fetchDhConfig()
        if (dhConfig.g == 0 || dhConfig.p.size == 0) {
            Hilog.info(0, "CjTelegram", "[SecretChats] Failed to fetch DH config")
            return 0
        }

        // 生成随机 a (256 字节)
        let a = ByteUtils.randomBytes(256)

        // gA = g^a mod p  (BigInt 大数模幂)
        let gBytes = BigIntMath.bigIntToBytes(BigIntMath.bytesToBigInt(Array<Byte>(4, { i: Int64 => UInt8(0) })), 4)
        let gVal = dhConfig.g
        let gAsBytes = Array<Byte>(4, repeat: 0)
        gAsBytes[0] = UInt8((gVal >> 24) & 0xFF)
        gAsBytes[1] = UInt8((gVal >> 16) & 0xFF)
        gAsBytes[2] = UInt8((gVal >> 8) & 0xFF)
        gAsBytes[3] = UInt8(gVal & 0xFF)
        let gA = BigIntMath.modPow(gAsBytes, a, dhConfig.p)

        // 发送 messages.requestEncryption
        let req = MessagesRequestEncryption()
        req.userId = userId
        req.userAccessHash = userAccessHash
        req.randomId = Int32(ByteUtils.bytesToInt32(ByteUtils.randomBytes(4)))
        req.gA = gA

        let client = getMTProtoClient()
        let responseBytes = client.sendRequest(req.toBytes())
        let chatResp = EncryptedChatResponse.deserialize(responseBytes)

        if (!chatResp.isSuccess || chatResp.chatId == 0) {
            Hilog.info(0, "CjTelegram", "[SecretChats] requestEncryption failed")
            return 0
        }

        // 保存会话状态
        let session = SecretChatSession()
        session.chatId = chatResp.chatId
        session.accessHash = chatResp.accessHash
        session.peerId = userId
        session.peerAccessHash = userAccessHash
        session.dhG = gVal
        session.dhP = dhConfig.p
        session.mySecret = a
        session.status = SecretChatStatus.REQUESTED

        sessionMutex.lock()
        sessions[chatResp.chatId] = session
        sessionMutex.unlock()

        Hilog.info(0, "CjTelegram", "[SecretChats] requestEncryption success, chatId")
        return chatResp.chatId
    }

    // ==================== 接受加密会话 (B 方) ====================

    /**
     * 接受对方发来的秘密聊天请求
     *
     * 流程：
     * 1. 获取 DH 参数 (g, p)
     * 2. 生成随机 b (256 字节)
     * 3. 计算 gB = g^b mod p
     * 4. 计算共享密钥 key = gA^b mod p
     * 5. 计算 keyFingerprint = SHA1(key) 低 64 位
     * 6. 发送 messages.acceptEncryption
     * 7. 标记会话为 READY
     *
     * @param chatId     秘密聊天 ID
     * @param accessHash 秘密聊天 access hash
     * @param gA         对方发来的 gA (来自 encryptedChatRequested)
     * @param peerId     对方用户 ID
     * @return 是否成功
     */
    public func acceptEncryption(chatId: Int32, accessHash: Int64, gA: Array<Byte>, peerId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[SecretChats] acceptEncryption chatId")

        let dhConfig = fetchDhConfig()
        if (dhConfig.g == 0 || dhConfig.p.size == 0) {
            Hilog.info(0, "CjTelegram", "[SecretChats] Failed to fetch DH config for accept")
            return false
        }

        // 生成随机 b
        let b = ByteUtils.randomBytes(256)

        // gB = g^b mod p
        let gVal = dhConfig.g
        let gAsBytes = Array<Byte>(4, repeat: 0)
        gAsBytes[0] = UInt8((gVal >> 24) & 0xFF)
        gAsBytes[1] = UInt8((gVal >> 16) & 0xFF)
        gAsBytes[2] = UInt8((gVal >> 8) & 0xFF)
        gAsBytes[3] = UInt8(gVal & 0xFF)
        let gB = BigIntMath.modPow(gAsBytes, b, dhConfig.p)

        // key = gA^b mod p (共享密钥)
        let rawKey = BigIntMath.modPow(gA, b, dhConfig.p)
        // 填充到 256 字节
        let sessionKey = Array<Byte>(256, repeat: 0)
        let offset = 256 - rawKey.size
        let safeOffset = if (offset < 0) { 0 } else { offset }
        for (i in 0..rawKey.size) {
            if (safeOffset + i < 256) {
                sessionKey[safeOffset + i] = rawKey[i]
            }
        }

        let keyFingerprint = SecretChatCrypto.calcKeyFingerprint(sessionKey)

        // 发送 messages.acceptEncryption
        let req = MessagesAcceptEncryption()
        req.chatId = chatId
        req.accessHash = accessHash
        req.gB = gB
        req.keyFingerprint = keyFingerprint

        let client = getMTProtoClient()
        let responseBytes = client.sendRequest(req.toBytes())
        let chatResp = EncryptedChatResponse.deserialize(responseBytes)

        if (!chatResp.isSuccess) {
            Hilog.info(0, "CjTelegram", "[SecretChats] acceptEncryption server rejected")
            return false
        }

        // 存储会话
        let session = SecretChatSession()
        session.chatId = chatId
        session.accessHash = accessHash
        session.peerId = peerId
        session.dhG = gVal
        session.dhP = dhConfig.p
        session.mySecret = b
        session.peerGKey = gA
        session.sessionKey = sessionKey
        session.keyFingerprint = keyFingerprint
        session.status = SecretChatStatus.READY

        sessionMutex.lock()
        sessions[chatId] = session
        sessionMutex.unlock()

        Hilog.info(0, "CjTelegram", "[SecretChats] acceptEncryption success, session READY")
        return true
    }

    // ==================== 密钥确认 (A 方在收到 gB 后完成协商) ====================

    /**
     * A 方在收到服务器推送的 encryptedChat（含 gB）后调用
     * 计算共享密钥并将会话标记为 READY
     *
     * @param chatId     秘密聊天 ID
     * @param gB         B 方发来的 gB (来自 encryptedChat 推送)
     * @param expectedFingerprint  服务器传递的 key_fingerprint，用于验证
     * @return 是否成功
     */
    public func finalizeKeyNegotiation(chatId: Int32, gB: Array<Byte>, expectedFingerprint: Int64): Bool {
        sessionMutex.lock()
        var sessionOpt: Option<SecretChatSession> = None
        if (sessions.contains(chatId)) {
            sessionOpt = Some(sessions[chatId])
        }
        sessionMutex.unlock()

        let session = match (sessionOpt) {
            case Some(s) => s
            case None =>
                Hilog.info(0, "CjTelegram", "[SecretChats] finalizeKeyNegotiation: session not found")
                return false
        }

        if (session.dhP.size == 0 || session.mySecret.size == 0) {
            Hilog.info(0, "CjTelegram", "[SecretChats] finalizeKeyNegotiation: missing DH params")
            return false
        }

        // key = gB^a mod p
        let rawKey = BigIntMath.modPow(gB, session.mySecret, session.dhP)
        let sessionKey = Array<Byte>(256, repeat: 0)
        let offset = 256 - rawKey.size
        let safeOffset = if (offset < 0) { 0 } else { offset }
        for (i in 0..rawKey.size) {
            if (safeOffset + i < 256) {
                sessionKey[safeOffset + i] = rawKey[i]
            }
        }

        let fingerprint = SecretChatCrypto.calcKeyFingerprint(sessionKey)
        if (fingerprint != expectedFingerprint) {
            Hilog.info(0, "CjTelegram", "[SecretChats] Key fingerprint mismatch! local=${fingerprint} server=${expectedFingerprint}")
        } else {
            Hilog.info(0, "CjTelegram", "[SecretChats] Key fingerprint verified chatId=${chatId}")
        }

        sessionMutex.lock()
        if (sessions.contains(chatId)) {
            let s = sessions[chatId]
            s.sessionKey = sessionKey
            s.keyFingerprint = fingerprint
            s.peerGKey = gB
            s.status = SecretChatStatus.READY
        }
        sessionMutex.unlock()

        Hilog.info(0, "CjTelegram", "[SecretChats] Key negotiation finalized for chat")
        return true
    }

    // ==================== 丢弃会话 ====================

    /**
     * 丢弃/销毁秘密聊天
     * 调用 messages.discardEncryption，并从本地删除会话
     *
     * @param chatId       秘密聊天 ID
     * @param deleteHistory 是否同时删除消息历史
     * @return 是否成功
     */
    public func discardEncryption(chatId: Int32, deleteHistory!: Bool = false): Bool {
        Hilog.info(0, "CjTelegram", "[SecretChats] discardEncryption chatId")

        let req = MessagesDiscardEncryption()
        req.chatId = chatId
        req.deleteHistory = deleteHistory

        let client = getMTProtoClient()
        let responseBytes = client.sendRequest(req.toBytes())

        // Bool 响应: boolTrue#997275b5 / boolFalse#bc799737
        let success = responseBytes.size >= 4 && parseBoolean(responseBytes)

        sessionMutex.lock()
        if (sessions.contains(chatId)) {
            let s = sessions[chatId]
            s.status = SecretChatStatus.DISCARDED
        }
        sessionMutex.unlock()

        Hilog.info(0, "CjTelegram", "[SecretChats] discardEncryption completed")
        return success
    }

    // ==================== 发送加密消息 ====================

    /**
     * 向秘密聊天发送加密消息
     *
     * 流程：
     * 1. 查找会话密钥
     * 2. 构造 DecryptedMessage TL 层载荷
     * 3. 用 SecretChatCrypto.encrypt 加密
     * 4. 调用 messages.sendEncrypted
     *
     * @param chatId  秘密聊天 ID
     * @param text    消息文本
     * @return 服务器返回的 date（发送成功），0 表示失败
     */
    public func sendEncryptedTextMessage(chatId: Int32, text: String): Int32 {
        sessionMutex.lock()
        var sessionOpt: Option<SecretChatSession> = None
        if (sessions.contains(chatId)) {
            sessionOpt = Some(sessions[chatId])
        }
        sessionMutex.unlock()

        let session = match (sessionOpt) {
            case Some(s) => s
            case None =>
                Hilog.info(0, "CjTelegram", "[SecretChats] sendEncrypted: session not found")
                return 0
        }

        if (session.status != SecretChatStatus.READY) {
            Hilog.info(0, "CjTelegram", "[SecretChats] sendEncrypted: session not READY")
            return 0
        }

        // 构造 decryptedMessage#91cc4674 内层载荷
        let innerPayload = buildDecryptedMessagePayload(text, session.outSeqNo)

        // 用会话密钥加密
        let encryptedPayload = SecretChatCrypto.encrypt(session.sessionKey, innerPayload)

        // 发送 messages.sendEncrypted
        let randomIdBytes = ByteUtils.randomBytes(8)
        let randomId = ByteUtils.bytesToInt64(randomIdBytes)

        let req = MessagesSendEncrypted()
        req.chatId = chatId
        req.accessHash = session.accessHash
        req.randomId = randomId
        req.data = encryptedPayload

        let client = getMTProtoClient()
        let responseBytes = client.sendRequest(req.toBytes())

        // messages.sentEncryptedMessage#560f8935 date:int
        // messages.sentEncryptedFile#9493ff32 date:int file:EncryptedFile
        let sentDate = parseSentEncryptedDate(responseBytes)

        if (sentDate > 0) {
            sessionMutex.lock()
            if (sessions.contains(chatId)) {
                sessions[chatId].outSeqNo = sessions[chatId].outSeqNo + 2
            }
            sessionMutex.unlock()
        }

        Hilog.info(0, "CjTelegram", "[SecretChats] sendEncryptedTextMessage done")
        return sentDate
    }

    // ==================== 接收/解密消息 ====================

    /**
     * 解密接收到的加密消息载荷
     *
     * @param chatId          秘密聊天 ID
     * @param encryptedBytes  来自服务器 encryptedMessage.bytes 字段
     * @return 解密后的明文（DecryptedMessage 载荷），失败时返回空数组
     */
    public func decryptIncomingMessage(chatId: Int32, encryptedBytes: Array<Byte>): Array<Byte> {
        sessionMutex.lock()
        var sessionOpt: Option<SecretChatSession> = None
        if (sessions.contains(chatId)) {
            sessionOpt = Some(sessions[chatId])
        }
        sessionMutex.unlock()

        let session = match (sessionOpt) {
            case Some(s) => s
            case None =>
                Hilog.info(0, "CjTelegram", "[SecretChats] decryptIncoming: session not found")
                return Array<Byte>(0, repeat: 0)
        }

        if (session.sessionKey.size == 0) {
            Hilog.info(0, "CjTelegram", "[SecretChats] decryptIncoming: no session key")
            return Array<Byte>(0, repeat: 0)
        }

        let decrypted = SecretChatCrypto.decrypt(session.sessionKey, encryptedBytes)

        sessionMutex.lock()
        if (sessions.contains(chatId)) {
            sessions[chatId].inSeqNo = sessions[chatId].inSeqNo + 2
        }
        sessionMutex.unlock()

        return decrypted
    }

    /**
     * 处理服务器推送的 updateNewEncryptedMessage
     *
     * 解析推送字节，识别：
     * - updateNewEncryptedMessage#12bcbd9a — 新加密消息
     * - updateEncryptionSettings — 加密设置更新（接受/丢弃通知）
     *
     * @param updateData  来自服务器的原始更新字节（已去除 constructor）
     * @return 解密后的明文（如果是消息），否则空数组
     */
    public func handleEncryptedUpdate(updateData: Array<Byte>): Array<Byte> {
        if (updateData.size < 4) { return Array<Byte>(0, repeat: 0) }
        let d = TLDeserializer(updateData)
        let ctor = d.readUInt32()

        // updateNewEncryptedMessage#12bcbd9a message:EncryptedMessage qts:int
        if (ctor == 0x12bcbd9a) {
            let msgCtor = d.readUInt32()
            // encryptedMessage#ed18c118 random_id:long chat_id:int date:int bytes:bytes
            if (msgCtor == 0xed18c118) {
                let _ = d.readInt64()  // random_id
                let chatId = d.readInt32()
                let _ = d.readInt32()  // date
                let encBytes = d.readBytes()
                return decryptIncomingMessage(chatId, encBytes)
            }
        }

        // updateEncryption#b4a2e88d chat:EncryptedChat date:int
        // Used to notify A party that B accepted (encryptedChat with gB inside)
        if (ctor == 0xb4a2e88d) {
            let chatCtor = d.readUInt32()
            // encryptedChat#fa56ce36 id:int access_hash:long date:int admin_id:long participant_id:long g_a_or_b:bytes key_fingerprint:long
            if (chatCtor == 0xfa56ce36) {
                let chatId = d.readInt32()
                let _ = d.readInt64()  // access_hash
                let _ = d.readInt32()  // date
                let _ = d.readInt64()  // admin_id
                let _ = d.readInt64()  // participant_id
                let gAOrB = d.readBytes()
                let keyFingerprint = d.readInt64()
                let _ = finalizeKeyNegotiation(chatId, gAOrB, keyFingerprint)
            }
        }

        return Array<Byte>(0, repeat: 0)
    }

    // ==================== Session Query ====================

    /**
     * 获取指定秘密聊天会话（只读）
     */
    public func getSession(chatId: Int32): Option<SecretChatSession> {
        sessionMutex.lock()
        var result: Option<SecretChatSession> = None
        if (sessions.contains(chatId)) {
            result = Some(sessions[chatId])
        }
        sessionMutex.unlock()
        return result
    }

    /**
     * 当前活跃会话数量
     */
    public func activeSessionCount(): Int64 {
        sessionMutex.lock()
        let count = Int64(sessions.size)
        sessionMutex.unlock()
        return count
    }

    // ==================== 内部辅助 ====================

    /**
     * 构造 decryptedMessage#91cc4674 内层载荷
     * random_id:long random_bytes:bytes message:string media:DecryptedMessageMedia
     */
    private func buildDecryptedMessagePayload(text: String, seqNo: Int32): Array<Byte> {
        let s = TLSerializer()
        // decryptedMessage#91cc4674
        s.writeUInt32(0x91cc4674)
        // flags: 0 (no entities, no reply)
        s.writeInt32(0)
        // random_id: 8 random bytes as Int64
        let randomId = ByteUtils.bytesToInt64(ByteUtils.randomBytes(8))
        s.writeInt64(randomId)
        // ttl: 0 (no self-destruct)
        s.writeInt32(0)
        // message: string
        s.writeString(text)
        // media: decryptedMessageMediaEmpty#89f5c4a
        s.writeUInt32(0x89f5c4a)
        return s.getBytes()
    }

    /**
     * 解析 messages.sentEncryptedMessage 响应，返回 date
     * messages.sentEncryptedMessage#560f8935 date:int
     * messages.sentEncryptedFile#9493ff32 date:int file:EncryptedFile
     */
    private func parseSentEncryptedDate(data: Array<Byte>): Int32 {
        if (data.size < 8) { return 0 }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        if (ctor == 0x560f8935 || ctor == 0x9493ff32) {
            return d.readInt32()
        }
        return 0
    }

    /**
     * 解析 Bool TL 类型
     * boolTrue#997275b5 / boolFalse#bc799737
     */
    private func parseBoolean(data: Array<Byte>): Bool {
        if (data.size < 4) { return false }
        let d = TLDeserializer(data)
        let ctor = d.readUInt32()
        return ctor == 0x997275b5
    }
}
