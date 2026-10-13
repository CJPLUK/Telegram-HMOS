package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList
import std.collection.HashMap

/**
 * 网格消息多选数据层（GridMessageSelectionNode）
 *
 * 管理媒体网格中消息的多选集合：支持 toggle 选中、查询是否选中、获取全部已选 ID、清空选集。
 *
 * 参考 iOS：GridMessageSelectionNode.swift
 *   - 每个 grid cell 维护本地 selected Bool，tap 时调用 toggle 回调
 *   - 选中集合由上层（相册多选控制器）持有
 *
 * 此服务在 Cangjie 侧集中管理整个媒体网格的选集状态，
 * 供 GridMessageSelectionComponent 查询并驱动 UI 渲染。
 */
private var _gridMessageSelectionServiceInstance: Option<GridMessageSelectionService> = None

public func getGridMessageSelectionService(): GridMessageSelectionService {
    match (_gridMessageSelectionServiceInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = GridMessageSelectionService()
            _gridMessageSelectionServiceInstance = Some(inst)
            return inst
    }
}

public class GridMessageSelectionService {

    // 已选中消息 ID 集合（无序，支持 O(n) 查询）
    private var selectedIds: ArrayList<Int64> = ArrayList<Int64>()

    // 选集变更监听回调列表：回调参数为当前已选数量
    private var changeListeners: ArrayList<(Int64) -> Unit> = ArrayList<(Int64) -> Unit>()

    // ───────────────────── 查询 ─────────────────────

    /**
     * 查询指定消息是否处于选中状态
     */
    public func isSelected(msgId: Int64): Bool {
        for (id in this.selectedIds) {
            if (id == msgId) {
                return true
            }
        }
        return false
    }

    /**
     * 返回当前已选消息 ID 快照（ArrayList 副本，调用方可安全持有）
     */
    public func getSelectedIds(): ArrayList<Int64> {
        let copy = ArrayList<Int64>()
        for (id in this.selectedIds) {
            copy.add(id)
        }
        return copy
    }

    /**
     * 当前已选数量
     */
    public func selectedCount(): Int64 {
        return this.selectedIds.size
    }

    // ───────────────────── 变更 ─────────────────────

    /**
     * 切换消息选中状态
     * @return true = 切换后为选中；false = 切换后为未选中
     */
    public func toggleSelection(msgId: Int64): Bool {
        let idx = this.indexOfId(msgId)
        var nowSelected: Bool = false
        if (idx >= 0) {
            this.removeAt(idx)
            nowSelected = false
            Hilog.info(0, "CjTelegram", "[GridMsgSelect] deselected msgId")
        } else {
            this.selectedIds.add(msgId)
            nowSelected = true
            Hilog.info(0, "CjTelegram", "[GridMsgSelect] selected msgId")
        }
        this.notifyListeners()
        return nowSelected
    }

    /**
     * 强制设置消息选中状态（不 toggle，幂等）
     */
    public func setSelected(msgId: Int64, selected: Bool): Unit {
        let idx = this.indexOfId(msgId)
        if (selected && idx < 0) {
            this.selectedIds.add(msgId)
            this.notifyListeners()
        } else if (!selected && idx >= 0) {
            this.removeAt(idx)
            this.notifyListeners()
        }
    }

    /**
     * 清空选集
     */
    public func clearSelection(): Unit {
        if (this.selectedIds.size > 0) {
            this.selectedIds = ArrayList<Int64>()
            this.notifyListeners()
        }
    }

    // ───────────────────── 监听器 ─────────────────────

    /**
     * 注册选集变更监听器（回调参数：当前已选数量）
     */
    public func addChangeListener(listener: (Int64) -> Unit): Unit {
        this.changeListeners.add(listener)
    }

    /**
     * 移除所有监听器（页面离开时调用）
     */
    public func clearListeners(): Unit {
        this.changeListeners = ArrayList<(Int64) -> Unit>()
    }

    // ───────────────────── 私有工具 ─────────────────────

    private func indexOfId(msgId: Int64): Int64 {
        var i: Int64 = 0
        for (id in this.selectedIds) {
            if (id == msgId) {
                return i
            }
            i = i + 1
        }
        return -1
    }

    private func removeAt(idx: Int64): Unit {
        let newList = ArrayList<Int64>()
        var i: Int64 = 0
        for (id in this.selectedIds) {
            if (i != idx) {
                newList.add(id)
            }
            i = i + 1
        }
        this.selectedIds = newList
    }

    private func notifyListeners(): Unit {
        let count = this.selectedIds.size
        for (cb in this.changeListeners) {
            cb(count)
        }
    }
}
