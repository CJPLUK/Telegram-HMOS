package ohos_app_cangjie_entry.core.storage.postbox

import std.collection.ArrayList
import std.collection.HashSet

/**
 * MessageHistoryIndexTable —— 按 (peerId, namespace, id) 无 timestamp 的 per-peer 消息 id 索引表。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/MessageHistoryIndexTable.swift
 *   - 主键 `key(_ id:)` = `[peerId:8][namespace:4][id:4]`（16 字节大端，**无 timestamp**），
 *     与消息主表 MessageHistoryTable 的 20 字节键（含 timestamp）不同：本表用「id 直接定位」，
 *     不必先知道 timestamp。
 *   - value 段在 iOS 是 `[flags:1][timestamp:4]...`；本单元只取「基础 id 索引」职责，value 只存
 *     timestamp(Int32)，供 getTimestamp 反查；iOS 的 flags / Holes 等不在本单元范围。
 *   - `getIndex` / `exists` / `existingNamespaces` 等是其增删查核心入口；本单元落
 *     add / getTimestamp / contains / removeId / idsForPeer 五个基础操作。
 *
 * 用途（为何与 MessageHistoryTable 并存）：
 *   - MessageHistoryTable.getMessage(peer, ns, id)（无 timestamp）目前必须在 (peer,ns) 整个区间
 *     做范围扫描逐条比对 id（O(区间长度)）。本索引表用 (peer,ns,id) 直接键定位（O(log n)），
 *     供「按 id 快速存在性判断 / 取 timestamp」，并为后续分页空洞探测复用。
 *
 * 键字节布局（固定 16 字节，全大端 big-endian，字节字典序 == 逻辑数值序）：
 *
 *     offset  0..7   peerId    (Int64, 8 字节)
 *     offset  8..11  namespace (Int32, 4 字节)
 *     offset 12..15  id        (Int32, 4 字节)
 *
 * 即「字节序」排序优先级为 peerId → namespace → id：同一 (peerId, namespace) 下键按 id 升序，
 * 故 idsForPeer 的范围扫描天然按 id 序枚举（无需内存内再排序）。
 *
 * value 字节布局（4 字节，大端 Int32 timestamp）：复用 ValueBoxKey.setInt32 / getInt32 这套
 *   已验证的大端 Int32 编解码（避免另起 PostboxEncoder：本表 value 只有一个标量 Int32）。
 *
 * MTProto 说明（N/A）：本地持久化二级索引表，不涉及 MTProto 协议。
 */
public class MessageHistoryIndexTable {
    // 本表逻辑描述符：二进制复合键（(peer,ns,id) 16 字节大端键），值是 BLOB。
    private let table: ValueBoxTable
    // 底层通用 KV 引擎（复用进程内单例，与 PostboxDatabase 同一 RDB 连接）。
    private let valueBox: ValueBox

    // ---- 键字节布局常量（与 iOS 8+4+4 对齐；注意比消息主表少了 timestamp 段）----
    private static let OFFSET_PEER_ID: Int64 = 0
    private static let OFFSET_NAMESPACE: Int64 = 8
    private static let OFFSET_ID: Int64 = 12
    private static let KEY_LENGTH: Int64 = 16
    // value：单个大端 Int32 timestamp，4 字节。
    private static let VALUE_LENGTH: Int64 = 4

    /**
     * 用进程内单例 ValueBox（RdbValueBox）构造（推荐路径）。
     * 表描述符固定为 (MESSAGE_HISTORY_INDEX_TABLE_ID, BinaryKey)。
     */
    public init() {
        this.table = ValueBoxTable(
            id: TableRegistry.MESSAGE_HISTORY_INDEX_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = RdbValueBox.getInstance()
    }

    /**
     * 注入式构造（测试 / 自定义 ValueBox 实现时使用）。
     */
    public init(valueBox: ValueBox) {
        this.table = ValueBoxTable(
            id: TableRegistry.MESSAGE_HISTORY_INDEX_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = valueBox
    }

    /**
     * 编码 (peerId, namespace, id) 为 16 字节大端复合键（对应 iOS `key(_ id:)`，但无 timestamp）。
     * [peerId:8][namespace:4][id:4]
     */
    public static func indexKey(peerId: Int64, namespace: Int32, id: Int32): ValueBoxKey {
        let k = ValueBoxKey(length: MessageHistoryIndexTable.KEY_LENGTH)
        k.setInt64(MessageHistoryIndexTable.OFFSET_PEER_ID, peerId)
        k.setInt32(MessageHistoryIndexTable.OFFSET_NAMESPACE, namespace)
        k.setInt32(MessageHistoryIndexTable.OFFSET_ID, id)
        return k
    }

    /**
     * 某 (peerId, namespace) 全部 id 的下界键（填 peerId+namespace 段，长度 12）。
     * 复用 ValueBoxKey「短者为小 + 前缀」语义：长度 12 的前缀键严格小于该 (peer,ns) 下任意
     * 16 字节成员键，故 [lowerBound, upperBound) 半开区间夹住该 (peer,ns) 的全部键。
     */
    private static func lowerBound(peerId: Int64, namespace: Int32): ValueBoxKey {
        let k = ValueBoxKey(length: 12)
        k.setInt64(MessageHistoryIndexTable.OFFSET_PEER_ID, peerId)
        k.setInt32(MessageHistoryIndexTable.OFFSET_NAMESPACE, namespace)
        return k
    }

    /**
     * 某 (peerId, namespace) 全部 id 的上界键 = lowerBound.successor()。
     */
    private static func upperBound(peerId: Int64, namespace: Int32): ValueBoxKey {
        return MessageHistoryIndexTable.lowerBound(peerId, namespace).successor()
    }

    /**
     * 把 timestamp(Int32) 编码成 4 字节大端 value（复用 ValueBoxKey 的大端 Int32 编解码）。
     */
    private static func encodeTimestamp(timestamp: Int32): Array<Byte> {
        let v = ValueBoxKey(length: MessageHistoryIndexTable.VALUE_LENGTH)
        v.setInt32(0, timestamp)
        return v.toBytes()
    }

    /**
     * 把 4 字节大端 value 解回 timestamp(Int32)。容错：若 value 字节不足 4，按缺位返 0
     * （正常写入路径必为 4 字节；防御性兜底，避免越界异常）。
     */
    private static func decodeTimestamp(bytes: Array<Byte>): Int32 {
        if (bytes.size < MessageHistoryIndexTable.VALUE_LENGTH) {
            return 0
        }
        let v = ValueBoxKey(bytes: bytes)
        return v.getInt32(0)
    }

    /**
     * 写入 / 覆盖一条 id 索引（对应 iOS justInsertMessage 写索引项的子集）。
     * key = (peer,ns,id) 16 字节大端键；value = timestamp 的 4 字节大端字节。
     * INSERT OR REPLACE 语义（同键覆盖），与底层 ValueBox.set 一致。
     */
    public func add(peerId: Int64, namespace: Int32, id: Int32, timestamp: Int32): Unit {
        let key = MessageHistoryIndexTable.indexKey(peerId, namespace, id)
        let value = MessageHistoryIndexTable.encodeTimestamp(timestamp)
        this.valueBox.set(this.table, key, value)
    }

    /**
     * 取某 (peer,ns,id) 的 timestamp（对应 iOS getIndex 取 timestamp 段）。
     * 命中返回 Some(timestamp)，未命中返回 None。
     */
    public func getTimestamp(peerId: Int64, namespace: Int32, id: Int32): Option<Int32> {
        let key = MessageHistoryIndexTable.indexKey(peerId, namespace, id)
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) => return Some(MessageHistoryIndexTable.decodeTimestamp(bytes))
            case None => return None
        }
    }

    /**
     * 某 (peer,ns,id) 是否存在（对应 iOS exists）。
     */
    public func contains(peerId: Int64, namespace: Int32, id: Int32): Bool {
        let key = MessageHistoryIndexTable.indexKey(peerId, namespace, id)
        return this.valueBox.exists(this.table, key)
    }

    /**
     * 删除一条 id 索引（对应 iOS justRemove 删索引项的子集）。
     * 不存在的键 remove 无副作用（与底层 ValueBox.remove 一致）。
     */
    public func removeId(peerId: Int64, namespace: Int32, id: Int32): Unit {
        let key = MessageHistoryIndexTable.indexKey(peerId, namespace, id)
        this.valueBox.remove(this.table, key)
    }

    /**
     * 按「账号全局」消息 id 反查索引项（对应 iOS messageIdsForGlobalIds：user / 基础群的云消息 id
     * 在账号内唯一，updateDeleteMessages 只带 id 不带 peer）。
     *
     * 全表扫描索引键（16 字节键 + 4 字节 timestamp，远小于消息主表），只保留
     * namespace == ns、id ∈ ids、且 peerFilter(peerId) 为真的项。
     * 返回 (peerId, id, timestamp) 三元组，供调用方精确删除主表行与本索引项。
     */
    public func entriesForGlobalIds(namespace: Int32, ids: HashSet<Int32>,
        peerFilter: (Int64) -> Bool): ArrayList<(Int64, Int32, Int32)> {
        let found = ArrayList<(Int64, Int32, Int32)>()
        if (ids.isEmpty()) { return found }
        this.valueBox.scan(this.table, { k, v =>
            if (k.length() == MessageHistoryIndexTable.KEY_LENGTH) {
                let id = k.getInt32(MessageHistoryIndexTable.OFFSET_ID)
                if (ids.contains(id) && k.getInt32(MessageHistoryIndexTable.OFFSET_NAMESPACE) == namespace) {
                    let peerId = k.getInt64(MessageHistoryIndexTable.OFFSET_PEER_ID)
                    if (peerFilter(peerId)) {
                        found.add((peerId, id, MessageHistoryIndexTable.decodeTimestamp(v)))
                    }
                }
            }
            return true
        })
        return found
    }

    /**
     * 枚举某 (peerId, namespace) 下全部已存 id，按 id 升序返回
     * （对应 iOS debugList / 区间枚举，但只取 id）。
     *
     * 升序扫描开-开区间 (lowerBound, upperBound)：lowerBound（12 字节前缀）严格小于该 (peer,ns) 下
     * 任意 16 字节成员键，upperBound = lowerBound.successor() 严格大于全部成员键，半开覆盖该
     * (peer,ns) 的全部键。键字节序 peerId→namespace→id，故扫描天然按 id 升序。
     *
     * 收集范式（KB「闭包只捕获 let 容器」约束）：结果收进一个 `let` ArrayList（引用被闭包捕获、
     * 内容可变），回调恒返回 true（不限条数），与 MessageHistoryTable.messagesForPeer 一致。
     */
    public func idsForPeer(peerId: Int64, namespace: Int32): Array<Int32> {
        let lower = MessageHistoryIndexTable.lowerBound(peerId, namespace)
        let upper = MessageHistoryIndexTable.upperBound(peerId, namespace)
        let collected = ArrayList<Int32>()
        this.valueBox.range(this.table, lower, upper, 0, { k =>
            let id = k.getInt32(MessageHistoryIndexTable.OFFSET_ID)
            collected.add(id)
            return true
        })
        let n = collected.size
        let arr = Array<Int32>(n, { _ => 0 })
        for (i in 0..n) {
            arr[i] = collected[i]
        }
        return arr
    }

    /**
     * 自检（验收项②③④⑤）：需要一个「已 open 的 PostboxDatabase（真实 RDB）」，
     * 因此只在设备 / 集成诊断时显式调用，不在 app 主流程自动运行
     * （与 MessageHistoryTable.selfCheck / ValueBoxKey.selfCheck 的定位一致）。
     *
     * 验证：
     *   ② add 后 contains 真 + getTimestamp 取回写入值；
     *   ③ 同 peer 多 namespace / 多 id 各自独立（不串扰）；
     *   ④ removeId 后 contains 假 + getTimestamp None；
     *   ⑤ idsForPeer 按 id 升序枚举到该 (peer,ns) 的全部已存 id。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        let peerId: Int64 = 9001
        let nsA: Int32 = 1
        let nsB: Int32 = 2

        // 清场（避免上一轮残留）
        this.removeId(peerId, nsA, 10)
        this.removeId(peerId, nsA, 20)
        this.removeId(peerId, nsA, 30)
        this.removeId(peerId, nsB, 10)

        // ② add 后 contains 真 + getTimestamp 取回写入值（含乱序插入，验证排序与 id 无关）
        this.add(peerId, nsA, 30, 3000)
        this.add(peerId, nsA, 10, 1000)
        this.add(peerId, nsA, 20, 2000)
        // ③ 同 peer 不同 namespace 独立：nsB 也存一个 id=10，但 timestamp 不同
        this.add(peerId, nsB, 10, 9999)

        if (!this.contains(peerId, nsA, 10)) { return false }
        if (!this.contains(peerId, nsA, 20)) { return false }
        if (!this.contains(peerId, nsA, 30)) { return false }
        if (!this.contains(peerId, nsB, 10)) { return false }

        match (this.getTimestamp(peerId, nsA, 10)) {
            case Some(ts) => if (ts != 1000) { return false }
            case None => return false
        }
        match (this.getTimestamp(peerId, nsA, 30)) {
            case Some(ts) => if (ts != 3000) { return false }
            case None => return false
        }
        // ③ nsB 的 id=10 取回 9999（与 nsA 的 id=10 互不串扰）
        match (this.getTimestamp(peerId, nsB, 10)) {
            case Some(ts) => if (ts != 9999) { return false }
            case None => return false
        }

        // 未命中 id 返 None / contains 假
        if (this.contains(peerId, nsA, 999)) { return false }
        match (this.getTimestamp(peerId, nsA, 999)) {
            case Some(_) => return false
            case None => ()
        }

        // ⑤ idsForPeer(nsA) 按 id 升序枚举到全部已存 id（10,20,30），且不含 nsB 的 id
        let idsA = this.idsForPeer(peerId, nsA)
        if (idsA.size != 3) { return false }
        if (idsA[0] != 10 || idsA[1] != 20 || idsA[2] != 30) { return false }
        // nsB 区间只含 id=10
        let idsB = this.idsForPeer(peerId, nsB)
        if (idsB.size != 1 || idsB[0] != 10) { return false }

        // ④ removeId 后 contains 假 + getTimestamp None，且 idsForPeer 不再枚举到
        this.removeId(peerId, nsA, 20)
        if (this.contains(peerId, nsA, 20)) { return false }
        match (this.getTimestamp(peerId, nsA, 20)) {
            case Some(_) => return false
            case None => ()
        }
        let idsAfterRemove = this.idsForPeer(peerId, nsA)
        if (idsAfterRemove.size != 2) { return false }
        if (idsAfterRemove[0] != 10 || idsAfterRemove[1] != 30) { return false }

        // 清场
        this.removeId(peerId, nsA, 10)
        this.removeId(peerId, nsA, 30)
        this.removeId(peerId, nsB, 10)
        // 清场后该 (peer,ns) 区间应为空
        if (this.idsForPeer(peerId, nsA).size != 0) { return false }

        return true
    }
}
