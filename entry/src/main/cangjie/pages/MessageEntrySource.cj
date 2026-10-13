package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import std.collection.ArrayList
import ohos_app_cangjie_entry.models.MessageEntry

/**
 * 聊天消息列表的 LazyForEach 数据源。
 *
 * 背景（2026-09-15 真机 RENDER_MEMORY_OVER_ERROR 被杀的根因）：消息 List 原先用
 * 非懒加载 ForEach 把 displayMessages 全量挂载，每条气泡各带一个 Canvas（GPU 离屏面
 * ≈1MB/条）；上滑分页不断追加历史，GL 内存每屏 +13MB 线性增长到 2.1GB 被系统杀。
 * 对位 iOS ChatHistoryListNode 的节点回收：只实例化可见区 + cachedCount 的条目。
 *
 * 整表替换时发 onDataReloaded；LazyForEach 按 keyGenerator 的键做 diff，与原 ForEach
 * 的键语义一致（身份段 + 内容段，见 ChatRoomPage 的 keyGenerator 注释）。
 */
public class MessageEntrySource <: IDataSource<MessageEntry> {
    private var entries: ArrayList<MessageEntry> = ArrayList<MessageEntry>()
    private var listeners: ArrayList<DataChangeListener> = ArrayList<DataChangeListener>()

    public init() {}

    public func totalCount(): Int64 {
        return this.entries.size
    }

    public func getData(index: Int64): MessageEntry {
        if (index < 0 || index >= this.entries.size) {
            return this.entries[if (this.entries.size > 0) { this.entries.size - 1 } else { 0 }]
        }
        return this.entries[index]
    }

    public func registerDataChangeListener(listener: DataChangeListener): Unit {
        for (existing in this.listeners) {
            if (refEq(existing, listener)) { return }
        }
        this.listeners.add(listener)
    }

    public func unregisterDataChangeListener(listener: DataChangeListener): Unit {
        let kept = ArrayList<DataChangeListener>()
        for (existing in this.listeners) {
            if (!refEq(existing, listener)) { kept.add(existing) }
        }
        this.listeners = kept
    }

    public func setEntries(values: ArrayList<MessageEntry>): Unit {
        this.entries = values
        for (listener in this.listeners) {
            listener.onDataReloaded()
        }
    }
}
