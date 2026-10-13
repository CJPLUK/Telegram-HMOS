package ohos_app_cangjie_entry.core.storage.postbox

import std.collection.ArrayList

/**
 * MessageHistoryHoleIndexTable —— 每个会话的「服务端历史空洞」索引。
 *
 * iOS 标尺：Telegram-iOS/submodules/Postbox/Sources/MessageHistoryHoleIndexTable.swift
 *   iOS 为每个 (peerId, namespace) 记录尚未从服务端取回的 id 区间（hole）。新会话初始整段
 *   1...Int32.max 都是 hole；fetchMessageHistoryHole（TelegramCore/Sources/State/Holes.swift:1038-1143）
 *   每次回包后按 filledRange `transaction.removeHole(...)`。历史视图遇到 hole 就去网络补，
 *   本地只在两个 hole 之间的连续区段里读消息。
 *
 * 本表存的是 hole 的补集——「已填充区间」（闭区间，按 lo 升序、两两不相交且不相邻）。
 * 两种表示等价；存补集的好处是无记录 = 全部是 hole，老库、新会话都不用初始化。
 *
 * 为什么必须有它：本地消息表还会被会话列表的 top message、推送、搜索跳转、日历定位等
 * 路径零散写入。没有 hole 信息时，上翻按「比锚点更早的 N 条」读本地，会越过中间从未取回
 * 的区段，把几个月甚至几年前的零散缓存直接拼在当前位置下面。
 *
 * 键：[peerId:8][namespace:4]（12 字节大端）；value：[count:4] 后接 count 个 [lo:4][hi:4]。
 *
 * MTProto 说明（N/A）：本地持久化索引，不涉及协议编解码。
 */
public class MessageHistoryHoleIndexTable {
    private let table: ValueBoxTable
    private let valueBox: ValueBox

    /** 区间数上限。超出时丢弃最早（id 最小）的区间：丢弃只会让那段重新变成 hole、再去网络补一次，不会读错数据。 */
    private static let MAX_RANGES: Int64 = 256

    public init() {
        this.table = ValueBoxTable(
            id: TableRegistry.MESSAGE_HISTORY_HOLE_INDEX_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = RdbValueBox.getInstance()
    }

    public init(valueBox: ValueBox) {
        this.table = ValueBoxTable(
            id: TableRegistry.MESSAGE_HISTORY_HOLE_INDEX_TABLE_ID,
            keyType: ValueBoxKeyType.BinaryKey
        )
        this.valueBox = valueBox
    }

    private static func key(peerId: Int64, namespace: Int32): ValueBoxKey {
        let k = ValueBoxKey(length: 12)
        k.setInt64(0, peerId)
        k.setInt32(8, namespace)
        return k
    }

    /** 读出该会话的已填充区间（lo 升序）。 */
    public func filledRanges(peerId: Int64, namespace: Int32): ArrayList<(Int32, Int32)> {
        let out = ArrayList<(Int32, Int32)>()
        match (this.valueBox.get(this.table, MessageHistoryHoleIndexTable.key(peerId, namespace))) {
            case Some(bytes) =>
                if (bytes.size < 4) { return out }
                let v = ValueBoxKey(bytes: bytes)
                let count = Int64(v.getInt32(0))
                var i: Int64 = 0
                while (i < count && 4 + (i + 1) * 8 <= bytes.size) {
                    let lo = v.getInt32(4 + i * 8)
                    let hi = v.getInt32(8 + i * 8)
                    out.add((lo, hi))
                    i += 1
                }
            case None => ()
        }
        return out
    }

    private func write(peerId: Int64, namespace: Int32, ranges: ArrayList<(Int32, Int32)>): Unit {
        let k = MessageHistoryHoleIndexTable.key(peerId, namespace)
        if (ranges.isEmpty()) {
            this.valueBox.remove(this.table, k)
            return
        }
        let v = ValueBoxKey(length: 4 + ranges.size * 8)
        v.setInt32(0, Int32(ranges.size))
        var i: Int64 = 0
        while (i < ranges.size) {
            let (lo, hi) = ranges[i]
            v.setInt32(4 + i * 8, lo)
            v.setInt32(8 + i * 8, hi)
            i += 1
        }
        this.valueBox.set(this.table, k, v.toBytes())
    }

    /**
     * 标记 [lo, hi] 已从服务端取回（对应 iOS transaction.removeHole(range: filledRange)）。
     * 与已有区间重叠或相邻（下一段 lo == 本段 hi + 1）即合并。
     */
    public func removeHole(peerId: Int64, namespace: Int32, lo: Int32, hi: Int32): Unit {
        if (lo > hi) { return }
        let ranges = this.filledRanges(peerId, namespace)
        let merged = ArrayList<(Int32, Int32)>()
        var curLo = lo
        var curHi = hi
        var inserted = false
        for ((rLo, rHi) in ranges) {
            if (inserted) {
                merged.add((rLo, rHi))
            } else if (Int64(rHi) + 1 < Int64(curLo)) {
                merged.add((rLo, rHi))
            } else if (Int64(curHi) + 1 < Int64(rLo)) {
                merged.add((curLo, curHi))
                merged.add((rLo, rHi))
                inserted = true
            } else {
                if (rLo < curLo) { curLo = rLo }
                if (rHi > curHi) { curHi = rHi }
            }
        }
        if (!inserted) {
            merged.add((curLo, curHi))
        }
        while (merged.size > MessageHistoryHoleIndexTable.MAX_RANGES) {
            merged.remove(at: 0)
        }
        this.write(peerId, namespace, merged)
    }

    /** 包含 id 的已填充区间；id 落在 hole 里则 None。 */
    public func filledRangeContaining(peerId: Int64, namespace: Int32, id: Int32): Option<(Int32, Int32)> {
        for ((lo, hi) in this.filledRanges(peerId, namespace)) {
            if (lo <= id && id <= hi) {
                return Some((lo, hi))
            }
        }
        return None
    }

    /** 清空该会话的记录（整段重新视为 hole），用于 clear history。 */
    public func clear(peerId: Int64, namespace: Int32): Unit {
        this.valueBox.remove(this.table, MessageHistoryHoleIndexTable.key(peerId, namespace))
    }
}
