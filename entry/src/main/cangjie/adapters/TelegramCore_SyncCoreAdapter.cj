package ohos_app_cangjie_entry.adapters

import ohos_app_cangjie_entry.services.{getTelegramCore_SyncCoreService}

/**
 * TelegramCore SyncCore 适配层 — 对外接口
 *
 * 对应 Telegram-iOS SyncCore 对外 API
 * 提供 syncPinnedChats() / syncSavedGifs() 简单接口，委托 TelegramCore_SyncCoreService 实现
 */
private var _adapterInstance: Option<TelegramCore_SyncCoreAdapter> = None

public func getTelegramCore_SyncCoreAdapter(): TelegramCore_SyncCoreAdapter {
    match (_adapterInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TelegramCore_SyncCoreAdapter()
            _adapterInstance = Some(inst)
            return inst
    }
}

public class TelegramCore_SyncCoreAdapter {
    public init() {}

    /**
     * 同步置顶聊天 — 委托 SyncCoreService.syncPinnedDialogs
     */
    public func syncPinnedChats(folderId!: Int32 = 0): Bool {
        return getTelegramCore_SyncCoreService().syncPinnedDialogs(folderId: folderId)
    }

    /**
     * 同步保存的 GIF — 委托 SyncCoreService.syncSavedGifs
     */
    public func syncSavedGifs(hash!: Int64 = 0): Bool {
        return getTelegramCore_SyncCoreService().syncSavedGifs(hash: hash)
    }
}
