package ohos_app_cangjie_entry.providers

import ohos_app_cangjie_entry.services.{getTelegramEngineItemCacheService, JsonParser, JsonObject}
import std.collection.*

/**
 * ItemCacheDataProvider — 将 ItemCacheService 封装为 UI 友好的数据接口 (feature: telegram_engine_item_cache)
 *
 * 将 API 层的 key-value 缓存转为 ViewModel/UI 可用的接口：
 * - 支持字符串和 JsonObject 的存取
 * - 使用 JsonParser 序列化/反序列化 JSON 数据
 */
public class ItemCacheDataProvider {
    private let cache = getTelegramEngineItemCacheService()

    /**
     * 获取字符串值
     */
    public func getString(key: String): Option<String> {
        return this.cache.get(key)
    }

    /**
     * 存储字符串值
     */
    public func putString(key: String, value: String): Unit {
        this.cache.put(key, value)
    }

    /**
     * 获取 JSON 对象
     * 使用 JsonParser 解析存储的 JSON 字符串
     */
    public func getObject(key: String): Option<JsonObject> {
        match (this.cache.get(key)) {
            case Some(jsonStr) =>
                if (jsonStr.size > 0) {
                    let obj = JsonParser.parseObject(jsonStr)
                    return Some(obj)
                }
                return None
            case None => return None
        }
    }

    /**
     * 存储 JSON 对象
     * 使用 JsonParser.stringify 序列化后存储
     */
    public func putObject(key: String, value: JsonObject): Unit {
        let jsonStr = JsonParser.stringify(value)
        this.cache.put(key, jsonStr)
    }

    /**
     * 删除指定 key
     */
    public func remove(key: String): Unit {
        this.cache.remove(key)
    }

    /**
     * 检查 key 是否存在
     */
    public func has(key: String): Bool {
        return this.cache.has(key)
    }

    /**
     * 清空所有缓存
     */
    public func clear(): Unit {
        this.cache.clear()
    }
}
