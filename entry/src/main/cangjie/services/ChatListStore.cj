package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import ohos_app_cangjie_entry.models.*
import ohos_app_cangjie_entry.core.storage.postbox.*
import ohos_app_cangjie_entry.core.storage.getAuthStorage
import std.collection.ArrayList
import std.sync.*

/**
 * ChatListStore —— RealChatListService 与本地 Postbox 会话列表主表之间的桥接层。
 *
 * 单元 P2-288c：让网络拉到的会话列表落本地 ChatListTable，UI 优先读本地（命中即离线可读），
 * 不足 / 不可用再走网络。本类把"Chat ↔ ChatListTable"的存储细节集中在一处，避免散进服务层。
 *
 * 对照 iOS local-first 语义（Telegram-iOS Postbox：会话项先入库、会话列表视图优先从 Postbox 读、
 * 网络回源再回填），与本工程消息侧 MessageHistoryStore.cj 同一范式（强约束照搬）。
 *
 * DB open 容错（最高优先：不破坏现有可运行性）：
 *   工程当前未在启动期 open PostboxDatabase（main_ability 不 open postbox.db），
 *   故本类在首次用到时 lazy open（用 getGlobalAbilityContext() 拿 UIAbilityContext）。
 *   拿不到 context 或 open 抛异常时，所有本地操作安全降级为 no-op / 空结果——
 *   调用方（RealChatListService）据此回退纯网络路径，绝不让会话列表加载崩。
 *
 * 替换语义（对照 iOS ChatListTable.replace）：
 *   网络回源得到的是该 folder 当前**权威**会话列表快照。一个会话的 top message 变化会改变
 *   topMessageTimestamp、置顶变化会改变 pinningRank —— 两者都进 ChatListIndex 物理键，旧键 != 新键。
 *   若只 setEntry，旧键会残留、同一 peer 出现多条会话列表项。故 storeChats 在写新批次前，先把本地
 *   现存会话项按各自 chatListIndex() 逐个 removeEntry（清旧键），再逐条 setEntry 写新项——
 *   消除残留、保持"同 peer 只一条"。这与 MessageHistoryStore 的幂等覆盖目标一致，只是会话列表
 *   的键含时间/置顶维度，需要显式删旧。
 *
 * MTProto 说明（N/A）：本地持久化桥接，不涉及 MTProto 协议。
 */
public class ChatListStore {
    private let chatListTable: ChatListTable
    // storeChats 会同时来自 UI 线程（打开会话的已读提交）与网络线程（dialogs 回源 / 推送），
    // 串行化避免"清旧键 / 写新批"两段交错产生重复行。异步写按序号去重：排在更新快照之后
    // 才轮到的旧快照直接丢弃，落盘结果始终是最后一次提交的那份。
    private let _writeMonitor = Monitor()
    private var _writeSeq: Int64 = 0
    private var _writeApplied: Int64 = 0

    public init() {
        this.chatListTable = ChatListTable()
    }

    /**
     * 确保 PostboxDatabase 已 open。
     *
     * 已 open → true。未 open → 尝试用 getGlobalAbilityContext() 拿到的 UIAbilityContext
     * lazy open；context 不可用或 open 抛异常 → false（安全降级，调用方回退网络）。
     *
     * 与 MessageHistoryStore.ensureDbOpen 完全同范式（同一 globalAbilityContext + 同一单例 DB）。
     */
    private func ensureDbOpen(): Bool {
        let db = PostboxDatabase.getInstance()
        if (db.isOpen()) {
            return true
        }
        match (getGlobalAbilityContext()) {
            case Some(ctx) =>
                try {
                    db.open(ctx)
                    return db.isOpen()
                } catch (e: Exception) {
                    Hilog.error(0, "CjTelegram", "[ChatListStore] lazy open failed: ${e}")
                    return false
                }
            case None =>
                Hilog.info(0, "CjTelegram", "[ChatListStore] no ability context, degrade to network")
                return false
        }
    }

    /**
     * 把一批网络回源得到的 Chat 列表落本地表（权威快照全量替换）。
     *
     * 步骤：
     *   1. 读出本地现存全部会话项（listChats(0)），按各自 chatListIndex() 逐个 removeEntry 清旧键
     *      —— 避免会话 top message / 置顶变化后旧键残留导致同 peer 多条。
     *   2. 逐条 ChatListEntry.fromChat(chat, pinningRank) -> replaceEntry 写新项。
     *      置顶会话按其在列表中的置顶序传 pinningRank（0,1,2…）；未置顶由 fromChat 写哨兵。
     *
     * 幂等：连续两次写同一批，结果一致（先清旧再写新）。
     * DB 不可用时静默 no-op（不抛、不崩）。
     *
     * @param chats 网络回源、已 parse + 已排序（置顶在前）的 Chat 列表
     */
    public func storeChats(chats: ArrayList<Chat>): Unit {
        synchronized(this._writeMonitor) {
            this._writeSeq += 1
            this._writeApplied = this._writeSeq
            this.storeChatsLocked(chats)
        }
    }

    /**
     * storeChats 的异步版：在调用线程拷贝快照（Chat.copy()，UI 线程随后改字段不会串进落盘），
     * RDB 清旧 / 写新在后台线程执行。打开会话的已读提交等 UI 线程路径用它，落盘不再挡在
     * 导航与首帧前面（实测同步版一次 ≈15ms，且开一个会话要跑两三次）。
     * 若排到它之前已有更新的快照落盘（同步或异步），本次过期快照直接丢弃。
     */
    public func storeChatsAsync(chats: ArrayList<Chat>): Unit {
        let snapshot = ArrayList<Chat>()
        for (chat in chats) { snapshot.add(chat.copy()) }
        let seq = synchronized(this._writeMonitor) {
            this._writeSeq += 1
            this._writeSeq
        }
        let _ = spawn {
            synchronized(this._writeMonitor) {
                if (seq > this._writeApplied) {
                    this._writeApplied = seq
                    this.storeChatsLocked(snapshot)
                } else {
                    Hilog.info(0, "CjTelegram", "[ChatListStore] async snapshot seq=${seq} superseded by ${this._writeApplied}, skipped")
                }
            }
        }
    }

    /** 持有 _writeMonitor 时调用。 */
    private func storeChatsLocked(chats: ArrayList<Chat>): Unit {
        if (!this.ensureDbOpen()) {
            return
        }
        try {
            // Step 1: 清旧键（按现存项各自的物理索引删除）
            let existing = this.chatListTable.listChats(0)
            for (old in existing) {
                this.chatListTable.removeEntry(old.chatListIndex())
                // 兼容清理升级前 user/chat/channel 共用正数 id 的旧物理键。
                this.chatListTable.removeEntry(old.legacyChatListIndex())
            }
            // Step 2: 写新批次（旧键已在 Step 1 清空，直接 setEntry 写新项）。
            // 置顶项按出现顺序分配递增 pinningRank。
            var pinRank: Int32 = 0
            for (chat in chats) {
                if (chat.isPinned) {
                    let item = IntermediateChatListItem.fromChat(chat, pinningRank: pinRank)
                    this.chatListTable.setEntry(item)
                    pinRank += 1
                } else {
                    let item = IntermediateChatListItem.fromChat(chat)
                    this.chatListTable.setEntry(item)
                }
            }
            // ChatListTable 全账号共用：记录本批权威快照归属的账号，切换账号后另一账号
            // 的缓存行不再作为首屏 / 启动基线（loadLocalChats 按 owner 过滤）。
            let ownerSlot = getAuthStorage().getActiveSlot()
            getAuthStorage().setChatListCacheOwnerSlot(ownerSlot)
            Hilog.info(0, "CjTelegram", "[ChatListStore] stored ${chats.size} chats (cleared ${existing.size} old) owner slot=${ownerSlot}")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[ChatListStore] storeChats failed: ${e}")
        }
    }

    /**
     * 本地优先读：取本地会话列表（已按"置顶在前、同档最新在前"物理有序），命中即可离线返回。
     *
     * - listChats(limit)：升序扫描全表，键编码保证顺序，无需内存再排序。
     * - 每个 IntermediateChatListItem.toChat() 回填本落盘项承载的字段
     *   （id / lastMessageTimestamp / unreadCount / isPinned / isMuted）以及显示字段
     *   （name / lastMessage / avatarText / draftText / username / isGroup / isChannel /
     *   isMegagroup，P2-288d 起持久化）。离线会话列表条目因此能直接显示名字 + 预览 + 头像文字。
     *   本地优先读用于"离线时可看到可用的会话列表"，UI 一旦联网刷新即被网络权威数据整体替换。
     *
     * DB 不可用 / 异常 → 返回空（调用方回退网络）。
     *
     * @param limit 最多返回会话数；<= 0 表示不限
     * @return 本地命中的 Chat 列表（物理有序）；空表示未命中 / 需回退网络
     */
    public func loadLocalChats(limit: Int64): ArrayList<Chat> {
        let result = ArrayList<Chat>()
        let ownerSlot = getAuthStorage().getChatListCacheOwnerSlot()
        let activeSlot = getAuthStorage().getActiveSlot()
        if (ownerSlot >= 0 && ownerSlot != activeSlot) {
            Hilog.info(0, "CjTelegram",
                "[ChatListStore] local cache owned by slot=${ownerSlot}, active slot=${activeSlot} → skipped")
            return result
        }
        if (!this.ensureDbOpen()) {
            return result
        }
        try {
            let items = this.chatListTable.listChats(limit)
            for (item in items) {
                result.add(item.toChat())
            }
            Hilog.info(0, "CjTelegram", "[ChatListStore] local hit ${result.size} chats (limit=${limit})")
        } catch (e: Exception) {
            Hilog.error(0, "CjTelegram", "[ChatListStore] loadLocalChats failed: ${e}")
            return ArrayList<Chat>()
        }
        return result
    }
}

// ==================== 单例访问器 ====================

private var _chatListStoreInstance: Option<ChatListStore> = None

public func getChatListStore(): ChatListStore {
    match (_chatListStoreInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ChatListStore()
            _chatListStoreInstance = Some(inst)
            return inst
    }
}
