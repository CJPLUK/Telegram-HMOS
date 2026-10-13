package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.storage.postbox.*
import ohos_app_cangjie_entry.models.PeerKey
import std.sync.Monitor

/** PeerKey 感知的 ReadStateTable 桥接层。 */
private var _dialogReadStateStoreInstance: Option<DialogReadStateStore> = None
private let _dialogReadStateStoreInstanceMonitor = Monitor()

public func getDialogReadStateStore(): DialogReadStateStore {
    return synchronized(_dialogReadStateStoreInstanceMonitor) {
        match (_dialogReadStateStoreInstance) {
            case Some(instance) => instance
            case None =>
                let instance = DialogReadStateStore()
                _dialogReadStateStoreInstance = Some(instance)
                instance
        }
    }
}

public class DialogReadStateStore {
    private let table = ReadStateTable()

    private func storageId(peerType: String, peerId: Int64): Int64 {
        return PeerKey.fromPeerType(peerType, peerId).storageId()
    }

    public func applyIncomingMessage(peerType: String, peerId: Int64,
        countAsUnread: Bool): Unit {
        if (!countAsUnread) { return }
        try {
            let id = this.storageId(peerType, peerId)
            match (this.table.getReadState(id)) {
                case Some(state) =>
                    state.unreadCount += 1
                    this.table.setReadState(id, state)
                case None =>
                    this.table.setReadState(id, PeerReadState(unreadCount: 1))
            }
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DialogReadStateStore] incoming degraded: ${e}")
        }
    }

    public func applyIncomingRead(peerType: String, peerId: Int64, maxReadId: Int32,
        stillUnread: Int32): Unit {
        try {
            let id = this.storageId(peerType, peerId)
            let state = match (this.table.getReadState(id)) {
                case Some(existing) => existing
                case None => PeerReadState()
            }
            if (maxReadId > state.maxIncomingReadId) { state.maxIncomingReadId = maxReadId }
            state.unreadCount = stillUnread
            if (stillUnread == 0) { state.markedUnread = false }
            this.table.setReadState(id, state)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DialogReadStateStore] readInbox degraded: ${e}")
        }
    }

    public func applyOutgoingRead(peerType: String, peerId: Int64, maxReadId: Int32): Unit {
        try {
            this.table.applyOutgoingRead(this.storageId(peerType, peerId), maxReadId)
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[DialogReadStateStore] readOutbox degraded: ${e}")
        }
    }
}
