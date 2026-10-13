package ohos_app_cangjie_entry.core.storage.postbox

import std.collection.ArrayList

/**
 * ChatListTable —— 会话列表主表（离线会话列表的存储核心）。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/ChatListTable.swift
 *   - 每个会话项以 `ChatListIndex -> 编码字节` 落库；物理键 = ChatListIndex 复合键
 *     （[pinningRank:4][invertedTimestamp:4][peerId:8] 16 字节大端键，字节序==逻辑序）；
 *     物理值 = IntermediateChatListItem 序列化字节。
 *   - replace(...)：同一会话 top message 变化时，旧 ChatListIndex（含旧 timestamp）的键变了，
 *     必须先删旧键再写新键，避免同一 peer 残留多条会话列表项。本类提供 replaceEntry 实现该语义。
 *
 * 本单元建在已合入 master 的 DB 底座 + ChatListEntry.cj 之上：
 *   - 键编码复用 ChatListIndex.key()（big-endian 复合键，升序扫描天然得到「置顶在前、同档最新在前」）；
 *   - 值编码复用 IntermediateChatListItem.encode(PostboxEncoder) / decode(PostboxDecoder)；
 *   - 全表区间复用 ChatListIndex.lowerBound() / upperBound()；
 *   - 表 id 由 TableRegistry.CHAT_LIST_TABLE_ID 集中分配（=102，≥100 业务段，不撞 100/101）。
 *
 * 表封装范式严格复用 MessageHistoryTable.cj：持有 ValueBoxTable(id, BinaryKey) + ValueBox，
 *   encode 成 value 字节落库，range 收集结果进一个 `let` ArrayList（引用被闭包捕获、内容可变；
 *   KB「闭包不得捕获本地 var」约束下的标准范式）。
 *
 * 范围说明：本单元只做 set/get/remove/有序 list/replace 五件核心存储操作（建在 ValueBox 上）；
 *   归档分区 / 视图推送 / draft / tags 等是后续单元职责，本文件不碰
 *   （归档在 Chat 模型补 archived 字段后再接，见 ChatListEntry.cj 文件头说明）。
 *
 * MTProto 说明（N/A）：本地持久化会话列表主表，不涉及 MTProto 协议。
 */
public class ChatListTable {
    // 本表的逻辑描述符：二进制复合键（ChatListIndex 16 字节大端键），值是 BLOB。
    private let table: ValueBoxTable
    // 底层通用 KV 引擎（复用进程内单例，与 PostboxDatabase 同一 RDB 连接）。
    private let valueBox: ValueBox

    /**
     * 用进程内单例 ValueBox（RdbValueBox）构造（推荐路径）。
     * 表描述符固定为 (CHAT_LIST_TABLE_ID, BinaryKey)。
     */
    public init() {
        this.table = ValueBoxTable(
            id: TableRegistry.CHAT_LIST_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = RdbValueBox.getInstance()
    }

    /**
     * 注入式构造（测试 / 自定义 ValueBox 实现时使用）。
     */
    public init(valueBox: ValueBox) {
        this.table = ValueBoxTable(
            id: TableRegistry.CHAT_LIST_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = valueBox
    }

    /**
     * 把一条 IntermediateChatListItem 编码成落库值字节：
     *   new PostboxEncoder -> item.encode(encoder) -> encoder.makeBytes()。
     * 与 MessageHistoryTable.encodeValue 同范式。
     */
    private static func encodeValue(item: IntermediateChatListItem): Array<Byte> {
        let encoder = PostboxEncoder()
        item.encode(encoder)
        return encoder.makeBytes()
    }

    /**
     * 把落库值字节解码回 IntermediateChatListItem：
     *   new PostboxDecoder(bytes) -> IntermediateChatListItem.decode。
     */
    private static func decodeValue(bytes: Array<Byte>): IntermediateChatListItem {
        return IntermediateChatListItem.decode(PostboxDecoder(bytes))
    }

    /**
     * 写入 / 覆盖一个会话列表项（对应 iOS 把一个会话项落进 ChatListTable）。
     *
     * 键 = item.chatListIndex().key()（含 pinningRank + topMessageTimestamp + peerId）；
     * 值 = encode(item)。INSERT OR REPLACE 语义：同键（同 rank/同 ts/同 peer）覆盖。
     *
     * 注意：若一个会话的 top message 变化（timestamp 变）或置顶状态变（pinningRank 变），
     * 其 ChatListIndex 键也变 —— 直接 setEntry 会写出新键、而旧键残留。需要「同 peer 只保留
     * 一条」语义时应改用 replaceEntry（先删旧键再写新键）。
     */
    public func setEntry(item: IntermediateChatListItem): Unit {
        let key = item.chatListIndex().key()
        let value = ChatListTable.encodeValue(item)
        this.valueBox.set(this.table, key, value)
    }

    /**
     * 按完整 ChatListIndex 取单个会话项（对应 iOS 按索引精确取）。
     * 命中：valueBox.get -> 字节 -> decode -> Some；未命中：None。
     */
    public func getEntry(index: ChatListIndex): Option<IntermediateChatListItem> {
        let key = index.key()
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) => return Some(ChatListTable.decodeValue(bytes))
            case None => return None
        }
    }

    /**
     * 按完整 ChatListIndex 删除单个会话项（对应 iOS remove）。
     * 不存在的键 remove 无副作用。
     */
    public func removeEntry(index: ChatListIndex): Unit {
        this.valueBox.remove(this.table, index.key())
    }

    /**
     * 单个会话项是否存在（按完整 ChatListIndex）。
     */
    public func containsEntry(index: ChatListIndex): Bool {
        return this.valueBox.exists(this.table, index.key())
    }

    /**
     * 全表会话列表（对应 iOS 会话列表枚举）：升序扫描全表区间 [lowerBound, upperBound)，
     * 取 limit 条，返回**有序**会话项。
     *
     * 有序性怎么保证（核心）：物理键 ChatListIndex.key() 布局为
     *   [pinningRank:4][invertedTimestamp:4][peerId:8]（大端、字节序==逻辑序），其中
     *   invertedTimestamp = TIMESTAMP_MAX - timestamp。于是单纯的「升序字节扫描」天然产出：
     *     ① pinningRank 升序 —— 置顶项 rank 小（0,1,2…）排前；未置顶项 rank=哨兵 Int32.max 排最后
     *        => 「置顶在前」；
     *     ② 同档内 invertedTimestamp 升序 == timestamp 降序 => 「最新在前」；
     *     ③ 时间相同按 peerId 升序稳定排序。
     *   因此本方法只需把既有的升序 [lowerBound, upperBound) 扫描结果原样收集即可，
     *   无需在内存里再排序（顺序已由键编码保证，见 ChatListEntry.cj 键布局说明）。
     *
     * limit <= 0 表示不限条数（透传给 valueBox.range 的 limit 语义）。
     * 收集范式：结果收进一个 `let` ArrayList（引用被闭包捕获、内容可变），回调恒返回 true，
     *   靠 range 的 limit（SQL LIMIT）早停 —— 与 MessageHistoryTable.messagesForPeer 一致。
     */
    public func listChats(limit: Int64): Array<IntermediateChatListItem> {
        let lower = ChatListIndex.lowerBound()
        let upper = ChatListIndex.upperBound()
        let collected = ArrayList<IntermediateChatListItem>()
        this.valueBox.rangeValues(this.table, lower, upper, limit, { _, v =>
            collected.add(ChatListTable.decodeValue(v))
            return true
        })
        return ChatListTable.toArray(collected)
    }

    /**
     * 替换一个会话项（对应 iOS ChatListTable.replace 语义）：先删旧索引对应的键、再写新项。
     *
     * 为什么需要：同一会话的 top message 变化会改变 topMessageTimestamp，置顶状态变化会改变
     * pinningRank —— 两者都进入 ChatListIndex 键，导致旧键 != 新键。若只 setEntry，旧键会残留，
     * 同一 peer 出现多条会话列表项。replaceEntry 显式「删旧 + 写新」消除残留。
     *
     * @param oldIndex 旧的 ChatListIndex（该会话上一次落库时的键）。None 表示该会话此前无旧项
     *                 （首次写入，无需删旧）。
     * @param newItem  本次要写入的会话项。
     *
     * 边界：若 oldIndex 与 newItem.chatListIndex() 恰好相同（rank/ts/peer 都没变），先删后写
     * 等价于纯覆盖，结果一致、无害。
     */
    public func replaceEntry(oldIndex: Option<ChatListIndex>, newItem: IntermediateChatListItem): Unit {
        match (oldIndex) {
            case Some(idx) => this.removeEntry(idx)
            case None => ()
        }
        this.setEntry(newItem)
    }

    /**
     * 收集容器 ArrayList 物化成 Array（保持原顺序）。与 MessageHistoryTable.toArray 同范式
     * （Array 固定长度构造需要元素工厂，用一个占位项填充后逐位覆盖）。
     */
    private static func toArray(list: ArrayList<IntermediateChatListItem>): Array<IntermediateChatListItem> {
        let n = list.size
        let arr = Array<IntermediateChatListItem>(n, { _ => ChatListTable.seedItem() })
        for (i in 0..n) {
            arr[i] = list[i]
        }
        return arr
    }

    /**
     * Array 固定长度构造所需的种子元素（随即被逐位覆盖，不参与逻辑）。
     */
    private static func seedItem(): IntermediateChatListItem {
        return IntermediateChatListItem(
            peerId: 0,
            topMessageId: 0,
            topMessageTimestamp: 0,
            pinningRank: IntermediateChatListItem.PINNING_RANK_UNPINNED,
            unreadCount: 0,
            flags: 0
        )
    }

    /**
     * 自检（验收项②③）：需要一个「已 open 的 PostboxDatabase（真实 RDB）」，
     * 因此只在设备 / 集成诊断时显式调用，不在 app 主流程自动运行
     * （与 MessageHistoryTable.selfCheck / ValueBoxKey.selfCheck 的定位一致）。
     *
     * 用本表（CHAT_LIST_TABLE_ID）插入若干会话（含置顶/非置顶/不同时间）后验证：
     *   ② setEntry -> getEntry 往返字段相等；removeEntry 后 getEntry 返 None；
     *   ③ listChats 有序：置顶在前、同档最新在前；limit 截断生效；
     *      replaceEntry 删旧加新后同 peer 不残留多键。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        // 会话集合（peerId 唯一）：
        //   置顶 rank=0：peer=10, ts=500
        //   置顶 rank=1：peer=11, ts=999（rank 大于 peer10 故排其后，尽管 ts 更大）
        //   未置顶：peer=20, ts=3000（最新）
        //   未置顶：peer=21, ts=2000
        //   未置顶：peer=22, ts=1000（最旧）
        let pinned0 = ChatListTable.makeItem(10, 500, 0, 1)
        let pinned1 = ChatListTable.makeItem(11, 999, 1, 0)
        let unNew = ChatListTable.makeItem(20, 3000, IntermediateChatListItem.PINNING_RANK_UNPINNED, 2)
        let unMid = ChatListTable.makeItem(21, 2000, IntermediateChatListItem.PINNING_RANK_UNPINNED, 0)
        let unOld = ChatListTable.makeItem(22, 1000, IntermediateChatListItem.PINNING_RANK_UNPINNED, 5)

        let allItems = [pinned0, pinned1, unNew, unMid, unOld]

        // 清场：先删全部（避免上一轮残留）
        for (it in allItems) {
            this.removeEntry(it.chatListIndex())
        }

        // ② setEntry -> getEntry 往返
        for (it in allItems) {
            this.setEntry(it)
        }
        match (this.getEntry(unNew.chatListIndex())) {
            case Some(got) =>
                if (got.peerId != 20 || got.topMessageTimestamp != 3000) { return false }
                if (got.unreadCount != 2) { return false }
                if (got.isPinned()) { return false }
            case None => return false
        }
        match (this.getEntry(pinned0.chatListIndex())) {
            case Some(got) =>
                if (got.peerId != 10 || got.pinningRank != 0) { return false }
                if (!got.isPinned()) { return false }
            case None => return false
        }
        // 不存在的索引返 None
        let absent = ChatListIndex(pinningRank: 0, timestamp: 1, peerId: 9999)
        match (this.getEntry(absent)) {
            case Some(_) => return false
            case None => ()
        }

        // ③ listChats 有序：期望顺序
        //   [peer10(rank0), peer11(rank1), peer20(ts3000), peer21(ts2000), peer22(ts1000)]
        let listed = this.listChats(0)
        if (listed.size != 5) { return false }
        let expectedPeers = [10, 11, 20, 21, 22]
        for (i in 0..5) {
            if (listed[i].peerId != Int64(expectedPeers[i])) { return false }
        }

        // limit 截断：取前 3 条 = peer10, peer11, peer20
        let top3 = this.listChats(3)
        if (top3.size != 3) { return false }
        if (top3[0].peerId != 10 || top3[1].peerId != 11 || top3[2].peerId != 20) { return false }

        // ③ replaceEntry：把 peer22（未置顶, ts=1000）替换为「ts=5000 的最新项」。
        //   旧键基于 ts=1000，新键基于 ts=5000，键不同；replaceEntry 应删旧写新，同 peer 不残留。
        let oldIdx = unOld.chatListIndex()
        let newUnOld = ChatListTable.makeItem(22, 5000, IntermediateChatListItem.PINNING_RANK_UNPINNED, 5)
        this.replaceEntry(Some(oldIdx), newUnOld)
        // 旧键应已删除
        match (this.getEntry(oldIdx)) {
            case Some(_) => return false
            case None => ()
        }
        // 列表仍是 5 条（没有因 replace 多出残留键）
        let afterReplace = this.listChats(0)
        if (afterReplace.size != 5) { return false }
        // peer22 现在 ts=5000，成为未置顶档最新，应排在所有未置顶之前
        //   期望顺序：[peer10, peer11, peer22(5000), peer20(3000), peer21(2000)]
        let expectedAfter = [10, 11, 22, 20, 21]
        for (i in 0..5) {
            if (afterReplace[i].peerId != Int64(expectedAfter[i])) { return false }
        }
        // 同 peer22 只剩一条：用旧 ts=1000 的键取不到，用新 ts=5000 的键能取到
        match (this.getEntry(newUnOld.chatListIndex())) {
            case Some(got) => if (got.topMessageTimestamp != 5000) { return false }
            case None => return false
        }

        // ② removeEntry 后空：删全部，listChats 应为空
        for (it in [pinned0, pinned1, unNew, unMid, newUnOld]) {
            this.removeEntry(it.chatListIndex())
        }
        if (this.listChats(0).size != 0) { return false }
        if (this.containsEntry(pinned0.chatListIndex())) { return false }

        return true
    }

    /**
     * selfCheck 辅助：构造一个会话列表项。
     */
    private static func makeItem(peerId: Int64, timestamp: Int32, pinningRank: Int32,
        unreadCount: Int32): IntermediateChatListItem {
        return IntermediateChatListItem(
            peerId: peerId,
            topMessageId: 0,
            topMessageTimestamp: timestamp,
            pinningRank: pinningRank,
            unreadCount: unreadCount,
            flags: 0
        )
    }
}
