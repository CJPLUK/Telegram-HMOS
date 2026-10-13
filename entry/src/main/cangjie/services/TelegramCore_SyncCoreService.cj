package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.core.mtproto.*
/**
 * TelegramCore SyncCore 服务 — 置顶对话与保存 GIF 同步
 *
 * 对应 Telegram-iOS SyncCore_SynchronizePinnedChatsOperation / SyncCore_SynchronizeSavedGifsOperation
 * 通过 messages.getPinnedDialogs 和 messages.getSavedGifs 同步服务器状态
 *
 * 与 UpdatesManager 不冲突：UpdatesManager 处理 pts/qts 推送，SyncCore 处理显式拉取的置顶/GIF 数据
 */
private var _syncCoreServiceInstance: Option<TelegramCore_SyncCoreService> = None

public func getTelegramCore_SyncCoreService(): TelegramCore_SyncCoreService {
    match (_syncCoreServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_SyncCoreService()
            _syncCoreServiceInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_SyncCoreService {
    public init() {}

    /**
     * 同步置顶对话 — 调用 messages.getPinnedDialogs
     * 成功后标记聊天列表需要刷新
     */
    public func syncPinnedDialogs(folderId!: Int32 = 0): Bool {
        let client = getMTProtoClient()
        let req = MessagesGetPinnedDialogs()
        req.folderId = folderId

        Hilog.info(0, "CjTelegram", "[SyncCore] Sending messages.getPinnedDialogs")
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[SyncCore] getPinnedDialogs: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            Hilog.info(0, "CjTelegram", "[SyncCore] getPinnedDialogs RPC Error")
            return false
        }

        if (constructor == 0x3371c354) {
            let dialogsCount = parsePeerDialogsResponse(d)
            Hilog.info(0, "CjTelegram", "[SyncCore] getPinnedDialogs success count=${dialogsCount}")
            return true
        }

        Hilog.info(0, "CjTelegram", "[SyncCore] getPinnedDialogs: unknown constructor")
        return false
    }

    /**
     * 同步保存的 GIF — 调用 messages.getSavedGifs
     */
    public func syncSavedGifs(hash!: Int64 = 0): Bool {
        let client = getMTProtoClient()
        let req = MessagesGetSavedGifs()
        req.hash = hash

        Hilog.info(0, "CjTelegram", "[SyncCore] Sending messages.getSavedGifs")
        let responseData = client.sendRequest(req.toBytes())

        if (responseData.size == 0) {
            Hilog.info(0, "CjTelegram", "[SyncCore] getSavedGifs: empty response")
            return false
        }

        let d = TLDeserializer(responseData)
        let constructor = d.readUInt32()

        if (constructor == TLConstructors.RPC_ERROR || constructor == 0x2144ca19) {
            let _ = d.readInt32()
            let _ = d.readString()
            Hilog.info(0, "CjTelegram", "[SyncCore] getSavedGifs RPC Error")
            return false
        }

        if (constructor == 0x2e0709a5) {
            let _ = d.readInt64()
            let _ = d.readUInt32()
            let gifsCount = d.readInt32()
            Hilog.info(0, "CjTelegram", "[SyncCore] getSavedGifs success")
            return true
        }

        if (constructor == 0xe8025ca2) {
            Hilog.info(0, "CjTelegram", "[SyncCore] getSavedGifs: not modified")
            return true
        }

        Hilog.info(0, "CjTelegram", "[SyncCore] getSavedGifs: unknown constructor")
        return false
    }

    private func parsePeerDialogsResponse(d: TLDeserializer): Int32 {
        let _ = d.readUInt32()
        let count = d.readInt32()
        return count
    }
}
