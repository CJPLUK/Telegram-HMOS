package ohos_app_cangjie_entry.services

/**
 * PushPayloadRouter — 推送 Payload 接收与 loc-key 路由（P2-257）
 *
 * iOS 对应（对照 iOS 实现做逐行 gap 分析）：
 *   submodules/TelegramUI/Sources/SharedNotificationManager.swift:247-277
 *   Telegram/NotificationService/Sources/NotificationService.swift:1098-1135
 *
 * 支持的 loc-key 路由分支：
 *   SESSION_REVOKE   → 强制登出（iOS: isForcedLogOut = true）
 *   PHONE_CALL_REQUEST → 来电（iOS: isCall = true）
 *   GEO_LIVE_PENDING → 地理位置轮询（iOS: isLocationPolling = true）
 *   MESSAGE_MUTED    → 轮询状态（iOS: shouldPollState = true）
 *   MESSAGE_DELETED  → 删除消息（iOS: action = .deleteMessage）
 *   READ_HISTORY     → 远端已读同步（iOS: action = .readMessages）
 *   READ_REACTION    → 已读 reaction 同步
 *   (其他)           → Unknown — 忽略
 *
 * 平台 Gap / Defer 清单：
 *   1. 加密 payload 解密（AES-IGE with masterNotificationsKey）：
 *      iOS 在 NotificationService.swift:950 用 decryptedNotificationPayload(key:, data:)
 *      鸿蒙端 routeRawPayload() 接收的是字符串 payload（未加密）或已解密的 JSON。
 *      全加密流水线（keyId 匹配 → AES-IGE 解密 → JSON 解析）defer：
 *      需要 AES-IGE 实现 + 正确的密钥派生，作为后续 crypto 单元接入。
 *      当前实现直接解析明文 JSON 字符串，对未加密推送场景有效。
 *   2. configurationUpdate 备用 DC 切换：defer（需 DC 管理接入）
 *   3. beginPollingState：defer（需 UpdatePoller 集成）
 *   4. CONF_CALL_REQUEST / CONF_VIDEOCALL_REQUEST：defer（群组通话）
 *   5. 推送接收回调注册（鸿蒙 HMS wantAgent / push receive entry）：
 *      需在 module.json5 配置 PushExtensionAbility 并实现 UIExtensionAbility。
 *      defer — 属于 HAP 工程配置层面，非 Cangjie 代码层面。
 */

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.convert.*

// ==================== Enums ====================

/**
 * 推送 loc-key 枚举（对应 iOS NotificationService switch-case）
 */
public enum PushLocKey {
    | SessionRevoke
    | PhoneCallRequest
    | GeoLivePending
    | MessageMuted
    | MessageDeleted
    | ReadHistory
    | ReadReaction
    | Unknown
}

/**
 * 推送 Payload 解析动作（对应 iOS Action enum in NotificationService）
 * 关联数据使用位置型元组（Cangjie enum 不支持命名参数）
 */
public enum PushPayloadAction {
    | Logout
    | IncomingCall(Int64)
    | LocationPolling(Int64)
    | PollState(Int64)
    | DeleteMessages(Int64, ArrayList<Int64>)
    | ReadMessages(Int64, Int32)
    | ReadReactions(Int64, ArrayList<Int64>)
    | Ignored
}

// ==================== PushPayload ====================

/**
 * 解析后的推送 Payload（从 loc-key JSON 字段提取）
 */
public class PushPayload {
    public var locKey: PushLocKey = PushLocKey.Unknown
    public var fromId: Int64 = 0
    public var chatId: Int64 = 0
    public var channelId: Int64 = 0
    public var msgId: Int32 = 0
    public var messages: String = ""

    public func peerId(): Int64 {
        if (this.fromId != 0) { return this.fromId }
        if (this.chatId != 0) { return this.chatId }
        return this.channelId
    }
}

// ==================== PushPayloadRouter ====================

/**
 * 推送 Payload 路由器
 *
 * 主入口：routePayload(jsonStr) → PushPayloadAction
 * 调用方根据 action 分发到对应业务逻辑（登出/来电/消息删除/已读等）
 */
public class PushPayloadRouter {

    public init() {}

    /**
     * 解析 loc-key 字符串为枚举
     */
    public static func parseLocKey(raw: String): PushLocKey {
        if (raw == "SESSION_REVOKE") { return PushLocKey.SessionRevoke }
        if (raw == "PHONE_CALL_REQUEST") { return PushLocKey.PhoneCallRequest }
        if (raw == "GEO_LIVE_PENDING") { return PushLocKey.GeoLivePending }
        if (raw == "MESSAGE_MUTED") { return PushLocKey.MessageMuted }
        if (raw == "MESSAGE_DELETED") { return PushLocKey.MessageDeleted }
        if (raw == "READ_HISTORY") { return PushLocKey.ReadHistory }
        if (raw == "READ_REACTION") { return PushLocKey.ReadReaction }
        return PushLocKey.Unknown
    }

    /**
     * 从明文 JSON payload 字符串路由到 PushPayloadAction
     *
     * 对应 iOS SharedNotificationManager.swift:247-277 locKey 分支路由
     * + NotificationService.swift:1098-1135
     *
     * 解密流程 defer（见文件头注释）：
     * 本函数接收的是已解密或未加密的 JSON 字符串。
     *
     * @param jsonStr 推送 payload JSON 字符串（明文，非 base64/加密）
     * @return PushPayloadAction 分发动作
     */
    public func routePayload(jsonStr: String): PushPayloadAction {
        Hilog.info(0, "CjTelegram", "[PushPayloadRouter] routePayload: parsing payload (len=${jsonStr.size})")
        let payload = parsePayloadJson(jsonStr)
        return this.dispatchAction(payload)
    }

    /**
     * 根据解析后的 PushPayload 分发动作
     */
    private func dispatchAction(payload: PushPayload): PushPayloadAction {
        match (payload.locKey) {
            case PushLocKey.SessionRevoke =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] SESSION_REVOKE => Logout")
                return PushPayloadAction.Logout

            case PushLocKey.PhoneCallRequest =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] PHONE_CALL_REQUEST => IncomingCall peerId=${payload.peerId()}")
                return PushPayloadAction.IncomingCall(payload.peerId())

            case PushLocKey.GeoLivePending =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] GEO_LIVE_PENDING => LocationPolling peerId=${payload.peerId()}")
                return PushPayloadAction.LocationPolling(payload.peerId())

            case PushLocKey.MessageMuted =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] MESSAGE_MUTED => PollState peerId=${payload.peerId()}")
                return PushPayloadAction.PollState(payload.peerId())

            case PushLocKey.MessageDeleted =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] MESSAGE_DELETED => DeleteMessages peerId=${payload.peerId()}")
                let ids = parseMessageIds(payload.messages, payload.msgId)
                return PushPayloadAction.DeleteMessages(payload.peerId(), ids)

            case PushLocKey.ReadHistory =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] READ_HISTORY => ReadMessages peerId=${payload.peerId()} maxId=${payload.msgId}")
                return PushPayloadAction.ReadMessages(payload.peerId(), payload.msgId)

            case PushLocKey.ReadReaction =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] READ_REACTION => ReadReactions peerId=${payload.peerId()}")
                let ids = parseMessageIds(payload.messages, payload.msgId)
                return PushPayloadAction.ReadReactions(payload.peerId(), ids)

            case PushLocKey.Unknown =>
                Hilog.info(0, "CjTelegram", "[PushPayloadRouter] Unknown loc-key, ignoring")
                return PushPayloadAction.Ignored
        }
    }

    /**
     * 解析 messages 字段（逗号分隔 message_id 列表）
     * 对应 iOS: messageIds.split(separator: ",") → [MessageId]
     */
    private func parseMessageIds(messagesStr: String, primaryId: Int32): ArrayList<Int64> {
        let result = ArrayList<Int64>()
        if (primaryId != 0) {
            result.add(Int64(primaryId))
        }
        if (messagesStr.size > 0) {
            let parts = messagesStr.split(",")
            for (part in parts) {
                let trimmed = part.trimAscii()
                if (trimmed.size > 0) {
                    try {
                        let n = Int64.parse(trimmed)
                        result.add(n)
                    } catch (_: Exception) {
                        Hilog.info(0, "CjTelegram", "[PushPayloadRouter] parseMessageIds: skip non-int '${trimmed}'")
                    }
                }
            }
        }
        return result
    }
}

// ==================== JSON parsing helper ====================

/**
 * 从推送 JSON payload 字符串解析 PushPayload
 *
 * 使用项目内 JsonParser（已在 JsonParser.cj 实现）。
 * 字段对照 iOS SharedNotificationManager.swift / NotificationService.swift:
 *   "loc-key"    → locKey
 *   "from_id"    → fromId   (user sender)
 *   "chat_id"    → chatId   (group)
 *   "channel_id" → channelId (channel)
 *   "msg_id"     → msgId
 *   "messages"   → messages (comma-separated ids for batch delete/read)
 */
private func parsePayloadJson(jsonStr: String): PushPayload {
    let payload = PushPayload()
    if (jsonStr.size == 0) {
        return payload
    }
    try {
        let obj = JsonParser.parseObject(jsonStr)
        let locKeyStr = obj.getString("loc-key")
        payload.locKey = PushPayloadRouter.parseLocKey(locKeyStr)
        let fromIdStr = obj.getString("from_id")
        if (fromIdStr.size > 0) {
            try {
                payload.fromId = Int64.parse(fromIdStr)
            } catch (_: Exception) {}
        }
        let chatIdStr = obj.getString("chat_id")
        if (chatIdStr.size > 0) {
            try {
                payload.chatId = Int64.parse(chatIdStr)
            } catch (_: Exception) {}
        }
        let channelIdStr = obj.getString("channel_id")
        if (channelIdStr.size > 0) {
            try {
                payload.channelId = Int64.parse(channelIdStr)
            } catch (_: Exception) {}
        }
        let msgIdStr = obj.getString("msg_id")
        if (msgIdStr.size > 0) {
            try {
                payload.msgId = Int32(Int64.parse(msgIdStr))
            } catch (_: Exception) {}
        }
        payload.messages = obj.getString("messages")
    } catch (e: Exception) {
        Hilog.info(0, "CjTelegram", "[PushPayloadRouter] parsePayloadJson failed: ${e}")
    }
    return payload
}

// ==================== Module-level router singleton ====================

private var _pushPayloadRouter: Option<PushPayloadRouter> = None

public func getPushPayloadRouter(): PushPayloadRouter {
    match (_pushPayloadRouter) {
        case Some(r) => return r
        case None =>
            let r = PushPayloadRouter()
            _pushPayloadRouter = Some(r)
            return r
    }
}
