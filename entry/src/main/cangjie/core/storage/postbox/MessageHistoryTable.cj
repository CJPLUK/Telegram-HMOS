package ohos_app_cangjie_entry.core.storage.postbox

import std.collection.ArrayList
import std.collection.HashSet

/**
 * MessageHistoryTable —— 消息历史主表（消息按 MessageIndex 复合键存，值是
 * IntermediateMessage 的 PostboxEncoder 编码字节）。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/MessageHistoryTable.swift
 *   - tableSpec(id) —— 每条消息以 `MessageIndex -> IntermediateMessage 编码字节` 落库；
 *     物理键 = `key(index)`（[peerId:8][namespace:4][timestamp:4][id:4] 大端复合键），
 *     物理值 = IntermediateMessage 序列化字节。
 *   - addMessages / getMessage / removeMessages 是其增删查的核心入口。
 *
 * 本单元在已合入 master 的 ValueBox KV 引擎（RdbValueBox）上落「消息主表」这一层：
 *   - 键编码复用 MessageIndex.key()（big-endian 复合键，字节序==逻辑序，供后续范围扫描）；
 *   - 值编码复用 IntermediateMessage.encode(PostboxEncoder) / decode(PostboxDecoder)；
 *   - 表 id 由 TableRegistry.MESSAGE_HISTORY_TABLE_ID 集中分配（≥100 业务段，不撞 METADATA=0）。
 *
 * 与 iOS 的差异（同源约束）：
 *   - getMessage(peerId, namespace, id)（无 timestamp）在 iOS 由 MessageHistoryIndexTable
 *     提供 (peer,ns,id) -> timestamp 的二级索引直接定位。本单元尚无该索引表（属后续 e 单元
 *     IndexTable 职责），故先用 `range((peer,ns) 下界, 上界)` 扫描该会话该命名空间的全部消息、
 *     逐条 extractKey 比对 id 命中即返回。后续 IndexTable 落地后此扫描可被 O(1) 定位取代。
 *
 * 范围说明：本单元只做 add/get/remove 三件核心存储操作（建在 ValueBox 上）；分页 / 二级索引 /
 *   tags / 视图推送等是后续单元职责，本文件不碰。
 *
 * MTProto 说明（N/A）：本地持久化消息主表，不涉及 MTProto 协议。
 */
public class MessageHistoryTable {
    // 本表的逻辑描述符：二进制复合键（MessageIndex 20 字节大端键），值是 BLOB。
    private let table: ValueBoxTable
    // 底层通用 KV 引擎（复用进程内单例，与 PostboxDatabase 同一 RDB 连接）。
    private let valueBox: ValueBox

    /**
     * 用进程内单例 ValueBox（RdbValueBox）构造（推荐路径）。
     * 表描述符固定为 (MESSAGE_HISTORY_TABLE_ID, BinaryKey)。
     */
    public init() {
        this.table = ValueBoxTable(
            id: TableRegistry.MESSAGE_HISTORY_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = RdbValueBox.getInstance()
    }

    /**
     * 注入式构造（测试 / 自定义 ValueBox 实现时使用）。
     */
    public init(valueBox: ValueBox) {
        this.table = ValueBoxTable(
            id: TableRegistry.MESSAGE_HISTORY_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = valueBox
    }

    /**
     * 从一条 IntermediateMessage 取其物理键所用的 MessageIndex。
     *
     * IntermediateMessage 的 id/timestamp 是 Int64（落盘宽类型），而 MessageIndex 的
     * id/timestamp 是 Int32（与 iOS 20 字节键布局的 4 字节段对齐）。这里做显式窄化转换，
     * 与 iOS 的 MessageId.Id（Int32）/ timestamp（Int32）键段一致。
     */
    private static func indexOf(im: IntermediateMessage): MessageIndex {
        return MessageIndex(
            peerId: im.peerId,
            namespace: im.namespace,
            timestamp: Int32(im.timestamp),
            id: Int32(im.id)
        )
    }

    /**
     * 把一条 IntermediateMessage 编码成落库值字节：
     *   new PostboxEncoder -> im.encode(encoder) -> encoder.makeBytes()。
     */
    private static func encodeValue(im: IntermediateMessage): Array<Byte> {
        let encoder = PostboxEncoder()
        im.encode(encoder)
        return encoder.makeBytes()
    }

    /**
     * 把落库值字节解码回 IntermediateMessage：
     *   new PostboxDecoder(bytes) -> IntermediateMessage.decode。
     */
    private static func decodeValue(bytes: Array<Byte>): IntermediateMessage {
        return IntermediateMessage.decode(PostboxDecoder(bytes))
    }

    /**
     * 批量写入消息（对应 iOS addMessages）。逐条把
     * `MessageIndex.key()` 作键、`encode(im)` 作值 set 进表（INSERT OR REPLACE 语义，
     * 同键覆盖，与 iOS 的 justInsertMessage 落库一致）。
     *
     * 注：本方法本身不开事务（单条 set 各自原子）；调用方若要「一组写要么全成要么全滚」，
     * 用 addMessagesInTransaction（包 PostboxTransaction）。
     */
    public func addMessages(messages: Array<IntermediateMessage>): Unit {
        for (im in messages) {
            let index = MessageHistoryTable.indexOf(im)
            let key = index.key()
            let value = MessageHistoryTable.encodeValue(im)
            this.valueBox.set(this.table, key, value)
        }
    }

    /**
     * 批量写入消息（事务版）：把整批 set 包在一个 PostboxTransaction 内，
     * 任一条失败则整批回滚（对应 iOS 把一组写包在 begin/commit 之间）。
     */
    public func addMessagesInTransaction(messages: Array<IntermediateMessage>): Unit {
        let txn = PostboxTransaction.getInstance()
        txn.withTransaction<Unit>({ =>
            this.addMessages(messages)
        })
    }

    /**
     * 按完整 MessageIndex 取单条消息（对应 iOS getMessage(index)）。
     * 命中：valueBox.get -> 字节 -> decode -> Some；未命中：None。
     */
    public func getMessage(index: MessageIndex): Option<IntermediateMessage> {
        let key = index.key()
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) => return Some(MessageHistoryTable.decodeValue(bytes))
            case None => return None
        }
    }

    /**
     * 按 (peerId, namespace, id) 取单条消息（无 timestamp，对应 iOS 经索引表的 getMessage）。
     *
     * 本单元尚无 (peer,ns,id) -> timestamp 二级索引（属后续 IndexTable 单元），故在该
     * (peer,ns) 区间内做范围扫描：lowerBound..upperBound 半开区间覆盖该会话该命名空间的
     * 全部键；逐条 extractKey 比对 id，命中即返回。后续 IndexTable 落地后此扫描可被 O(1) 取代。
     *
     * 注意：范围扫描走「带值」的 rangeValues —— 命中后直接拿到 value 字节解码，避免命中后
     * 再二次 get 一次。结果收集进一个 `let` ArrayList（其引用被闭包捕获，内容可变），
     * 命中即把回调返回 false 早停（KB「闭包不得捕获本地 var」约束下的标准收集范式，
     * 与 RdbValueBox.selfCheck 的 collected.add(...) 一致）。
     */
    public func getMessage(peerId: Int64, namespace: Int32, id: Int32): Option<IntermediateMessage> {
        let lower = MessageIndex.lowerBound(peerId: peerId, namespace: namespace)
        let upper = MessageIndex.upperBound(peerId: peerId, namespace: namespace)
        // range 是「开-开」区间 (key > start AND key < end)；lower 段长度 12 短于任意
        // 20 字节成员键、且为其前缀，故 lower < 成员键成立（lower 必被排除，但它本就不是
        // 任何真实消息键，排除无害）；upper = lower.successor() 同样不是真实键。半开覆盖成立。
        let hits = ArrayList<IntermediateMessage>()
        this.valueBox.rangeValues(this.table, lower, upper, 0, { k, v =>
            let idx = MessageIndex.extractKey(k)
            if (idx.id == id) {
                hits.add(MessageHistoryTable.decodeValue(v))
                return false  // 命中即停
            }
            return true
        })
        if (hits.size > 0) {
            return Some(hits[0])
        }
        return None
    }

    /**
     * 批量删除消息（对应 iOS removeMessages）。逐条按 `MessageIndex.key()` remove；
     * 不存在的键 remove 无副作用（与 iOS 一致）。
     */
    public func removeMessages(indices: Array<MessageIndex>): Unit {
        for (index in indices) {
            let key = index.key()
            this.valueBox.remove(this.table, key)
        }
    }

    /**
     * 单条消息是否存在（按完整 MessageIndex）。
     */
    public func containsMessage(index: MessageIndex): Bool {
        return this.valueBox.exists(this.table, index.key())
    }

    // ==================== 分页 / 范围查询（对应 iOS getMessagesAround / earlierEntries / laterEntries）====================
    //
    // iOS 标尺：MessageHistoryTable.swift 的 `getMessagesAround(...)`（围绕某 index 取上下窗口）、
    //   `earlierEntries(id:peerId:namespace:..., count:)` / `laterEntries(...)`（以某 index 为界向前/后取 count）。
    //
    // 物理顺序复用 MessageIndex.key() 的 20 字节大端复合键：同一 (peer,namespace) 下键按
    //   timestamp 升序、再 id 升序 —— 即「时间正序」。因此所有「时间序」遍历都直接落到键字节序上，
    //   交给 valueBox.rangeValues 的开-开区间扫描，无需在内存里再排序。
    //
    // 收集范式严格复用本类 getMessage(peer,ns,id) 已验证的写法：结果收进一个 `let` ArrayList
    //   （引用被闭包捕获、内容可变；KB「闭包不得捕获本地 var」约束下的标准范式），rangeValues 的
    //   limit 控制条数、回调恒返回 true（靠 SQL LIMIT 早停，与 RdbValueBox.scanRangeImpl 对齐）。
    //
    // 关于 rangeValues 的方向（实证自 ValueBox.cj / RdbValueBox.scanRangeImpl）：
    //   区间是「开-开」(key > lo AND key < hi)；start < end → 升序，start > end → 降序（内部交换边界）。
    //   故「取某键之前的 N 条」用降序 range(start=该键, end=下界)（拿到的是「最靠近且 < 该键」的 count 条，
    //   但顺序是降序，需反转回时间正序）；「取某键之后的 N 条」用升序 range(start=该键, end=上界)。

    /**
     * 取某 (peerId, namespace) 会话该命名空间的最早 limit 条消息，按时间正序返回
     * （对应 iOS 以会话维度的有界时间序读取）。
     *
     * 升序扫描开-开区间 (lowerBound, upperBound)：lowerBound（12 字节前缀）严格小于该 (peer,ns) 下
     * 任意 20 字节成员键，upperBound = lowerBound.successor() 严格大于全部成员键，故半开覆盖该会话该
     * 命名空间的全部消息。limit <= 0 表示不限条数。结果天然按键字节序（== 时间序）升序。
     */
    public func messagesForPeer(peerId: Int64, namespace: Int32, limit: Int64): Array<IntermediateMessage> {
        let lower = MessageIndex.lowerBound(peerId: peerId, namespace: namespace)
        let upper = MessageIndex.upperBound(peerId: peerId, namespace: namespace)
        let collected = ArrayList<IntermediateMessage>()
        this.valueBox.rangeValues(this.table, lower, upper, limit, { _, v =>
            collected.add(MessageHistoryTable.decodeValue(v))
            return true
        })
        return MessageHistoryTable.toArray(collected)
    }

    /**
     * 取该 (peerId, namespace) 区间内、键严格 < fromIndex.key() 的、最靠近 fromIndex 的 count 条消息，
     * 按时间正序返回（对应 iOS earlierEntries：以某 index 为界向「更早」方向取 count）。
     *
     * 用降序 range(start=fromIndex.key(), end=lowerBound)：start > end 触发降序，开-开区间
     * (lowerBound, fromIndex.key()) 即 `key > lowerBound AND key < fromIndex.key()`，恰好排除 fromIndex
     * 自身（开边界）、并从紧邻 fromIndex 的更早一条往更早方向降序取 count 条 —— 这正是「最靠近的 count 条」。
     * 降序拿到的顺序是「由近到远」，需反转回「时间正序（由远到近）」后返回。count <= 0 返回空。
     */
    public func earlierMessages(peerId: Int64, namespace: Int32, fromIndex: MessageIndex,
        count: Int64): Array<IntermediateMessage> {
        if (count <= 0) {
            return Array<IntermediateMessage>(0, { _ => IntermediateMessage() })
        }
        let lower = MessageIndex.lowerBound(peerId: peerId, namespace: namespace)
        let start = fromIndex.key()
        // 降序收集（由近到远）
        let collected = ArrayList<IntermediateMessage>()
        this.valueBox.rangeValues(this.table, start, lower, count, { _, v =>
            collected.add(MessageHistoryTable.decodeValue(v))
            return true
        })
        // 反转为时间正序（由远到近）
        let arr = MessageHistoryTable.toArray(collected)
        arr.reverse()
        return arr
    }

    /**
     * 取该 (peerId, namespace) 区间内、键严格 > fromIndex.key() 的、最靠近 fromIndex 的 count 条消息，
     * 按时间正序返回（对应 iOS laterEntries：以某 index 为界向「更晚」方向取 count）。
     *
     * 用升序 range(start=fromIndex.key(), end=upperBound)：start < end 触发升序，开-开区间
     * (fromIndex.key(), upperBound) 即 `key > fromIndex.key() AND key < upperBound`，排除 fromIndex 自身、
     * 从紧邻 fromIndex 的更晚一条往更晚方向升序取 count 条。升序天然即「时间正序」，直接返回。count <= 0 返回空。
     */
    public func laterMessages(peerId: Int64, namespace: Int32, fromIndex: MessageIndex,
        count: Int64): Array<IntermediateMessage> {
        if (count <= 0) {
            return Array<IntermediateMessage>(0, { _ => IntermediateMessage() })
        }
        let upper = MessageIndex.upperBound(peerId: peerId, namespace: namespace)
        let start = fromIndex.key()
        let collected = ArrayList<IntermediateMessage>()
        this.valueBox.rangeValues(this.table, start, upper, count, { _, v =>
            collected.add(MessageHistoryTable.decodeValue(v))
            return true
        })
        return MessageHistoryTable.toArray(collected)
    }

    /**
     * 围绕 (peerId, namespace, id) 取一个时间序连续窗口（对应 iOS getMessagesAround）。
     *
     * 窗口语义（固定）：以中心消息为锚，取「中心之前 floor(count/2) 条 + 中心本身 + 中心之后
     * (count - floor(count/2) - 1) 条」，合并后按时间正序去重返回。窗口总条数 <= count（边界不足时变短）。
     *   - count=4 → 中心前 2 条 + 中心 + 后 1 条（floor(4/2)=2 早侧，4-2-1=1 晚侧）。
     *   - count=5 → 中心前 2 条 + 中心 + 后 2 条。
     * 这与 iOS getMessagesAround「aroundIndex 居中、上下大致均分」的语义对齐（iOS 同样把剩余名额偏向更晚侧）。
     *
     * 中心降级：若 (peer,ns,id) 当前不存在（已删/未达），无法定位锚点，则降级为「该会话该命名空间最近
     * count 条」（降序取 count 后反转回时间正序），保证调用方仍能拿到一页可用历史。
     *
     * 去重：earlier(<中心) / 中心 / later(>中心) 三段按键天然不相交，这里仍以键字节序 description() 做集合去重，
     * 防止任何边界重叠（belt-and-suspenders），并保证最终按时间正序输出。
     */
    public func getMessagesAround(peerId: Int64, namespace: Int32, id: Int32,
        count: Int64): Array<IntermediateMessage> {
        if (count <= 0) {
            return Array<IntermediateMessage>(0, { _ => IntermediateMessage() })
        }
        match (this.getMessage(peerId, namespace, id)) {
            case Some(center) =>
                let centerIndex = MessageHistoryTable.indexOf(center)
                let earlyCount = count / 2
                let lateCount = count - earlyCount - 1
                let earlier = this.earlierMessages(peerId, namespace, centerIndex, earlyCount)
                let later = this.laterMessages(peerId, namespace, centerIndex, lateCount)
                // 合并：earlier(时间正序) + 中心 + later(时间正序)，按键去重。
                let seen = HashSet<String>()
                let merged = ArrayList<IntermediateMessage>()
                for (m in earlier) {
                    MessageHistoryTable.addUnique(merged, seen, m)
                }
                MessageHistoryTable.addUnique(merged, seen, center)
                for (m in later) {
                    MessageHistoryTable.addUnique(merged, seen, m)
                }
                return MessageHistoryTable.toArray(merged)
            case None =>
                // 降级：取该会话该命名空间最近 count 条（降序后反转回时间正序）。
                let lower = MessageIndex.lowerBound(peerId: peerId, namespace: namespace)
                let upper = MessageIndex.upperBound(peerId: peerId, namespace: namespace)
                let collected = ArrayList<IntermediateMessage>()
                // 降序：start=upper > end=lower，从最晚一条往更早取 count 条。
                this.valueBox.rangeValues(this.table, upper, lower, count, { _, v =>
                    collected.add(MessageHistoryTable.decodeValue(v))
                    return true
                })
                let arr = MessageHistoryTable.toArray(collected)
                arr.reverse()
                return arr
        }
    }

    /**
     * 分页辅助：把收集容器 ArrayList 物化成 Array（保持原顺序）。
     */
    private static func toArray(list: ArrayList<IntermediateMessage>): Array<IntermediateMessage> {
        let n = list.size
        let arr = Array<IntermediateMessage>(n, { _ => IntermediateMessage() })
        for (i in 0..n) {
            arr[i] = list[i]
        }
        return arr
    }

    /**
     * 分页辅助：按消息物理键去重后追加（键已存在则跳过）。
     */
    private static func addUnique(out: ArrayList<IntermediateMessage>, seen: HashSet<String>,
        im: IntermediateMessage): Unit {
        let keyHex = MessageHistoryTable.indexOf(im).key().description()
        if (seen.contains(keyHex)) {
            return
        }
        seen.add(keyHex)
        out.add(im)
    }

    /**
     * 自检（验收项②③④）：需要一个「已 open 的 PostboxDatabase（真实 RDB）」，
     * 因此只在设备 / 集成诊断时显式调用，不在 app 主流程自动运行
     * （与 RdbValueBox.selfCheck / ValueBoxKey.selfCheck 的定位一致）。
     *
     * 用本表（MESSAGE_HISTORY_TABLE_ID）插入 3 条消息，验证：
     *   ② add 3 条后 getMessage(index) 各自取回且字段相等；
     *      getMessage(peer,ns,id)（无 ts 扫描）也能取回；
     *   ③ getMessage 不存在 index 返 None；
     *   ④ removeMessages 后再 get 返 None。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        let peerId: Int64 = 555
        let namespace: Int32 = 2

        // 3 条消息，时间/ id 递增；带 text / authorId / blob 以校验字段往返。
        let m1 = MessageHistoryTable.makeMessage(peerId, namespace, 100, 1000, "first", 11)
        let m2 = MessageHistoryTable.makeMessage(peerId, namespace, 200, 2000, "second 世界", 22)
        let m3 = MessageHistoryTable.makeMessage(peerId, namespace, 300, 3000, "third", 33)
        m2.attributesData = [1u8, 2u8, 3u8]

        let i1 = MessageHistoryTable.indexOf(m1)
        let i2 = MessageHistoryTable.indexOf(m2)
        let i3 = MessageHistoryTable.indexOf(m3)

        // 清场：先删可能残留的 3 条
        this.removeMessages([i1, i2, i3])

        // ② 写入并逐条取回
        this.addMessages([m1, m2, m3])

        match (this.getMessage(i2)) {
            case Some(got) =>
                if (got.peerId != peerId || got.namespace != namespace) { return false }
                if (got.id != 200 || got.timestamp != 2000) { return false }
                if (got.text != "second 世界" || got.authorId != 22) { return false }
                if (got.attributesData.size != 3 || got.attributesData[0] != 1 ||
                    got.attributesData[2] != 3) { return false }
            case None => return false
        }
        match (this.getMessage(i1)) {
            case Some(got) => if (got.id != 100 || got.text != "first") { return false }
            case None => return false
        }
        match (this.getMessage(i3)) {
            case Some(got) => if (got.id != 300 || got.timestamp != 3000) { return false }
            case None => return false
        }

        // ② getMessage(peer, ns, id)（无 ts 扫描）取回 m2
        match (this.getMessage(peerId, namespace, 200)) {
            case Some(got) => if (got.id != 200 || got.text != "second 世界") { return false }
            case None => return false
        }

        // ③ 不存在的 index 返 None（完整 index 与 scan 两路都验）
        let absent = MessageIndex(peerId: peerId, namespace: namespace, timestamp: 9999, id: 999)
        match (this.getMessage(absent)) {
            case Some(_) => return false
            case None => ()
        }
        match (this.getMessage(peerId, namespace, 999)) {
            case Some(_) => return false
            case None => ()
        }

        // ④ removeMessages 后再 get 返 None
        this.removeMessages([i1, i2, i3])
        match (this.getMessage(i2)) {
            case Some(_) => return false
            case None => ()
        }
        match (this.getMessage(peerId, namespace, 200)) {
            case Some(_) => return false
            case None => ()
        }
        if (this.containsMessage(i1)) { return false }

        // ⑤ 分页查询自检（验收项 P2-287d）：另起一个干净的 (peer,ns) 区间，
        //    插入 10 条递增 timestamp 消息（id == timestamp/100，便于断言定位）。
        if (!this.selfCheckPagination()) { return false }

        return true
    }

    /**
     * 分页查询自检（验收项 P2-287d）。插入 10 条递增 timestamp 消息后验证：
     *   - messagesForPeer 返回 10 条且时间正序；
     *   - earlier(from=第6条, count=3) 返回第3/4/5条（时间正序）；
     *   - later(from=第6条, count=3) 返回第7/8/9条（时间正序）；
     *   - getMessagesAround(中心=第5条, count=4) 返回以第5条为中心的连续窗口（第3/4/5/6条）；
     *   - 越界 count 不崩、到边界即止（earlier(from=第1条) / later(from=第10条) 返回空，
     *     count 远大于剩余条数时只返回剩余）。
     * 全部断言通过返回 true。需已 open 的 PostboxDatabase，由 selfCheck 串联调用。
     */
    private func selfCheckPagination(): Bool {
        let peerId: Int64 = 7001
        let namespace: Int32 = 3

        // 构造并清场 10 条：timestamp = 100,200,...,1000；id = 1,2,...,10。
        let msgs = ArrayList<IntermediateMessage>()
        let indices = ArrayList<MessageIndex>()
        for (n in 1..11) {
            let im = MessageHistoryTable.makeMessage(peerId, namespace, Int64(n), Int64(n * 100),
                "msg-${n}", Int64(n))
            msgs.add(im)
            indices.add(MessageHistoryTable.indexOf(im))
        }
        // 清场（避免上一轮残留）
        this.removeMessages(MessageHistoryTable.toIndexArray(indices))

        // 写入 10 条
        this.addMessages(MessageHistoryTable.toArray(msgs))

        // (1) messagesForPeer 返回 10 条且时间正序（id 1..10 递增）
        let all = this.messagesForPeer(peerId, namespace, 0)
        if (all.size != 10) { return false }
        for (i in 0..10) {
            if (all[i].id != Int64(i + 1)) { return false }
            if (all[i].timestamp != Int64((i + 1) * 100)) { return false }
        }

        // limit 截断：messagesForPeer(limit=4) 取最早 4 条（id 1..4）
        let firstFour = this.messagesForPeer(peerId, namespace, 4)
        if (firstFour.size != 4) { return false }
        if (firstFour[0].id != 1 || firstFour[3].id != 4) { return false }

        // (2) earlier(from=第6条, count=3) → 第3/4/5条（时间正序）
        let from6 = indices[5]  // 第6条（id=6）
        let earlier3 = this.earlierMessages(peerId, namespace, from6, 3)
        if (earlier3.size != 3) { return false }
        if (earlier3[0].id != 3 || earlier3[1].id != 4 || earlier3[2].id != 5) { return false }

        // (3) later(from=第6条, count=3) → 第7/8/9条（时间正序）
        let later3 = this.laterMessages(peerId, namespace, from6, 3)
        if (later3.size != 3) { return false }
        if (later3[0].id != 7 || later3[1].id != 8 || later3[2].id != 9) { return false }

        // (4) getMessagesAround(中心=第5条, count=4) → 中心前 2 + 中心 + 后 1 = 第3/4/5/6条
        let around = this.getMessagesAround(peerId, namespace, 5, 4)
        if (around.size != 4) { return false }
        if (around[0].id != 3 || around[1].id != 4 || around[2].id != 5 || around[3].id != 6) {
            return false
        }
        // count=5 → 中心前 2 + 中心 + 后 2 = 第3/4/5/6/7条
        let around5 = this.getMessagesAround(peerId, namespace, 5, 5)
        if (around5.size != 5) { return false }
        if (around5[0].id != 3 || around5[4].id != 7) { return false }

        // (5) 边界：earlier(from=第1条) 返回空；later(from=第10条) 返回空
        let earlierEdge = this.earlierMessages(peerId, namespace, indices[0], 3)
        if (earlierEdge.size != 0) { return false }
        let laterEdge = this.laterMessages(peerId, namespace, indices[9], 3)
        if (laterEdge.size != 0) { return false }

        // 越界 count 不崩、到边界即止：earlier(from=第3条, count=99) 只返回第1/2条
        let earlierClip = this.earlierMessages(peerId, namespace, indices[2], 99)
        if (earlierClip.size != 2) { return false }
        if (earlierClip[0].id != 1 || earlierClip[1].id != 2) { return false }

        // getMessagesAround 中心不存在 → 降级取最近 count 条（id 999 不存在）
        let degraded = this.getMessagesAround(peerId, namespace, 999, 3)
        if (degraded.size != 3) { return false }
        // 最近 3 条 = 第8/9/10条（时间正序）
        if (degraded[0].id != 8 || degraded[1].id != 9 || degraded[2].id != 10) { return false }

        // 清场
        this.removeMessages(MessageHistoryTable.toIndexArray(indices))
        return true
    }

    /**
     * 分页自检辅助：把 MessageIndex 收集容器物化成 Array。
     */
    private static func toIndexArray(list: ArrayList<MessageIndex>): Array<MessageIndex> {
        let n = list.size
        let arr = Array<MessageIndex>(n, { _ =>
            MessageIndex(peerId: 0, namespace: 0, timestamp: 0, id: 0)
        })
        for (i in 0..n) {
            arr[i] = list[i]
        }
        return arr
    }

    /**
     * selfCheck 辅助：构造一条带核心字段的 IntermediateMessage。
     */
    private static func makeMessage(peerId: Int64, namespace: Int32, id: Int64, timestamp: Int64,
        text: String, authorId: Int64): IntermediateMessage {
        let im = IntermediateMessage()
        im.peerId = peerId
        im.namespace = namespace
        im.id = id
        im.timestamp = timestamp
        im.text = text
        im.authorId = authorId
        return im
    }
}
