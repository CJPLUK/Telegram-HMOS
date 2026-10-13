package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog
import std.collection.ArrayList

/**
 * SpotlightSupportBinding — Spotlight 搜索封装层
 *
 * 对应 Telegram-iOS SpotlightSupport.swift (CoreSpotlight)。
 *
 * 平台差异说明：
 *   HarmonyOS 无等效于 iOS CoreSpotlight 的系统级应用内容搜索索引 API。
 *   本实现提供完整的本地索引结构（SpotlightItem 条目构造含 id/title/keywords）
 *   并实现本地内存索引的增删查，系统级索引提交路径为 deferred（平台无此能力）。
 *   HarmonyOS 最接近的能力为 module.json5 shortcuts 静态快捷方式，
 *   不支持动态内容索引，故系统侧提交接口明确标记为 platform_gap。
 *
 * 提供：
 * - indexItems: 将会话条目加入本地索引
 * - deindexItems: 从本地索引移除指定条目
 * - deindexAll: 清空本地索引
 * - searchLocalIndex: 按关键词在本地索引中搜索
 * - getIndexedItems: 获取全部已索引条目
 * - getIndexedCount: 获取已索引数量
 */

private var _spotlightSupportBindingInstance: Option<SpotlightSupportBinding> = None

/**
 * 获取 SpotlightSupportBinding 单例
 */
public func getSpotlightSupportBinding(): SpotlightSupportBinding {
    match (_spotlightSupportBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = SpotlightSupportBinding()
            _spotlightSupportBindingInstance = Some(inst)
            return inst
    }
}

/**
 * Spotlight 可搜索条目
 * 对应 iOS CSSearchableItem + CSSearchableItemAttributeSet
 */
public class SpotlightItem {
    /** 唯一标识符，对应 iOS CSSearchableItem.uniqueIdentifier */
    public var uniqueId: String = ""
    /** 显示标题，对应 iOS CSSearchableItemAttributeSet.title */
    public var title: String = ""
    /** 内容描述，对应 iOS CSSearchableItemAttributeSet.contentDescription */
    public var contentDescription: String = ""
    /** 关键词列表，对应 iOS CSSearchableItemAttributeSet.keywords */
    public var keywords: Array<String> = Array<String>(0, repeat: "")
    /** 领域标识，对应 iOS CSSearchableItem.domainIdentifier */
    public var domainIdentifier: String = ""

    public init() {}

    public init(uniqueId: String, title: String, contentDescription: String,
                keywords: Array<String>, domainIdentifier: String) {
        this.uniqueId = uniqueId
        this.title = title
        this.contentDescription = contentDescription
        this.keywords = keywords
        this.domainIdentifier = domainIdentifier
    }
}

/**
 * Spotlight 搜索绑定层
 *
 * 内部维护一个本地内存索引，实现条目增删查。
 * 系统级索引提交 (CSSearchableIndex.default().indexSearchableItems) 在
 * HarmonyOS 上无对应 API，故 indexItems 在本地索引成功后记录
 * platform_gap 日志而不调用系统接口。
 */
public class SpotlightSupportBinding {
    private var _localIndex: ArrayList<SpotlightItem> = ArrayList<SpotlightItem>()

    /**
     * 将条目加入本地索引
     * 对应 iOS CSSearchableIndex.default().indexSearchableItems(items, completionHandler:)
     *
     * 平台差异：系统侧索引提交 deferred（HarmonyOS 无此 API），
     *           仅在本地内存索引中登记；可被 searchLocalIndex 查询。
     *
     * @param items 待索引条目数组
     * @return 成功加入本地索引的条目数
     */
    public func indexItems(items: Array<SpotlightItem>): Int64 {
        var added: Int64 = 0
        var i: Int64 = 0
        while (i < items.size) {
            let item = items[i]
            if (item.uniqueId.size == 0) {
                i = i + 1
                continue
            }
            // 若已存在则更新，否则追加（对应 iOS 幂等索引语义）
            var found: Bool = false
            var j: Int64 = 0
            while (j < this._localIndex.size) {
                if (this._localIndex[j].uniqueId == item.uniqueId) {
                    this._localIndex[j] = item
                    found = true
                    break
                }
                j = j + 1
            }
            if (!found) {
                this._localIndex.add(item)
            }
            added = added + 1
            i = i + 1
        }
        // platform_gap: HarmonyOS 无系统级内容搜索索引 API，本地索引已更新
        Hilog.info(0, "CjTelegram", "[SpotlightBinding] indexed items (local only, system API N/A on HarmonyOS)")
        return added
    }

    /**
     * 从本地索引移除指定 uniqueId 的条目
     * 对应 iOS CSSearchableIndex.default().deleteSearchableItems(withIdentifiers:completionHandler:)
     *
     * @param identifiers 待移除的 uniqueId 数组
     * @return 实际移除的条目数
     */
    public func deindexItems(identifiers: Array<String>): Int64 {
        var removed: Int64 = 0
        var i: Int64 = 0
        while (i < identifiers.size) {
            let targetId = identifiers[i]
            let newList = ArrayList<SpotlightItem>()
            var j: Int64 = 0
            var found: Bool = false
            while (j < this._localIndex.size) {
                if (this._localIndex[j].uniqueId == targetId) {
                    found = true
                } else {
                    newList.add(this._localIndex[j])
                }
                j = j + 1
            }
            if (found) {
                this._localIndex = newList
                removed = removed + 1
            }
            i = i + 1
        }
        return removed
    }

    /**
     * 按 domain 从本地索引移除所有条目
     * 对应 iOS CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers:completionHandler:)
     *
     * @param domainIdentifier 域标识符
     * @return 实际移除的条目数
     */
    public func deindexDomain(domainIdentifier: String): Int64 {
        let newList = ArrayList<SpotlightItem>()
        var removed: Int64 = 0
        var i: Int64 = 0
        while (i < this._localIndex.size) {
            let item = this._localIndex[i]
            if (item.domainIdentifier == domainIdentifier) {
                removed = removed + 1
            } else {
                newList.add(item)
            }
            i = i + 1
        }
        this._localIndex = newList
        return removed
    }

    /**
     * 清空本地索引
     * 对应 iOS CSSearchableIndex.default().deleteAllSearchableItems(completionHandler:)
     */
    public func deindexAll(): Unit {
        this._localIndex = ArrayList<SpotlightItem>()
        Hilog.info(0, "CjTelegram", "[SpotlightBinding] all items deindexed (local)")
    }

    /**
     * 在本地索引中按关键词搜索
     * 匹配逻辑：query 字符串在 title / contentDescription / keywords 任一字段中出现则命中
     *
     * @param query 搜索词（不区分大小写 ASCII）
     * @return 匹配的条目数组
     */
    public func searchLocalIndex(query: String): Array<SpotlightItem> {
        if (query.size == 0) {
            return this.getIndexedItems()
        }
        let lowerQuery = query.toAsciiLower()
        let results = ArrayList<SpotlightItem>()
        var i: Int64 = 0
        while (i < this._localIndex.size) {
            let item = this._localIndex[i]
            if (spotlightItemMatchesQuery(item, lowerQuery)) {
                results.add(item)
            }
            i = i + 1
        }
        return Array<SpotlightItem>(results.size, { idx: Int64 => results[idx] })
    }

    /**
     * 获取全部已索引条目的快照
     * @return 当前本地索引的完整副本（顺序同添加顺序）
     */
    public func getIndexedItems(): Array<SpotlightItem> {
        let size = this._localIndex.size
        return Array<SpotlightItem>(size, { i: Int64 => this._localIndex[i] })
    }

    /**
     * 获取已索引条目总数
     * @return 本地索引条目数
     */
    public func getIndexedCount(): Int64 {
        return this._localIndex.size
    }
}

/**
 * 判断 SpotlightItem 是否包含给定查询词（ASCII 不区分大小写）
 * query 应已转为小写
 */
private func spotlightItemMatchesQuery(item: SpotlightItem, query: String): Bool {
    if (item.title.toAsciiLower().contains(query)) {
        return true
    }
    if (item.contentDescription.toAsciiLower().contains(query)) {
        return true
    }
    var k: Int64 = 0
    while (k < item.keywords.size) {
        if (item.keywords[k].toAsciiLower().contains(query)) {
            return true
        }
        k = k + 1
    }
    return false
}
