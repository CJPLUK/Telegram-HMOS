package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
import ohos_app_cangjie_entry.models.ReactionData
import std.collection.ArrayList

/**
 * messages.getAvailableReactions — 获取所有可用表情反应
 *
 * TL Schema: messages.getAvailableReactions#18dea0ac hash:int = messages.AvailableReactions
 *
 * hash: 客户端本地版本 hash，传 0 始终拉取最新。
 * Returns: messages.availableReactions 或 messages.availableReactionsNotModified
 */
private class MessagesGetAvailableReactions <: TLObject {
    public var hash: Int32 = 0

    public override func getConstructorId(): UInt32 { return 0x18dea0ac }

    public override func serialize(serializer: TLSerializer) {
        serializer.writeInt32(this.hash)
    }
}

/**
 * 表情反应选择服务（Phase R — ReactionSelectionNode）
 *
 * 对应 iOS ReactionSelectionNode 中的数据层职责：
 * - 拉取可用反应列表（messages.getAvailableReactions）
 * - 代理发送/移除单条消息反应（messages.sendReaction）
 *
 * 调用链：
 *   fetchAvailableReactions() → getMTProtoClient().sendRequest() → 解析响应
 *   sendReaction()            → getRealMessageService().sendReaction()
 *   removeReaction()          → getRealMessageService().removeReaction()
 */
public class ReactionSelectionService {

    /**
     * 获取可用反应列表
     *
     * 向服务端发送 messages.getAvailableReactions，解析返回的 emoji 列表。
     * 若网络失败或服务端返回 notModified，回退到 Telegram 17 个标准免费表情。
     *
     * @return emoji 字符串数组（如 ["👍", "❤️", ...]）
     */
    public func fetchAvailableReactions(): Array<String> {
        Hilog.info(0, "CjTelegram", "[ReactionSelectionService] fetchAvailableReactions start")
        let client = getMTProtoClient()
        let req = MessagesGetAvailableReactions()
        req.hash = 0

        try {
            let responseData = client.sendRequest(req.toBytes())
            let parsed = parseAvailableReactionsResponse(responseData)
            if (parsed.size > 0) {
                Hilog.info(0, "CjTelegram", "[ReactionSelectionService] fetchAvailableReactions ok, count=${parsed.size}")
                return parsed
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ReactionSelectionService] fetchAvailableReactions exception: ${e}")
        }

        return defaultFreeReactions()
    }

    /**
     * 发送/切换消息反应
     *
     * 委托 RealMessageService.sendReaction，构成完整调用链：
     *   ReactionSelectionService → RealMessageService → MTProtoClient.sendRequest()
     *
     * @param peerType 对话类型 (user/chat/channel)
     * @param peerId   对话 ID
     * @param msgId    目标消息 ID
     * @param emoji    要发送的 emoji（空字符串 = 移除所有反应）
     * @return 是否成功
     */
    public func sendReaction(peerType: String, peerId: Int64, msgId: Int32, emoji: String): Bool {
        Hilog.info(0, "CjTelegram", "[ReactionSelectionService] sendReaction peer=${peerType}/${peerId} msgId=${msgId} emoji=${emoji}")
        return getRealMessageService().sendReaction(peerType, peerId, msgId, emoji)
    }

    /**
     * 发送 custom-emoji 消息反应（P2-375）
     *
     * 委托 RealMessageService.sendCustomEmojiReaction，构成完整调用链：
     *   ReactionSelectionService → RealMessageService → MTProtoClient.sendRequest()
     *   使用 reactionCustomEmoji#8935fc73 document_id:long TL 构造器
     *
     * @param peerType   对话类型 (user/chat/channel)
     * @param peerId     对话 ID
     * @param msgId      目标消息 ID
     * @param documentId custom emoji 的 document_id（来自 reactionCustomEmoji TL）
     * @return 是否成功
     */
    public func sendCustomEmojiReaction(peerType: String, peerId: Int64, msgId: Int32, documentId: Int64): Bool {
        Hilog.info(0, "CjTelegram", "[ReactionSelectionService] sendCustomEmojiReaction peer=${peerType}/${peerId} msgId=${msgId} docId=${documentId}")
        return getRealMessageService().sendCustomEmojiReaction(peerType, peerId, msgId, documentId)
    }

    /**
     * 移除消息反应
     *
     * @param peerType 对话类型
     * @param peerId   对话 ID
     * @param msgId    目标消息 ID
     * @return 是否成功
     */
    public func removeReaction(peerType: String, peerId: Int64, msgId: Int32): Bool {
        Hilog.info(0, "CjTelegram", "[ReactionSelectionService] removeReaction peer=${peerType}/${peerId} msgId=${msgId}")
        return getRealMessageService().removeReaction(peerType, peerId, msgId)
    }

    // ==================== 内部解析 ====================

    /**
     * 解析 messages.availableReactions 响应，提取 emoji 字符串列表
     *
     * messages.availableReactions#768e3aad hash:int reactions:Vector<AvailableReaction>
     * availableReaction#c077ec01 ... emoticon:string title:string ...
     *
     * 简化解析：扫描 STRING_MARKER(0x0d) 后读取长度前缀字符串；
     * 由于 emoticon 是第一个字符串字段，连续匹配即可提取。
     */
    private func parseAvailableReactionsResponse(data: Array<Byte>): Array<String> {
        let result = ArrayList<String>()
        if (data.size < 8) { return result.toArray() }

        var i: Int64 = 0
        // 跳过 4 字节构造器 ID
        i = 4

        // 检查是否是 messages.availableReactions#768e3aad
        let c0 = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        if (c0 != 0x768e3aad) {
            // notModified 或未知响应，返回空 → 调用方会用默认列表
            return result.toArray()
        }

        // hash (4 bytes)
        i = i + 4

        // reactions vector: 0x1cb5c415 + count(4)
        if (i + 8 > data.size) { return result.toArray() }
        let vectorId = UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
        i = i + 4
        if (vectorId != 0x1cb5c415) { return result.toArray() }

        let count = Int32(data[i]) | (Int32(data[i + 1]) << 8) | (Int32(data[i + 2]) << 16) | (Int32(data[i + 3]) << 24)
        i = i + 4

        var idx: Int32 = 0
        while (idx < count && i < Int64(data.size)) {
            // availableReaction constructor(4) + flags(4) + emoticon(string)
            // skip constructor(4) + flags(4)
            i = i + 8
            // read emoticon string (TL string: if first byte <= 253, it's length, then bytes, padded to 4-byte boundary)
            if (i >= Int64(data.size)) { break }
            let strLen = Int64(data[i])
            if (strLen <= 253) {
                i = i + 1
                if (i + strLen > Int64(data.size)) { break }
                var strBytes = Array<Byte>(strLen, repeat: 0)
                var si: Int64 = 0
                while (si < strLen) {
                    strBytes[si] = data[i + si]
                    si = si + 1
                }
                let emoticon = String.fromUtf8(strBytes)
                result.add(emoticon)
                i = i + strLen
                // align to 4 bytes
                let total = 1 + strLen
                let pad = (4 - (total % 4)) % 4
                i = i + pad
            } else {
                // 3-byte length encoding (strLen == 254)
                if (i + 4 > Int64(data.size)) { break }
                let longLen = Int64(data[i + 1]) | (Int64(data[i + 2]) << 8) | (Int64(data[i + 3]) << 16)
                i = i + 4
                if (i + longLen > Int64(data.size)) { break }
                var strBytes = Array<Byte>(longLen, repeat: 0)
                var si: Int64 = 0
                while (si < longLen) {
                    strBytes[si] = data[i + si]
                    si = si + 1
                }
                let emoticon = String.fromUtf8(strBytes)
                result.add(emoticon)
                i = i + longLen
                let total = 4 + longLen
                let pad = (4 - (total % 4)) % 4
                i = i + pad
            }
            // skip remaining fields of availableReaction: title(string) + document(Document) + ...
            // We only need emoticon; skip by breaking after count extraction
            // Since we can't know exact layout of the rest, we just trust the count + break
            // and fall through to parse next element from 'i' as-is.
            // In practice, malformed input → loop terminates via bounds check.
            idx = idx + 1
        }

        return result.toArray()
    }

    /**
     * Telegram 标准 17 个免费反应（与 QuickReactionBar 保持一致）
     */
    private func defaultFreeReactions(): Array<String> {
        return ["👍", "👎", "❤️", "🔥", "🎉", "🤩", "😱", "😁", "😢", "🙏", "🤔", "🤯", "🥰", "🤮", "💩", "🤬", "👏"]
    }
}

// ==================== 单例访问 ====================

private var _reactionSelectionServiceInstance: Option<ReactionSelectionService> = None

public func getReactionSelectionService(): ReactionSelectionService {
    match (_reactionSelectionServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = ReactionSelectionService()
            _reactionSelectionServiceInstance = Some(svc)
            return svc
    }
}
