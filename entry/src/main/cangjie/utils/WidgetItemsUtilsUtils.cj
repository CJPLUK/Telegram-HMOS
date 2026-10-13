package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.getWidgetItemsUtilsBinding
import ohos_app_cangjie_entry.bindings.WidgetItemData
import std.collection.ArrayList

/**
 * WidgetItemsUtilsUtils — 桌面小组件工具上层调用接口
 *
 * 对应 iOS WidgetItemsUtils.swift 中 WidgetDataPeer.Message 扩展对外提供的能力：
 *   iOS: 把当前对话快照序列化后写入 AppGroup UserDefaults，
 *        供 WidgetKit Extension 直接读取渲染。
 *   HarmonyOS: 本层提供 WidgetItemData（bindings 层数据传输对象）的序列化/
 *              反序列化接口。Preferences 持久化由 services 层（WidgetItemsService）
 *              负责，因为 services 层持有 UIAbilityContext 访问权限。
 *
 * 层次说明：
 *   utils 层位于 bindings 层之上、services 层之下：
 *     bindings → utils → services（services 可以调用 utils，不可反向）
 *   因此本层只提供纯逻辑封装（JSON 序列化/反序列化），
 *   不访问 services 层的 Preferences / MTProto 能力。
 *
 * 典型用法（在 services 层）：
 *   // services 层将 WidgetPeerItem 转为 WidgetItemData 后调用：
 *   let data = widgetPeerItemToData(item)        // services 层本地转换
 *   let json = serializeWidgetItems(dataList)    // 调用本函数
 *   // 然后用 Preferences 持久化 json 字符串
 *
 * S-64/R-69 自查（N/A）：
 *   本文件为纯逻辑工具函数，无 @Component / build() / aboutToAppear，
 *   S-64（aboutToAppear 必须 public）和 R-69（spawn 返回值）均不适用。
 */

/**
 * 将 WidgetItemData 列表序列化为 JSON 字符串
 *
 * 对应 iOS WidgetDataPeer 编码为 JSON 的逻辑（AppGroup 数据格式）。
 * 空列表返回 "[]"。
 *
 * 调用链：serializeWidgetItems(items)
 *   → WidgetItemsUtilsBinding.serializeItems(items)
 *   → 各 item.toJson() 拼接为 JSON 数组字符串
 *
 * @param items  要序列化的 WidgetItemData 条目列表（由调用方从 WidgetPeerItem 转换而来）
 * @return       JSON 数组字符串
 */
public func serializeWidgetItems(items: ArrayList<WidgetItemData>): String {
    return getWidgetItemsUtilsBinding().serializeItems(items)
}

/**
 * 从 JSON 字符串反序列化 WidgetItemData 列表
 *
 * 对应 iOS 读取 AppGroup UserDefaults 后解析 JSON 的逻辑。
 * 解析失败或空输入返回空列表。
 *
 * 调用链：deserializeWidgetItems(json)
 *   → WidgetItemsUtilsBinding.deserializeItems(json)
 *   → splitJsonObjects → parseJsonObject
 *
 * @param json  JSON 数组字符串（由 serializeWidgetItems 产生）
 * @return      解析出的 WidgetItemData 条目列表
 */
public func deserializeWidgetItems(json: String): ArrayList<WidgetItemData> {
    return getWidgetItemsUtilsBinding().deserializeItems(json)
}

/**
 * 将单条 WidgetItemData 序列化为 JSON 对象字符串
 *
 * 对应 WidgetItemData.toJson()，提供顶层函数入口以便调用方不需要持有对象引用。
 *
 * @param item  要序列化的单条条目
 * @return      JSON 对象字符串
 */
public func serializeWidgetItem(item: WidgetItemData): String {
    return item.toJson()
}
