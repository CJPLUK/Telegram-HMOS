package ohos_app_cangjie_entry.services

import kit.ArkUI.*
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*

/**
 * 草稿/回复/编辑/选择态的本地持久化数据载体
 */
public class ChatInterfaceStateData {
    public var chatId: Int64 = 0
    public var draftText: String = ""
    public var replyToMsgId: Int64 = 0
    public var replyToSenderName: String = ""
    public var replyToText: String = ""
    public var editingMsgId: Int64 = 0
    public var editingOriginalText: String = ""
    public var selectedMsgCount: Int32 = 0
}

/**
 * 聊天输入界面状态服务
 *
 * 对应 iOS ChatInterfaceState.swift (ChatInterfaceState class)
 *
 * 功能:
 * - 草稿/回复/编辑状态的本地持久化 (HarmonyOS Preferences)
 * - 服务端草稿同步 messages.saveDraft (真实 TL)
 * - 调用链: saveDraftToServer → getMTProtoClient().sendRequest(MessagesSaveDraft)
 */
public class ChatInterfaceStateService {
    private var preferences: Option<Preferences> = None
    private var initialized: Bool = false

    public func initialize(context: UIAbilityContext): Unit {
        try {
            let prefs = Preferences.getPreferences(context, "telegram_interface_state")
            this.preferences = Some(prefs)
            this.initialized = true
            Hilog.info(0, "CjTelegram", "[CISSvc] Initialized with Preferences")
        } catch (e: Exception) {
            this.initialized = true
            Hilog.info(0, "CjTelegram", "[CISSvc] Preferences init failed, memory only: ${e}")
        }
    }

    public func isInitialized(): Bool {
        return this.initialized
    }

    // ==================== 本地持久化 ====================

    /**
     * 加载指定 chatId 的界面状态（草稿/回复/编辑）
     */
    public func loadDraftState(chatId: Int64): ChatInterfaceStateData {
        let data = ChatInterfaceStateData()
        data.chatId = chatId
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let prefix = "cis_${chatId}_"
                    let draftVal = prefs.get(prefix + "draft", PreferencesValueType.StringData(""))
                    match (draftVal) {
                        case PreferencesValueType.StringData(s) => data.draftText = s
                        case _ => ()
                    }
                    let replyIdVal = prefs.get(prefix + "reply_id", PreferencesValueType.Integer(0))
                    match (replyIdVal) {
                        case PreferencesValueType.Integer(n) => data.replyToMsgId = n
                        case _ => ()
                    }
                    let replyNameVal = prefs.get(prefix + "reply_name", PreferencesValueType.StringData(""))
                    match (replyNameVal) {
                        case PreferencesValueType.StringData(s) => data.replyToSenderName = s
                        case _ => ()
                    }
                    let replyTextVal = prefs.get(prefix + "reply_text", PreferencesValueType.StringData(""))
                    match (replyTextVal) {
                        case PreferencesValueType.StringData(s) => data.replyToText = s
                        case _ => ()
                    }
                    let editIdVal = prefs.get(prefix + "edit_id", PreferencesValueType.Integer(0))
                    match (editIdVal) {
                        case PreferencesValueType.Integer(n) => data.editingMsgId = n
                        case _ => ()
                    }
                    let editTextVal = prefs.get(prefix + "edit_orig", PreferencesValueType.StringData(""))
                    match (editTextVal) {
                        case PreferencesValueType.StringData(s) => data.editingOriginalText = s
                        case _ => ()
                    }
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CISSvc] loadDraftState error: ${e}")
                }
            case None => ()
        }
        return data
    }

    /**
     * 保存草稿文本到本地 Preferences
     */
    public func saveDraftState(chatId: Int64, draftText: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let prefix = "cis_${chatId}_"
                    prefs.put(prefix + "draft", PreferencesValueType.StringData(draftText))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[CISSvc] Draft saved locally for chat ${chatId}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CISSvc] saveDraftState error: ${e}")
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[CISSvc] Preferences not ready, cannot save draft")
        }
    }

    /**
     * 设置回复状态并持久化
     */
    public func setReplyState(chatId: Int64, replyToMsgId: Int64, senderName: String, replyText: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let prefix = "cis_${chatId}_"
                    prefs.put(prefix + "reply_id", PreferencesValueType.Integer(replyToMsgId))
                    prefs.put(prefix + "reply_name", PreferencesValueType.StringData(senderName))
                    prefs.put(prefix + "reply_text", PreferencesValueType.StringData(replyText))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[CISSvc] Reply state saved for chat ${chatId}, msgId=${replyToMsgId}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CISSvc] setReplyState error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 设置编辑状态并持久化
     */
    public func setEditState(chatId: Int64, editingMsgId: Int64, originalText: String): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let prefix = "cis_${chatId}_"
                    prefs.put(prefix + "edit_id", PreferencesValueType.Integer(editingMsgId))
                    prefs.put(prefix + "edit_orig", PreferencesValueType.StringData(originalText))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[CISSvc] Edit state saved for chat ${chatId}, msgId=${editingMsgId}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CISSvc] setEditState error: ${e}")
                }
            case None => ()
        }
    }

    /**
     * 清除指定 chat 的所有界面状态（发送/取消回复后调用）
     */
    public func clearState(chatId: Int64): Unit {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let prefix = "cis_${chatId}_"
                    prefs.put(prefix + "draft", PreferencesValueType.StringData(""))
                    prefs.put(prefix + "reply_id", PreferencesValueType.Integer(0))
                    prefs.put(prefix + "reply_name", PreferencesValueType.StringData(""))
                    prefs.put(prefix + "reply_text", PreferencesValueType.StringData(""))
                    prefs.put(prefix + "edit_id", PreferencesValueType.Integer(0))
                    prefs.put(prefix + "edit_orig", PreferencesValueType.StringData(""))
                    prefs.flush()
                    Hilog.info(0, "CjTelegram", "[CISSvc] Cleared all state for chat ${chatId}")
                } catch (e: Exception) {
                    Hilog.info(0, "CjTelegram", "[CISSvc] clearState error: ${e}")
                }
            case None => ()
        }
    }

    // ==================== 服务端草稿同步 ====================

    /**
     * 将草稿同步到服务器 messages.saveDraft
     * 调用链: saveDraftToServer → getMTProtoClient().sendRequest(MessagesSaveDraft)
     *
     * peerType: "user" | "chat" | "channel"
     * peerId:   对端的 Telegram ID
     * replyToMsgId: 若正在回复则 > 0，否则传 0
     */
    public func saveDraftToServer(draftText: String, peerType: String, peerId: Int64, replyToMsgId: Int32): Unit {
        let capturedDraft = draftText
        let capturedPeerType = peerType
        let capturedPeerId = peerId
        let capturedReplyId = replyToMsgId
        let _ = spawn {
            try {
                let client = getMTProtoClient()
                let req = MessagesSaveDraft()
                req.message = capturedDraft
                req.replyToMsgId = capturedReplyId
                req.peer = buildInputPeer(capturedPeerType, capturedPeerId)
                let _ = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[CISSvc] saveDraftToServer OK, peer=${capturedPeerId}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CISSvc] saveDraftToServer error: ${e}")
            }
        }
    }

    /**
     * 清除服务端草稿（发送空草稿）
     */
    public func clearServerDraft(peerType: String, peerId: Int64): Unit {
        let capturedPeerType = peerType
        let capturedPeerId = peerId
        let _ = spawn {
            try {
                let client = getMTProtoClient()
                let req = MessagesSaveDraft()
                req.message = ""
                req.replyToMsgId = 0
                req.peer = buildInputPeer(capturedPeerType, capturedPeerId)
                let _ = client.sendRequest(req.toBytes())
                Hilog.info(0, "CjTelegram", "[CISSvc] clearServerDraft OK, peer=${capturedPeerId}")
            } catch (e: Exception) {
                Hilog.info(0, "CjTelegram", "[CISSvc] clearServerDraft error: ${e}")
            }
        }
    }

    // ==================== 内部辅助 ====================

    private func buildInputPeer(peerType: String, peerId: Int64): TLObject {
        if (peerType == "channel") {
            let p = InputPeerChannel()
            p.channelId = Int64(peerId)
            p.accessHash = 0
            return p
        } else if (peerType == "chat") {
            let p = InputPeerChat()
            p.chatId = Int64(peerId)
            return p
        } else {
            let p = InputPeerUser()
            p.userId = Int64(peerId)
            p.accessHash = 0
            return p
        }
    }
}

// ==================== 单例 ====================

private var _cisServiceInstance: Option<ChatInterfaceStateService> = None

public func getChatInterfaceStateService(): ChatInterfaceStateService {
    match (_cisServiceInstance) {
        case Some(svc) => return svc
        case None =>
            let svc = ChatInterfaceStateService()
            _cisServiceInstance = Some(svc)
            return svc
    }
}
