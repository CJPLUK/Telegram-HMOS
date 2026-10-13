package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.{Chat, Message, PeerKey}
import ohos_app_cangjie_entry.interop.{callArkOnJSTask, INAPP_BANNER_SHOW}
import std.collection.HashMap
import std.sync.{AtomicBool, Monitor}

private let _applicationForeground = AtomicBool(true)

public func setApplicationForeground(value: Bool): Unit {
    _applicationForeground.store(value)
}

/** 应用是否在前台（AppState.onForeground/onBackground 维护）。 */
public func isApplicationForeground(): Bool {
    return _applicationForeground.load()
}

private var _notificationCoordinatorInstance: Option<NotificationCoordinator> = None
private let _notificationCoordinatorInstanceMonitor = Monitor()

public func getNotificationCoordinator(): NotificationCoordinator {
    return synchronized(_notificationCoordinatorInstanceMonitor) {
        match (_notificationCoordinatorInstance) {
            case Some(instance) => instance
            case None =>
                let instance = NotificationCoordinator()
                _notificationCoordinatorInstance = Some(instance)
                instance
        }
    }
}

/**
 * 从已提交消息派生系统通知。
 *
 * UpdatesManager 先写 MessageHistoryStore，再调用本服务。这里不解析 raw update，
 * 只做去重与展示决策，避免通知状态领先于消息/Chats 状态。
 */
public class NotificationCoordinator {
    private let _monitor = Monitor()
    private var _processed = HashMap<String, Bool>()
    private var _processedCount: Int64 = 0

    private func markFirst(key: String): Bool {
        return synchronized(this._monitor) {
            if (this._processed.contains(key)) { return false }
            // 有界会话级去重缓存；极端长会话达到上限后清空，服务端 messageId 仍保证近期去重。
            if (this._processedCount >= 4096) {
                this._processed = HashMap<String, Bool>()
                this._processedCount = 0
            }
            this._processed[key] = true
            this._processedCount += 1
            true
        }
    }

    private func findChat(peerKey: PeerKey): Option<Chat> {
        let snapshot = getChatListProjection().currentSnapshot()
        for (chat in snapshot.chats) {
            if (PeerKey.fromPeerType(chat.peerType, chat.id).equals(peerKey)) {
                return Some(chat)
            }
        }
        return None
    }

    public func handleIncomingCommitted(peerType: String, peerId: Int64, message: Message, outgoing: Bool): Unit {
        if (outgoing || message.id == 0) { return }
        let peerKey = PeerKey.fromPeerType(peerType, peerId)
        let dedupeKey = "${peerKey}:${message.id}"
        if (!this.markFirst(dedupeKey)) {
            Hilog.info(0, "CjTelegram", "[NotificationCoordinator] duplicate suppressed key=${dedupeKey}")
            return
        }
        let foreground = _applicationForeground.load()
        if (isConversationVisible(peerType, peerId)) {
            Hilog.info(0, "CjTelegram", "[NotificationCoordinator] visible peer suppressed key=${dedupeKey}")
            return
        }

        var peerName = message.senderName
        var muted = false
        match (this.findChat(peerKey)) {
            case Some(chat) =>
                muted = chat.isMuted
                if (!chat.name.isEmpty()) { peerName = chat.name }
            case None =>
                match (getPeerStore().getLocalPeer(peerId, peerType: peerKey.toPeerType())) {
                    case Some(peer) => if (!peer.name.isEmpty()) { peerName = peer.name }
                    case None => ()
                }
        }
        if (muted) {
            Hilog.info(0, "CjTelegram", "[NotificationCoordinator] muted peer suppressed key=${dedupeKey}")
            return
        }
        if (peerName.isEmpty()) { peerName = "Telegram" }
        if (foreground) {
            // S7-59: foreground → in-app banner instead of a system notification
            // (iOS ApplicationContext.swift:418-420: enqueue ChatMessageNotificationItem only when
            // InAppNotificationSettings.displayPreviews; the chat must not be visible).
            if (getTelegramCoreSettingsService().getInAppDisplayPreviews()) {
                this.showInAppBanner(peerType, peerId, peerKey, peerName, message)
            } else {
                Hilog.info(0, "CjTelegram", "[NotificationCoordinator] in-app preview disabled key=${dedupeKey}")
            }
            return
        }

        let badge = getBadgeService().getBadgeNumber()
        let _ = getLocalNotificationDisplayService().publishLocalNotification(
            peerName,
            message.content,
            "msg_${peerKey.namespace}_${peerId}_${message.id}",
            "message",
            badge,
            peerId: peerKey.toString(),
            navPeerId: peerId,
            navPeerType: peerKey.toPeerType(),
            navMessageId: message.id
        )
        Hilog.info(0, "CjTelegram", "[NotificationCoordinator] published key=${dedupeKey}")
    }

    private func showInAppBanner(peerType: String, peerId: Int64, peerKey: PeerKey, peerName: String, message: Message): Unit {
        // Title: private chat → peer; group/channel with an author → "author@group"
        // (ChatMessageNotificationItem.swift:140-170).
        var title = peerName
        if (peerType != "user" && message.senderName.size > 0 && message.senderName != peerName) {
            title = message.senderName + "@" + peerName
        }
        let text = if (message.content.size > 0) { message.content } else { message.mediaDescription }
        var avatarPath = ""
        var avatarColor: Int64 = 0x317AFF
        match (this.findChat(peerKey)) {
            case Some(chat) =>
                avatarPath = chat.avatarLocalPath
                avatarColor = chat.avatarColor
            case None => ()
        }
        if (avatarPath.isEmpty() && peerType == "user") {
            avatarPath = getUserPhotoService().getUserPhotoPath(peerId)
        }
        let letter = if (peerName.size > 0) { peerName.toRuneArray()[0].toString() } else { "" }
        let payload = "{\"title\":\"${bannerJsonEscape(title)}\",\"text\":\"${bannerJsonEscape(text)}\"," +
            "\"avatarPath\":\"${bannerJsonEscape(avatarPath)}\",\"avatarLetter\":\"${bannerJsonEscape(letter)}\"," +
            "\"avatarColor\":${avatarColor & 0xFFFFFF},\"peerId\":\"${peerId}\",\"peerType\":\"${peerKey.toPeerType()}\"," +
            "\"peerName\":\"${bannerJsonEscape(peerName)}\",\"msgId\":\"${message.id}\"}"
        callArkOnJSTask(INAPP_BANNER_SHOW, payload, { _r: String => })
        Hilog.info(0, "CjTelegram", "[NotificationCoordinator] in-app banner peer=${peerKey} msg=${message.id}")
    }

    public func handleReadCommitted(peerType: String, peerId: Int64, stillUnread: Int32): Unit {
        if (stillUnread != 0) { return }
        let peerKey = PeerKey.fromPeerType(peerType, peerId)
        getLocalNotificationDisplayService().cancelNotificationsForPeer(peerKey.toString())
        Hilog.info(0, "CjTelegram", "[NotificationCoordinator] cancelled peer=${peerKey}")
    }
}

private func bannerJsonEscape(value: String): String {
    return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
}
