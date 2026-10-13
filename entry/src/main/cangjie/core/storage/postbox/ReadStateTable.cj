package ohos_app_cangjie_entry.core.storage.postbox

import std.collection.ArrayList

/**
 * ReadStateTable —— 每会话（peer）的「已读边界 + 未读计数」持久化表。
 *
 * iOS 标尺：
 *   - Telegram-iOS/submodules/Postbox/Sources/MessageHistoryReadStateTable.swift
 *       `tableSpec(id) = ValueBoxTable(id: id, keyType: .int64)` —— 键是 int64 的 peerId
 *       （`key(id) = ValueBoxKey(length: 8).setInt64(0, id.toInt64())`）。
 *       每 peer 存一组 namespace -> PeerReadState；.idBased 分支字段为
 *       maxIncomingReadId / maxOutgoingReadId / maxKnownId / count(=未读) / markedUnread。
 *       applyIncomingMaxReadId：当 maxIncomingReadId < 新 maxReadId（或 markedUnread）时，把
 *       maxIncomingReadId 抬到新值、未读 count 减去 [oldMax+1, newMax] 区间内的未读条数、
 *       清 markedUnread。applyOutgoingMaxReadId：仅当 maxOutgoingReadId < 新值时抬升出向边界。
 *
 * 本单元范围（与 iOS 严格对齐的「持久化子集」）：
 *   - 只做「持久化的已读状态表 + 读写 + 接线」。iOS 的 namespace 维度（每 peer 多 namespace）在
 *     本工程消息模型里未拆分（消息 id 全局单 namespace），故本表 1 peer = 1 PeerReadState（等价
 *     iOS 单 namespace 的退化），键直接是 peerId。这是「最小面、与现有模型对齐」而非裁剪功能：
 *     工程内 markAsRead / unreadCount 链路本就按单 peer 维度运作（见 RealMessageService.markAsRead、
 *     ChatListViewModel.unreadCount）。
 *   - iOS 区间统计回调 incomingStatsInRange（按 message-id 区间精确数未读条数 + 探 holes）依赖
 *     MessageHistoryTable 的逐条索引；本工程当前未在本表层暴露该回调。faithful 简化：applyIncomingRead
 *     把读边界推进到/越过 maxIncomingReadId 时，视作「读到该边界即清空该会话未读」（unreadCount=0）、
 *     并清 markedUnread —— 与 iOS「读到 topMessageId 时未读归零」的收敛终态一致，是 iOS 行为在缺少
 *     逐条 holes 信息时的保守正确退化（不会少清、也不会把已读重新算成未读）。
 *
 * 依赖底座（已合入 master）：
 *   - ValueBox.cj / RdbValueBox.cj —— ValueBoxTable + get/set/remove/scan（KV 引擎）。
 *   - ValueBoxKey.cj               —— 8 字节大端键 setInt64/getInt64。
 *   - PostboxCoding.cj             —— PostboxEncoder / PostboxDecoder（字段级标量编解码）。
 *   - TableRegistry.cj             —— READ_STATE_TABLE_ID = 104 + schema checkTable。
 *
 * 表封装范式严格复用 PeerTable.cj（Int64Key 表：键=peerId 的 8 字节大端 ValueBoxKey，值=
 *   PostboxEncoder 编码字节）。totalUnreadCount 走 valueBox.scan 全表求和，计数载体用一个 `let`
 *   ArrayList（引用被闭包捕获、内容可变；KB「闭包不得捕获本地 var」约束下的标准范式，与
 *   PeerTable.getAllPeers 一致）。
 *
 * MTProto 说明（N/A）：本地持久化已读状态表，不涉及 MTProto 协议。
 */

/**
 * PeerReadState —— 单会话已读状态值类型（对应 iOS PeerReadState .idBased 分支字段子集）。
 *
 * - maxIncomingReadId：已读到的「最大入向（对方发来）消息 id」边界。
 * - maxOutgoingReadId：对方已读到的「最大出向（我发出）消息 id」边界（用于「已送达/已读」回执）。
 * - unreadCount      ：当前会话未读条数（对应 iOS PeerReadState.count）。
 * - markedUnread     ：用户手动标「未读」标志（即便 unreadCount==0 也在列表显示未读点）。
 *
 * 用 class（与工程内 IntermediatePeer / models 纯数据类风格一致；落盘项需可变字段聚合）。
 * encode(PostboxEncoder) / static decode(PostboxDecoder) 与底座编解码层对称；缺字段 decode
 * 回落默认值（向后兼容旧库）。
 */
public class PeerReadState {
    public var maxIncomingReadId: Int32
    public var maxOutgoingReadId: Int32
    public var unreadCount: Int32
    public var markedUnread: Bool

    public init(
        maxIncomingReadId!: Int32 = 0,
        maxOutgoingReadId!: Int32 = 0,
        unreadCount!: Int32 = 0,
        markedUnread!: Bool = false
    ) {
        this.maxIncomingReadId = maxIncomingReadId
        this.maxOutgoingReadId = maxOutgoingReadId
        this.unreadCount = unreadCount
        this.markedUnread = markedUnread
    }

    /**
     * 编码到 PostboxEncoder（字段级标量编解码）。字段 key 用短稳定串，与 decode 对称。
     */
    public func encode(encoder: PostboxEncoder): Unit {
        encoder.encodeInt32(this.maxIncomingReadId, key: "mi")
        encoder.encodeInt32(this.maxOutgoingReadId, key: "mo")
        encoder.encodeInt32(this.unreadCount, key: "uc")
        encoder.encodeBool(this.markedUnread, key: "mu")
    }

    /**
     * 从 PostboxDecoder 还原（与 encode 严格对称）；缺字段回落默认值，向后兼容旧库。
     */
    public static func decode(decoder: PostboxDecoder): PeerReadState {
        let mi = decoder.decodeInt32("mi", orElse: 0)
        let mo = decoder.decodeInt32("mo", orElse: 0)
        let uc = decoder.decodeInt32("uc", orElse: 0)
        let mu = decoder.decodeBool("mu", orElse: false)
        return PeerReadState(
            maxIncomingReadId: mi,
            maxOutgoingReadId: mo,
            unreadCount: uc,
            markedUnread: mu
        )
    }
}

/**
 * ReadStateTable —— 已读状态表（持有 ValueBoxTable(READ_STATE_TABLE_ID, Int64Key) + ValueBox）。
 *
 * 键 = peerId 的 8 字节大端 ValueBoxKey（Int64Key 表，底层 INTEGER 主键，对齐 iOS .int64 键）。
 * 值 = PeerReadState 的 PostboxEncoder 编码字节。
 */
public class ReadStateTable {
    // 本表逻辑描述符：int64 键（peerId），值是 BLOB。
    private let table: ValueBoxTable
    // 底层通用 KV 引擎（与 PostboxDatabase 同一 RDB 连接）。
    private let valueBox: ValueBox

    /**
     * 用进程内单例 ValueBox（RdbValueBox）构造（推荐路径）。
     */
    public init() {
        this.table = ValueBoxTable(
            id: TableRegistry.READ_STATE_TABLE_ID,
            keyType: ValueBoxKeyType.Int64Key
        )
        this.valueBox = RdbValueBox.getInstance()
    }

    /**
     * 注入式构造（测试 / 自定义 ValueBox 实现时使用）。
     */
    public init(valueBox: ValueBox) {
        this.table = ValueBoxTable(
            id: TableRegistry.READ_STATE_TABLE_ID,
            keyType: ValueBoxKeyType.Int64Key
        )
        this.valueBox = valueBox
    }

    /**
     * 把 peerId 编码成 8 字节大端键（对应 iOS ReadStateTable.key(_:)：
     *   `ValueBoxKey(length: 8).setInt64(0, peerId)`）。
     */
    private static func keyForPeer(peerId: Int64): ValueBoxKey {
        let k = ValueBoxKey(length: 8)
        k.setInt64(0, peerId)
        return k
    }

    private static func encodeValue(state: PeerReadState): Array<Byte> {
        let encoder = PostboxEncoder()
        state.encode(encoder)
        return encoder.makeBytes()
    }

    private static func decodeValue(bytes: Array<Byte>): PeerReadState {
        return PeerReadState.decode(PostboxDecoder(bytes))
    }

    // ==================== 基础读写 ====================

    /**
     * 写入 / 覆盖某会话的已读状态（对应 iOS resetStates + beforeCommit 落库）。
     * 键 = keyForPeer(peerId)；值 = encode(state)。INSERT OR REPLACE 语义：同 peerId 覆盖。
     */
    public func setReadState(peerId: Int64, state: PeerReadState): Unit {
        let key = ReadStateTable.keyForPeer(peerId)
        let value = ReadStateTable.encodeValue(state)
        this.valueBox.set(this.table, key, value)
    }

    /**
     * 按 peerId 取某会话已读状态（对应 iOS get）。命中 Some，未命中 None。
     */
    public func getReadState(peerId: Int64): Option<PeerReadState> {
        let key = ReadStateTable.keyForPeer(peerId)
        match (this.valueBox.get(this.table, key)) {
            case Some(bytes) => return Some(ReadStateTable.decodeValue(bytes))
            case None => return None
        }
    }

    /**
     * 按 peerId 删除某会话已读状态。不存在的键 remove 无副作用。
     */
    public func removeReadState(peerId: Int64): Unit {
        this.valueBox.remove(this.table, ReadStateTable.keyForPeer(peerId))
    }

    // ==================== 便捷更新 ====================

    /**
     * 应用入向已读（用户读到 maxReadId；对应 iOS applyIncomingMaxReadId）。
     *
     * 语义（faithful 简化，见文件头说明）：
     *   - 仅当新边界推进（maxReadId > maxIncomingReadId）或当前 markedUnread 时才更新；否则 no-op。
     *   - 更新：maxIncomingReadId 抬到 max(旧值, maxReadId)；既然用户读到了该边界，本会话未读清零
     *     （unreadCount = 0）、清 markedUnread。
     *   - 该会话此前无已读状态记录（getReadState == None）时，新建一条（边界=maxReadId、未读=0、
     *     markedUnread=false）。
     *
     * 不存在的会话也安全：新建后落库。
     */
    public func applyIncomingRead(peerId: Int64, maxReadId: Int32): Unit {
        match (this.getReadState(peerId)) {
            case Some(state) =>
                if (maxReadId > state.maxIncomingReadId || state.markedUnread) {
                    if (maxReadId > state.maxIncomingReadId) {
                        state.maxIncomingReadId = maxReadId
                    }
                    // 读到边界 -> 本会话未读收敛归零、清手动未读标记。
                    state.unreadCount = 0
                    state.markedUnread = false
                    this.setReadState(peerId, state)
                }
            case None =>
                let fresh = PeerReadState(
                    maxIncomingReadId: maxReadId,
                    maxOutgoingReadId: 0,
                    unreadCount: 0,
                    markedUnread: false
                )
                this.setReadState(peerId, fresh)
        }
    }

    /**
     * 应用出向已读（对方读到 maxReadId；对应 iOS applyOutgoingMaxReadId）。
     *
     * 语义：仅当 maxReadId > maxOutgoingReadId 时抬升出向已读边界；不影响未读计数 / markedUnread。
     * 该会话此前无记录时，新建一条（出向边界=maxReadId，其余默认）。
     */
    public func applyOutgoingRead(peerId: Int64, maxReadId: Int32): Unit {
        match (this.getReadState(peerId)) {
            case Some(state) =>
                if (maxReadId > state.maxOutgoingReadId) {
                    state.maxOutgoingReadId = maxReadId
                    this.setReadState(peerId, state)
                }
            case None =>
                let fresh = PeerReadState(
                    maxIncomingReadId: 0,
                    maxOutgoingReadId: maxReadId,
                    unreadCount: 0,
                    markedUnread: false
                )
                this.setReadState(peerId, fresh)
        }
    }

    /**
     * 取某会话未读计数（无记录 -> 0）。
     */
    public func getUnreadCount(peerId: Int64): Int32 {
        match (this.getReadState(peerId)) {
            case Some(state) => return state.unreadCount
            case None => return 0
        }
    }

    /**
     * 全项目未读总数（遍历全表 unreadCount 求和；对应 iOS 各 peer count 求和）。
     *
     * 走 valueBox.scan 全表扫描；求和载体用一个单元素 `let` ArrayList<Int64>（闭包改其内容、引用
     * 不变；KB「闭包不得捕获本地 var」约束下的标准范式，与 PeerTable.getAllPeers 计数器一致）。
     */
    public func totalUnreadCount(): Int32 {
        let acc = ArrayList<Int64>()
        acc.add(0)
        this.valueBox.scan(this.table, { _, v =>
            let state = ReadStateTable.decodeValue(v)
            acc[0] = acc[0] + Int64(state.unreadCount)
            return true
        })
        return Int32(acc[0])
    }

    // ==================== 自检 ====================

    /**
     * 自检（验收项②）：需一个已 open 的真实 RDB，故只在设备 / 集成诊断时显式调用，不在 app 主
     * 流程自动运行（与 PeerTable.selfCheck 定位一致）。
     *
     * 验证：
     *   - setReadState -> getReadState 往返字段相等；
     *   - applyIncomingRead 正确推进 maxIncomingReadId、未读归零、清 markedUnread；
     *   - applyOutgoingRead 抬升出向边界；
     *   - getUnreadCount / totalUnreadCount 求和；
     *   - removeReadState 后 getReadState 返 None。
     * 全部断言通过返回 true，任一不符返回 false。
     */
    public func selfCheck(): Bool {
        let peerA: Int64 = 70001
        let peerB: Int64 = 70002
        let peerC: Int64 = 70003

        // 清场：删上一轮残留。
        this.removeReadState(peerA)
        this.removeReadState(peerB)
        this.removeReadState(peerC)

        // setReadState -> getReadState 往返。
        let sA = PeerReadState(
            maxIncomingReadId: 100,
            maxOutgoingReadId: 50,
            unreadCount: 7,
            markedUnread: true
        )
        this.setReadState(peerA, sA)
        match (this.getReadState(peerA)) {
            case Some(got) =>
                if (got.maxIncomingReadId != 100) { return false }
                if (got.maxOutgoingReadId != 50) { return false }
                if (got.unreadCount != 7) { return false }
                if (!got.markedUnread) { return false }
            case None => return false
        }

        // getUnreadCount 命中。
        if (this.getUnreadCount(peerA) != 7) { return false }

        // applyIncomingRead 推进边界 -> 未读归零、清 markedUnread。
        this.applyIncomingRead(peerA, 120)
        match (this.getReadState(peerA)) {
            case Some(got) =>
                if (got.maxIncomingReadId != 120) { return false }
                if (got.unreadCount != 0) { return false }
                if (got.markedUnread) { return false }
                if (got.maxOutgoingReadId != 50) { return false }  // 出向边界不受影响
            case None => return false
        }

        // applyIncomingRead 非推进（旧 id 小于当前边界且未 markedUnread）-> no-op。
        this.applyIncomingRead(peerA, 10)
        if (this.getUnreadCount(peerA) != 0) { return false }
        match (this.getReadState(peerA)) {
            case Some(got) => if (got.maxIncomingReadId != 120) { return false }
            case None => return false
        }

        // applyOutgoingRead 抬升出向边界。
        this.applyOutgoingRead(peerA, 80)
        match (this.getReadState(peerA)) {
            case Some(got) =>
                if (got.maxOutgoingReadId != 80) { return false }
                if (got.maxIncomingReadId != 120) { return false }  // 入向不受影响
            case None => return false
        }
        // 非推进的出向已读 -> no-op。
        this.applyOutgoingRead(peerA, 30)
        match (this.getReadState(peerA)) {
            case Some(got) => if (got.maxOutgoingReadId != 80) { return false }
            case None => return false
        }

        // 对无记录会话 applyIncomingRead -> 新建。
        this.applyIncomingRead(peerB, 5)
        match (this.getReadState(peerB)) {
            case Some(got) =>
                if (got.maxIncomingReadId != 5) { return false }
                if (got.unreadCount != 0) { return false }
            case None => return false
        }

        // totalUnreadCount 求和：给 B、C 注入未读后求和。
        this.setReadState(peerB, PeerReadState(maxIncomingReadId: 5, unreadCount: 3))
        this.setReadState(peerC, PeerReadState(maxIncomingReadId: 9, unreadCount: 4))
        // peerA 未读=0、B=3、C=4 -> 总 7。
        if (this.totalUnreadCount() != 7) { return false }

        // removeReadState 后 None；无记录会话 getUnreadCount=0。
        this.removeReadState(peerA)
        match (this.getReadState(peerA)) {
            case Some(_) => return false
            case None => ()
        }
        if (this.getUnreadCount(peerA) != 0) { return false }

        this.removeReadState(peerB)
        this.removeReadState(peerC)
        if (this.totalUnreadCount() != 0) { return false }

        return true
    }
}
