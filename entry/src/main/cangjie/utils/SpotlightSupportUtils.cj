package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{
    getSpotlightSupportBinding,
    SpotlightItem,
    SpotlightSupportBinding
}
import std.collection.ArrayList

/**
 * SpotlightSupportUtils — Spotlight 搜索上层工具接口
 *
 * 对应 Telegram-iOS SpotlightSupport.swift 公开 API：
 *   indexConversation / deindexConversation / deindexAllConversations
 *
 * 提供：
 * - indexConversation: 将单个会话索引（id + title + peers/keywords）
 * - indexConversations: 批量索引会话列表
 * - deindexConversation: 从索引移除单个会话
 * - deindexConversations: 批量移除
 * - deindexAllConversations: 清空所有会话索引
 * - searchLocalIndex: 按关键词本地搜索
 * - getIndexedCount: 获取当前已索引条目数
 * - buildSpotlightItem: 构建 SpotlightItem（供调用方自定义条目）
 *
 * 平台说明：
 *   系统级 Spotlight 搜索在 HarmonyOS 上无对应 API（deferred platform gap）。
 *   本地索引（内存）完整可用，searchLocalIndex 可在应用内实现会话搜索。
 */

/** 会话类型的领域标识符，对应 iOS CSSearchableItem domainIdentifier */
public let SPOTLIGHT_DOMAIN_CONVERSATION: String = "telegram.conversation"

/**
 * 将单个会话索引到本地 Spotlight 索引
 * 对应 iOS SpotlightSupport.indexConversation(id:title:peerNames:)
 *
 * @param conversationId  会话 ID（唯一标识，如 peer ID 字符串形式）
 * @param title           会话标题（对方名称或群名）
 * @param peerNames       参与者名称列表（作为搜索关键词）
 * @return 成功加入本地索引则返回 true
 */
public func indexConversation(conversationId: String, title: String, peerNames: Array<String>): Bool {
    if (conversationId.size == 0) {
        return false
    }
    let keywords = buildKeywords(title, peerNames)
    let item = SpotlightItem(
        conversationConvertToUniqueId(conversationId),
        title,
        buildContentDescription(title, peerNames),
        keywords,
        SPOTLIGHT_DOMAIN_CONVERSATION
    )
    let added = getSpotlightSupportBinding().indexItems(Array<SpotlightItem>(1, repeat: item))
    return added > 0
}

/**
 * 批量索引会话列表
 * @param items 形如 (conversationId, title, peerNames) 的元素，由调用方用 buildConversationItems 构造
 * @return 成功加入本地索引的条目数
 */
public func indexConversations(items: Array<SpotlightItem>): Int64 {
    return getSpotlightSupportBinding().indexItems(items)
}

/**
 * 从本地 Spotlight 索引移除单个会话
 * 对应 iOS SpotlightSupport.deindexConversation(id:)
 *
 * @param conversationId 会话 ID
 * @return 是否实际移除（若原本未索引则返回 false）
 */
public func deindexConversation(conversationId: String): Bool {
    if (conversationId.size == 0) {
        return false
    }
    let uid = conversationConvertToUniqueId(conversationId)
    let removed = getSpotlightSupportBinding().deindexItems(Array<String>(1, repeat: uid))
    return removed > 0
}

/**
 * 批量从本地 Spotlight 索引移除会话
 * @param conversationIds 会话 ID 列表
 * @return 实际移除数量
 */
public func deindexConversations(conversationIds: Array<String>): Int64 {
    let uids = ArrayList<String>()
    var i: Int64 = 0
    while (i < conversationIds.size) {
        if (conversationIds[i].size > 0) {
            uids.add(conversationConvertToUniqueId(conversationIds[i]))
        }
        i = i + 1
    }
    if (uids.size == 0) {
        return 0
    }
    let uidArr = Array<String>(uids.size, { idx: Int64 => uids[idx] })
    return getSpotlightSupportBinding().deindexItems(uidArr)
}

/**
 * 清空本地 Spotlight 索引中的所有会话条目
 * 对应 iOS SpotlightSupport.deindexAllConversations()
 */
public func deindexAllConversations(): Unit {
    getSpotlightSupportBinding().deindexDomain(SPOTLIGHT_DOMAIN_CONVERSATION)
}

/**
 * 清空本地 Spotlight 索引（所有领域）
 */
public func deindexAllSpotlight(): Unit {
    getSpotlightSupportBinding().deindexAll()
}

/**
 * 在本地 Spotlight 索引中按关键词搜索
 * 匹配规则：query 出现在 title / contentDescription / keywords 任一字段中即命中
 *
 * @param query 搜索词（不区分大小写 ASCII）
 * @return 匹配的 SpotlightItem 数组
 */
public func searchLocalIndex(query: String): Array<SpotlightItem> {
    return getSpotlightSupportBinding().searchLocalIndex(query)
}

/**
 * 获取当前已索引的会话条目总数
 * @return 本地 Spotlight 索引中的条目数
 */
public func getIndexedCount(): Int64 {
    return getSpotlightSupportBinding().getIndexedCount()
}

/**
 * 构建 SpotlightItem（供调用方自定义索引条目）
 * @param conversationId 会话 ID
 * @param title          显示标题
 * @param peerNames      参与者名称列表（用于 keywords）
 * @return 已填好字段的 SpotlightItem
 */
public func buildSpotlightItem(conversationId: String, title: String, peerNames: Array<String>): SpotlightItem {
    let keywords = buildKeywords(title, peerNames)
    return SpotlightItem(
        conversationConvertToUniqueId(conversationId),
        title,
        buildContentDescription(title, peerNames),
        keywords,
        SPOTLIGHT_DOMAIN_CONVERSATION
    )
}

// --- 内部辅助函数 ---

/**
 * 将 conversationId 转换为 Spotlight uniqueId 格式
 * 格式: "telegram.conversation.<conversationId>"
 */
private func conversationConvertToUniqueId(conversationId: String): String {
    return SPOTLIGHT_DOMAIN_CONVERSATION + "." + conversationId
}

/**
 * 构建内容描述字符串
 * 若 peerNames 非空则拼接为 "peer1, peer2"；否则使用 title
 */
private func buildContentDescription(title: String, peerNames: Array<String>): String {
    if (peerNames.size == 0) {
        return title
    }
    var desc: String = ""
    var i: Int64 = 0
    while (i < peerNames.size) {
        if (i > 0) {
            desc = desc + ", "
        }
        desc = desc + peerNames[i]
        i = i + 1
    }
    return desc
}

/**
 * 构建关键词数组
 * 包含 title 以及所有 peerNames，去除空字符串
 */
private func buildKeywords(title: String, peerNames: Array<String>): Array<String> {
    let list = ArrayList<String>()
    if (title.size > 0) {
        list.add(title)
    }
    var i: Int64 = 0
    while (i < peerNames.size) {
        if (peerNames[i].size > 0) {
            list.add(peerNames[i])
        }
        i = i + 1
    }
    return Array<String>(list.size, { idx: Int64 => list[idx] })
}
