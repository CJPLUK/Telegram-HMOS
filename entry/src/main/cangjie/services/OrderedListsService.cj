package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import kit.AbilityKit.UIAbilityContext
import std.collection.ArrayList
import std.time.DateTime

/**
 * 有序列表条目 — 对应 iOS OrderedItemListEntry
 * 每个条目携带一个字节序列 ID 和 JSON 序列化的内容字符串
 */
public class OrderedListEntry {
    public var id: String = ""
    public var contents: String = ""
    public var addedAt: Int64 = 0

    public init() {}
}

/**
 * 有序列表操作结果
 */
public class OrderedListResult {
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

/**
 * 有序列表查询结果（含条目列表）
 */
public class OrderedListEntriesResult {
    public var entries: ArrayList<OrderedListEntry> = ArrayList<OrderedListEntry>()
    public var success: Bool = false
    public var errorMessage: String = ""

    public init() {}
}

// Preferences 键名前缀
let ORDERED_LIST_KEY_PREFIX = "ol_"
let ORDERED_LIST_IDS_SUFFIX = "_ids"
let ORDERED_LIST_ENTRY_SUFFIX = "_entry_"
let ORDERED_LIST_ADDED_AT_SUFFIX = "_at_"
let ORDERED_LIST_CONTEXT_NAME = "telegram_ordered_lists"

// 默认最大长度（对应 iOS removeTailIfCountExceeds 缺省值）
let ORDERED_LIST_DEFAULT_MAX_SIZE: Int32 = 200

private var _orderedListsServiceInstance: Option<OrderedListsService> = None

public func getOrderedListsService(): OrderedListsService {
    match (_orderedListsServiceInstance) {
        case Some(s) => s
        case None =>
            let s = OrderedListsService()
            _orderedListsServiceInstance = Some(s)
            s
    }
}

/**
 * 有序列表引擎服务
 *
 * 对应 iOS TelegramEngine.OrderedLists，实现最近优先（prepend）的有序列表
 * CRUD 操作，通过 HarmonyOS Preferences API 持久化存储。
 *
 * iOS 原实现: TelegramEngineOrderedLists.swift
 *   - addOrMoveToFirstPosition → postbox.transaction → addOrMoveToFirstPositionOrderedItemListItem
 *   - clear                   → postbox.transaction → replaceOrderedItemListItems(items: [])
 *   - removeItem              → postbox.transaction → removeOrderedItemListItem
 *
 * HarmonyOS 适配：以 Preferences 持久化替代 Postbox transaction，
 * 保持相同的 collectionId (Int32) + id (String) 二级键寻址语义。
 *
 * 调用链: DataProvider → OrderedListsService → Preferences (persistent storage)
 */
public class OrderedListsService {
    private var preferences: Option<Preferences> = None
    private var initialized: Bool = false

    /**
     * 使用 UIAbilityContext 初始化持久化存储
     * 应在 MainAbility.onWindowStageCreate 中通过 getOrderedListsService().initialize(context) 调用
     */
    public func initialize(context: UIAbilityContext): Unit {
        try {
            let prefs = Preferences.getPreferences(context, ORDERED_LIST_CONTEXT_NAME)
            this.preferences = Some(prefs)
            this.initialized = true
            Hilog.info(0, "CjTelegram", "[OrderedListsSvc] Initialized with Preferences")
        } catch (e: Exception) {
            this.initialized = true
            Hilog.info(0, "CjTelegram", "[OrderedListsSvc] Preferences init failed, memory-only mode")
        }
    }

    public func isInitialized(): Bool {
        return this.initialized
    }

    // ==================== Core Operations ====================

    /**
     * 添加或移动条目到列表首位（最近优先）
     *
     * 对应 iOS: addOrMoveToFirstPosition(collectionId:id:item:removeTailIfCountExceeds:)
     * - 若 id 已存在于列表中，先移除旧位置，再插入到首位
     * - 若 removeTailIfCountExceeds 非空，当列表超过该长度时删除末尾条目
     *
     * @param collectionId 集合标识（如 recentGifs=0, recentStickers=1 等）
     * @param id           条目唯一 ID（iOS 的 MemoryBuffer 在此以字符串表示）
     * @param contents     序列化后的条目内容（JSON 字符串）
     * @param maxCount     超过此数量时裁剪末尾，-1 表示不裁剪
     */
    public func addOrMoveToFirstPosition(
        collectionId: Int32,
        id: String,
        contents: String,
        maxCount!: Int32 = -1
    ): OrderedListResult {
        let result = OrderedListResult()
        Hilog.info(0, "CjTelegram", "[OrderedListsSvc] addOrMoveToFirst colId=${collectionId} id=${id}")

        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let ids = this.loadIds(prefs, collectionId)

                    // 若已存在，先移除旧位置
                    let newIds = ArrayList<String>()
                    newIds.add(id)
                    for (existingId in ids) {
                        if (existingId != id) {
                            newIds.add(existingId)
                        }
                    }

                    // 裁剪超出部分（对应 removeTailIfCountExceeds）
                    let limit: Int32 = if (maxCount > 0) { maxCount } else { ORDERED_LIST_DEFAULT_MAX_SIZE }
                    let finalIds = ArrayList<String>()
                    var cnt: Int32 = 0
                    for (eid in newIds) {
                        if (cnt < limit) {
                            finalIds.add(eid)
                        }
                        cnt = cnt + 1
                    }

                    // 写入 ID 列表和条目内容
                    this.saveIds(prefs, collectionId, finalIds)
                    this.saveEntry(prefs, collectionId, id, contents)
                    prefs.flush()

                    result.success = true
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] addOrMoveToFirst OK, total=${finalIds.size}")
                } catch (e: Exception) {
                    result.errorMessage = "存储失败"
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] addOrMoveToFirst error: ${e}")
                }
            case None =>
                result.errorMessage = "服务未初始化"
        }
        return result
    }

    /**
     * 清空指定集合的所有条目
     *
     * 对应 iOS: clear(collectionId:) → replaceOrderedItemListItems(items: [])
     */
    public func clear(collectionId: Int32): OrderedListResult {
        let result = OrderedListResult()
        Hilog.info(0, "CjTelegram", "[OrderedListsSvc] clear colId=${collectionId}")

        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let ids = this.loadIds(prefs, collectionId)
                    // 删除所有条目的 entry 键
                    for (eid in ids) {
                        let entryKey = this.entryKey(collectionId, eid)
                        let addedAtKey = this.addedAtKey(collectionId, eid)
                        if (prefs.has(entryKey)) { prefs.delete(entryKey) }
                        if (prefs.has(addedAtKey)) { prefs.delete(addedAtKey) }
                    }
                    // 清空 ID 列表
                    let idsKey = this.idsKey(collectionId)
                    if (prefs.has(idsKey)) { prefs.delete(idsKey) }
                    prefs.flush()
                    result.success = true
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] clear OK colId=${collectionId}")
                } catch (e: Exception) {
                    result.errorMessage = "清空失败"
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] clear error: ${e}")
                }
            case None =>
                result.errorMessage = "服务未初始化"
        }
        return result
    }

    /**
     * 移除指定条目
     *
     * 对应 iOS: removeItem(collectionId:id:) → removeOrderedItemListItem
     */
    public func removeItem(collectionId: Int32, id: String): OrderedListResult {
        let result = OrderedListResult()
        Hilog.info(0, "CjTelegram", "[OrderedListsSvc] removeItem colId=${collectionId} id=${id}")

        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let ids = this.loadIds(prefs, collectionId)
                    let newIds = ArrayList<String>()
                    for (eid in ids) {
                        if (eid != id) {
                            newIds.add(eid)
                        }
                    }
                    this.saveIds(prefs, collectionId, newIds)

                    // 删除条目内容
                    let entryKey = this.entryKey(collectionId, id)
                    let addedAtKey = this.addedAtKey(collectionId, id)
                    if (prefs.has(entryKey)) { prefs.delete(entryKey) }
                    if (prefs.has(addedAtKey)) { prefs.delete(addedAtKey) }
                    prefs.flush()
                    result.success = true
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] removeItem OK colId=${collectionId}")
                } catch (e: Exception) {
                    result.errorMessage = "删除失败"
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] removeItem error: ${e}")
                }
            case None =>
                result.errorMessage = "服务未初始化"
        }
        return result
    }

    /**
     * 获取指定集合的所有条目（按最近优先顺序）
     */
    public func getItems(collectionId: Int32): OrderedListEntriesResult {
        let result = OrderedListEntriesResult()

        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let ids = this.loadIds(prefs, collectionId)
                    for (eid in ids) {
                        let contentsKey = this.entryKey(collectionId, eid)
                        let addedAtKey = this.addedAtKey(collectionId, eid)
                        let contents = if (prefs.has(contentsKey)) {
                            let v = prefs.get(contentsKey, PreferencesValueType.StringData(""))
                            match (v) {
                                case PreferencesValueType.StringData(s) => s
                                case _ => ""
                            }
                        } else { "" }
                        let addedAt: Int64 = if (prefs.has(addedAtKey)) {
                            let v = prefs.get(addedAtKey, PreferencesValueType.Integer(0))
                            match (v) {
                                case PreferencesValueType.Integer(n) => n
                                case _ => 0
                            }
                        } else { 0 }
                        let entry = OrderedListEntry()
                        entry.id = eid
                        entry.contents = contents
                        entry.addedAt = addedAt
                        result.entries.add(entry)
                    }
                    result.success = true
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] getItems colId=${collectionId} count=${result.entries.size}")
                } catch (e: Exception) {
                    result.errorMessage = "读取失败"
                    Hilog.info(0, "CjTelegram", "[OrderedListsSvc] getItems error: ${e}")
                }
            case None =>
                result.success = true
        }
        return result
    }

    /**
     * 检查条目是否存在于集合中
     */
    public func contains(collectionId: Int32, id: String): Bool {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let ids = this.loadIds(prefs, collectionId)
                    for (eid in ids) {
                        if (eid == id) { return true }
                    }
                    return false
                } catch (e: Exception) {
                    return false
                }
            case None => return false
        }
    }

    /**
     * 获取集合当前条目数量
     */
    public func count(collectionId: Int32): Int32 {
        match (this.preferences) {
            case Some(prefs) =>
                try {
                    let ids = this.loadIds(prefs, collectionId)
                    return Int32(ids.size)
                } catch (e: Exception) {
                    return 0
                }
            case None => return 0
        }
    }

    // ==================== Storage Helpers ====================

    private func idsKey(collectionId: Int32): String {
        return ORDERED_LIST_KEY_PREFIX + Int64(collectionId).toString() + ORDERED_LIST_IDS_SUFFIX
    }

    private func entryKey(collectionId: Int32, id: String): String {
        return ORDERED_LIST_KEY_PREFIX + Int64(collectionId).toString() + ORDERED_LIST_ENTRY_SUFFIX + id
    }

    private func addedAtKey(collectionId: Int32, id: String): String {
        return ORDERED_LIST_KEY_PREFIX + Int64(collectionId).toString() + ORDERED_LIST_ADDED_AT_SUFFIX + id
    }

    /**
     * 从 Preferences 读取有序 ID 列表（逗号分隔存储）
     */
    private func loadIds(prefs: Preferences, collectionId: Int32): ArrayList<String> {
        let key = this.idsKey(collectionId)
        let ids = ArrayList<String>()
        if (!prefs.has(key)) {
            return ids
        }
        let val = prefs.get(key, PreferencesValueType.StringData(""))
        let raw = match (val) {
            case PreferencesValueType.StringData(s) => s
            case _ => ""
        }
        if (raw.size == 0) {
            return ids
        }
        let parts = raw.split(",")
        for (part in parts) {
            if (part.size > 0) {
                ids.add(part)
            }
        }
        return ids
    }

    /**
     * 将有序 ID 列表写回 Preferences（逗号分隔）
     */
    private func saveIds(prefs: Preferences, collectionId: Int32, ids: ArrayList<String>): Unit {
        let key = this.idsKey(collectionId)
        if (ids.size == 0) {
            if (prefs.has(key)) { prefs.delete(key) }
            return
        }
        var joined = ""
        var first = true
        for (id in ids) {
            if (first) {
                joined = id
                first = false
            } else {
                joined = joined + "," + id
            }
        }
        prefs.put(key, PreferencesValueType.StringData(joined))
    }

    /**
     * 写入单个条目的内容（contents + addedAt timestamp）
     */
    private func saveEntry(prefs: Preferences, collectionId: Int32, id: String, contents: String): Unit {
        let entryKey = this.entryKey(collectionId, id)
        let addedAtKey = this.addedAtKey(collectionId, id)
        prefs.put(entryKey, PreferencesValueType.StringData(contents))
        // 使用当前时间（毫秒级）作为 addedAt，供 UI 展示排序参考
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        prefs.put(addedAtKey, PreferencesValueType.Integer(nowMs))
    }
}
