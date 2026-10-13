package ohos_app_cangjie_entry.adapters

import ohos_app_cangjie_entry.services.{
    getTelegramCore_SecretChatsService,
    SecretChatSession,
    SecretChatStatus
}

/**
 * TelegramCore 秘密聊天适配层 — 对外接口
 *
 * 对应 Telegram-iOS TelegramCore/Sources/SecretChats/ 公开 API
 * 为上层业务提供易用的秘密聊天接口，委托 TelegramCore_SecretChatsService 实现
 *
 * 调用示例：
 *   let adapter = getTelegramCore_SecretChatsAdapter()
 *   // 发起加密会话（A 方）
 *   let chatId = adapter.requestEncryption(userId: 123, userAccessHash: 0x456)
 *   // 接受加密会话（B 方，收到 encryptedChatRequested 推送后调用）
 *   let ok = adapter.acceptEncryption(chatId: 1, accessHash: 0x789, gA: gABytes, peerId: 123)
 *   // 发送加密消息
 *   let date = adapter.sendEncryptedTextMessage(chatId: 1, text: "Hello E2E!")
 *   // 解密收到的消息
 *   let plaintext = adapter.decryptIncomingMessage(chatId: 1, encryptedBytes: bytes)
 */
private var _secretChatsAdapterInstance: Option<TelegramCore_SecretChatsAdapter> = None

public func getTelegramCore_SecretChatsAdapter(): TelegramCore_SecretChatsAdapter {
    match (_secretChatsAdapterInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_SecretChatsAdapter()
            _secretChatsAdapterInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_SecretChatsAdapter {
    public init() {}

    /**
     * 向用户发起秘密聊天请求（A 方）
     *
     * 执行 messages.getDhConfig + messages.requestEncryption TL 调用序列。
     * A 方生成随机 a，计算 gA = g^a mod p，发送给服务器。
     *
     * @param userId         对方用户 ID
     * @param userAccessHash 对方用户 access_hash
     * @return 秘密聊天 chatId（> 0 表示成功）
     */
    public func requestEncryption(userId: Int64, userAccessHash: Int64): Int32 {
        return getTelegramCore_SecretChatsService().requestEncryption(userId, userAccessHash)
    }

    /**
     * 接受对方发来的秘密聊天请求（B 方）
     *
     * 执行 messages.getDhConfig + messages.acceptEncryption TL 调用序列。
     * B 方生成随机 b，计算 gB = g^b mod p，推导共享密钥 key = gA^b mod p。
     *
     * @param chatId     来自服务器推送的秘密聊天 ID
     * @param accessHash 来自服务器推送的 access_hash
     * @param gA         来自 encryptedChatRequested 推送的 g_a 字段
     * @param peerId     对方用户 ID
     * @return 是否成功
     */
    public func acceptEncryption(chatId: Int32, accessHash: Int64, gA: Array<Byte>, peerId: Int64): Bool {
        return getTelegramCore_SecretChatsService().acceptEncryption(chatId, accessHash, gA, peerId)
    }

    /**
     * A 方完成密钥协商（收到服务器 encryptedChat 推送后调用）
     *
     * A 方在 requestEncryption 后会收到服务器推送，其中包含 B 方的 gB，
     * 此时调用此方法完成密钥派生：key = gB^a mod p。
     *
     * @param chatId              秘密聊天 ID
     * @param gB                  来自 encryptedChat 推送的 g_a_or_b 字段
     * @param expectedFingerprint 来自 encryptedChat 推送的 key_fingerprint 字段（用于验证）
     * @return 是否成功
     */
    public func finalizeKeyNegotiation(chatId: Int32, gB: Array<Byte>, expectedFingerprint: Int64): Bool {
        return getTelegramCore_SecretChatsService().finalizeKeyNegotiation(chatId, gB, expectedFingerprint)
    }

    /**
     * 丢弃秘密聊天
     *
     * 调用 messages.discardEncryption，并清理本地会话。
     *
     * @param chatId        秘密聊天 ID
     * @param deleteHistory 是否同时请求服务器删除消息历史
     * @return 是否成功
     */
    public func discardEncryption(chatId: Int32, deleteHistory!: Bool = false): Bool {
        return getTelegramCore_SecretChatsService().discardEncryption(chatId, deleteHistory: deleteHistory)
    }

    /**
     * 向秘密聊天发送加密文本消息
     *
     * 使用 AES-IGE + SecretChatCrypto 加密，调用 messages.sendEncrypted。
     *
     * @param chatId 秘密聊天 ID（会话必须处于 READY 状态）
     * @param text   消息文本
     * @return 服务器返回的消息 date（> 0 表示成功）
     */
    public func sendEncryptedTextMessage(chatId: Int32, text: String): Int32 {
        return getTelegramCore_SecretChatsService().sendEncryptedTextMessage(chatId, text)
    }

    /**
     * 解密收到的加密消息载荷
     *
     * @param chatId         秘密聊天 ID
     * @param encryptedBytes 来自 encryptedMessage.bytes 字段的原始加密字节
     * @return 解密后的 DecryptedMessage TL 载荷（明文字节），失败时返回空数组
     */
    public func decryptIncomingMessage(chatId: Int32, encryptedBytes: Array<Byte>): Array<Byte> {
        return getTelegramCore_SecretChatsService().decryptIncomingMessage(chatId, encryptedBytes)
    }

    /**
     * 处理服务器推送的秘密聊天更新
     *
     * 识别并处理 updateNewEncryptedMessage / updateEncryption 推送。
     *
     * @param updateData 原始更新字节（含 constructor）
     * @return 若是新消息推送，返回解密后的明文；否则返回空数组
     */
    public func handleEncryptedUpdate(updateData: Array<Byte>): Array<Byte> {
        return getTelegramCore_SecretChatsService().handleEncryptedUpdate(updateData)
    }

    /**
     * 查询指定秘密聊天会话状态
     *
     * @param chatId 秘密聊天 ID
     * @return Option<SecretChatSession>，None 表示会话不存在
     */
    public func getSession(chatId: Int32): Option<SecretChatSession> {
        return getTelegramCore_SecretChatsService().getSession(chatId)
    }

    /**
     * 当前活跃秘密聊天会话数
     */
    public func activeSessionCount(): Int64 {
        return getTelegramCore_SecretChatsService().activeSessionCount()
    }

    /**
     * 获取会话状态字符串（便于 UI 展示）
     * 返回: "pending" / "requested" / "ready" / "discarded" / "not_found"
     */
    public func getSessionStatus(chatId: Int32): String {
        let sessionOpt = getTelegramCore_SecretChatsService().getSession(chatId)
        return match (sessionOpt) {
            case Some(s) => s.status
            case None => "not_found"
        }
    }
}
